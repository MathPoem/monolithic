# Mono

`src/Mono.sol` — the MONO reserve token and its vault in one contract (HANDBOOK §3.1–3.2).
Interface: `src/interfaces/IMono.sol`. Tests: `test/IndexMono.t.sol`.

## What it is

An ERC-20 (solady) whose supply is a claim on a single asset: INDEX. NAV is
`totalAssets() / totalSupply()`, in INDEX per MONO, 18 decimals — the floor.

**The one invariant everything rests on: `nav()` never decreases.** Two halves:

- **No outflow.** There is no path that moves INDEX out of the contract. Not `withdraw`,
  not `redeem`, not an owner hatch — there is no owner.
- **No dilutive mint.** `issue()` requires `assetsIn·S >= A·shares`, so post-mint NAV
  `(A + assetsIn)/(S + shares)` is >= pre-mint `A/S`. Checked exactly with
  `fullMulDivUp`, rounding against the harvester.

`burn()` retires a claim without touching the pot, so NAV rises. Anything transferred in
raises NAV with no entry point at all — that is how the tax sweep accrues.

## Surface

| | |
| --- | --- |
| `index` | INDEX. Immutable. The only thing held. |
| `asset` | ERC-4626 alias: `address(index)`. |
| `issuer` | the harvest module — [`GenerousAuction`](GenerousAuction.md). The only address that may mint. Set once at construction, handed over once. |
| `genesisCap` | ceiling on the one-shot genesis mint. Immutable. |
| `genesis(shares, assetsIn, to)` | issuer-only, once, capped. Seeds the vault, sets opening NAV. |
| `issue(shares, assetsIn, to)` | issuer-only, post-genesis. The only ongoing mint. Non-dilutive. |
| `burn(shares)` | anyone, own balance. |
| `setIssuer(newIssuer)` | issuer-only, once, post-genesis. See below. |
| `nav()`, `totalAssets()` | the floor and the pot. |

## The issuer handoff

`GenerousAuction`'s constructor needs this token's address, so this token's constructor cannot name
the auction. `setIssuer` is the one-shot resolution:

1. deploy `Mono` with the **deployer** as `issuer`;
2. deployer calls `genesis` to seed the vault and set the opening NAV;
3. deployer calls `setIssuer(auction)` and keeps nothing.

Guarded on both ends: `issuerHandedOff` makes it once and only once, and `genesisDone` is required
because handing off first would leave `issue` reverting `NotGenesis()` forever. `setIssuer` moves no
assets, so "no outflow" is untouched — `test_vaultHasNoOutflow` checks the outflow selectors, and
`test_issuerHandoffIsOneShot` checks this.

## ERC-4626: read surface only, deliberately

Every view is real (`asset`, `totalAssets`, `convertTo*`, `preview*`) so NAV is one standard
call for integrators. Every mutator is closed: `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem`
return 0, and `deposit`/`mint`/`withdraw`/`redeem` revert `Closed()`. Aggregators that read the
max functions correctly see a vault nobody can enter or exit.

Not laziness — the design:

- **Open deposit at NAV** lets anyone convert backing into MONO at book while MONO trades
  above book. The premium arbs to zero and the harvest has nothing to sell.
- **Open redeem at par** leaves `(A − x·NAV)/(S − x)` unchanged: the floor stops ratcheting
  and the vault drains at flat NAV.

The floor is defended by the **wall** — a pool-side bid below NAV whose fills burn — never by
redemption.

## How MONO gets minted

The auction is the only caller of `issue`. On `claim` it passes the INDEX the bid already spent, so
the strike lands here in the same transaction the supply is created. `issue` rejects anything
dilutive; the auction floors bids at `nav()` and clamps a claim through `convertToShares` rather than
letting a stale bid price revert. That contract's doc has the detail:
[The mint path](GenerousAuction.md#the-mint-path).

## Deferred

`ponytail:` in the source — the wall's outflow is not built here. Direction is still
`[LOCKED]` in the handbook (keeper bid vs one-sided range order) and it must buy-and-burn
atomically or it is just a drain. Own contract, own audit. Until then the vault has no exit,
which is the safe default.
