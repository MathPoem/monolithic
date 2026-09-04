# MonoHook

`src/MonoHook.sol` — the MONO/INDEX Uniswap v4 hook. Two jobs: the price accumulator of
HANDBOOK §3.6 and the trade tax of §3.4.
Interface: `src/interfaces/IMonoHook.sol`. Tests: `test/MonoHook.t.sol`.
Rulings implemented here: `MONOHOOK-REVIEW.md` (D24).

## Why both jobs are in one contract

A v4 hook's permissions are encoded in its **address**, and the address is inside the `PoolKey`.
A hook that gains a permission later is a different hook, which means a different pool and a POL
migration. **Anything this hook cannot do on the day it ships, it can never do.** That is why the
tax is here at deploy rather than "added to `_beforeSwap` later", and why the oracle-only version
must never reach mainnet.

## Why the oracle has to exist

§3.6 is `[LAW]`: every trigger reads a TWAP, never spot, computed from the pool's own accumulator,
and "in v4 the accumulator lives in our hook". That is not a preference — **v4 ships no oracle at
all**. `grep -ri observ lib/v4-periphery/lib/v4-core/src` returns nothing; v3's `observe()` has no
v4 counterpart.

## An EMA, not a ring buffer

v3's oracle is an array of `(timestamp, tickCumulative)` samples with a binary search over it. At
τ of 15 minutes a buffer would be perfectly affordable — the sizing argument is **not** what
decides this. Two things do:

- **`grow()` is griefable and someone has to pay it.** Cardinality is a live operational chore
  with no natural owner.
- **It fails closed.** Under-grown, `observe` reverts `OLD` — and the reading that goes dark is
  the *gate*. A price oracle whose failure mode is "the machine stops" is worse than one that
  cannot fail.

An EMA in tick space is one slot, forever, at any horizon, with nothing to grow and nothing to
search. It carries the same information: a time-weighted mean of ticks is a geometric mean of
prices, exactly what `tickCumulative` averages.

The trade, named honestly: an EMA has **no fixed cutoff**. A boxcar TWAP forgets everything older
than its window; an EMA's tail decays but never reaches zero. For a gate, a rate and a strike leg,
"recent matters more, old fades" is the property being bought.

### The three horizons

They are **`tau`, not window widths**: a displacement held `t` seconds moves the reading
`1 - exp(-t/tau)` of the way, so `tau` is the 63% point.

| Horizon | Consumer | τ (D24, final) |
| --- | --- | --- |
| `Strike` | the money path, composed by the caller as `max(spot, strike)` | **1 min** |
| `Throttle` | accrual rate + tap refill | **5 min** |
| `Gate` | the LIVE/PAUSED chatter-damper on the 15% threshold | **15 min** |

D24 collapsed these from day-length windows. Day lengths solved a problem the round structure
already solves: the prize per round is lot-bounded, so every attack must hold a displaced price
across blocks, against arbitrage and tax, for pocket change. The strike window equals the round
length — each round prices at the standing price of its own minute.

Two standing instructions from the ruling:

- **The gate is a chatter-damper, not a security boundary.** Throttle is ≈ 0 at the 15% threshold,
  so there is nothing behind the door to fake open. **Do not add hysteresis.**
- **The strike reference is plain `max(spot, EMA_1m)`.** No band, no crash-skip, no clamp; a ±band
  guard was considered and rejected. At τ = 1 min the EMA converges in ~2 minutes, and a
  pump-at-crank only overpays the vault. **Do not re-add defensively.**

They stay constructor arguments so a re-sim needs no new bytecode. Strictly increasing, or the
constructor reverts `InvalidHorizons`.

## What accrues, and why nothing intra-block does

`beforeSwap` reads the tick the pool is **sitting on** — the price that has stood since
`lastUpdate` — and accrues that over the elapsed seconds. The tick a swap is about to move to has
been true for zero seconds and is worth zero.

So a price pushed and released inside one block contributes **nothing**: the first swap accrues the
pre-push price, the second reaches `dt == 0` and accrues nothing. To move the reading you must hold
the displacement across a block boundary, exposed to arbitrage the whole time. **There is no atomic
path**, which is the load-bearing half of why τ can be minutes rather than hours.
`test_intraBlockSpikeCostsTheOracleNothing` is the check;
`test_heldDisplacementDoesMoveTheReading` is its control, so it cannot pass on a dead oracle.

## Reading

`meanTick(id, horizon)` folds the seconds since `lastUpdate` in before answering, using the same
accrual the next swap will write. So a pool nobody has swapped in hours reads as the price
**actually standing**, and the preview never disagrees with the commit
(`test_readAgreesWithTheNextWrite`). `meanSqrtPriceX96` is the same reading as a `sqrtPriceX96` —
a drop-in for `slot0`'s.

