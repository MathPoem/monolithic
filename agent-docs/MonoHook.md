# MonoHook

`src/MonoHook.sol` — the price accumulator of HANDBOOK §3.6, as a Uniswap v4 hook.
Interface: `src/interfaces/IMonoHook.sol`. Tests: `test/MonoHook.t.sol`, `test/MonoHookGas.t.sol`.

## Why it has to exist

§3.6 is `[LAW]`: **every trigger reads a TWAP, never spot**, computed from the pool's own price
accumulator, and "in v4 the accumulator lives in our hook". That is not a stylistic preference —
**v4 ships no oracle at all**. `grep -ri observ lib/v4-periphery/lib/v4-core/src` returns nothing.
v3's `observe()` has no v4 counterpart, so a protocol that wants a TWAP on a v4 pool writes one.

Everything currently reading `slot0` spot is waiting on this: `Mono.poolPrice`, `Mono.premiumBips`
(and therefore `GenerousAuction`'s constructor gate, `src/GenerousAuction.sol:197`), and the §3.4
tax curve, which prices off mNAV.

## An EMA, not a ring buffer

v3's oracle is an array of `(timestamp, tickCumulative)` samples with a binary search over it. It is
the obvious port and it is the wrong one here:

| | v3 ring buffer | this |
| --- | --- | --- |
| storage | one slot per observation, `grow()` to extend | **one slot, forever** |
| 12–24h horizon on a busy pool | thousands of slots, each ~20k gas to initialise | same one slot |
| not grown enough | reverts `OLD` — the gate goes dark | cannot happen |
| read | binary search | one `expWad` |
| horizons | any, if the buffer spans them | three, always available |

The long gate window is what kills the buffer. A 12–24h window on a chain with fast blocks and a
busy pool needs the buffer to span thousands of swaps; whoever pays to grow it pays cold-slot
prices, and if it is ever under-grown the **exercise gate stops reading** rather than reading
badly. An exponential moving average carries the same information — a time-weighted mean of ticks,
so a geometric mean of prices, exactly what `tickCumulative` averages — in fixed storage at any
horizon.

The trade is real and worth naming: the EMA has **no fixed cutoff**. A boxcar TWAP forgets
everything older than its window; an EMA's tail decays but never reaches zero. For the three jobs
in §3.6 — a gate, a rate, a strike leg — "recent matters more, old fades" is the property being
bought, and the sharp cutoff was never load-bearing.

### The three horizons are `tau`, not widths

A displacement held `t` seconds moves the reading `1 - exp(-t/tau)` of the way; `tau` is the 63%
point. HANDBOOK's D17 windows map onto it directly:

| Horizon | Consumer (§3.6) | HANDBOOK window |
| --- | --- | --- |
| `Short` | strike reading, as `max(spot, short)` | FRESH 30–60min |
| `Medium` | accrual rate + tap refill | MEDIUM 1–4h |
| `Long` | exercise gate (≥15%) | LONG 12–24h |

They are **constructor arguments, not constants**, because HANDBOOK marks the exact lengths `[SIM]`.
Strictly increasing or the constructor reverts `InvalidHorizons` — a deployment that transposed two
would read plausibly and gate wrongly.

## What accrues, and why nothing intra-block does

`beforeSwap` reads the tick the pool is **sitting on** — the price that has stood since
`lastUpdate` — and accrues that over the elapsed seconds. The tick a swap is about to move to has
been true for zero seconds and is worth zero.

So a price pushed and released inside one block contributes **nothing**: the first swap accrues the
pre-push price, and the second reaches `dt == 0` and accrues nothing at all. To move this reading
you have to hold the displacement across a block boundary, exposed to arbitrage the whole time,
which is §3.6's stated target property — *no way to influence the machine except by paying it*.
`test_intraBlockSpikeCostsTheOracleNothing` is the check, with
`test_heldDisplacementDoesMoveTheReading` as its control so it cannot pass on a dead oracle.

### There is no `afterSwap`, deliberately

The only tick this contract ever needs is the one standing *before* a swap; between swaps that is
the pool's live tick, which a view reads for itself from `StateLibrary.getSlot0`. An `afterSwap`
leg would cost a second hook call and a stored `lastTick` to record something already knowable —
measured at ~5.4k gas per swap for nothing.

It also leaves `beforeSwap` — the permission the §3.4 tax needs for its dynamic-fee override —
**already claimed**. That matters more than the gas: a v4 hook's permissions are encoded in its
address and the address is inside the `PoolKey`, so a hook that gains a permission later is a
different hook, a different pool, and a POL migration. The tax can be added to `_beforeSwap` in
place.

## Reading

`meanTick(id, horizon)` folds the seconds since `lastUpdate` in before answering, using the same
accrual the next swap will write. Two consequences worth relying on:

- A pool nobody has swapped in hours reads as the price **actually standing**, not as a stale
  average.
- The preview never disagrees with the commit — `test_readAgreesWithTheNextWrite`.

`meanSqrtPriceX96` is the same reading as a `sqrtPriceX96`, so it is a drop-in for `slot0`'s and a
consumer's existing price math changes only in where it reads from.

Both revert `NotInitialized` for a pool this hook has never been named by, rather than answering
with tick 0 — which would silently mean a price of 1:1.

### `max(spot, short)` is the caller's job

D17's strike rule is `NAV + 0.6 * max(spot, shortTWAP)`. That composition is **not** in this
contract: the consumer already reads `slot0` for spot and already owns the orientation and unit
conversion (INDEX per MONO vs the pool's token1/token0). Putting half of it here would split one
formula across two contracts. This hook's one job is the accumulator.

## Cost

Measured against the identical pool with no hook, both warm, in `test/MonoHookGas.t.sol`:

| | gas |
| --- | --- |
| swap, no hook | ~86.7k |
| swap, this hook | ~105.4k |
| **accumulator overhead** | **~18.6k** |

That is one hook call, one `extsload` for the live tick, one cold slot read, one slot write, and
three `expWad`s. For scale, a v3 pool writing a fresh observation slot is ~20k, and it buys one
horizon rather than three. The test asserts `< 25_000` as a regression guard.

`expWad` rather than the cheaper Padé factor `tau / (dt + tau)`: Padé is first-order, so after a
long silence it leaves a residual `tau / (dt + tau)` where the truth is `exp(-dt/tau)` — a pool
untouched for a month would still read 2.4% of the way back to a month-stale price. What a quiet
pool reads is a money input. `expWad` saturates to 0 past ~41 time constants instead of reverting,
which is correct: by then the old reading genuinely is gone.

## Storage

One slot per pool. `int64` × 3 EMAs (mean tick × `PRECISION = 1e6`) + `uint32 lastUpdate` +
`bool initialized` = 232 bits. A tick maxes at 887272, so a scaled EMA reaches 8.9e11 — ten million
times inside `int64`, while resolving a millionth of a tick against a tick that is already only
1bp.

`lastUpdate` wraps in 2106, and wraps correctly: modular subtraction still yields the true elapsed
seconds unless a pool sits unswapped for 136 years. Same assumption v3 makes.

## Deploying

A v4 hook's address **is** its permission set, so it has to be mined:

1. mine an address with `AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG` — `v4-periphery/utils/HookMiner.sol`,
   `HookMiner.find(deployer, flags, creationCode, constructorArgs)`;
2. CREATE2-deploy `MonoHook` to it (`BaseHook`'s constructor asserts the address matches
   `getHookPermissions`, so a bad mine reverts at deploy);
3. initialize the MONO/INDEX pool with this hook in its `PoolKey` — `afterInitialize` seeds the
   accumulator from the opening price, so there is no window where the oracle is dark.

**Initialise the pool with `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) as `PoolKey.fee`** even
though nothing sets a dynamic fee yet. `updateDynamicLPFee` is gated on the pool having been
*created* dynamic (`PoolManager.sol:340`), and the fee is in the `PoolKey`, so a static-fee pool can
never become a dynamic one. Same argument as the `beforeSwap` bit: it is free now and a pool
migration later.

## Not wired up yet

`Mono` still reads the v3 stub `IUniswapV3Pool` and is untouched by this change. Migrating it is
the next step and it is not small — in v4 there is no pool contract, so `Mono.pool` (an `address`)
becomes a `PoolKey`/`PoolId`, `setPool`'s `token0()/token1()` pairing check becomes a
`currency0/currency1` check that can also pin the hook address, and `poolPrice()` /
`premiumCloseAmount()` reroute through `StateLibrary` and this hook. See
[Mono.md](Mono.md#the-pool-and-the-premium).

`Index._poolPrice` should **not** move. Those are third-party AAPLx/USDG v3 pools, not ours; the
stub is correct there and the shared "same ceiling, same upgrade" comment overstates the link.
