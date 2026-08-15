# MonoAuction

Source: [`src/MonoAuction.sol`](../src/MonoAuction.sol) · human-readable walkthrough: [`doc.md`](../human-docs/doc.md)

## What it is

A **continuous**, **pay-as-bid** tick book with **geometric distribution**. One contract hosts many **markets** (`marketId`). Each round splits its supply across every live tick by weight `q^(tau-i)` instead of filling high → low; escrow that does not fill **stays in the book and competes again next round**. Bids pay their own price, not a uniform clearing price.

The distribution rule is specified in [`generous-auction.pdf`](../human-docs/generous-auction.pdf) and modelled interactively in [`index.html`](../human-docs/index.html).

The book is keyed by **market, not round**, so a round boundary copies nothing. There is no bid migration, no child auction, and no `auctionId` rotation. This is **not** Uniswap CCA — it shares only the sparse linked list of price levels.

Bids are **INDEX-only**, enforced structurally: `index` is a constructor immutable, there is no per-market `currency` parameter, and `submitBid` is not `payable`.

### What is being sold, and in what

For the harvest auction the sold token is **MONO** and the currency is **INDEX** — bidders escrow INDEX, never USDG or ETH (HANDBOOK §3.5 step 1). This is what makes the auction oracle-free:

- The strike is `NAV + k·premium`, and NAV is INDEX-per-MONO. INDEX escrow is already in strike units, so purchasing power cannot drift against the price it must pay.
- The machine pool is MONO/INDEX, so the pool ratio *is* price-in-backing-units. Nothing in the fill path needs a USD feed.
- Proceeds land in the vault as INDEX, the only asset it holds.

USDG belongs at the **edges** only, via the §3.5 USDG→INDEX zap. **That zap is not implemented** — today a bidder must already hold INDEX.

> **Still not the ratified stage-1 mechanism.** §3.5 (D15) specifies bids as a **share of premium `x`** repriced every block, with per-block escrow drawdown, top-bid-only accrual, an exercise gate, reserve-x, and an 80/20 split. This contract now has the continuous book and the persistent position, but bids are **absolute prices** settled in discrete rounds. Full gap list: [`discrepancies.md`](../human-docs/discrepancies.md).

## Interface

`src/interfaces/IMonoAuction.sol`, inherited by the contract, carries all structs, events and
errors. `Market` stays in the implementation — it holds mappings and never crosses the ABI. The
Uniswap price stub lives in `src/interfaces/IUniswapV3Pool.sol`.

## Core concepts

### Price / WAD

Prices are currency per token in **WAD** (`1e18`):

- tokens from currency at price `P`: `currency * 1e18 / P`
- currency from tokens at price `P`: `tokens * P / 1e18`

### Market vs round

| | Key? | Meaning |
|---|---|---|
| `marketId` | **yes** — outer mapping key | One sale: token, floor, recipients, persistent book |
| `Market.round` | **no** — a label | Which selling window we are in; for events and UIs only |

Because `round` is not a key, `openRound` is O(1) and touches nothing in the book. Two markets cannot share a book; two rounds of one market always do.

### Tick

`Market.ticks[price] → Tick { next, prev, demand, survival, epoch, init }`

- Prices must be multiples of **`tickSpacing`** and `≥ floorPrice`; each market's floor must itself sit on the grid.
- `tickSpacing` is a **constructor immutable** — per-market grids would let a caller pick their own O(n) walk in `_initializeTick`, and two markets on different grids share no comparable book. Floored at `MIN_TICK_SPACING = 2`.
- Floor tick is created at `createMarket`.
- New prices are inserted into a sorted doubly linked list via a caller `prevTick` hint.
- `demand` is live escrow, always `>=` the sum of live positions at that price.
- `survival` / `epoch` are the **depletion index** (below). A round boundary never resets them.

### Position

`Market.positions[owner][price] → Position { amount, tokensOwed, survivalAtEntry, epoch }`

Keyed by **`(owner, price)`** — there is no bid id and positions are **not enumerable on-chain**. That is deliberate and safe: no code path iterates bidders. A bidder can hold a position at every price they like (a demand curve), but only one per price — re-bidding at the same price harvests, then grows the record.

`amount` is escrow *as of `survivalAtEntry`*, not live escrow. Live escrow is derived, never stored.

## The depletion index

The reason the book can persist. Instead of snapshotting each round's fill per tick (which the next round would overwrite, corrupting unclaimed fills from the previous one), each tick carries a multiplicative factor. On a partial fill:

```
tick.survival ×= (1 − filledFraction)
tick.demand   −= filled
```

and a position reads:

```
live   = amount × tick.survival / position.survivalAtEntry     // rounds DOWN
spent  = amount − live
tokens = spent × 1e18 / price
```

O(1), correct across unlimited rounds, multiplicative rather than additive.

