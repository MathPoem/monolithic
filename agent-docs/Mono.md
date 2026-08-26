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
| `asset` | `address(index)`, under the name integrators expect on a backed token. |
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

## A plain ERC-20, not an ERC-4626 vault

MONO is `solady/ERC20` plus the vault state. The 4626 entry and exit surface is **absent from
the bytecode** — no `deposit`/`mint`/`withdraw`/`redeem`, and no `max*`. `test_noVaultEntryOrExitInBytecode`
is the guard.

Why not claim the standard and close it? Returning 0 from `max*` is technically conformant,
which is the worst place to be: it passes every automated sniff test and fails the real one. A
4626 indexer detects a vault; an integrator builds an unwind or liquidation route on `redeem()`;
that route always reverts. The liveness bug lands in *their* protocol and gets attributed to
this token. The one real benefit — NAV in a single standard call — is already served by `nav()`,
which promises nothing it cannot do.

What is kept, because the names are the clearest ones for the job and none of them implies an
exit:

| | |
| --- | --- |
| `asset()` | `address(index)`, under the name integrators expect on a backed token |
| `totalAssets()` | the pot |
| `nav()` | the one-call price read |
| `convertToShares` / `convertToAssets` | the two conversions. `GenerousAuction.claim` depends on `convertToShares` — see [the NAV clamp](GenerousAuction.md#the-nav-clamp) |

Issuance still emits `Deposit`, borrowed from 4626 so indexers read a mint as one. There is no
`Withdraw` counterpart, because there is no withdrawal.

### Why there is no entry or exit at all

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
