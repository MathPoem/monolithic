# Mono

`src/Mono.sol` — the MONO reserve token and its vault in one contract (HANDBOOK §3.1–3.2).
Interface: `src/interfaces/IMono.sol`. Tests: `test/IndexMono.t.sol`.

## What it is

An ERC-20 (solady) whose supply is a claim on a single asset: INDEX. NAV is
`totalAssets() / totalSupply()`, in INDEX per MONO, 18 decimals — the floor.

**The one invariant everything rests on: `nav()` never decreases.** Two halves:

- **No outflow.** There is no path that moves INDEX out of the contract. Not `withdraw`,
  not `redeem`, not a rescue. Ownership is mint-only.
- **No dilutive mint.** `mint()` requires `assetsIn·S >= A·shares`, so post-mint NAV
  `(A + assetsIn)/(S + shares)` is >= pre-mint `A/S`. Checked exactly with
  `fullMulDivUp`, rounding against the harvester.

`burn()` retires a claim without touching the pot, so NAV rises. Anything transferred in
raises NAV with no entry point at all — that is how the tax sweep accrues.

## Surface

| | |
| --- | --- |
| `index` | INDEX. Immutable. The only thing held. |
| `owner` | OpenZeppelin `Ownable`. The only address that may mint. Deployer, then usually handed to [`GenerousAuction`](GenerousAuction.md). |
| `genesisCap` | ceiling on the first mint. Immutable. |
| `mint(shares, assetsIn, to)` | owner-only. First call seeds the vault and sets opening NAV (capped). Later calls are non-dilutive. |
| `burn(shares)` | anyone, own balance. |
| `nav()`, `totalIndex()` | the floor and the pot. |

## Ownership

`Ownable`, same as [`Index`](Index.md). The deployer is owner at construction. `mint` is
`onlyOwner`; `burn` is not. Ownership does not move INDEX.

`GenerousAuction`'s constructor needs this token's address, so this token's constructor cannot name
the auction. The usual handoff:

1. deploy `Mono` (deployer is owner);
2. owner calls `mint` once to seed the vault and set the opening NAV;
3. owner calls `transferOwnership(auction)`.

After that the auction is the only caller of `mint`. Ownership is not one-shot — the new owner can
transfer again. `test_vaultHasNoOutflow` still checks there is no INDEX exit.

## A plain ERC-20, not an ERC-4626 vault

MONO is `solady/ERC20` plus the vault state. The 4626 entry and exit surface is **absent from
the bytecode** — no `deposit`/`mint(shares,to)`/`withdraw`/`redeem`, and no `max*`.
`test_noVaultEntryOrExitInBytecode` is the guard. Owner `mint(shares, assetsIn, to)` is a
different function.

Why not claim the standard and close it? Returning 0 from `max*` is technically conformant,
which is the worst place to be: it passes every automated sniff test and fails the real one. A
4626 indexer detects a vault; an integrator builds an unwind or liquidation route on `redeem()`;
that route always reverts. The liveness bug lands in *their* protocol and gets attributed to
this token. The one real benefit — NAV in a single standard call — is already served by `nav()`,
which promises nothing it cannot do.

What is kept — no 4626 names at all, because every one of them either promises an exit or
duplicates something clearer:

| | |
| --- | --- |
| `index()` | the INDEX it holds |
| `totalIndex()` | the pot |
| `nav()` | the one-call price read |
| `maxIssuable(indexAmount)` | the most MONO `mint` will accept that much INDEX for — the inverse of its non-dilution check. `GenerousAuction.claim` clamps to it, see [the NAV clamp](GenerousAuction.md#the-nav-clamp) |

Issuance emits `Minted`. There is no `Withdraw` counterpart, because there is no withdrawal.

### Why there is no entry or exit at all

- **Open deposit at NAV** lets anyone convert backing into MONO at book while MONO trades
  above book. The premium arbs to zero and the harvest has nothing to sell.
- **Open redeem at par** leaves `(A − x·NAV)/(S − x)` unchanged: the floor stops ratcheting
  and the vault drains at flat NAV.

The floor is defended by the **wall** — a pool-side bid below NAV whose fills burn — never by
redemption.

## How MONO gets minted

The first `mint` is the seed: no prior NAV, so the ratio you pass *is* the floor, capped at
`genesisCap`. `genesisDone` stays true even if supply later burns to zero, so that path cannot
run again. After the handoff the auction is the only caller. On `claim` it passes the INDEX the
bid already spent, so the strike lands here in the same transaction the supply is created.
Later `mint`s reject anything dilutive; the auction floors bids at `nav()` and clamps a claim
through `maxIssuable` rather than letting a stale bid price revert. That contract's doc has the
detail:
[The mint path](GenerousAuction.md#the-mint-path).

## Deferred

`ponytail:` in the source — the wall's outflow is not built here. Direction is still
`[LOCKED]` in the handbook (keeper bid vs one-sided range order) and it must buy-and-burn
atomically or it is just a drain. Own contract, own audit. Until then the vault has no exit,
which is the safe default.
