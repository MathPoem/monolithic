# GenerousAuction

`src/GenerousAuction.sol` — the distribution rule of [`generous-auction.md`](../human-docs/generous-auction.md)
as a **single continuous sale**: one token, one currency, one persistent book, emitting
`emissionPerRound` every `roundBlocks` blocks with no operator in the loop.

It is also **the harvest channel** of HANDBOOK §3.5: `token` is [`Mono`](Mono.md), `currency` is the
INDEX that backs it, and the auction is `Mono`'s owner. See [The mint path](#the-mint-path).

Spec is the paper; this doc only records what the contract does differently and why.

## Shape

One deployment = one sale, configured by a single `Config` struct (fourteen positional arguments
overflowed the constructor stack, and a deployer transposing two `uint64`s would too). Everything in
it is immutable — `token`, `currency`, `floorPrice`, `tickSpacing`, `decayQ` (`q`, Q96),
`windowTicks`, `admin`, `startBlock`, `endBlock` — except
`roundBlocks` / `emissionPerRound`, which `admin` may re-schedule. There is no market id, no market
registry, and no cross-market `reserved` ledger — a second sale is a second deployment.

The book is keyed by price alone, so a round boundary copies nothing — it is a division, not a
transaction, at any depth.

Two consequences that shape the whole implementation:

- **No code path walks the list to write.** `_initializeTick` takes the exact predecessor from the
  caller and validates it in O(1); a stale hint reverts rather than being repaired on-chain.
- **Positions are not enumerable.** They are keyed by `(owner, price)` with no index, which is fine
  because nothing ever needs to enumerate them — `_harvest` prices one position in O(1).

The contract's own header comment is deliberately short and points here. This doc is the mechanism;
the source carries only the *why* of each local decision.

Lifecycle:

```
submitBid ⇄ withdrawBid → claim (mints)
                           ↑
                  sync (anyone, any time; also implicit in all three above)
```

## Emission is a schedule, not a transaction

`emittedToDate()` is a closed form of the block number:

```
anchorEmitted + floor((block - anchorBlock) / roundBlocks) * emissionPerRound
```

with at most one queued generation of `(K, R)` folded in at its boundary, and the block clamped to
`[startBlock, endBlock]` (`endBlock == 0` is open-ended). Nothing accrues per block, nobody has to
open or close anything, and a keeper is optional: `sync(maxTicks)` distributes
`emittedToDate() - tokensSold`, and `submitBid`/`withdrawBid`/`claim` all run
it first so the book is never reshaped in the middle of a backlog. A trailing partial round never
emits — the schedule floors.

### Lazy is exact, not approximate

A thousand silent rounds cost **one** sweep, and land exactly where a thousand sweeps would.
`_pour` parameterises the whole pour by a single scalar `C`, and relative weights
`w_i/w_j = q^(j-i)` do not depend on the anchor `tau`. So one sweep of `N·R` is the same allocation
as `N` sweeps of `R` over a static book, down to flooring dust. This is why the paper's §3
accumulator is unnecessary here, not merely skipped — there is nothing left for it to amortise.

### Carry

A round the book cannot absorb — every tick capped, or no book at all — is **not** burned.
`tokensSold` is cumulative and `due()` is measured against the schedule, so the shortfall stays
owed and the next sync distributes it. Nothing can reach `due()`, so carry is out of
the seller's hands too.

The known ceiling, marked `ponytail:` in the source: carry is unbounded. A long dry spell hands the
first bidder back a large backlog at their own price. Cap the per-sync draw if that turns out to be
worth gaming.

### Rescheduling

`setRoundParams(K, R)` is admin-only and takes effect at the **next** round boundary — the round in
flight finishes at the rate it started under. It needs no sync first: `_emittedAt` is exact for
every past block regardless of what is queued, so rounds that already elapsed keep their old rate
whether or not anyone settled them. A second call before the boundary replaces the first.

## Distribution

Live tick `i` at distance `d = (tau - price) / tickSpacing` below the top of book `tau` carries
weight `w = q^d` and takes `w/W` of the round's supply, paying **its own price** (pay-as-bid).
A tick that exhausts mid-round leaves the live set, `W` shrinks, and the rest of that same round
re-flows by renormalised weights — the paper's waterfall (§1.2), most of it upward.

Solved in one sweep, not iterated (§A.6). With `a_i = w_i · C`, tick `i` dies at
`kappa_i = cap_i / w_i` where `cap_i = demand_i / price_i`. `_pour` sorts by `kappa` and walks it:
each step either reaches the next death (drop it from `W`, continue) or exhausts the supply (fix
`C`, stop). `O(n log n)`. **Death order is not price order** — a rich low tick outlives a poor high
tick — which is why the sort exists and a bitmap would not do.

