# Architecture-conformance review — spec vs. implementation

**Date:** 2026-08-02 · **Spec sources:** `HANDBOOK.md` v2.1, `image.png`, `implementation.md`,
`agent-docs/MonoAuction.md` · **Code under review:** `src/MonoAuction.sol`, `src/Mono.sol`,
`src/Index.sol`, `test/`, `script/`.

## Executive summary

`src/MonoAuction.sol` is not the harvest mechanism any spec source describes. HANDBOOK §3.5
ratifies (D15) a **perpetual streaming book**: formula bids `strike = NAV + x·premium`
recomputed per block off TWAP, no start/end, no expiry, escrow drawn down to the vault
continuously, top-bid-only accrual. `image.png` draws a **per-block clearing auction** at
`min bid = NAV + premium/2`. The code is a third thing: a **fixed-price, fixed-window,
pay-as-bid tick book** with `startBlock`/`endBlock`, idle rolls, and a constant `floorPrice`
set at creation. It never reads NAV, premium, or a TWAP; it has no gate, no capacity meter,
no treasury split, no mint. It is a generic token-sale auction that happens to be named
`MonoAuction`.

Nothing connects it to `Mono.sol`. `MonoAuction` never imports `Mono`, never calls
`issue()`, never holds INDEX. `Mono.genesis()`/`issue()` require `msg.sender == issuer` and
pull INDEX **from** the issuer — `MonoAuction` has neither function nor INDEX balance, so a
deployment with `issuer = MonoAuction` can never mint the genesis supply. There is no test
and no script that deploys the two together; `script/DeployLocal.s.sol` wires the auction to
two `TestERC20`s.

Of HANDBOOK §13's Day-1 list, three of nine items exist (INDEX wrap/unwrap, MONO token,
vault custody+burn). The v4 hook (tax + TWAP accumulator), the wall, the harvest module, the
treasury contract, the acquisition engine, and the keeper do not exist in `src/` at all.
The single largest missing piece is the TWAP accumulator: without it no strike, gate, tax,
or capacity number in the whole protocol can be computed.

One outright exploit: `onTokensReceived`/`fund` are unauthenticated and funding is
push-based, so an auction's supply can be front-run and swept by an attacker's own auction
(§F1). This is the pattern used by both the deploy script and every test.

---

## A. Mechanism mismatch — is `MonoAuction.sol` the ratified mechanism?

### A1. The auction is a fixed-price sale, not a formula-bid book
**Severity: Critical**
**Spec says:** HANDBOOK §3.5 (lines 204–216, 222–239): bidders bid **x**, "a share of
premium paid"; "price = NAV + x·premium, recomputed per block from TWAP NAV + premium
(formula bids can't go stale — this fixes what killed the old fixed-price discrete
auctions)". `image.png` agrees the price is derived (`min bid = NAV + premium/2`,
"must look at the pool price", "monitors premium").
**Code does:** A bid is `maxPrice` in absolute currency-per-token WAD units
(`MonoAuction.sol:248`, `Bid.maxPrice` at `:67`), validated only against a constant
`floorPrice` fixed at `createAuction` (`:262`, `:446`). Fill price is that literal number
(`_settle` `:484`, `_fillOf` `:527`). No NAV, no premium, no TWAP anywhere in the file —
the words do not occur.
**Impact:** This is precisely the fixed-price discrete auction D15 says was killed. Every
resting bid is a free option against a NAV that rises on every tax sweep and every strike:
NAV moves, the bid does not, and the bidder mints below the intended strike. The mechanism
D15 exists to prevent is the mechanism that got built.

### A2. Start/end blocks and expiry
**Severity: High**
**Spec says:** §3.5 D15 flow, step 3: "**No bid expiry** — escrow exhaustion is the only
automatic exit"; "Enter any time"; the book is perpetual with free entry/exit; CCA is
explicitly rejected *because* it is a "finite-lot launch auction".
**Code does:** Every auction has `startBlock`/`endBlock` (`MonoAuction.sol:43-44`),
`submitBid` reverts `AuctionOver` at `endBlock` (`:259`), and the book terminates in a
`settle` pass (`:316`). Continuity is faked by rolling the residue into a *new* `auctionId`
(`_openChild`, `:535`) with a new window.
**Impact:** Finite-lot lifecycle, the exact shape D15 rejected. The roll chain also means
a bidder's position is repeatedly torn down and re-created under a new id, which no part of
the spec's user flow ("manage any time", "claim any time") contemplates.

