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

While the channel is open, minting charges only the new stock and `burn` is disabled. Once its per-INDEX target is met,
ordinary pro-rata minting and burning resume.

## Composition reduction (D12)

No function removes a basket stock or lowers a per-INDEX quantity. Asset removal and the
single-stock surplus redeem path are deliberately absent from the bytecode.
