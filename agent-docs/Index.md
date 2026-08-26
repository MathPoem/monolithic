# Index

`src/Index.sol` is the in-kind basket wrapper described by HANDBOOK §5. Its public ABI is in
`src/interfaces/IIndex.sol`.

## Construction

The constructor takes a `Stock[]` — each entry carries the asset, allocation in basis points,
and Chainlink price feed. Every stock must be non-zero and the allocations must sum to 10,000.
`setPriceFeed` replaces a feed after deployment.

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
argument carries the token, its post-add target weight in basis points, and its price feed.

Requirements:

- the stock must not already be in the basket;
- asset, allocation, and feed must all be non-zero;
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

`setPriceFeed` and `withdrawFees` are **not** timelocked. A feed swap moves no assets and may need
to be immediate (an aggregator deprecation); collected fees are already earned and outside the pot
valuation, so delaying them protects nobody.

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