`q → 0` is strict high → low priority; `q = 1` splits evenly. In a dense book the top tick's share
tends to `(1 - q)`, so `q` **is** the soft anti-whale cap.

### Deliberately not implemented: the lazy `G` accumulator

The paper's §3 — global accumulator `G`, mantissa+shift rebase on a change of `tau`, sorted death
queue with hints — exists to smear the sweep across transactions. This contract runs the sweep
inline at settle over a bounded window instead. No accumulator to drift, no queue to keep sorted,
no rebase when `tau` moves. What is kept from §3 is the part that actually buys O(1) claims: the
per-tick multiplicative index.

Cost of that trade: a sync is O(live ticks), not O(1). It is chunked (below) so it never has to fit
in one block. Revisit only if a live book gets deep enough that a chunked sync is uncomfortable.

## Bounded window

Only the top `windowTicks` grid steps participate; past that `q^d` has rounded to nothing. A window
is a fixed **price band** `[tau - windowTicks·tickSpacing, tau]`, so it holds at most
`windowTicks + 1` distinct tick prices — the gather is bounded by construction, no caller-supplied
cap needed.

The constructor rejects `q^windowTicks > 1%` (`WindowTooNarrow`) so a deployment cannot silently
strand real demand just past the edge. `q == Q96` (flat) is exempt: there the window *is* the
intended participation set.

Calibrate `q` **with** `tickSpacing`: weights decay per grid step, so on this arithmetic grid `q`'s
reach is an absolute price band. Window width and top-cap strength are one knob, not two.

## Depletion index (why claims are O(1))

Per tick: `survival` (Q128) and `epoch`. On a partial fill `survival *= (1 - filledFraction)`; on a
whole fill `epoch += 1` and `survival` resets, because driving it to zero would break the division
that prices later entries.

A position stores `amount` and `survivalAtEntry`. Live escrow is
`amount * tick.survival / position.survivalAtEntry` — one division, however many rounds and partial
fills went by. A position from an older epoch was, by definition, fully consumed.

**Allocations are never stored.** Settle writes only `survival`/`epoch`/`demand` per tick and the
aggregates `tokensUnclaimed`/`currencyRaised`. `Position.tokensOwed` is materialised lazily by
`_harvest`, on the first claim/bid/withdraw that touches the position. Reading the raw `positions`
mapping shows only that crystallised half — **`positionOf` is the number to trust**, it adds the
uncrystallised remainder.

Rounding is DOWN at every per-tick step. A sum of floors is no greater than the floor of the sum, so
allocations can never exceed supply; the shortfall is dust, never insolvency. `claim` clamps against
`tokensUnclaimed` so per-position rounding lands in the bidder's favour.

## The mint path

**Nothing is pre-funded.** `claim` mints, by calling `Mono.mint(tokens, assetsIn, owner)` with the
INDEX the fill already took out of the position's escrow. Strike paid and supply created in one
transaction — so INDEX can never sit here as un-backed proceeds, and there is no `sweepCurrency`,
because there is nothing to sweep.

