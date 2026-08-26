# Index.sol — review (2026-08-01)

Reviewed against the ratified design (DECISIONS D12/D14/D18/D19/D20, P6g/P6j/P7,
audit riders). Verdict: core math is excellent — fix layer, not rebuild.

## What's right (keep as is)

| Piece | Why it's right |
|---|---|
| `deficitToMint()` fixed-point | Correctly solves "deposits lift the target too" — without it the channel never closes. Textbook D19 |
| Termination: per-INDEX ratio, sub-1-raw-unit = rounding | Exactly the ratified rule |
| 1% haircut charged against the minter | Channel price = 1.01× fair — the pot wins every fill |
| Bottom-up feed pricing, no pool quotes | As ratified (D18) |
| 1h staleness gate | Doubles as market-hours-only for free. Keep; delete the TODOs |
| MIN_LIQUIDITY + MIN_FIRST_MINT | Proper inflation-attack guard |
| Exclusive mint during reallocation | You were right, we were wrong — now ratified. Users buy INDEX on the pool during campaigns; arbs source the new stock, mint at the haircut, sell INDEX — demand itself fills the deficit, and the deficit only shrinks. Keep `burn()` ungated (that's the price floor of the arb band) |

## Must-fix

### 1. One frozen stock bricks ALL redemption
`burn()` sends every leg in one tx — if a single stock's transfer reverts, nobody
can redeem anything.
**Why it matters:** the issuer can really freeze/blocklist a token (verified
powers). One frozen stock out of ten must not lock all ten. Ratified behavior
(P6g): skip the frozen leg, user forfeits that sliver to the pot (their choice,
shown in UI), everything else pays out. No IOUs — that design was considered and
killed.
**Fix:** per-leg transfer with skip-on-revert + `LegSkipped` event.
**Test:** freeze 1 of 2 mock stocks → burn pays the other leg.

### 2. Owner can swap any price feed, anytime
`setPriceFeed` + `addStock` are plain `onlyOwner`, no timelock.
**Why it matters:** whoever holds the key can point the channel at a fake feed,
open a campaign, mint INDEX against garbage prices, and drain the pot via burn.
The haircut can't help — the feed is attacker-controlled. Our public promise is
"composition can't move until governance exists," and that must be provable from
code, not from trusting us.
**Fix:** composition + feed functions callable only by a governance address that
starts UNSET and is set exactly once (at stage-2). Additionally: no feed swaps
while `reallocating`, and validate the new feed (decimals, fresh round) on set.

### 3. No daily cap on the channel
**Why it matters:** the 1% haircut only covers *honest* feed error (feeds drift up
to their ~0.5% deviation setting before updating — bottom-up pricing cancels the
shared part, haircut covers the rest). A *broken or hacked* feed can be off by
10% — no haircut covers that. The defense there is blast radius: cap what the
channel can mint per day, so a bad feed leaks basis points per day instead of the
whole campaign in one block, and we have days to react.
**Fix:** per-24h mint cap during reallocation (tunable under a hardcoded ceiling,
~a few % of pot value/day).

### 4. No mint/redeem fee — decision needed BEFORE deploy (principal's call)
**Why it matters:** two reasons a small fee (~0.05% each way) exists in the
design. (1) Security: there's a family of dust/rounding/mint-redeem-cycling
attacks that each harvest well under 0.1% per loop — a 0.05% fee makes all of them
unprofitable at once, the cheapest firewall there is. (2) Revenue: half the fee
goes to the treasury as freshly-minted INDEX (matched by assets kept in the pot —
nobody is diluted). If built: charged in-kind, and the GENESIS wrap is exempt
(taxing the founding deposit would just hand the treasury a slice of our own seed).
**Fix:** deploy-time constant (0 = no fee) so the decision can land either way
without a redeploy. The contract is immutable — this can't be added later.

### 5. Fire-escape surface missing
No `returnProceeds` / `escrowSlice` / `deregister`.
**Why it matters:** if a stock dies or freezes permanently, there is currently no
lawful way to ever get it out of the pot — and per fix 1, it degrades everyone's
exit meanwhile. The escape machinery must ship day 1 (dormant, no valid caller
until governance) so it's audited once with everything else.
**Fix + full reasoning:** see FIRE-ESCAPE.md — the two modes, function shapes, and
tests.

## Smaller gaps
- **Can't raise an existing stock's target** — only add-new. Allowed by the
  ratified composition policy; fine to defer, but say so explicitly.
- **One campaign at a time** — fine for v1, document it.
- **Genesis parity quirk:** empty-pot mint takes 1 raw unit of EVERY stock per
  share, ignoring allocations. Harmless for our single-stock genesis; assert
  single-asset at genesis so nobody ever multi-asset-deploys it wrong.
- **Allocation bips rounding drift** across repeated `addStock` — cosmetic (bips
  only read at add time), leave a comment.

## Priority
1. Frozen-leg skip (funds safety)
2. Governance gating + feed lockdown (drain vector)
3. Daily cap
4. Fee decision (principal)
5. Fire-escape hooks, then smaller gaps
