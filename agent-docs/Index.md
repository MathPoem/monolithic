# Index

`src/Index.sol` is the in-kind basket wrapper described by HANDBOOK §5. Its public ABI is in
`src/interfaces/IIndex.sol`.

## Construction

The constructor takes a `Stock[]` — each entry carries the asset, allocation in basis points,
and Chainlink price feed. Every leg must be non-zero and the allocations must sum to 10,000.
`setPriceFeed` replaces a feed after deployment.

## Mint and burn

`mint(shares, to)` deposits the quoted basket assets and issues INDEX. `burn(shares, to)` burns
the caller's INDEX and transfers its pro-rata slice of the pot to `to`. The quote helper for the
outgoing assets remains `proceedsOfRedeem(shares)`.

## Reallocation proposal

`startReallocation(Stock[] allocation)` receives the complete target basket, not only
the new leg. Each entry contains the stock token, its target allocation in basis points, and its
price feed.

The proposal must:

- contain every current basket leg exactly once;
- contain exactly one new leg, because the deficit channel fills one asset at a time;
- contain no zero asset, zero allocation, zero feed, or duplicate asset; and
- sum to exactly 10,000 basis points (100%).

All validation happens before storage is changed. The current legs' allocation metadata and feeds
are updated, the new leg is appended, and its allocation is converted once into the raw
`targetPerIndex` quantity used by the deficit channel.

While the channel is open, minting charges only the new leg. Once its per-INDEX target is met,
ordinary pro-rata minting resumes. `burn` stays pro-rata throughout — it is never gated.

## Composition reduction (D12)

No function removes a basket leg or lowers a per-INDEX quantity. Asset removal and the
single-leg surplus redeem path are deliberately absent from the bytecode.
