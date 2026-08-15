# MonoAuction — how it works

A plain-language walkthrough of [`src/MonoAuction.sol`](../src/MonoAuction.sol).

---

## The idea in one sentence

Bidders say **"I'll pay at most X per token, and here's my money."** Periodically the contract sorts those offers from highest price to lowest and hands out tokens in that order until the supply runs out. **Everyone pays their own price**, not a shared clearing price.

That last part matters. If you bid 3.0 and supply runs out at 2.0, you still pay 3.0. This is a **pay-as-bid** auction (sometimes called discriminatory-price), deliberately not a uniform-price one.

The second thing that matters: **an offer that doesn't fill doesn't go away.** It stays in the book and competes again next round, with nothing copied, re-keyed, or re-submitted. That is what "continuous" means here, and it's the design's whole point.

## What's being bought and sold

- **Sold:** any ERC-20, set per market. For the real use case this is MONO.
- **Paid in:** always **INDEX**, the basket token, fixed at deploy. There is no way to bid in ETH, USDG, or anything else — `submitBid` isn't even `payable`.

Why INDEX only? The price a bidder owes is denominated in INDEX (it derives from NAV, which is "INDEX per MONO"). Escrow in the same unit as the debt can't drift against it between bidding and settling. USDG is also 6-decimal, which would silently break the 18-decimal fill math.

## Markets and rounds

- A **market** is one sale: a token, a floor price, recipients, and a **persistent book**. `marketId` is the storage key.
- A **round** is one selling window over that book. `round` is a counter for events and UIs — **not** a key. Advancing it copies nothing.

One deployed contract hosts many markets. Market #3 can never touch market #7's escrow.

---

## The three things stored

### Prices are "currency per token", 18 decimals

A price of `2e18` means **2 INDEX buys 1 token**:

```
tokens you get   =  currency × 1e18 / price
currency needed  =  tokens × price / 1e18
```

### A tick is a price level, and it remembers how depleted it is

Bids snap to a grid — every price must be a multiple of `tickSpacing`, fixed contract-wide at deploy.

```
Tick { next, prev, demand, survival, epoch, init }
```

`demand` is the total live escrow at that price. `next`/`prev` make the initialized prices a **sorted doubly linked list** — only prices someone actually bid at exist in it.

`survival` and `epoch` are the interesting part: they're a **depletion index**, explained below. Nothing about a round boundary touches them.

### A position is one bidder's standing offer at one price

```
Position { amount, tokensOwed, survivalAtEntry, epoch }
```

Keyed by **`(owner, price)`** — not by a sequential bid id. One bidder can hold a position at every price they like (a demand curve), but only one per price; bidding again at the same price grows the existing record rather than creating a second one.

There is no bid id and no way to enumerate positions on-chain. That's fine, because nothing needs to: no code path ever iterates bidders.

---

## The depletion index — why nothing has to be copied

The naive way to run a second round is to snapshot each tick's fill, then reset it. That breaks immediately: a bidder who filled in round 1 and hasn't claimed yet would read round 2's numbers and get the wrong tokens. The only fix would be to write every bidder's result before resetting — an O(number of bids) pass, exactly the cost we're trying to avoid.

So instead of a snapshot, each tick carries a **multiplicative survival factor**. When a tick has fraction `r` of its demand filled:

```
tick.survival  ×=  (1 − r)
tick.demand    −=  filled
```

A position records `survival` when it enters. At any later moment, for any number of intervening rounds:

```
live escrow  =  amount × tick.survival / position.survivalAtEntry
spent        =  amount − live escrow
tokens       =  spent × 1e18 / price
```

Three storage reads, O(1), no loop. Multiplicative, not additive — a position haircut 50% twice has 25% left, not zero.

**The full-fill case needs an epoch.** A tick above the clearing price fills 100%, so `r = 1` and survival would hit exactly zero, breaking the division for anyone who entered later. So a 100% fill instead bumps `Tick.epoch` and resets `survival`. Any position whose `epoch` is older than its tick's was, by definition, fully consumed — no arithmetic needed.

Three consequences fall out, all deliberate:

1. **A round boundary is O(1).** Measured: `openRound` costs 40,486 gas against a 25-tick book and 40,498 against a 400-tick one.
2. **No unbounded walk is reachable on a third party's gas.** The linked-list insert is only reachable from `submitBid`, where the caller picks the hint and pays for it.
3. **Positions needn't be enumerable**, which is what lets them be keyed by `(owner, price)`.

---

## Worked example: three bidders

Setup: **100 tokens**, floor price 1.0, tick spacing 0.1.

