# Index

`src/Index.sol` is the in-kind basket wrapper described by HANDBOOK §5. Its public ABI is in
`src/interfaces/IIndex.sol`.

## Construction

The constructor takes a `Stock[]` — each entry carries the asset, allocation in basis points,
its Chainlink price feed, and the `asset`/stablecoin Uniswap v3 pool that feed is cross-checked
against. Every field must be non-zero and the allocations must sum to 10,000.
`setPriceFeed(asset, priceFeed, pool)` replaces a feed and its pool after deployment; the two move
together, because a feed is only as trustworthy as the market it can be compared to.

## Mint and burn

`mint(shares, to)` deposits the quoted basket assets and issues INDEX. `burn(shares, to)` burns
the caller's INDEX and transfers its pro-rata slice of the pot to `to`. The quote helper for the
outgoing assets remains `proceedsOfRedeem(shares)`.

## Fee (P7)

`feeRate` is the in-kind fee charged each way, settable by the owner via `setFeeRate`.

**The denominator is 100_000, not 10_000** — so `1755` is 1.755% and `50` is 0.05%. Hard-capped
at `5_000` (5%) on every set; starts at `0`, so a fresh deployment charges nothing.

It is charged in kind **on the way in only**: `calculateAmountOfAssetsToMintIndex` grosses the
pro-rata cost up by `1 + feeRate` and the surplus is booked to `fees[asset]`. `burn` is untouched —
`proceedsOfRedeem` pays the full pro-rata slice, so redemption stays free.

**`fees` is netted out of `_contractAssetBalance`, alongside `reserved`.** A collected fee is
therefore never counted as backing, which is what makes it withdrawable without hurting holders:
NAV per share is flat across a fee-charging mint, and flat again when the owner sweeps. If
`fees` were left inside the pot valuation instead, NAV would rise as fees accrued and drop when
they were swept — holders would watch backing evaporate.

`withdrawFees(assets_, to)` is `onlyOwner` and reads `fees[asset]` only. There is no path in the
contract — for the owner or anyone else — that moves the pot's own balance or a claimant's
`reserved` leg. That boundary is the whole safety argument for giving the owner a sweep at all, and
`test_withdrawCannotReachThePot` pins it.

This is a variant of P7, not P7 as written: the spec says ~half the fee goes to the treasury as
freshly-minted INDEX and the rest stays in the pot. Here 100% is collected in kind and swept by the
owner, and no INDEX is minted to anyone.

Two carve-outs:

- **Genesis** (`supply == 0`) is exempt. There are no holders for it to accrue to, and taxing the
  founding deposit only charges the founder for seeding the pot.
- **Deficit-channel mints** are exempt; they pay the 1% D20 haircut instead. This settles the open
  question in `human-docs/discrepancies.md` E8: P7 is **not** additive to the haircut. It also
  keeps `deficitToMint`'s fixed point untouched — the only genuinely delicate math in the contract.

Since burn is free, a mint/redeem round trip costs the rate once. Measured against what was spent
rather than the pro-rata base, 1.755% reads as 1,724 per 100,000 (`1_755 / 1.01755`).

## Deferred legs

The stock issuer can freeze a token or blocklist an address. A `burn` that sent every leg in one
transaction would then revert wholesale — one frozen stock out of ten locking all ten. So `burn`
pays leg by leg and, when a transfer fails, books that leg to `to` instead of reverting:

- `owed(owner, asset)` — raw units booked to `owner` and not yet collected.
- `reserved(asset)` — the sum of every `owed` entry for that asset.
- `claim(assets_, to)` — collects them. Reverts if a listed asset owes the caller nothing, so a
  repeated asset cannot pay twice and a stale list fails loudly. A still-frozen token reverts and
  the leg stays on the books until it thaws.

`burn`'s returned `got[]` counts only what was actually **transferred**; a deferred leg reads 0
there and must be read from `owed`, or an integrator over-credits the redeemer.

The invariant this rests on: a booked sliver is no longer pot property. `_contractAssetBalance`
returns the raw balance **minus `reserved`**, and every valuation in the contract — `deficit`,
`_potValue`, `proceedsOfRedeem`, `calculateAmountOfAssetsToMintIndex` — reads it rather than
`balanceOf`. Paid or booked, a leg lowers the pot by the same amount, so no other holder's slice
moves and the next redeemer can never be paid out of someone's uncollected leg. Any new valuation
must read `_contractAssetBalance`; reading the raw balance reintroduces a money pump.

Minting during a freeze stops on its own — a mint has to transfer every leg *in*, and that
reverts. There is no ledger on the mint side and none is wanted.

## Adding a stock

`addStock(Stock stock)` lists one new stock and opens the deficit mint channel for it. The
argument carries the token, its post-add target weight in basis points, its price feed, and its
pool.

Requirements:

- the stock must not already be in the basket;
- asset, allocation, feed, and pool must all be non-zero;
- `allocationBips` must be strictly less than 10,000; and
- the pot must have a non-zero INDEX supply.

