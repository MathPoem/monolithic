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

## Composition reduction (D12)

No function removes a basket stock or lowers a per-INDEX quantity. Asset removal and the
single-stock surplus redeem path are deliberately absent from the bytecode.