| Bidder | Price | Escrow | Tokens they want |
|---|---|---|---|
| Alice | **3.0** | 90 INDEX | 30 |
| Bob | **2.0** | 100 INDEX | 50 |
| Carol | **2.0** | 60 INDEX | 30 |

Together they want 110 tokens but only 100 exist — oversubscribed. The book:

```
3.0  →  90 INDEX     (Alice)
2.0  → 160 INDEX     (Bob 100 + Carol 60 share one tick)
1.0  →   0 INDEX     (floor, created with the market, empty)
```

### Settling: walk down from the top

**Tick 3.0.** Wants `90 × 1e18 / 3.0 = 30 tokens`. 100 available → **clears whole.** Epoch bumps, 90 INDEX collected, 70 tokens left.

**Tick 2.0.** Wants `160 / 2.0 = 80 tokens`, only 70 left → **marginal.** Spend exactly the remainder: `70 × 2.0 = 140 INDEX` of the 160 offered. `survival ×= 20/160`, `demand` drops to 20.

Supply is gone, so the walk stops — tick 1.0 is never visited. Total raised: **230 INDEX**.

### Who gets what

| Bidder | Spent | Tokens | Live escrow left | Price paid |
|---|---|---|---|---|
| Alice | 90 | **30** | 0 (tick cleared) | 3.0 |
| Bob | 87.5 | **43.75** | 12.5 | 2.0 |
| Carol | 52.5 | **26.25** | 7.5 | 2.0 |

`30 + 43.75 + 26.25 = 100 tokens`; `90 + 87.5 + 52.5 = 230 INDEX`.

Two rules: price priority is absolute **across** ticks — Alice is fully served before anyone at 2.0 is looked at. Pro-rata only breaks the tie **inside** the one tick that couldn't be fully served, and everyone there is cut by the same factor: no time priority, no size advantage.

**And Bob's and Carol's leftovers are not refunded.** They stay in the book as live escrow at 2.0. Next round they compete again, automatically. If they'd rather have the money back, they withdraw.

---

## Lifecycle

```
createMarket → fund → openRound → submitBid ⇄ withdrawBid → settle → claim
                 ↑                                             │
                 └──────────── openRound (O(1), copies nothing) ┘
                                          └→ sweepCurrency / sweepUnsoldTokens
```

### `createMarket(token, fundsRecipient, tokensRecipient, floorPrice, idleBlocks)`

Opens a market and seeds the floor tick. No currency argument (always INDEX), no spacing argument (contract-wide). The floor must sit on the grid, and the token can't *be* INDEX.

### `fund(marketId, amount)`

Transfer tokens in, then call this. It checks the contract holds them **and** that they aren't already owed to another market, then reserves them. Supply added mid-round is immediately sellable.

### `openRound(marketId, endBlock)`

Starts the next selling window. Requires the previous round to be settled. Moves the clock, re-arms the settle flags, bumps the counter — and touches **nothing** in the book. This is the O(1) round boundary.

### `submitBid(marketId, price, amount, owner, prevTick)`

Pulls `amount` INDEX, escrows it, adds to the tick's demand, and grows the `(owner, price)` position.

- `owner` is separate from the sender — you can bid for someone else, and **they** control it afterwards.
- Bidding again at the same price **harvests first**, then grows the position. That's required: `survivalAtEntry` is only meaningful for one `amount`.
- `prevTick` is a **search hint**, not data. Inserting a new price means finding its neighbours in the sorted list, and storage can't jump into the middle of a linked list. Pass the tick just below your price and insertion is O(1); pass the floor and it walks up. Either is correct — the contract validates and walks to the real slot — so a bad hint costs you gas, never a corrupt book. Measured against a 400-tick book: **236k gas with a good hint, 1.15M from the floor.**
- Your escrow must buy at least 1 wei of token; max price is 10,000× the floor.

### `withdrawBid(marketId, price)`

Returns **all** live escrow at `(msg.sender, price)` and closes the position. Tokens already won stay claimable. Blocked only *mid-settle*, while the book is being consumed — otherwise open, including between rounds.

This is a **free cancel option**: a bidder can sit in the book and walk away for nothing. Deliberate — it's the price of guaranteeing an offer that never clears always has an exit. A cancel fee is the noted upgrade if it turns out to be worth gaming.

### `settle(marketId, maxTicks)`

Runs the high→low walk, applying the depletion index as it goes. Callable by anyone at or after `endBlock`, **or early** once the market has been quiet for `idleBlocks`. `maxTicks` chunks it; progress saves to `settleCursor` every iteration.

### `claim(marketId, owner, price)`

Harvests and pays out the tokens accrued. **Does not close the position** — live escrow keeps competing. Permissionless; tokens always go to `owner`.