Incumbent target weights are rescaled down proportionally to make room; any rounding dust lands
on the first incumbent. The new stock is appended, and its weight is converted once into the raw
`targetPerIndex` quantity used by the deficit channel.

While the channel is open, minting charges only the new stock. Once its per-INDEX target is met,
ordinary pro-rata minting resumes. `burn` stays pro-rata throughout — it is never gated.

## Timelock

`addStock`, `setFeeRate` and `fireEscape` carry the `timelocked` modifier: they accept
`msg.sender == address(this)` only, so the sole way to reach them is `queue(data)` → wait
`TIMELOCK_DELAY` (2 days) → `execute(data)`. `queue`/`cancel`/`execute` are `onlyOwner`; the
delay is a `constant`, because a notice period the owner can shorten on demand is not one.

`queue` keys on `keccak256(data)`, so identical calldata cannot be pending twice at once.
`execute` bubbles the target's own revert — a change that went stale during the notice period
fails with `StalePrice` or `DuplicateAsset` rather than an opaque call failure — and because the
whole transaction reverts, a failed `execute` leaves the entry queued for a retry.

`setPriceFeed`, `setMaxDivergenceBips` and `withdrawFees` are **not** timelocked. A feed swap moves no assets and may need
to be immediate (an aggregator deprecation); collected fees are already earned and outside the pot
valuation, so delaying them protects nobody.

## Feed vs. pool (reallocation only)

The deficit channel is the one mint path priced off the oracle rather than off the pot's own
balances, so it is the one path where a wrong feed dilutes holders. Ordinary `mint` and `burn` are
pure pro-rata and read no prices at all.

`_price` applies **one guard per path, never both**. While `reallocating` is true the pool is the
check and `MAX_FEED_AGE` is not consulted: an equity feed stops updating the moment its market
closes, so a Sunday round is old by construction and its age says nothing about whether the price
is still right — a live market that agrees with it does. The feed's price is compared against the
stock's `asset`/stablecoin Uniswap v3 pool and the mint reverts with `PriceDiverged(asset)` if they
sit more than `maxDivergenceBips` apart.

Everywhere else — `addStock` striking `targetPerIndex`, `saleFloor` pricing a clip — no pool is
read, so `MAX_FEED_AGE` (1 hour) is the only guard left and it still applies. **Every** stock in the
basket is checked, not just `pendingAsset` — the mint is priced off `_perIndexValue`, which reads
the whole pot, so a stale incumbent dilutes exactly as well as a stale pending asset does.

`maxDivergenceBips` starts at 200 (2%), is owner-settable, and is capped at 1,000 (10%). Divergence
is measured as a fraction of the *feed* price, because the feed is what the mint is actually
charged at. The stablecoin leg of the pool is taken as exactly $1.

`_poolPrice` reads `slot0` and branches on token ordering, since which side the stock sits on is an
accident of address sort. The pool must hold the stock or the read reverts `InvalidPool`; a listed
stock with no pool reverts `MissingPool`.

### Known ceilings

`slot0` is **spot**, so it is movable inside a single block. Someone minting against a feed that has
drifted can shove the pool towards that feed in the same transaction and the check will not see it.
This is a sanity check on an honest feed, not a manipulation-resistant oracle — swap in the v4
hook's TWAP accumulator (HANDBOOK §3.6) when it lands.

`maxDivergenceBips` defaults to 200 while `HAIRCUT_BIPS` is 100. A band wider than the haircut
authorises more feed error than the cushion absorbs; set it below 100 if the channel is expected to
run against feeds that drift.

`addStock` strikes `targetPerIndex` from the oracle while `reallocating` is still false, so that
one read is **not** cross-checked. `saleFloor`/`armSale` are likewise unchecked, and both are
blocked during reallocation anyway.

Dropping the age check on this path makes the pool the **single** point of failure there. A dead
feed plus a pushed pool mints at whatever the attacker chose, with only `HAIRCUT_BIPS` in the way.
That is the trade for staying open outside market hours, and it is what makes the `slot0` ceiling
above load-bearing rather than cosmetic.

## Composition reduction (D12)

D12 NEVER REDUCE holds with exactly one exception: `fireEscape(asset)`, the emergency exit from
`new_docs/FIRE-ESCAPE.md`. It removes `asset` from `_assets` and `stocks`, moves the freed
`allocationBips` onto the first surviving incumbent, and transfers the pot's balance of it to
`owner()`. Requires the asset to be listed, not to be the last one, and no open channel.

Both sides of the composition move in that one transaction — mint and redeem both read `_assets`
— so there is no window where they disagree and no money pump. Only the pot's *own* balance
leaves: `_contractAssetBalance` nets out `reserved` and `fees`, and `claim` / `withdrawFees` keep
working on a delisted asset because they read `owed` / `fees` rather than `_assets`.