### A3. No per-block escrow drawdown to the vault
**Severity: Critical**
**Spec says:** §3.5: "escrow drawn down to the vault each block"; "streaming payment = no
default possible"; internals `:257-263`: `cost = rate·dt·strike`, `head.escrow -= fill·strike`,
payout each interval.
**Code does:** Escrow sits untouched until `settle`, then the whole filled amount is booked
to `currencyRaised` (`:486`, `:493`) and later pushed to `fundsRecipient` by `sweepCurrency`
(`:404`). `fundsRecipient` is an arbitrary address chosen at `createAuction` — there is no
vault type, no `Mono` reference, no INDEX assumption.
**Impact:** No streaming, no continuous accretion to NAV, and the vault is whatever address
the auction creator typed.

### A4. No top-bid-only accrual
**Severity: High**
**Spec says:** §3.5 step 2: "only the highest FUNDED bid receives the capacity drip …
Rank 2+ accrues ZERO"; "strict top-bid accrual" (v2.1 changelog, line 40).
**Code does:** `_settle` walks the whole book high→low filling every tick until supply is
exhausted (`:478-503`), and ties at a tick fill pro-rata (`_fillOf`, `:523`). Many bidders
are served per round.
**Impact:** Different price-discovery object entirely. Clearing-x — the dataset D10/D16 says
decides stage-2 `k` — is not produced by this design.

### A5. No gate
**Severity: Critical**
**Spec says:** §3.5(c) `[LOCKED]` and D15 step 5: "premium < 15% (long TWAP) pauses the drip
globally; bids/escrow sit; auto-resume". `image.png`: "works only when premium >= 15%".
§7 lists the gate in Bucket 3 and SYSTEM-REVIEW A2 says stage-1 harvest must inherit it
"from day one".
**Code does:** Nothing. The only word "gate" in the file is a comment about resolve
re-entry (`:337`).
**Impact:** The gate is the floor on the vault's minimum take per mint (§3.5(c): "≈ NAV +
half of 15%"). Without it, harvesting at a 1% premium is permitted — the rejected
open-mint-at-NAV design.

### A6. No capacity meter / tap / escalator
**Severity: Critical**
**Spec says:** §3.5(a) accrual curve 0.5%/wk @15% rising to a **2%/wk hard ceiling
`[LAW]`**; §3.5(d) the tap; `image.png` "if premium is too high during several blocks then
harvest amount increases"; §7 Bucket 1 LAW "capacity ceiling ≤ 2%/wk".
**Code does:** `totalSupply` is a constructor-style argument (`:198`), topped up by an
unauthenticated `fund()` (`:231`). Nothing rate-limits issuance over time; nothing reads
supply of MONO at all.
**Impact:** A `[LAW]`-class invariant (drip cap) has no implementation and no test. The
roll mechanism actively works against it: unsold supply rolls forward uncapped
(`_openChild`, `:539`), which `implementation.md:220` itself flags as "breaks the drip cap".

### A7. No treasury split
**Severity: High**
**Spec says:** §3.5 D15: "Treasury gets 20% of the excess above NAV+0.5·premium";
internals: `(NAV+0.5p)·fill + 80%·excess → vault; 20%·excess → treasury`. §11 item 1 calls
this "already settled".
**Code does:** One `fundsRecipient`, 100% of proceeds (`:412`).
**Impact:** No revenue path; a change to the settlement math and the payout topology, not a
parameter.

### A8. No reserve-x floor
**Severity: High**
**Spec says:** §3.5 and §7: reserve x `[SIM]` anchored ~20% of the premium share, "stops
x≈0 capture"; `image.png` says the floor is `NAV + premium/2`.
**Code does:** `floorPrice` is an absolute constant per auction (`:435`, `:446`), unrelated
to NAV or premium and never updated as NAV rises.
**Impact:** After any NAV ratchet the floor is below NAV, so the auction can sell MONO for
less than book — the one thing `Mono.issue()`'s `Dilutive` check would reject if the two
contracts were ever connected (they are not; see B1).

### A9. Claim is not a pure transfer of already-minted MONO
**Severity: Medium**
**Spec says:** §3.5 step 4: "accrued MONO was minted-and-paid-for at accrual; claim = pure
transfer, no pricing, no deadline, no timing games (strike locks at accrual)"; internals:
`claim(): zero-then-transfer accrued MONO — never mints`.
**Code does:** `claim` computes the fill lazily at claim time when the auction has not
rolled (`_fillOf` inside `claim`, `:369`), including a clamp against a shared
`tokensUnclaimed` budget (`:528-530`) that shrinks as others claim.
**Impact:** Claim order affects the last claimant's token count (by rounding dust). Minor
economically, but it is pricing-at-claim, which the spec explicitly forbids.

