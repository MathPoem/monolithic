# MONOLITHIC — Implementation Plan

**Source-of-truth order (set 2026-07-31):**
1. **`image.png`** — the architecture diagram. Wins wherever it contradicts the handbook.
2. `HANDBOOK.md` — governs everything the picture is silent about (the majority of detail).
3. Verified chain + v4/CCA facts from `lib/` — these are physics, not preferences, and
   override both when something is simply not buildable as drawn.

Where the picture is silent, the handbook's ratified value is used and marked `[HB]`.
Where I had to choose because neither says, it's marked `[DEFAULT]` with the reasoning.

---

## 1. What the picture mandates

Read off the diagram, in its own terms:

| # | The picture says | Handbook said | Now |
|---|---|---|---|
| 1 | `$MONO (ERC-4626)` holding NVDA + AAPL + MSFT directly | vanilla ERC-20; separate vault; single asset (AAPLx) | **MONO is a tokenized multi-asset vault** |
| 2 | `wrapper for stocks` → `Indx`, minted by users depositing stocks in proportion | UNIT deferred to stage 3; minting **vault-only** | **Indx ships day one, public in-kind mint** |
| 3 | Machine pool = `Indx / $Mono`; also `Indx / USDG`; also `$MONO / $LITH` | MONO/AAPLx + MONO/WETH satellite | **Three pools as drawn** |
| 4 | Harvest = **auction (stage 1) + staking (stage 2)**; "once LITH is deployed the auction won't be needed" | auctions killed; continuous accrual curve only | **Per-block auction now, staking later** |
| 5 | Auction min bid = `NAV + premium/2`; staking strike = `nav + 0.6·premium` | one `k = 0.5` | **Two k's: 0.5 auction, 0.6 staking** |
| 6 | Auction "must look at the pool price" | TWAP-only triggers `[LAW]` | **`max(spot, TWAP)`** — see §2.3 |
| 7 | "if premium too high during several blocks then harvest amount increases" | capacity escalator, 2%/wk ceiling | escalator as drawn, ceiling kept `[HB]` |
| 8 | Floor: "if MONO dumps to the NAV price the vault uses its shares to buy MONO from the market" | wall bid at `NAV·(1−tick)`, fills burned | **market buy as drawn**, tick + burn kept `[HB]` — §2.2 |
| 9 | Hook: "tax **and distribution** depending on premium" + floor support | tax → 100% vault | tax curve as drawn; split `[DEFAULT]` 100% vault |
| 10 | MONO staking → LITH rewards; LITH staking → per-block harvest rights, 7d cooldown | tranche curve; warmup + cooldown | stage 2, as drawn + handbook hygiene |

Consequence: **stage 1 is now the handbook's stage 1 + stage 3 + an auction.** Budget
~2,400 lines of consequential Solidity, not 1,100, and one admin-path oracle that the
single-asset design did not need.

---

## 2. The three places the picture needs a knob, not a rewrite

The picture is a diagram, not a spec, so on three points it's underdetermined in a way that
silently costs a core property. I've kept the picture's mechanism and added the handbook's
calibration knob rather than substituting the handbook's mechanism.

### 2.1 ERC-4626 mint/redeem must both be gated
A conformant 4626 is fatal here, and the picture doesn't ask for conformance — it labels
MONO a vault token:

- **`deposit`/`mint` open at NAV** = anyone converts backing into MONO at book while MONO
  trades at 1.2× book. The premium arbs to zero and the auction has nothing to sell.
- **`redeem` open at par** = exit at exactly NAV leaves `(assets − x·NAV)/(supply − x)`
  **unchanged**, so the floor stops ratcheting and the vault drains at a flat NAV. The
  ratchet exists only because the wall pays 0.99 for a 1.00 claim.