**This is a deliberate departure from `FIRE-ESCAPE.md`**, which requires a governance-only caller
installed once at stage 2, a per-clip cap of roughly 1% of pot value, and a vote naming both the
asset and the mode. Here the owner takes the entire balance in one step and the 2-day notice
period is the only protection holders have. Liquidation and any return of value happen off-chain,
at the owner's discretion; there is no `escrowSlice`, no `returnProceeds`, and no Mode 2
escrow-and-claim. `redeemSurplus` and any rebalance path remain absent from the bytecode.

## Selling a stock from inside the pot (FIRE-ESCAPE.md Mode 1)

`fireEscape` hands a whole balance to `owner()` and everything after that is off-chain trust. The
sale path is the alternative for a stock that is *dying but still tradeable*: the pot sells it in
clips on the Arcus spot RFQ rail without the assets ever leaving its own custody.

Arcus spot is RFQ, not an AMM — there is no function to call that returns a fill. The taker only
*signs* an intent (a Permit2 `PermitWitnessTransferFrom` carrying a `TakerIntent` witness) and the
router's relayer submits the settlement transaction. Permit2's `SignatureVerification` takes the
ERC-1271 branch whenever the signer has code, so the pot can be that taker: it vouches for a
digest instead of producing a signature. `isValidSignature` returns the magic value for
`armedIntent` and nothing else.

The consequence that makes this worth having: the sell leg is pulled from the pot and the buy leg
is delivered back to it inside one transaction. Both tokens are listed, so `_potValue` counts the
replacement the instant it arrives. There is no desk hop, no custody gap, and no "in transit"
slice invisible to redeemers — which is why this needs neither `escrowSlice` nor `returnProceeds`.

### Two tiers, because a timelock cannot sign a 60-second quote

Router quotes expire in about a minute, so the 2-day notice period cannot sit on each clip. It
sits on the *campaign* instead:

| | Caller | What it decides |
|---|---|---|
| `openSale` / `closeSale` | `timelocked` | which stock, into which stock, `dailyCap`, `maxSlipBips` |
| `armSale` / `disarmSale` | `onlyOwner` (keeper) | *when*, inside those bounds |

The keeper is a scheduler, not a seller. Everything that could be abused is checked on-chain:

- **Price floor from the pot's own feeds.** `saleFloor(sellToken, sellAmount)` prices the clip off
  Chainlink and applies `maxSlipBips`; `armSale` refuses any `minBuyAmount` below it. A keeper
  cannot sell the basket cheaply to a friendly maker. `saleFloor` is public because the off-chain
  keeper reads it to build `minBuyAmount` before asking the router for a quote.
- **`maxSlipBips` is hard-capped** at `MAX_SALE_SLIP_BIPS` (3%), so no vote can authorise a giveaway.
- **`dailyCap`** bounds the blast radius if the keeper key is lost.
- **Net balance only.** `sellAmount` is checked against `_contractAssetBalance`, so a clip can
  never eat a redeemer's `reserved` leg or an uncollected `fee`.
- **`allowWrapped` is hashed as `false`** and never taken as an argument. Arcus settles illiquid
  names in a wrapped placeholder a maker redeems later; an unlisted wrapper arriving here would be
  backing `_potValue` cannot see.
- **The buy leg must be listed.** Otherwise the proceeds land outside `_assets`, NAV steps down at
  settlement, and mint/redeem can be cycled against the gap.
- **One armed digest at a time**, bounded by `MAX_INTENT_TTL` (15 minutes), so a signed commitment
  cannot long outlive the price it was struck at. `closeSale` kills the armed intent and revokes
  the Permit2 allowance along with the campaign.
- **Fails closed on a bad oracle**: `saleFloor` goes through `_price`, which reverts on a missing
  or stale feed, so `armSale` reverts rather than signing against one.

`ARCUS_SETTLEMENT` is a constant, not a constructor argument — the contract is immutable, so a
different chain is a redeploy, and this way the Permit2 spender cannot be set wrong at deploy time.

### What is still deliberately absent

Mode 2 (a permanently dead, *frozen* stock) is untouched by this. A frozen token cannot be sold,
so it still needs escrow-and-claim, and none of that is in the bytecode. `fireEscape` also stays
exactly as it was — the two are separate exits and neither replaces the other.

### Known ceilings

`soldToday` is charged when a clip is **armed**, not when it settles; the pot never learns whether
a settlement happened. An armed-then-unfilled clip therefore burns daily budget until the window
rolls. Reading Permit2's nonce bitmap would make this exact, if a keeper ever needs to retry
several times inside one window.

`armedIntent` is not cleared after a fill, because nothing calls back to say it filled. Permit2's
consumed nonce makes replay impossible and `MAX_INTENT_TTL` bounds the staleness, so what remains
is untidiness rather than risk.

A sale moves actual balances away from `allocationBips` targets without changing the targets
themselves — the same drift any imbalance produces. Weights are only read when a stock is added.

Verified end-to-end on chain 4663 before being written here: `test/IndexArcusSale.t.sol` forks the
chain so real Permit2 recomputes the digest and calls back into the pot, and the standalone probe
in `acrus_test/` executed a real sale through the live router.