### A10. No zap, no USDG edge, no INDEX escrow
**Severity: High**
**Spec says:** §3.5 step 1: "deposit USDG. Contract auto-zaps USDG → INDEX at entry …
escrow is held in INDEX — purchasing power stable in strike terms"; withdrawals return
INDEX with optional auto-zap back.
**Code does:** `currency` is an arbitrary address, escrowed and refunded verbatim
(`:268-274`, `:381-384`). No routing, no INDEX awareness.

### A11. No anti-flicker, no checkpoint model, no keeper poke
**Severity: Medium**
**Spec says:** §3.5: min increment Δx, min active period on head-affecting changes, min
deposit `[SIM]`; `checkpoint()` on every head-change event + hourly `poke()`.
**Code does:** No min increment (only `BidTooSmall` = "must buy ≥1 wei", `:266`), no active
period, no checkpointing. `withdrawBid` is a free cancel at any time before settle — the
code comment at `:283-285` acknowledges it as a known unpriced option.
**Impact:** The bid-flicker attack D15 sizes parameters against is unmitigated. Note the
tests exercise this option deliberately (`MonoAuctionResolve.t.sol:139`, `:222`).

### A12. Implemented features no spec source asks for
**Severity: Medium** (scope + audit surface)
None of the following appears in HANDBOOK, `image.png`, or `implementation.md` §5.4:
- **Multi-auction hosting** in one contract with a global `reserved[asset]` ledger
  (`:77`) — the whole cross-auction safety apparatus exists only because the contract is
  generic. A single perpetual book needs none of it.
- **Idle timeout + auction rolling** (`:466`, `:535`, `:565`) — roughly 130 lines,
  including the migration pass, cursors, and the double-count guard. The spec's answer to
  "the round ended and money is still resting" is that rounds do not exist.
- **`tickSpacing` / tick alignment / linked-list insert hints** (`:264`, `:622`) — a sorted
  book by `x` is required, but a price *grid* with caller-supplied `prevTick` hints is a
  CCA-derived construct the spec does not ask for.
- **`MAX_PRICE_MULTIPLE` ceiling** (`:26`) — a symptom of absolute-price bids; formula bids
  are bounded by `x ∈ [reserveX, 1]` naturally.
- **Native-ETH currency support** (`:268`, `:642`) — the money leg is USDG in and INDEX
  inside, always.