**Implementation:** MONO implements the ERC-4626 **read surface** — `asset()` (= Indx),
`totalAssets()`, `convertToAssets`, `convertToShares`, `previewRedeem` — over the multi-asset
vault, so NAV is one standard call for integrators and dashboards. `maxDeposit`/`maxMint`
return 0 for everyone except the auction/harvest module; `maxWithdraw`/`maxRedeem` return 0.
`deposit`/`redeem` revert for the public. The floor is the pool-side bid the picture draws
(§2.2), not redemption.

`[DEFAULT]` — this is 4626-shaped, not 4626-conformant, and the contract must say so in
NatSpec: aggregators index 4626 vaults and trust `maxWithdraw`. The alternative that *is*
conformant — open `redeem` at `NAV·(1−tick)`, shares burned, haircut accreting to holders —
would give a stronger floor than any market bid (it works at zero liquidity) and preserve
the ratchet exactly. It adds a path the picture doesn't draw, so it's not the default. Worth
30 minutes of your time before P1 starts.

### 2.2 The wall needs a tick
The picture says the vault buys "if MONO dumps to the NAV price." Bidding *at* NAV means
buying a 1.00 claim for 1.00 — the floor holds but never rises, and the accretion engine in
§3.3 of the handbook disappears. The picture doesn't specify a tick, so this is silence, not
contradiction: `wallTick` is a constructor parameter, default **0.75%** `[HB]`, and fills are
**burned** `[HB]`, which is what makes the retire-below-NAV spread redistribute.

Set it to 0 and the floor goes flat. The knob is deliberate — leave it tunable.

### 2.3 "Must look at the pool price" vs TWAP-only
Spot-only is a one-block paint attack: push spot up, win a cheap auction against an inflated
premium, dump. TWAP-only is what the handbook mandates but it lags, which leaks premium on
real pumps — the picture's instinct is right that a stale reading is wrong for an auction.

**Implementation:** `premium = max(spot, TWAP)` for the auction floor and the strike, TWAP
alone for the ≥15% gate. Painting spot *up* only raises what a bidder pays; painting it down
can't get under the TWAP floor. This is PROPOSALS P3's brainstormed shape, and it satisfies
both the picture's "look at the pool price" and the paint-resistance the LAW is protecting.

---

## 3. Load-bearing v4 facts (verified against `lib/`)

Physics. These override both docs.

1. **A hook cannot take the tax directly.** Pulling value out of a swap needs
   `beforeSwapReturnDelta`, which requires the Labs allowlist and loses auto-routing on
   uniswap.org. So tax = **dynamic LP fee** → accrues to POL positions → keeper sweeps to
   vault. Verified: `LPFeeLibrary.DYNAMIC_FEE_FLAG = 0x800000`,
   `OVERRIDE_FEE_FLAG = 0x400000`, `MAX_LP_FEE = 1_000_000` pips.
2. **Per-swap fee override is legal without return-delta** — `beforeSwap` returns
   `(bytes4, BeforeSwapDelta, uint24)`; `ZERO_DELTA` + `fee | OVERRIDE_FEE_FLAG`. Tax curve,
   launch decay, and harvester exemption all ride this one path.
3. **v4 ships no oracle** at our pinned commits — the accumulator lives in our hook.
4. **The floor bid needs no custom accounting.** `SwapParams.sqrtPriceLimitX96` exists, so
   the vault swaps Indx→MONO with the limit at the wall price and v4 fills only down to it.
   The pool enforces the cap ⇒ **floor defense can be permissionless**, no keeper trust, no
   MEV window to police.
5. **Hook permissions live in the address bits** ⇒ CREATE2 at a mined salt via
   `v4-periphery/src/utils/HookMiner.sol`. Also resolves deploy circularity (§7).