Both revert `NotInitialized` for a pool this hook has never been named by, rather than answering
with tick 0, which would silently mean a price of 1:1.

**`max(spot, strike)` is the caller's job.** The consumer already reads spot and already owns the
orientation and unit conversion; splitting one formula across two contracts would be worse.

## The tax

### A continuous curve, not stepped zones

Stepped mNAV zones put a front-runnable boundary on the chart — a 3× sell-fee jump at 1.5 is worth
nudging a trade across, and it also fails router slippage checks in a burst when it flips. A lerp
between two anchors has no boundary at all:

```
tax(m) = lerp((mStart, rateStart) -> (mEnd, rateEnd)), clamped flat outside both anchors
```

Rates are in **pips** (1e6 = 100%), v4's own fee unit. `m` is mNAV in WAD. Each side is one
storage slot.

**Launch anchors (D24, tunable):**

| Side | anchors | at book | at 2× | at ≥3× |
| --- | --- | --- | --- | --- |
| `sellTax` | 0.5% @ 1.00 → 4.5% @ 3.00 | 0.5% | 2.5% | 4.5% |
| `buyTax` | 2.0% @ 1.00 → 1.5% @ 1.50 | 2.0% | 1.5% | 1.5% |
| **round trip** | | **2.5%** | **4.0%** | **6.0%** |

Sell rises with the premium — the profit-taker at a high premium is the primary NAV engine. Buy
falls, so the vault is cheapest to enter when it most needs entrants. `test_launchAnchorsMatchTheRuling`
pins these against the ruling's own numbers.

### The rate input is spot over book — deliberately not a TWAP

`mNav()` is `spot / Mono.nav()`, both in INDEX per MONO, WAD. NAV comes off **balances**; the
accumulator is not consulted anywhere in the tax path.

That is the right way round. Pushing the price towards a cheaper rate **is** the taxed trade, so
the manipulation pays for itself, while a lagging reference would invent an exploit the live read
does not have. `test_taxReadsNavFromBalancesNotTheOracle` proves the coupling: a donation to the
vault reprices the tax in the same block while the EMA does not move.

**Nothing in the tax path may revert** — a tax that can revert is a pool that can be bricked. Every
input is either bounded by construction or degrades to a rate: an unpriceable vault answers `mNav`
of 0, which clamps both curves to their opening anchor.

### Ceilings governance cannot reach

| | |
| --- | --- |
| `MAX_TAX_PIPS` | 5% per side. Checked on both anchors. Constant. |
| `MIN_VAULT_BIPS` | 50%. The vault's share of the take can never be voted below it. Constant. |
| `mStart < mEnd`, `mStart != 0` | or the lerp divides by zero / runs backwards |

Anchors, the split and the treasury are all settable **behind the timelock** — `queue` / `cancel` /
`execute` with a 2-day notice and a `timelocked` modifier that only `address(this)` satisfies, the
same pattern as [`Index`](Index.md). Numbers adjustable forever; code frozen at deploy.

### Collection: hook-take, not an LP fee

**An LP fee accrues to liquidity providers.** That is harmless while the pool is 100% POL and a
silent siphon the moment it is not, so the hook takes the fee itself, in the **input** token,
whoever is LPing.

Taking the input token needs both return-delta legs, because the input is on a different leg
depending on the swap type:

| Swap | specified currency | fee taken in | where |
| --- | --- | --- | --- |
| exact input | the input | specified leg | `_beforeSwap` |
| exact output | the output — the input amount is not knowable until the swap has run | unspecified leg | `_afterSwap` |

This is the only reason `_afterSwap` exists; the accumulator wants nothing from it.

### Distribution and the crank

Fees accumulate as real ERC-20 on the hook and are paid out by `crank()`, which is permissionless.

| Side | Collected in | Vault share (default 70%) | Treasury (30%) |
| --- | --- | --- | --- |
| Buy | INDEX | transferred to `Mono` — it has no entry point, so this is pure backing and NAV rises | INDEX |
| Sell | MONO | **burned** — supply down, NAV up | MONO |

The vault may never hold MONO `[LAW]`, which is why its share of the sell tax is retired rather
than banked; burning counts as vault-side for the 50% floor. The treasury's MONO share is a natural
source for P11 referral payouts — spent without ever being market-sold.

## Cost

Measured against the identical pair with no hook, both warm (`test_hookOverheadPerSwap`):

| | gas |
| --- | --- |
| swap, no hook | ~85k |
| swap, this hook | ~129k |
| **overhead** | **~44k** |

