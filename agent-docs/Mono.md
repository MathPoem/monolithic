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
| `MINTER_ROLE` | OpenZeppelin `AccessControl`. The only role that may mint. Deployer at first, then [`GenerousAuction`](GenerousAuction.md). |
| `DEFAULT_ADMIN_ROLE` | Grants and revokes `MINTER_ROLE`, and calls `setPool`. Stays with the deployer. |
| `genesisCap` | ceiling on the first mint. Immutable. |
| `mint(shares, assetsIn, to)` | owner-only. First call seeds the vault and sets opening NAV (capped). Later calls are non-dilutive. |
| `burn(shares)` | anyone, own balance. |
| `nav()`, `totalIndex()` | the floor and the pot. |
| `pool` | the MONO/INDEX v3 pool. Zero until `setPool`. |
| `setPool(pool_)` | owner-only, callable **once**. |
| `poolPrice()`, `premium()`, `premiumBips()` | the market, and how far it sits above the floor. |

## Roles

OpenZeppelin `AccessControl`, **not** `Ownable` — [`Index`](Index.md) still uses `Ownable`, and the
two are allowed to differ. Two roles:

| Role | Gates | Held by |
| --- | --- | --- |
| `MINTER_ROLE` | `mint` | the deployer for the genesis mint, then the auction |
| `DEFAULT_ADMIN_ROLE` | `setPool`, and granting/revoking `MINTER_ROLE` | the deployer |

The constructor grants the deployer **both**: admin to wire the sale up, minter to run the genesis
mint that sets the opening NAV. `burn` is open to anyone over their own balance and always was.

`GenerousAuction`'s constructor needs this token's address, so this token's constructor cannot name
the auction. The handoff:

1. deploy `Mono` (deployer holds both roles);
2. `mint` once to seed the vault and set the opening NAV;
3. create the MONO/INDEX pool, `setPool(pool)`;
4. deploy `GenerousAuction`;
5. `grantRole(MINTER_ROLE, auction)`;
6. `renounceRole(MINTER_ROLE, deployer)`.

**Step 6 is not optional.** Granting alone leaves *two* minters. Under `Ownable` the handoff was a
transfer and the deployer lost the power by construction; under `AccessControl` a grant only adds,
so the deployer has to give its own half up explicitly. `script/DeployGenerousAuction.s.sol` does
both and logs the resulting `hasRole` on each address.

### What the admin can still do

`DEFAULT_ADMIN_ROLE` can grant `MINTER_ROLE` back to itself at any time. This is a real
weakening versus `transferOwnership`, and it is worth being precise about what it does and does
not buy:

- It **cannot** lower NAV. Every mint goes through the non-dilution check regardless of who holds
  the role, so a rogue minter can only add supply at or above book. The floor invariant is
  enforced in `mint`, not in the access control.
- It **can** add supply the auction did not sell, diluting nobody's backing but competing with the
  harvest for the same premium.

Revoking the deployer's admin role, or moving it to a timelock or multisig, closes that. Nothing in
this contract does it for you.

Why roles rather than ownership: several sales can hold `MINTER_ROLE` at once, and a finished sale
is torn down with `revokeRole` instead of an ownership transfer that has to go somewhere. The
handoff stops being a single-occupancy baton.