6. **v4-periphery is pinned to `60cd938`, not main** — main deleted `src/utils/BaseHook.sol`
   (PR #510). Don't bump without re-homing it.
7. **CCA is one-shot and immutable** (`floorPrice`, `endBlock`, `totalSupply` fixed at
   deploy; bids persist across blocks). It cannot be the per-block harvest auction — see
   §5.4. Usable only for the launch, if at all.

---

## 4. Architecture

```
   User ──buy stocks in proportion──►┌──────────┐
   User ──USDG──►[Indx/USDG pool]───►│   Indx   │  mirror wrapper, public in-kind mint
                                     │  ERC-20  │  redeem in-kind always open
                                     └────┬─────┘
                                          │ asset() / quote asset
   ┌───────────────┐  holds       ┌───────▼──────────┐
   │ NVDAx AAPLx   │◄─────────────│      MONO        │ 4626 read surface
   │ MSFTx  …      │  proportions │  multi-asset     │ mint: auction/harvest only
   └───────────────┘  == Indx     │  vault + token   │ redeem: disabled
                       recipe     └───┬─────────┬────┘
                                      │         │ supplies POL
                    ┌─────────────────▼───┐  ┌──▼─────────────────┐
                    │  HarvestAuction     │  │ [Indx/MONO pool]   │ machine pool
                    │  per-block clearing │  │  + MonoHook        │ tax · TWAP · floor
                    │  floor NAV+0.5·prem │  └────────────────────┘
                    │  gate ≥15% · escal. │
                    └─────────────────────┘  [MONO/LITH pool]  ── stage 2
```

`IntakeRouter` keeps vault proportions equal to the Indx recipe — see §5.2, because
oracle-free NAV depends on it.

---

## 5. Contract specs

### 5.1 `MONO.sol` — ~260 lines
ERC-20 + multi-asset vault + 4626 read surface.

```solidity
function asset() external view returns (address);          // Indx
function totalAssets() public view returns (uint256);      // vault expressed in Indx baskets
function nav() public view returns (uint256);              // totalAssets * 1e18 / totalSupply
function convertToAssets(uint256) external view;           // = 4626 semantics
function coverage() external view returns (uint256);
function mintTo(address,uint256) external onlyIssuer;      // auction (s1) / harvest (s2)
function settleBacking(address token, uint256 amt) external onlyIssuer;
function defendFloor(uint256 maxSpend) external;           // permissionless, §3.4
function maxDeposit(address) external pure returns (uint256) { return 0; }  // §2.1
```

- **`totalAssets()` is oracle-free only while vault proportions match the Indx recipe.** Then
  the vault is exactly *m* baskets and `NAV = m/supply` — pure arithmetic, no feed. Drift
  breaks this, which is why the intake router exists and why `totalAssets` must value the
  vault as `min over assets (balance_i / recipe_i)` — conservative rounding, never
  optimistic. Surplus above the min is real but uncounted until rebalanced.
- **`uiMultiplier`-aware for every stock leg.** Corporate actions come through the
  multiplier, not a rebase. This is the most dangerous line in the codebase: a missed
  multiplier misprices NAV, the auction floor, and the floor bid simultaneously — and with N
  assets there are now N places to miss it.
- **`defendFloor`** — permissionless. Computes the wall price from `nav` and `wallTick`,
  swaps Indx→MONO with `sqrtPriceLimitX96` at that price, **burns everything received**,
  reverts on zero fill. Reverts if the auction settled this block (wall/harvest mutual
  exclusion `[HB LAW]`).
- **No other outflow.** No admin withdraw, no rescue, no sweep.
- **`haltOnIssuerEvent()`** — freezes auction + floor defense on proof of an AAPLx-family
  `Paused`/`Blocked`/`AdminBurn`/`Upgraded` event. Halt only, never spend; un-halt timelocked.
  With N stock legs this is N times more likely to fire than the single-asset design.

### 5.2 `Indx.sol` + `IntakeRouter.sol` — ~300 lines
The picture's `wrapper for stocks`. Public, in-kind, both directions.

- **`mint(uint256 baskets)`** — pulls each recipe leg in exact proportion, rounding **up** in
  the pot's favour; mints Indx 1:1 with baskets. This is ETF creation, and the reason the
  handbook restricted minting (donation-farming) doesn't bite when the deposit must be exact
  in-kind at the current recipe — a donor can only ever hand over full baskets.
- **`redeem(uint256 baskets)`** — the reverse, rounding down. Always open, no gate. This pins
  Indx to book and is what makes it safe for retail to hold.
- **Recipe** = the vault's current proportions, read from MONO, so the mirror is definitional
  rather than maintained.
- **`IntakeRouter`** — routes tax proceeds and auction proceeds into the **lowest-filled
  bucket** so vault proportions converge on the recipe instead of drifting. Without this,
  `totalAssets()`'s conservative `min` silently under-counts and NAV understates the floor.
- **Composition change** (adding a stock) = value-matched swap, admin path, timelocked, the
  **one** place an oracle is allowed. Conservative rounding, and it cannot reduce
  `totalAssets()` — assert that.

### 5.3 `MonoHook.sol` — ~340 lines
On the Indx/MONO pool. Permissions: `afterInitialize`, `beforeSwap`, `afterSwap`. **No
return-delta flags.**

- **Oracle (~120 lines):** ring buffer of `(uint32 timestamp, int56 tickCumulative)` written
  in `afterSwap`, seeded at `afterInitialize`, extrapolating from the last observation using
  the current tick when trading has been quiet — mandatory on a chain with a ~70% dead
  calendar. `observe(secondsAgo)` takes the window as a **read-time argument**, so the gate
  can read 24h and the auction 30m off one buffer with no redeploy.
- **Tax curve (~90 lines)** in `beforeSwap`: premium from `max(spot, TWAP)` (§2.3) → zone fee
  `[HB]` (floor 1.5%/0.5%, mid 1%/1%, premium 1%/3%) → × launch decay → 0 if the sender is
  `HarvestSellRouter` on a MONO sell → return `fee | OVERRIDE_FEE_FLAG`. Hard-capped at 3%.
- **Floor support:** the hook cannot buy (no return-delta), so "floor price support in the
  pool" is implemented as the permissionless `defendFloor` in §5.1, callable by anyone
  including the keeper, price-capped by the pool. The hook's role is to *publish* the trigger
  (`floorBreached()` view) so bots race to call it — which is the desired MEV: the only
  profitable action is defending the floor.
- **"Distribution depending on premium"** — the picture's phrase. `[DEFAULT]` 100% of tax to
  vault, one immutable `taxSplitBps` constant at 0 so a split is a one-line change if you
  decide the P1 company share later.

### 5.4 `HarvestAuction.sol` — ~420 lines
The picture's stage-1 issuance channel: **per-block clearing auction**, written fresh, not
CCA. CCA cannot do this job — its `floorPrice` is immutable (can't track a NAV that rises on
every tax event), its bids persist across blocks (the stale-bid option the handbook killed
auctions over), and its unsold supply rolls forward uncapped (breaks the drip cap). We take
CCA's *clearing algorithm* and drop its *lifecycle*:

- **Per-block, no cross-block bids.** A bid is valid for the block it lands in. This is the
  single change that removes the stale-bid option: the floor is recomputed from live NAV and
  `max(spot, TWAP)` at settlement, so a bidder can never hold an option against a moved NAV.
- **Floor** = `NAV + 0.5·premium` (the picture's `premium/2`), immutable `k`.
- **Uniform clearing price** per block: bids above clear fully, bids at clearing fill
  pro-rata — CCA's shape, and the reason to keep it is that everyone in a block pays the same
  price, which is un-gameable by ordering within the block.
- **Gate:** settles only while TWAP premium ≥ 15% (`[HB]`, the picture agrees).
- **Escalator:** "premium too high for several blocks → harvest amount increases" — per-block
  issuance allowance rises with sustained premium, hard-capped at **2%/wk `[HB LAW]`**. The
  picture gives no ceiling; without one the escalator is an uncapped mint, so the cap stays.
- **Proceeds 100% to vault** via `settleBacking`, in Indx (the quote asset), which the intake
  router redeems in-kind into the lowest-filled legs.
- **Retirement:** `setIssuer(harvest)` at stage 2 — "once LITH is deployed the auction won't
  be needed." One timelocked switch, the only admin economic function.

### 5.5 `PremiumCurve.sol` — ~90 lines, pure
One curve, read three times (`[HB]` §9 hygiene): `premium()`, `taxFee()`,
`issuanceAllowance()` (the escalator, clamped at the 2%/wk ceiling internally),
`tapRate()`. Pure ⇒ fuzzable standalone and liftable into `sim/` so campaign 2 simulates the
shipping numbers.

### 5.6 `HarvestSellRouter.sol` — ~60 lines
Mint-and-sell atomically so the fee exemption is provable — the router sells only MONO minted
in the same transaction and never holds MONO across transactions. Without it the exemption is
a tax hole.

### 5.7 Stage 2 (specified, not built)
`LITH` ERC-20 fixed supply · `LithStaking` (7d cooldown per picture + 3–7d accrual warmup
`[HB]`) · per-block harvest rights pro-rata to stake, `strike = nav + 0.6·premium`, rights
**accrue while premium is low and bank** (picture and handbook agree) · `MonoStaking` →
LITH rewards from a finite budget (`[HB]` rewards-only-from-revenue-or-tranches law) ·
`MONO/LITH` pool · auction retired.

---

## 6. Test plan

The invariants are the product. Foundry invariant tests over a handler that swaps, taxes,
bids, settles, defends, mints and redeems Indx:

| Invariant | Guards |
|---|---|
| `nav()` never decreases across any op sequence | the whole thesis |
| MONO supply rises only via the current issuer | issuance law |
| vault legs fall only in `defendFloor` and Indx in-kind redemption | outflow law |
| every floor fill priced ≤ `nav·(1−wallTick)` | the 0.99-for-1.00 ratchet |
| no settlement while TWAP premium < 15% | gate |
| minted over any rolling 7d ≤ 2% of supply | escalator ceiling |
| `defendFloor` and auction settlement never share a block | mutual exclusion |
| Indx mint→redeem round-trip never profits the caller | wrapper rounding |
| vault proportions stay within ε of the recipe under random intake | keeps NAV oracle-free |
| `totalAssets()` monotone under composition change | the one admin oracle |

Plus:
- **Oracle-independence test:** point every Chainlink feed at a mock that **reverts**, run the
  entire suite. Tax, floor, gate, auction must all still pass. That's the oracle-free claim as
  an executable assertion — cheap, and it fails loudly the day someone adds a feed read to the
  money path.
- **Fork tests on 4663:** real stock tokens — `uiMultiplier` change mid-life on one leg (does
  NAV track it? does the recipe?), `adminBurn` against the vault (honest coverage + halt),
  global pause during a floor defense.
- **Curve parity:** `PremiumCurve` fuzz vectors diffed against `sim/`'s Python.
- **Auction adversarial set:** spot-paint into a bid, sandwich the settlement, bid-then-dump in
  one block, and the C1 spot-pump raid from §9 — each must lose money.

---

## 7. Deploy sequence

Circular deps (MONO needs Indx as `asset()`, Indx reads MONO's recipe, hook reads MONO) are
resolved by precomputing addresses, **not** by mutable setters.

1. CREATE2 factory; precompute MONO, Indx, IntakeRouter, HarvestAuction addresses.
2. Deploy Indx, MONO, IntakeRouter, HarvestAuction — every cross-reference immutable.
3. `HookMiner.find` a salt for `AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP`; deploy MonoHook.
4. Seed the vault in-kind (treasury stocks) → mint genesis Indx → mint genesis MONO. Genesis
   MONO is the one non-auction mint: cap it in the constructor, one shot, so the issuance law
   stays checkable.
5. `initialize(Indx/MONO, DYNAMIC_FEE_FLAG, hook)`; seed POL; LP → multisig+timelock `[HB]`.
6. `initialize(Indx/USDG)` + POL for retail entry (picture's second pool).
7. Deploy HarvestSellRouter (registered immutably in the hook).
8. Verify on Blockscout; publish the address set — scam lookalikes exist `[HB]`.

---

## 8. Parameters

Immutable: auction `k = 0.5`, staking `k = 0.6`, 2%/wk ceiling, 3% fee ceiling, floor
mechanism, LITH supply. Timelocked 48–72h within ceilings: escalator base rate, fee levels,
gate threshold, decay half-lives, `setIssuer` at stage 2.

| Undecided | Taken | Revisit |
|---|---|---|
| `wallTick` | **0.75%** `[HB]` — §2.2, 0 makes the floor flat | campaign 2 |
| tax split ("distribution") | 100% vault, `taxSplitBps = 0` | P1 package |
| fee curve shape | zone-stepped behind `taxFee()` | campaign 2 (P2) |
| premium reading | `max(spot, TWAP)`; gate TWAP-only | campaign 2 (P3) |
| basket recipe | NVDAx + AAPLx + MSFTx, cap-weighted `[HB]` (equal-weight needs selling winners — banned) | pre-launch |
| 4626 conformance | read surface only, mint/redeem gated — §2.1 | **before P1** |
| launch mechanics | POL seed; CCA only if `currency` can be Indx and the LBP strategy attaches our hook | pre-launch |
| USDG buffer | deleted, no intake path `[HB]` | — |

Blocking nothing yet, mandatory before mainnet: whether `uiMultiplier` is already applied in
`balanceOf` for each stock leg (read `Stock.sol` at `0xb354…`), and the v4 fee-switch /
CCA-family outcome.

---

## 9. Phases

| Phase | Deliverable | LOC | Gate |
|---|---|---|---|
| P1 | `Indx` + `IntakeRouter` + in-kind mint/redeem | ~300 | round-trip-never-profits invariant green |
| P2 | `MONO` multi-asset vault, `nav()`, 4626 reads, `defendFloor` | ~260 | NAV-monotonicity invariant green |
| P3 | `MonoHook` oracle + tax curve + launch decay | ~340 | TWAP survives a 48h gap; reverting-feed suite green |
| P4 | `PremiumCurve` + `HarvestAuction` | ~510 | gate/escalator/drip-cap + adversarial auction set green |
| P5 | `HarvestSellRouter` + exemption | ~60 | exemption unreachable except via router |
| P6 | Deploy scripts, three pools, POL seed | ~200 | testnet dry run on 4663 |
| P7 | Keeper (TS): sweeps, sentinels, floor bots | — | sentinels fire on simulated issuer events |
| P8 | Audit prep: NatSpec, invariant report, issuer-risk disclosure | — | external audit (mandatory) |

Stage 2 (LITH, both staking contracts, auction retirement) after P8.

Ordering note: P1 before P2 is deliberate — MONO's `asset()` is Indx, so the wrapper has to
exist and be trustworthy before the vault denominated in it means anything.

---

## Appendix — what the flip to picture-first cost

For the record, so it's a decision and not an accident:

1. **Scope roughly doubled.** Multi-asset vault + wrapper + intake router + a third pool were
   the handbook's stage 3, gated on "affordability" precisely because they're expensive.
2. **One oracle entered the system.** Composition change can't be done oracle-free. It's
   admin-path, timelocked, conservatively rounded, and cannot reduce `totalAssets()` — but the
   "zero feeds anywhere" property is now "zero feeds in the money path."
3. **N× issuer exposure.** Every stock leg carries `adminBurn`/pause/blocklist risk from a
   single EOA. Three legs, three counterparties, and the halt path fires more often.
4. **The auction is bespoke.** CCA's lifecycle is unusable, so ~420 lines of clearing logic
   become ours to audit — the most adversarial surface in the build, and it ships at launch
   rather than at stage 2 when LITH staking replaces it anyway.

Cheapest de-risk if any of that lands badly: build P1–P3 (wrapper, vault, hook) and run the
auction in `sim/` against the accrual curve before committing to P4. The economics question —
does per-block clearing extract more premium than `NAV + k·premium` — is answerable without
Solidity, and it decides whether 420 adversarial lines are worth shipping at launch.