**Full fills use an epoch.** A 100% fill would drive `survival` to zero and break the division for later entrants, so it bumps `Tick.epoch` and resets `survival` to `SURVIVAL_ONE` (`2^128`). A position whose `epoch` is older than its tick's was fully consumed by definition — no arithmetic required.

`_harvest` materialises spent → `tokensOwed` and returns live escrow. It is O(1), idempotent, and mirrored read-only by the `positionOf` view so callers see the truth before anyone harvests.

## Price and NAV reads

`constructor(monoPool, mono, index, tickSpacing)` sets the bid currency and grid, and wires two price sources, both currently **read-only and unused by the fill path**:

| Member | Reads | Notes |
|---|---|---|
| `monoPrice()` | `IUniswapV3Pool.slot0()` | Spot, 18dec, from `sqrtPriceX96`. `monoIsToken0` derived from `pool.token0()` at deploy, never passed in. Assumes both pool tokens are 18dec. |
| `nav()` | `Mono.nav()` | INDEX per MONO, straight through to the vault. |
| `premium()` | both | `price − NAV`, floored at 0. |

Before wiring these into anything that moves funds: **`IUniswapV3Pool` is a stub** (the real source is a v4 hook with a TWAP accumulator that does not exist yet), and **`monoPrice()` is spot, paintable in one block** — §3.6 makes every money trigger TWAP-only.

`nav()` deliberately does not call the INDEX wrapper: `Index.sol` holds the stocks but does not know how many MONO claim them, and reading INDX would give a *USD* NAV, which §3.2 keeps out of the money path.

## Lifecycle

```
createMarket → fund → openRound → submitBid ⇄ withdrawBid → settle → claim
                ↑                                              │
                └───────────── openRound (O(1)) ───────────────┘
                                     └→ sweepCurrency / sweepUnsoldTokens
```

### 1. `createMarket`

Token, recipients, floor, `idleBlocks`. No currency parameter, no spacing parameter. Rejects `token == index`, a zero floor, a floor above `MAX_FLOOR_PRICE`, and a floor off-grid. Seeds the floor tick with `survival = SURVIVAL_ONE`.

### 2. `fund`

Transfer supply in first; `fund` checks `balanceOf >= reserved + amount` and adds to `remaining`. Supply added mid-round is immediately sellable.

### 3. `openRound`

Requires the previous round settled (`endBlock == 0 || settleDone`). Bumps `round`, sets `startBlock`/`endBlock`/`lastBidBlock`, clears `settleStarted`/`settleDone`/`settleCursor`. **Copies nothing** — measured flat at ~40.5k gas from 25 to 400 ticks.

### 4. `submitBid`

Pulls INDEX via `safeTransferFrom`, reserves it, initializes the tick if needed, harvests the existing position, then grows it and the tick's demand. Not `payable`. `owner` may differ from `msg.sender` and is who controls and is paid.

`prevTick` is a search hint; a legal but poor hint only costs the caller gas (236k with a good hint vs 1.15M from the floor against a 400-tick book). This is the **only** path that reaches `_initializeTick`, which is why the list walk can never be forced onto a third party.

### 5. `withdrawBid`

Returns **all** live escrow at `(msg.sender, price)` and zeroes the position; `tokensOwed` stays claimable. Blocked only mid-settle (`settleStarted && !settleDone`) — open during a round and between rounds. All-or-nothing, so there is no dust-leftover case to check.

### 6. `settle`

Distributes the round's supply geometrically, one **window** at a time, from `highestTick` down.

A window is the live ticks inside the price band `[tau - windowTicks*tickSpacing, tau]`, where `tau` is the highest live tick. Each tick gets weight `w = q^d` for `d = (tau - price) / tickSpacing`, normalised by `W = sum(w)`. Distance is measured in **grid steps from the price**, so gaps of empty levels dilute correctly — being second in the book is not the same as being one tick down.

The allocation is solved in closed form, not iterated. Writing `a_i = w_i * C`:

| Step | Effect |
|---|---|
| `kappa_i = cap_i / w_i` | The `C` at which tick `i` runs dry; `cap_i = demand_i / price_i`, clamped to the supply |
| Sort by `kappa`, sweep | Each step either reaches the next exhaustion (drop that `w` from `W`, continue — this is the waterfall) or the supply runs out, fixing `C` |
| Write back | Dry ticks whole-clear (`demand = 0`, `epoch += 1`, `survival = SURVIVAL_ONE`, raise `demand`); survivors take `w_i * C`, `survival *= keep/demand` |

**Exhaustion order is not price order** — a rich low tick outlives a poor high tick — which is why the sort exists and a bitmap would not do. Verified by `test_exhaustionOrderIsNotPriceOrder`.

A window is poured whole or not at all: a partial `W` would misprice every tick in it. So `maxTicks` budgets **list nodes visited**, not work inside a window, and `settleCursor` saves progress *between* windows. Resuming is sound because a later window only runs once every tick above it is dry, so the new `tau` is exactly where the previous window ended (`testFuzz_chunkedEqualsOneShot`).