Roughly 19k of that is the accumulator (one hook call, one `extsload`, one slot write, three
`expWad`s) and the rest is the tax (a `nav()` call, the curve read, and the `take`). The test
asserts `< 60_000` as a regression guard.

`expWad` rather than the cheaper Padé factor `tau / (dt + tau)`: Padé is first-order, so after a
silence it leaves a residual `tau / (dt + tau)` where the truth is `exp(-dt/tau)` — at τ of a
minute, a pool quiet for an hour would still read 1.6% of the way back to an hour-stale price.
`expWad` saturates to 0 past ~41 time constants instead of reverting, which is correct.

**ponytail: the fee is `take`n as real ERC-20 on every taxed swap** rather than minted as an
ERC-6909 claim and settled in the crank. Claims would save perhaps 8k a swap at the cost of an
`unlockCallback` and a second accounting surface; `balanceOf` being the whole ledger is worth more
today. Revisit if swap gas becomes the binding constraint.

## Storage

One slot per pool for the accumulator: `int64` × 3 EMAs (mean tick × `PRECISION = 1e6`) +
`uint32 lastUpdate` + `bool initialized` = 232 bits. A tick maxes at 887272, so a scaled EMA
reaches 8.9e11 — ten million times inside `int64`, resolving a millionth of a tick against a tick
that is already only 1bp. One slot each for `buyTax` and `sellTax`.

`lastUpdate` wraps in 2106, and wraps correctly: modular subtraction still yields the true elapsed
seconds unless a pool sits unswapped for 136 years. Same assumption v3 makes.

## Deploying

A v4 hook's address **is** its permission set, so it has to be mined:

```
AFTER_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
= (1<<12) | (1<<7) | (1<<3) | (1<<6) | (1<<2) = 0x10CC
```

1. deploy `Mono`, genesis-mint to set the opening NAV;
2. mine an address with those flags — `v4-periphery/utils/HookMiner.sol`,
   `HookMiner.find(deployer, flags, creationCode, constructorArgs)`;
3. CREATE2-deploy `MonoHook(poolManager, mono, treasury, 60, 300, 900)` to it. `BaseHook`'s
   constructor asserts the address matches `getHookPermissions`, so a bad mine reverts at deploy;
4. initialize the MONO/INDEX pool with this hook in its `PoolKey`. `afterInitialize` refuses any
   other pair (`WrongPair`) and seeds the accumulator from the opening price.

**Initialise with `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) as `PoolKey.fee`.** Nothing sets a
dynamic fee — the tax is hook-take, not an LP fee — but `updateDynamicLPFee` is gated on the pool
having been *created* dynamic (`PoolManager.sol:340`) and the fee is in the `PoolKey`, so a static
pool can never become one. Free now, a POL migration later. Same argument as the permission bits.

### Routing, unresolved

HANDBOOK:617 chose dynamic LP fees precisely *because* fee-only hooks auto-route on uniswap.org
while "return-delta (custom-curve) hooks need Labs allowlist". D24 overrides that on
LP-siphoning grounds, which is right — but it spends auto-routing. **Confirm the 4663 allowlist is
actually held before this is deployed**, because §3's whole point is that it cannot be changed
after.

## Not this contract

- **The launch ramp is retired.** `afterInitialize` seeding makes readings valid from t = 0, so the
  old `min(elapsed, target)` bootstrap has nothing left to cover. Remove it from any consumer that
  inherited one; there was never one here.
- **Consumer-side (auction), still outstanding:** a permissionless, incentivised crank for the
  rounds, and an **escalator lot-cap that is hardcoded and modest**. The second one matters here:
  "the amount at stake per round is tiny" is the invariant the 1/5/15 τ choice leans on, and
  `GenerousAuction.emissionPerRound` is currently an admin-settable `uint128` with no ceiling —
  `saleSupply` caps the total, not the round. Until that lands, the oracle's security rests on an
  admin's discretion.
- **`Mono` is not wired to this yet.** It still reads the v3 stub `IUniswapV3Pool`. Migrating it
  means `Mono.pool` (an `address`) becomes a `PoolKey`/`PoolId`, `setPool`'s `token0()/token1()`
  check becomes a `currency0/currency1` check that can also pin the hook address, and
  `poolPrice()` / `premiumCloseAmount()` reroute through `StateLibrary` and this hook.
- **`Index._poolPrice` is a separate pile.** Two notes for it, per D24: the stock/USDG pools on
  this chain were found via the **V4Quoter** (a v3 stub may read nothing at all), and the ratified
  D22 veto prefers the **Rialto propAMM `getAmountOut`** as the live-market source. Steer there
  rather than reusing anything here.