### Sweeps

- `sweepCurrency` — raised INDEX → `fundsRecipient`. Safe before bidders claim.
- `sweepUnsoldTokens(marketId, amount)` — unsold tokens → `tokensRecipient`, only between rounds.

---

## Escrow safety

`reserved[asset]` tracks everything the contract owes anyone: escrowed supply, live bids, unswept proceeds. **A new market may only claim balance above `reserved`** — which is why `fund` checks `balanceOf >= reserved + amount` instead of trusting the balance.

For the sold token there's an exact invariant, asserted at every stage by `test_tokenInvariantHolds`:

```
reserved[token] == remaining + tokensUnclaimed
```

### Rounding is deliberately one-directional

Live escrow rounds **down**, so the sum of positions at a tick can never exceed that tick's `demand`. The shortfall — at most 1 wei per position per fill — becomes unrecoverable dust rather than a claim on someone else's money. Token payouts are additionally clamped against `tokensUnclaimed`, so per-position rounding in the bidder's favour is absorbed by the budget, never by the pot. `test_roundingFavoursThePot` pins both directions.

---

## Gas and the chunking discipline

Nothing on the bid, claim, withdraw, or round-boundary path iterates the book. Measured with `--isolate`, comparing a 50-tick book against a 1,000-tick one:

| Operation | 50 ticks | 1,000 ticks |
|---|---|---|
| `claim` | 111,299 | 111,311 |
| `withdrawBid` | 67,385 | 67,398 |
| `openRound` | 40,493 | 40,505 |

Flat to within 13 gas across a 20× book. The one walk that remains is `settle`, over ticks, bounded by `maxTicks` and cursored — an interrupted call is never lost work.

---

## Parameters and limits

| Name | Value / meaning | Notes |
|---|---|---|
| `tickSpacing` | Deploy-time, contract-wide | Must be ≥ 2 and must divide every market's floor price |
| `index` | Deploy-time | The only accepted currency; can't be zero or the token being sold |
| `SURVIVAL_ONE` | `2^128` | Scale of the depletion index; Q128 for headroom against repeated partial fills |
| `MAX_PRICE_MULTIPLE` | `1e4` | Bids capped at 10,000× the floor |
| Minimum bid | escrow × 1e18 ≥ price | Must buy ≥ 1 wei of token |
| `idleBlocks` | Per market; 0 disables | Blocks of silence after which `settle` may be called early |

---

## Known gaps

**Empty ticks are never delisted.** A tick whose demand goes to zero stays in the linked list, so `settle` still pays a step for it and it still lengthens the `submitBid` insert walk. Costs gas; can't brick anything, since settle is chunked and the insert is caller-paid.

**Survival underflow is handled but not exercised.** If a single tick were partially filled ~128 consecutive times, the Q128 index could round to zero. The code treats that as a full clear so `demand` can never outlive the index that prices it, at the cost of stranding the remaining escrow as dust. Practically unreachable — by then every position at that tick retains under 2⁻¹²⁸ of its escrow — and marked with a `ponytail:` comment naming the ceiling.

**Price feeds are wired but unused.** `monoPrice()`, `nav()`, and `premium()` are read-only and nothing in the fill path touches them. `monoPrice()` reads Uniswap v3 **spot**, manipulable within one block, and `IUniswapV3Pool` is a stub — the intended source is a v4 hook with a TWAP accumulator that doesn't exist yet. Nothing that moves money should read these as they stand.

**Still not the ratified mechanism.** HANDBOOK §3.5 specifies bids as a *share of premium* repriced every block (`strike = NAV + x·premium`), with per-block escrow drawdown and an exercise gate. This contract has the continuous book and the persistent position, but bids are still absolute prices settled in discrete rounds. See [`discrepancies.md`](discrepancies.md) for the full gap list.

---

## Function reference

| Function | What it does |
|---|---|
| `createMarket` | Open a market and seed its floor tick |
| `fund` | Reserve transferred-in supply |
| `openRound` | Start the next selling window (O(1)) |
| `submitBid` | Bid at a price, escrow INDEX, grow your position |
| `withdrawBid` | Take back all live escrow at one price |
| `settle` | Run the high→low fill (chunked) |
| `claim` | Collect accrued tokens without closing the position |
| `sweepCurrency` | Raised INDEX → `fundsRecipient` |
| `sweepUnsoldTokens` | Unsold tokens → `tokensRecipient`, between rounds |
| `markets` / `ticks` / `positionOf` | State views; `positionOf` mirrors `_harvest` read-only |
| `idleTimedOut` / `settleProgress` | Round-state views for callers and UIs |