- **`tokensRecipient` / `sweepUnsoldTokens`** (`:389`) — unsold capacity is not a thing that
  gets returned to anyone; uncreated capacity simply is not created ("empty book ⇒ capacity
  not created", §3.5 internals).
- **Pay-as-bid across a whole book** — see A4.

### A13. `agent-docs/MonoAuction.md` documents a different contract than the one in `src/`
**Severity: Low**
- `:64` "Returns `(liveAuctionId, bidId)`. If idle timed out, the parent is resolved and
  rolled first; the new bid lands on the **child** id." — `submitBid` returns one value and
  reverts `MustResolve` (`MonoAuction.sol:256`).
- `:37`, `:76` reference `_assignFills`, which does not exist (it is `_processBids`).
- `:78` "Resolve/idle uses a full settle in one go" — `resolve` takes `maxTicks` and is
  chunked (`MonoAuction.sol:330`).
- `:51` "`idleBlocks == 0` — idle roll disabled" — `resolve` still rolls after `endBlock`
  regardless of `idleBlocks` (see F2).
Per `CLAUDE.md` rule 2 the doc must track the code; it does not.

---

## B. Missing wiring

### B1. The two halves of the protocol are not connected, and cannot be
**Severity: Critical**
**Spec says:** §3.5 — the auction is "the only mint path for new MONO", proceeds to vault.
**Code does:** `MonoAuction.sol` imports only solady (`:4-6`). It contains no reference to
`Mono`, `issue()`, `nav()`, or INDEX. It moves pre-existing token balances; it cannot mint.
Conversely `Mono.issue()` and `Mono.genesis()` require `msg.sender == issuer` and
`asset.safeTransferFrom(msg.sender, …)` (`Mono.sol:167`, `:173`, `:185`, `:195`) — the
issuer must itself hold and spend INDEX. `MonoAuction` has no function that calls either,
and no path that approves INDEX.
**Impact:** Setting `issuer = address(MonoAuction)` produces a system where genesis can
never be called and MONO can never be minted. There is no deployment of `Mono` + `Index` +
`MonoAuction` anywhere in `test/` or `script/`; `IndexMono.t.sol:15` uses
`address(0x11A2)` as a stand-in issuer and `script/DeployLocal.s.sol:30-32` deploys the
auction against two `TestERC20`s. The wiring has never been exercised even in a mock.

### B2. No NAV / premium / TWAP read anywhere in the repo
**Severity: Critical**
**Spec says:** §3.6 `[LAW]` "every trigger reads a TWAP"; D17's three windows; the
accumulator "lives in our hook".
**Code does:** No hook exists in `src/`. `Mono.nav()` exists but is called by nothing except
tests. Premium is not computed anywhere.
**Impact:** Every ratified number in the protocol (strike, gate, accrual rate, tap, tax
curve) is downstream of a reading that no contract produces.

### B3. No treasury address, no capacity meter, no tap, no gate contract
**Severity: High** — see A5–A7. There is no `treasury` identifier in `src/`.

### B4. `Deps.t.sol` still pins CCA as a dependency
**Severity: Info**
`test/Deps.t.sol` asserts the `cca/` remapping resolves and `foundry.toml:12` keeps the
submodule, while D15 (HANDBOOK line 39, and `implementation.md:110`) concludes CCA is
unsuitable. `lib/continuous-clearing-auction` is also dirty in the working tree. Dead
weight, and solady/OZ/permit2 are all reached *through* that submodule
(`foundry.toml:15-17`), so it cannot simply be dropped.

---

## C. Vault (`Mono.sol`) vs spec

### C1. The wall does not exist — the vault has no outflow at all
**Severity: Critical** (missing subsystem, acknowledged in-code)
**Spec says:** §3.3 `[LAW]` standing bid at `NAV × (1 − wallTick)`, fills burned; §7 LAW
"vault outflow = wall only", "wall buys burn"; §13 Day 1 "wall keeper/range bid".
`image.png`: "If mono dumps to the nav price then the vault will use its shares to buy mono
from the market". `implementation.md:167` specifies `defendFloor` as permissionless with
`sqrtPriceLimitX96`.
**Code does:** No outflow of any kind (`Mono.sol:31-34` documents the omission as
deliberate). `burn()` (`:204`) burns the *caller's* MONO, so the accretion arithmetic works
only if some other contract already bought MONO — which nothing does.
**Impact:** The "inverse DAT" floor — the protocol's headline property — is absent. MONO
below NAV has no closing mechanism.

### C2. Vault and treasury are not separate contracts because there is no treasury
**Severity: High**
**Spec says:** §7 Bucket 1 `[LAW]`: "**vault and treasury are physically separate
contracts** (both hold INDEX — F2, explicit genesis split)".
**Code does:** One contract, no treasury, and `genesis()` (`:166`) mints all shares to a
single `to` with no split.
**Impact:** A LAW-tagged deploy-time invariant is unimplementable from the current code.

### C3. Token and vault are merged — handbook says vanilla ERC-20 + separate vault
**Severity: Medium** (spec conflict, see E1)
**Spec says:** §8 load-bearing facts: "Tax must live in a v4 HOOK, **MONO stays a vanilla
ERC-20**"; §13 Day 1 lists "MONO token (vanilla ERC-20)" and "Vault (INDEX custody …)" as
two line items. `image.png` draws `$MONO (ERC 4226)` — one object.
**Code does:** `Mono.sol` is both. Transfers stay vanilla, so the hook-tax constraint is not
violated, but the vault can never be upgraded, replaced, or given a wall without migrating
the token.
**Impact:** The wall must now be a *separate* contract holding a spend allowance on a vault
that has no allowance mechanism — i.e. C1 cannot be fixed without changing `Mono.sol`.

### C4. NAV monotonicity holds only in INDEX units and only while supply > 0
**Severity: Medium**
**Spec says:** §1 "Backing-per-token (NAV) is mechanically non-decreasing".
**Code does:** `nav()` returns `WAD` when `totalSupply() == 0` (`Mono.sol:93`). Two reachable
states: (a) pre-genesis, where `nav()` reports 1.0 against an empty vault; (b) post-genesis
if the entire float is burned — which §3.1 explicitly contemplates ("the vault can always
afford to buy the entire float — full capitulation ends with vault surplus"). In state (b)
NAV drops from whatever it was to 1.0, `issue()` reverts `NoSupply` (`:190`) forever, and
the entire INDEX balance is permanently stranded.
**Impact:** The one invariant the thesis rests on has a hole at the exact scenario §3.1
uses to argue solvency. Not covered by `testFuzz_navNeverDecreases`
(`IndexMono.t.sol:162`), which never burns.

### C5. `issue()` enforces non-dilution but not the strike
**Severity: Medium**
**Spec says:** §3.5(e) the strike is `NAV + k·premium`, with the vault floor at
`NAV + 0.5·premium` in both stages.
**Code does:** `issue()` only checks `assetsIn ≥ ceil(A·shares/S)` — i.e. `strike ≥ NAV`
(`Mono.sol:193`), and the test asserts paying exactly NAV is allowed
(`IndexMono.t.sol:148-150`).
**Impact:** The vault-side backstop is NAV, not NAV+0.5p. Every premium-share law is
therefore enforced entirely in the harvest module — which does not exist. If the current
auction were wired in, it would mint at whatever `floorPrice` was typed at creation.

### C6. Missing `coverage()`
**Severity: Low**
§3.1: "Coverage ratio (unencumbered assets ÷ NAV×supply) is a primary dashboard stat";
`implementation.md:150` lists `coverage()`. Not present in `Mono.sol`.

### C7. Tax inflow path is a bare donation, with no sweeper and no split
**Severity: Medium**
**Spec says:** §3.4 tax accrues to the vault off a v4 dynamic LP fee, swept by a keeper
(`implementation.md:93`); P1 leaves a company share open.
**Code does:** `totalAssets()` = `balanceOf` (`Mono.sol:86`), so any transfer in raises NAV
(`test_taxSweepRaisesNav`, `IndexMono.t.sol:236`). That is the correct *shape*, but there is
no hook producing fees, no keeper sweeping POL fees into it, and no split point.
**Impact:** "Primary NAV engine" (§1) has no source.

### C8. `uiMultiplier` / corporate-action correctness is assumed, not verified
**Severity: Medium**
**Spec says:** §8: "Corporate actions via `uiMultiplier` (not rebase) — NAV code must be
multiplier-aware." `implementation.md:161` calls it "the most dangerous line in the
codebase".
**Code does:** `Index` prices everything off live `balanceOf` (`Index.sol:77-101`), which is
multiplier-safe **if and only if** `Stock.sol` applies the multiplier inside `balanceOf`.
`Index.sol:20-21` states this is unconfirmed. `Mono` reads INDEX (a plain solady ERC-20), so
it inherits the assumption transitively.
**Impact:** If the assumption is wrong, NAV, the auction floor and the wall price are all
wrong simultaneously. There is no fork test on 4663 (`implementation.md:281` requires one).

### C9. Decimals
**Severity: Low**
`Mono` assumes 18-dec INDEX for WAD math (`:93`) — correct today, since `Index` inherits
solady's 18 decimals and AAPLx is 18dec. But `Index.costToMint` at empty pot returns
`shares` raw units *per leg* (`Index.sol:87-88`), so adding a 6-dec leg (USDG buffer, a
6-dec stock) makes genesis parity nonsense, and `Index` has no per-leg scaling anywhere.
§3.1's "optional small USDG buffer" is unbuildable in the current `Index`. (§6 B3 says
"lean = delete" — then delete it in the handbook.)

### C10. Closed 4626 surface — matches spec, one drift
**Severity: Info**
`Mono.sol:128-159` implements exactly `implementation.md` §2.1, except that §2.1 says
`maxDeposit`/`maxMint` "return 0 for everyone except the auction/harvest module" while the
code returns 0 unconditionally. The code is the safer reading. No action beyond updating
`implementation.md`.

---

## D. Missing subsystems (HANDBOOK §13 "Day 1" vs `src/`)

**Severity: High** (as a set)

| §13 Day-1 requirement | In `src/`? |
|---|---|
| INDEX wrapper: wrap/unwrap + in-kind mint/redeem at pot slice | **Yes** — `Index.sol` |
| … + P7 wrapper fee (~0.05% each way, half to treasury) | No (`Index.sol:23`, pending) |
| … + dormant deficit mint channel (P6j/D19/D20) | No — and the asset list is fixed at construction (`Index.sol:49-58`), so the growth-only covenant has **no** growth path without redeploy |
| … + fire escape behind glass (P6a/b/f/g) | No |
| MONO token | **Yes** — `Mono.sol` (merged with vault, see C3) |
| v4 hook on MONO/INDEX: curve tax + launch decay + harvest-exemption routing + **TWAP accumulator** | **No** — nothing. This blocks §3.4, §3.5, §3.6 entirely |
| Vault: INDEX custody + burn | **Yes** — `Mono.sol` |
| … + coverage | No (C6) |
| … + wall keeper / range bid | **No** (C1) |
| … + separate treasury contract `[LAW]` | **No** (C2) |
| Harvest module: accrual curve, banking, gate ≥15%, premium tap, D15 auction book | **No** — `MonoAuction.sol` is a different mechanism (§A) |
| Acquisition engine (zap USDG/ETH → AAPLx → wrap; treasury RFQ keeper) | No |
| ReferralRegistry (optional) | No |
| Keeper: issuer-event sentinels, wall/harvest execution | No |
| POL / pool deployment / three pools | No — `script/DeployLocal.s.sol` deploys two `TestERC20`s and one auction |

Also absent and named in `implementation.md` §5: `IntakeRouter`, `PremiumCurve`,
`HarvestSellRouter` (without which the §3.4 `[LAW]` harvester sell-fee exemption is a tax
hole), `haltOnIssuerEvent`. Stage-2 items (LITH, staking) are correctly absent.

The test suite reflects the same gap: no invariant test exists for any of `implementation.md`
§6's ten listed invariants except NAV monotonicity and the wrapper round-trip. There is no
oracle-independence test, no fork test, no adversarial auction set.

---

## E. Spec-internal contradictions (need a human decision, not a code change)

### E1. Source-of-truth order is itself contested
**Severity: High**
`implementation.md:3-8` declares `image.png` **wins** over `HANDBOOK.md`. `HANDBOOK.md:46-53`
declares that `SPEC`/`DECISIONS`/`PROPOSALS` win over the handbook — and D15/D16/D17 are
ratified decisions. `CLAUDE.md` points agents at `agent-docs/` as source of truth. So the
strongest-authority document (DECISIONS, via D15) is the one `implementation.md` overrides
with a whiteboard photo. Until this is settled, "conformance" is undefined. **Decide which
document the auction is built to.**

### E2. Reserve-x ~20% contradicts the vault-floor invariant NAV+0.5p
**Severity: High** — internal to HANDBOOK, and it breaks the published pseudocode
`HANDBOOK.md:22` and `:309` state the vault-floor invariant is `NAV + 0.5·premium` in **both**
stages. `HANDBOOK.md:211` and the §7 table (`:575`) set reserve x ≈ **0.2**. The D15
settlement pseudocode (`:262`) is `payout: (NAV+0.5p)·fill + 80%·excess → vault; 20%·excess
→ treasury`. With a single bidder at the reserve, `strike = NAV + 0.2p < NAV + 0.5p`, so
"excess" is negative and the payout line underflows: either the vault is paid more than the
bidder deposited, or the invariant is violated. `image.png` says `min bid = NAV + premium/2`,
i.e. reserveX = 0.5, which is self-consistent. **Pick 0.2 or 0.5.**

### E3. INDEX valuation: pool quote vs constituent feeds
**Severity: High**
`image.png` steps 4–5: "INDX needs to go to INDX/USDG pool to know how much it's worth in
usd terms" — a pool quote in the mint path. D18 (`HANDBOOK.md:27`, `:481-495`) says the
deficit channel prices "**bottom-up from per-constituent feeds off actual composition — no
pool quote anywhere**", and "no protocol MATH ever depends on an INDEX trading venue (the
routing pool is distribution infrastructure, not a price source)". Direct contradiction on
the one path where an oracle is allowed at all.

### E4. Deficit fill: pause other legs vs keep both legs open
**Severity: Medium**
`image.png` items 2–3, 8: "we stop accepting nvda and apple until 2000 of HOOD is filled";
"In the rebalancing period it's possible to unwrap INDX" (implying mint is shut). D19
(`HANDBOOK.md:32-34`, `:487-491`): pro-rata mint and redemption are **ratio-neutral** so they
"never undo progress" and stay open; only deficit deposits move the ratio. §5 `:470` says
"Both legs open (the closed-mint era is over)". Picture shuts a leg the handbook keeps open.

### E5. Floor support: hook-side vault buying vs keeper/range-order wall
**Severity: High**
`image.png` hook bubble: "Floor price support in the pool — if a sale is big, the vault
$MONO to peg the floor", plus "If mono dumps to the nav price then the vault will use its
shares to buy mono from the market". Three conflicts:
(a) §7 LAW "vault outflow = wall only" and "wall buys burn" — the picture never says burn,
and a vault that buys and *holds* MONO also violates "vault never holds MONO as backing"
`[LAW]`;
(b) §3.3 says buy at `NAV × (1 − wallTick)`, the picture says at NAV — bidding *at* NAV
retires a 1.00 claim for 1.00 and the ratchet in §3.3 disappears (`implementation.md:67-74`
flags this and picks 0.75%);
(c) §8 routing: a hook that moves value needs `beforeSwapReturnDelta` → Labs allowlist →
loses auto-routing (`implementation.md:92-104`). A hook cannot do this leg as drawn.
**Decide: keeper bid, one-sided range order, or permissionless `defendFloor`; and confirm
the tick + burn.**

### E6. "Once LITH is deployed the auction won't be needed" vs the auction's data role
**Severity: Medium**
`image.png` treats the auction as disposable scaffolding. D10/D16 (`HANDBOOK.md:22`, `:216`,
`:312`) make stage-1 **clearing-x history the dataset used to sanity-check `k = 0.6` before
the immutable stage-2 deploy**. A throwaway auction that does not record a clean clearing-x
series (the current pay-as-bid, multi-tick, roll-chained design does not) leaves the
stage-2 parameter unvalidatable. Also `HANDBOOK.md:722`: stage-2 contracts must be
deploy-ready *during* stage 1, so "won't be needed later" is not a reason to under-build.

### E7. Banking is `[LOCKED]` but has no stage-1 expression
**Severity: Medium**
§3.5(b) `[LOCKED]`: rights accrue **unfunded** and "bank indefinitely". §3.5 D15 internals:
"empty book ⇒ capacity not created (mirrors totalStaked==0)". In stage 1 the auction fuses
accrual and exercise, so unclaimed capacity is destroyed, not banked. Either §3.5(b) is
stage-2-only (say so) or the auction needs a reservoir.

### E8. "Buffer fee" 1% vs D20 haircut 1% vs P7 wrapper fee 0.05%
**Severity: Medium**
`image.png` item 6: user gets "2 INDX tokens minus 1% in the HOOD token for the buffer fee".
D20 (`HANDBOOK.md:36-38`, `:571`) ratifies a **1% haircut** on deficit-channel mints, framed
as feed-error protection, not a fee, and taken as a mint discount rather than a token
skim. P7 (`:472`) is a separate ~**0.05%** each-way wrapper fee on ordinary in-kind
mint/redeem, half to treasury. Three names, two-and-a-bit mechanisms, one number reused.
**Confirm the picture's "buffer fee" == D20's haircut, and that P7 is additive.**

### E9. `ERC 4226` in `image.png` is a typo for ERC-4626
**Severity: Info** — assumed throughout. No such standard exists. Worth correcting on the
board so nobody builds to it.

### E10. "Auction is per block" vs D15's perpetual book
**Severity: High**
`image.png`: "auction is per block", "the members are winning the mint $mono right away".
D15: a *continuous* book with lazy checkpoints, explicitly "no per-block writes"
(`HANDBOOK.md:245`). These are different mechanisms with different gas profiles and
different MEV surfaces. `implementation.md:224` picks per-block. **Decide.**

---

## F. Correctness / security bugs in the code as written

### F1. Auction supply can be stolen by front-running `onTokensReceived`
**Severity: Critical**
**Code:** `createAuction` is unauthenticated and lets the caller set `fundsRecipient` and
`tokensRecipient` (`MonoAuction.sol:192-217`). `onTokensReceived` is unauthenticated and
credits *any* unreserved balance of `a.token` to the calling auction
(`:220-228`). Funding is push-based: the seller transfers tokens in as one transaction and
acknowledges them in another.
**Failure scenario:** The seller sends `SUPPLY` MONO to the auction contract
(`script/DeployLocal.s.sol:34`, and the same two-step in every test helper). Before the
seller's `onTokensReceived` lands, an attacker calls
`createAuction(token=MONO, currency=X, fundsRecipient=attacker, tokensRecipient=attacker,
totalSupply=SUPPLY, floorPrice=1, tickSpacing=1, startBlock=now, endBlock=now+1,
idleBlocks=0)` then `onTokensReceived(attackerId)` — the balance check passes because the
transfer is not yet reserved. The seller's own call now reverts `InvalidAmount`. One block
later the attacker calls `settle(attackerId, 1)` (no bids → `settleDone`, `remaining ==
SUPPLY`) and `sweepUnsoldTokens(attackerId)` (`:389`), which transfers the whole supply to
`tokensRecipient = attacker`. `fund()` (`:231`) has the identical hole.
**Existing coverage:** none. `MonoAuctionSecurityTest.test_cannotClaimAnotherAuctionsEscrow`
(`test/MonoAuctionSecurity.t.sol:79`) only proves an auction cannot claim *already-reserved*
balance; the unreserved-deposit window is exactly what is exploitable.
**Fix shape:** pull the supply inside `createAuction`/`fund` with
`safeTransferFrom(msg.sender, …)` and delete `onTokensReceived`.

### F2. Anyone can force-roll a finished auction, denying the seller `sweepUnsoldTokens`
**Severity: Medium**
**Code:** `resolve`'s entry gate is
`if (!a.settleStarted && !_idleTimedOut(a) && block.number < a.endBlock) revert`
(`MonoAuction.sol:338`). After `endBlock` this passes **regardless of `idleBlocks`**, even
though `idleBlocks == 0` is documented as "idle roll disabled"
(`agent-docs/MonoAuction.md:51`). `_openChild` then sets `a.remaining = 0` and
`a.tokensSwept = true` (`:539-541`) and moves the unsold supply into a child.
**Failure scenario:** Seller runs a one-shot auction with `idleBlocks = 0`, 90 of 100 tokens
unsold. At `endBlock` a griefer calls `resolve` first. The seller's `sweepUnsoldTokens`
reverts `AlreadySwept`; the 90 tokens now sit in child auction #2 with a fresh window of the
same duration. At child `endBlock` the griefer resolves again. The supply is recoverable
only by winning a race the griefer can re-enter forever, at ~one `resolve` call per round.
Unfilled bidders are likewise pushed into a child and must call `withdrawBid` there rather
than being refunded.
**Existing coverage:** `MonoAuctionRoll.t.sol:52` tests sweep-then-roll (the safe order);
roll-then-sweep is untested.

### F3. `resolve` mints junk child auctions unconditionally
**Severity: Low**
`resolve` always calls `_openChild` when `rolledTo == 0` (`:344`), even for an auction that
sold out with every bid fully filled and nothing to migrate. Result: a zero-supply,
zero-bid auction id per resolve, plus a permanent `rolledTo` pointer that changes `claim`'s
behaviour (`:355`, `:364`) — claims are blocked until the migration pass completes even
though it has nothing to do. Cheap to trigger, no funds at risk.

### F4. Cross-function reentrancy window on `reserved` during `claim`
**Severity: Low** (unreachable with the intended assets)
`claim` decrements `reserved[a.token]` **before** transferring (`:378-379`), and
`onTokensReceived`/`fund` are the two external mutators without `nonReentrant`
(`:220`, `:231`). With a callback-capable token, a receiver hook fired mid-transfer sees
`reserved` already reduced while the balance is still high, and can credit the difference to
its own auction. INDEX (solady ERC-20) and USDG have no callbacks, so this is not live
today — but the contract advertises itself as asset-generic.

### F5. Book-depth griefing on the migration pass
**Severity: Low**
Dust ticks cost ~one bid each (`MonoAuctionResolve.t.sol:57` creates 200 for 1000 wei
apiece). Migration inserts each surviving bid into the child with a hint of
`child.floorPrice` whenever `maxPrice < child.highestTick` (`:593-594`), so
`_initializeTick` walks the child list from the bottom (`:627-632`). Settle and resolve are
both caller-chunked so nothing bricks, but the party who wants their claim unblocked
(`:355`) pays O(ticks × bids) gas across the pass.

### F6. Last claimant absorbs the rounding dust
**Severity: Info** (known, tested)
`_fillOf` rounds each bid's currency share **up** (`:523-525`) and clamps tokens to the
shrinking `tokensUnclaimed` budget (`:528-530`), so with many bids at one partially-filled
tick the final claimant can receive a few wei fewer tokens than pro-rata while paying full
`fillCurrency`. Solvency is preserved and
`MonoAuctionSecurityTest.test_solvencyAcrossPartialFillRounding` (`:132`) asserts the
direction. Noted only because A9 makes claim-time pricing a spec violation as well.

### F7. `Index`: assets donated before the first mint are captured by the first minter
**Severity: Low**
`costToMint` returns `shares` per leg whenever `totalSupply() == 0` (`Index.sol:87-88`),
ignoring any balance already sitting in the pot. A donation (accidental, or a stock airdrop)
landing before the genesis mint is handed to the first minter at 1:1. Post-genesis the
`MIN_LIQUIDITY` lock (`:34`, `:117`) makes supply==0 unreachable, so the window is
deploy-time only — but the genesis wrap is exactly when a large AAPLx balance is in motion.

---

## What would need to be built

1. **The D15 streaming book, as a new contract** — sorted-by-x book, `checkpoint()` on every
   head-change event + keeper `poke()`, escrow drawdown at `strike = NAV + x·premium`,
   top-bid-only accrual, reserve-x, gate, capacity meter, 80/20 vault/treasury split,
   `claim` = pure transfer. `MonoAuction.sol` shares no reusable core with it; keep it only
   if you also want a generic token sale, and fix F1 first either way.
2. **The v4 hook** — TWAP accumulator with read-time windows (D17: 12–24h / 30–60min /
   1–4h), dynamic-fee tax curve, launch decay, harvester exemption. Everything else is
   blocked on this; build it before the auction.
3. **The wall** — `defendFloor`, permissionless, `sqrtPriceLimitX96`-capped at
   `NAV × (1 − wallTick)`, burns everything received. Requires an outflow path in `Mono`,
   which today has none.
4. **A treasury contract** — separate from the vault (`[LAW]`), receiving the 20%-of-excess
   split and the P7 half-fee.
5. **Wire `Mono.issue()` to the harvest module** and add a deploy script + integration test
   that actually stands up `Index` → `Mono` → harvest → pool. Nothing today proves the
   three contracts can coexist.
6. **`Index`: dormant deficit channel + fire escape** (D14 says both ship day 1, inert), or
   accept that composition is frozen forever and say so in the handbook.
7. **Decide E1, E2, E3, E5, E10** before any of the above is written. Four of them change
   the shape of the contract, not a constant.