The constructor enforces the wiring it needs: `currency == address(Mono.index())`, or `mint` would
pull the wrong token. The deployer must also transfer `Mono` ownership after construction — see
[Mono.md](Mono.md#ownership).

`due()` is `emittedToDate() - tokensSold`, **uncapped**. The schedule is the entire supply
constraint; there is no balance to run out and no `remaining()`.

### The NAV clamp

`Mono.mint` refuses any mint that would lower NAV, and NAV rises every time someone else claims. So
two guards, at the two ends:

- **`submitBid` floors bids at `nav()`**, not at the immutable `floorPrice`. NAV only rises, so the
  two diverge over the life of the sale and only the live one is a real floor.
- **`claim` clamps instead of reverting.** A position that filled before NAV grew past its price
  would otherwise be stranded forever, its escrow already spent. Instead it mints
  `maxIssuable(assetsIn)` — what that escrow buys at the *current* NAV.

The clamp does not short-change the claimer: they receive MONO backed by exactly the INDEX they
paid, which is the most a non-dilutive mint can hand anyone. `maxIssuable` rather than
`assetsIn / nav()` because `nav()` floors, and dividing by a floored NAV lands a wei over what
`mint` accepts.

The whole escrow goes to the vault either way, so NAV is non-decreasing across every claim —
`test_navNeverFallsAcrossClaims`.

## Sync chunking

`sync(maxTicks)` processes one window at a time from the top of book down, saving `settleCursor`
between windows. `settleCursor == 0` means "start from the top"; anything else is a genuinely
truncated sweep, where every tick above the cursor is known dry. The implicit syncs inside
`submitBid`/`withdrawBid`/`claim` run at `SYNC_TICKS = 128`.

**`SYNC_TICKS` does not bound one window.** `_gather` step 2 always collects its whole band, so a
single window of up to `windowTicks + 1` live ticks runs to completion regardless. The real ceiling
on what one bidder pays for someone else's backlog is therefore **`windowTicks`**, which is a
deployment choice:

| Book | Implicit sweep a bid drags behind it |
| --- | --- |
| `windowTicks = 8`, 10 live ticks | ~169k |
| `windowTicks = 255`, 256 live ticks | ~2.3M |
| nothing due (the common path) | ~26k |

Measured at ~9–17k per live tick. Pick `windowTicks` with the bid cost in mind, not only the
`MAX_EDGE_WEIGHT` pairing — and note that a spammer can fill the top window with dust ticks and
make every bid pay for the full sweep.

On the first window of a sweep that started from the top, `highestTick` is dropped onto the real top
of book. Dead ticks are never unlinked, so without that an abandoned run of spam ticks above the
book would be re-walked by every sync forever and could starve the live ticks below it. A window is **never left half-poured** — a partial `W` would misprice every tick in
it — so `maxTicks` budgets *list nodes visited*, not work inside a window.

Two stop conditions, and the difference matters:

- **window ran dry** (every tick in it exhausted): the book below can still be served, keep walking;
- **supply ran out inside the window**: nothing below is reachable, stop. Without this the walk
  would chase per-tick flooring dust down the entire book.

Permissionless and always callable. It only ever moves the book to where the schedule already says
it should be, so who calls it and when decides nothing but who pays the gas — no operation is ever
blocked waiting for a settle to finish.

## Invariants

- `currency.balanceOf(this) >= sum(live escrow) + currencyRaised`.
- `tokensUnclaimed == sum of every position's tokensOwed` — MONO sold and not yet minted.
- `Mono.nav()` is non-decreasing across every `claim`.
- `Tick.demand >= sum of live positions at that tick` (positions round down).
- A position's tokens are recoverable in O(1) at any time, across unlimited rounds.

## Surface

Declared in `src/interfaces/IGenerousAuction.sol`, which the contract inherits and which carries
all structs, events and errors. `Window` stays in the implementation — memory-only, never crosses
the ABI.


| Function | Notes |
| --- | --- |
| `sync(maxTicks)` | Permissionless, chunked, resumable. Implicit at the head of the three below. |
| `setRoundParams(K, R)` | Admin only. Effective next boundary, never retroactive. |
| `submitBid(price, amount, owner, prevTick)` | `prevTick` must be the **exact** predecessor; a stale hint reverts `BadPrevHint`. Re-bidding at the same price harvests and grows; never a second record. Reverts `AuctionEnded` past `endBlock`. |
| `withdrawBid(price)` | Returns all live escrow. Won tokens stay claimable. Free cancel — see the `ponytail:` note in the source. |
| `claim(owner, price)` | Permissionless, always pays `owner`. **Mints** the MONO and sends the escrow that bought it to the vault. Does **not** close the position. Clamps to `maxIssuable(assetsIn)` if NAV outran the bid price. |
| `remaining` / `due` / `emittedToDate` / `roundsElapsed` / `positionOf` / `previewWindow` / `weightAt` | Views. `previewWindow` mirrors `_gather` + `_pour` over the same `due()` a sync would use, so a UI never reimplements the curve — and the lens equals the execution. |

## Tests

`test/GenerousAuction.t.sol`. The anchor is the paper's appendix A.9 worked example — four ticks,
`q = 0.5`, a 150-token draw (one emission round), published answer **20 / 96 / 10 / 24** — asserted
through `previewWindow`, through the sync that follows it in the same block, and through settlement.
Alongside it: emission accrual and the trailing partial round, one lazy sweep equalling three
sequential ones bit for bit, carry over an empty book, sweep-cannot-take-carry, and the three
non-retroactivity properties of `setRoundParams`. Prices sit on this contract's arithmetic grid rather than the
paper's geometric ladder, which changes nothing: the allocation depends only on each tick's weight
and its capacity in tokens.

## Relationship to `MonoAuction`

`src/MonoAuction.sol` is the same mechanism with a multi-market wrapper (`marketId`, a `reserved`
ledger, an explicit `fund`) plus a MONO/NAV price stub. `GenerousAuction` is that mechanism with the
wrapper removed for the one-sale-after-another case. Changing the distribution math in one without
the other will drift them.