`test_vaultHasNoOutflow` still checks there is no INDEX exit — roles change who may add supply,
never whether backing can leave.

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
| `poolPrice()` | the market price, in the same unit as `nav()` |
| `premium()` | `poolPrice() - nav()`, signed |
| `premiumBips()` | the same gap over the floor, in bips. `+1500` is 15% above NAV |
| `premiumCloseAmount()` | the same gap restated as supply: MONO that would close it |
| `maxIssuable(indexAmount)` | the most MONO `mint` will accept that much INDEX for — the inverse of its non-dilution check. `GenerousAuction.claim` clamps to it, see [the NAV clamp](GenerousAuction.md#the-nav-clamp) |

Issuance emits `Minted`. There is no `Withdraw` counterpart, because there is no withdrawal.

### Why there is no entry or exit at all

- **Open deposit at NAV** lets anyone convert backing into MONO at book while MONO trades
  above book. The premium arbs to zero and the harvest has nothing to sell.
- **Open redeem at par** leaves `(A − x·NAV)/(S − x)` unchanged: the floor stops ratcheting
  and the vault drains at flat NAV.

The floor is defended by the **wall** — a pool-side bid below NAV whose fills burn — never by
redemption.

## The pool, and the premium

`nav()` is the floor. `poolPrice()` is what the market actually pays. `premium()` is the gap:

```solidity
premium() == int256(poolPrice()) - int256(nav())
```

Both sides are **INDEX per MONO, 18 decimals**, which is why the comparison is a plain
subtraction with no conversion. That is the reason the pool is MONO/INDEX and not MONO/stablecoin
— a USD-denominated pool would drag Index's whole oracle path into this contract just to make the
two numbers comparable. It also matches where this is going: the real venue is the v4 MONO/INDEX
pool with the TWAP accumulator in our own hook (HANDBOOK §3.6), and `IUniswapV3Pool` is the
placeholder standing in for it.

`premiumBips()` is the same gap divided by the floor, in basis points — `+1500` is MONO trading
15% above NAV. **A threshold belongs against this, not `premium()`**: an absolute gap of 0.15 INDEX
is 15% at a floor of 1.0 and 1.5% at a floor of 10, and the floor only ratchets up.
[`GenerousAuction`'s premium gate](GenerousAuction.md#the-premium-gate) is the caller.

`premium()` is **signed on purpose**. A negative premium — MONO trading below book — is not an
error state; it is precisely the condition the wall exists to buy into. Flooring it at zero would
discard the only half that is actionable today.

### Sizing: the premium as supply

`premiumCloseAmount()` answers the gap in MONO instead of in price — how much MONO sold into the
pool would carry its price back down to `nav()`. [`GenerousAuction`](GenerousAuction.md) uses it as
the entire size of a sale.

Standard v3 single-range math, branching on which side of the pair MONO sits:

| MONO is | pool quotes | selling MONO | amount |
| --- | --- | --- | --- |
| `token0` | INDEX per MONO | drives it **down** | `dx = L x (1/sqrt(T) - 1/sqrt(C))` |
| `token1` | MONO per INDEX | drives it **up** | `dy = L x (sqrt(T) - sqrt(C))` |

`sqrt(C)` is the pool's live `sqrtPriceX96`; `sqrt(T)` is `sqrt(nav())` in the pool's own
orientation. Returns 0 when the market is already at or below book, and 0 when the pool reports no
liquidity.

**Known ceiling — this is a sizing heuristic, not a quote.** `liquidity()` is the **in-range** `L`
only. The formula is exact while the swap stays inside the current tick and **understates** the
moment it would cross one, because real books hold liquidity outside the active tick that this
cannot see. Walking the tick bitmap is the fix; it needs far more of the pool's surface than the
`IUniswapV3Pool` stub exposes, and it lands with the same v4 hook work as everything else here.

Combined with the spot-price ceiling above: the number is read once, from a manipulable source,
with an approximation that errs low. It is right for sizing a sale. It is not right for anything
that has to be exact.

### Why `setPool` is not a constructor argument

A Uniswap pool for MONO/INDEX cannot exist before MONO does: `createPool` takes both token
addresses. So the pool address cannot be a constructor immutable, and cannot be validated at
deploy. Same circularity as the [ownership handoff](#ownership) above. The deployment order is:

1. deploy `Mono`;
2. create the MONO/INDEX pool;
3. owner calls `setPool(pool)`.

`setPool` is `DEFAULT_ADMIN_ROLE` and **one-shot** — a second call reverts `PoolAlreadySet`, so it is
immutable in every sense except the EVM's. The one call it does get checks the pairing
(`token0`/`token1` must be exactly MONO and INDEX, either order) and reverts `InvalidPool`
otherwise. That check is only possible here, which is the argument for a setter over a CREATE2
precomputed address: a wrong precomputed address would be unverifiable and permanent.

`poolPrice()` reverts `PoolNotSet` until step 3, so nothing reads a zero price by accident.

### Known ceiling

`slot0` is **spot** — movable inside a single block by anyone willing to push the pool and move it
back. Same ceiling as `Index._poolPrice`, and the same upgrade (the v4 hook's TWAP accumulator).
Until that lands, `premium()` is a monitoring read. **Do not gate anything that moves value on
it.**

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