Settle stops as soon as the supply runs out inside a window. That matters: per-tick flooring leaves a few wei behind, and without the stop the walk would chase that dust down the whole book — the unbounded traversal the old high → low fill avoided by zeroing `remaining` on its marginal tick.

Callable at/after `endBlock` **or** early once idle. If `survival` would round to 0 (Q128, needs ~128 consecutive halvings of one tick), it is treated as a whole clear so `demand` cannot outlive the index that prices it; the leftover becomes dust. Marked `ponytail:` in-code.

#### Calibrating `q` and `windowTicks`

Both are constructor immutables, and they are **one decision, not two**. Weights decay per grid step, so on this arithmetic grid `q`'s reach is an absolute price band of `windowTicks * tickSpacing`. A fine `tickSpacing` needs `q` near 1 to cover a sensible price range — which in turn softens the `(1 - q)` ceiling the top tick gets. **Window width and top-cap strength are the same knob pulling opposite ways**; a hard cap under any book shape needs a separate overlay.

The constructor rejects `q^windowTicks > 1%` (`WindowTooNarrow`) so a deployment cannot silently strand real demand just past the edge. `q == Q96` (flat split) is exempt. `weightAt(d)` and `previewWindow(marketId)` expose the curve and the next window's actual allocation for UIs — `previewWindow` is asserted to match settlement exactly.

Limits: `q -> 0` recovers the old strict high → low fill (`q = 1` in Q96 units is that limit, and the pre-existing suite runs on it unchanged); `q = Q96` splits evenly.

### 7. `claim`

Harvests, then pays `tokensOwed` clamped by `tokensUnclaimed`. **Does not close the position** — live escrow keeps competing. Permissionless; tokens go to `owner`.

### 8. Sweeps

- `sweepCurrency` — `currencyRaised` → `fundsRecipient` (safe before claims).
- `sweepUnsoldTokens(marketId, amount)` — `remaining` → `tokensRecipient`, only between rounds.

## Invariants

**Token:** `reserved[token] == remaining + tokensUnclaimed`, maintained by `fund`, `settle`, `claim`, and `sweepUnsoldTokens`. Asserted at every stage by `test_tokenInvariantHolds`.

**Escrow:** `reserved[asset] <= balanceOf(this)`. New markets may only claim unspoken-for balance (`fund`).

**Rounding is one-directional.** Live escrow rounds **down**, so `sum(live positions) <= tick.demand` — the shortfall (≤1 wei per position per fill) is unrecoverable dust, never a claim on another position's escrow. Token payouts are additionally clamped by `tokensUnclaimed`. Both directions pinned by `test_roundingFavoursThePot`.

## Gas properties (the ones the design exists for)

Regression-tested in `test/MonoAuctionGas.t.sol`; run with `--isolate` for real cold-access pricing.

| Operation | 50 ticks | 1,000 ticks |
|---|---|---|
| `claim` | 111,299 | 111,311 |
| `withdrawBid` | 67,385 | 67,398 |
| `openRound` | 40,493 | 40,505 |

`settle` is the one operation that is *not* flat, by design — it now touches every live tick in the window rather than only the ticks it drains. Measured linear at **~78k + 9.2k per live tick** (1 tick 86.9k, 4 ticks 114.3k, 16 ticks 224.5k). `windowTicks` is therefore the real gas knob. Reads are unaffected: `claim` and `positionOf` still go through `survival`/`epoch` in O(1), untouched by this change.

Flat to within 13 gas across a 20× book. When measuring these: use `--isolate`, hold the bid *price* constant across runs (a full clear and a partial fill differ by ~9.5k gas in `_harvest`), and use a **fresh recipient address per run** — an ERC20 balance slot going zero→nonzero costs 20k versus 2.9k, which looks like a 17k depth effect and is not.

## Known gaps

- **Empty ticks are never delisted.** Zero-demand ticks stay in the list, so `settle` pays a step for them and they lengthen the `submitBid` insert walk. Gas cost only.
- **Price feeds unused** — see above; nothing that moves money may read them yet.
- **Not the §3.5 mechanism** — absolute prices in discrete rounds, not a share-of-premium stream.

## Main entrypoints

| Function | Role |
|----------|------|
| `createMarket` | Open a market |
| `fund` | Reserve transferred-in supply |
| `openRound` | Start the next selling window (O(1)) |
| `submitBid` | Bid; grows the `(owner, price)` position |
| `withdrawBid` | Take back all live escrow at one price |
| `settle` | Geometric distribution, one window at a time (chunked) |
| `claim` | Collect accrued tokens, position stays live |
| `sweepCurrency` / `sweepUnsoldTokens` | Recipient payouts |
| `weightAt` / `previewWindow` | Curve and next-window allocation, for UIs |
| `markets` / `ticks` / `positionOf` / `idleTimedOut` / `settleProgress` | Views |
