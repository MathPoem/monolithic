# MONOLITHIC — Developer Handbook

**Protocol design version 2.1 — 2026-08-01** (v2.0 earlier same day; initial edition v1.0 aligned 2026-07-23)

**The single reference for the whole protocol.** Aggregates every subsystem, mechanic,
decision, open question, and verified chain fact. Written for the dev/audit team.

---

## What changed: v1.0 (2026-07-23) → v2.0 (2026-08-01)

The initial handbook described a three-stage roadmap with a deferred basket migration
and several open mechanisms. All of the following landed since:

| Area | v1.0 said | v2.0 says |
|---|---|---|
| **Wrapper / staging** | INDEX = deferred stage-3 event; MIRROR wrapper (vault in raw stocks, parallel mirror pot); capital-neutral migration | **INDEX ships DAY 1** (D14); **vault holds INDEX directly** (P4); genesis = launch AAPLx wrapped 1:1; migration DELETED — stages are switches, not migrations |
| **Composition changes** | Rebalancer (value-matched swap, admin oracle) + intake router steering inflows | **NEVER REDUCE covenant** (D12): growth-only recipe; adding an asset = LITH vote + **deficit mint channel** (P6j: single-asset mint at Chainlink minus 1% haircut (D20), metered, market-hours, deficit-only); router logic superseded |
| **Asset removal** | (not designed) | Emergency-only **fire escape** (P6a/b/f/g): sellable-dead → patient in-fund liquidation; frozen → mint pause + skip-leg redemption + voluntary forfeit; IOU machinery deleted |
| **Wrapper fee** | (not designed) | P7: ~0.05% each way in-kind; ~half to treasury as freshly-minted INDEX; share-math firewall |
| **Stage-1 harvest** | "GDA-adjacent" continuous mechanism; GDA half-life = primary capture dial | **Streaming premium-share auction** (D15): formula bids NAV + x·premium off TWAP (can't go stale), highest bid wins per-block drip, pay-your-bid, escrow = expiry, no bid expiry; reserve-x floor replaces the half-life dial; treasury 20% of excess above NAV+0.5p |
| **Stage-2 strike / k** | k prior 0.5, 100% to vault; decide k off stage-2 sims; optional engine service fee (+0.1p — the "hidden second k" problem) | **D16: NAV + 0.6·premium — 0.5p vault, 0.1p treasury**; treasury % = one-way ratchet DOWN (hardcoded max 10); engine service fee KILLED; vault-floor invariant NAV+0.5p both stages; 60 sanity-checked vs stage-1 clearing-x before immutable deploy |
| **TWAP** | Single 24h window everywhere; window-split pending (P3) | **D17 three-window architecture**: gate LONG 12–24h · strike FRESH 30–60min with **max(spot, shortTWAP)** · accrual/tap MEDIUM 1–4h; one accumulator, three horizons |
| **Staking contract** | (not designed) | Accumulator implementation design (§4.6): lazy settle, checkpoint ordering invariant, variable-rate resampling, tap token buckets |
| **Stage-1 duration** | traction-gated 2–6wk | Target **~4 weeks** (D13); metric remains the trigger, date never announced; stage-2 contracts deploy-ready DURING stage 1 |
| **Audit state** | pre-audit | Fresh audit 2026-08-01 (AUDIT-2026-08-01.md), no criticals; riders: genesis wrap fee-exempt; deficit-channel wake-up LITH-gated IN CODE; single-asset-era freeze = full redemption pause (disclose); P6j needs on-chain feed-freshness guard |
| **Token naming / index pricing** | wrapper token "UNIT"; deficit pricing loosely "Chainlink minus haircut" | **Renamed INDEX** (D18); deficit channel prices **bottom-up from per-constituent feeds off actual composition — no pool quote anywhere**; per-feed staleness guard; feed-existence = governance eligibility rule |
| **Doc set** | BASKET-RESEARCH = stage-3 authority | BASKET-RESEARCH = historical record; authority = DECISIONS (D12–D18) + PROPOSALS P4–P7 |

## What changed: v2.0 → v2.1 (same day, 2026-08-01)

- **D19** — deficit-channel termination = PER-INDEX ratio target (absolute-balance and
  cumulative-deposit rules rejected; pro-rata flows are ratio-neutral so unwraps never
  undo progress).
- **D20** — haircut ratified at **1%** + two-layer rationale (haircut covers honest
  feed error, hard-bounded by feed config; daily meter bounds broken-feed tails);
  composition policy on record (nothing driven to zero; never-raised assets still
  bought pro-rata forever; treasury = default channel filler).
- **D15 refinements** — CCA confirmed unsuitable → custom streaming-book auction;
  USDG at the edges / INDEX escrow inside; strict top-bid accrual; strike locks at
  accrual. Full user flow written as the dev spec + contract internals added as
  **SUGGESTED implementation** (§3.5).
- Sell-one-stock-for-another question re-asked and re-affirmed NO (covenant stands;
  capability itself must not exist in bytecode).

> **How to read this doc.** This is a *compendium*, not the source of authority. When
> this doc and a source doc disagree, the **source doc wins**:
> - `SPEC.md` — the ratified/accepted design (v0.9 + only explicitly-accepted changes).
> - `PROPOSALS.md` — open ideas NOT yet accepted.
> - `DECISIONS.md` — post-v0.9 ratified decisions with reasoning.
> - `VERIFICATION.md` — verified on-chain facts (addresses, feeds, routing).
> - `ADVERSARIAL.md` — attack checklist verdicts.
> - `BASKET-RESEARCH.md`, `LITH-MODEL-RESEARCH.md` — deep research + verdicts.
> - `SYSTEM-REVIEW.md` — full coherence pass, gaps, campaign-2 list.
> - `sim/` + `results/RESULTS.md` — the Monte-Carlo model and campaign-1 output.
>
> **Status tags used throughout:**
> `[LAW]` immutable at deploy · `[LOCKED]` accepted architecture · `[SIM]` prior value,
> to be tuned in simulation · `[PENDING]` open proposal, not decided · `[GAP]` needs a
> spec before build · `[VERIFIED]` confirmed on-chain 2026-07-19 · `[DECIDE]` a call the
> principal still owes.

---

## 0. Doc map — "where do I find X?"

| Looking for… | Section | Source doc |
|---|---|---|
| One-paragraph pitch | §1 | SPEC §1 |
| Glossary / token roles | §2 | — |
| Vault, NAV, wall math | §3.1–3.3 | SPEC §4.1–4.2 |
| Tax mechanics | §3.4 | SPEC §4.3, PROPOSALS P1/P2 |
| Harvest: accrual, banking, gate, tap, strike | §3.5 | SPEC §4.4, DECISIONS, PROPOSALS P3 |
| TWAP design | §3.6 | SPEC §4.5, PROPOSALS P3 |
| LITH, staking, execution engine, tranches | §4 | LITH-MODEL-RESEARCH, DECISIONS |
| INDEX wrapper / basket (day 1) | §5 | DECISIONS D12–D14, PROPOSALS P4–P7 (BASKET-RESEARCH = historical) |
| POL, treasury, liquidity | §6 | SPEC §8–9, DECISIONS D14 |
| Immutable laws + parameters | §7 | SPEC §10 |
| Contract addresses, chain facts | §8 | VERIFICATION |
| Security posture / attacks | §9 | ADVERSARIAL, SYSTEM-REVIEW |
| Sim results | §10 | results/RESULTS.md |
| Open decisions | §11 | SYSTEM-REVIEW §E |
| Open proposals | §12 | PROPOSALS |
| Build scope & staging | §13 | SPEC §7, §15 |

---

## 1. What Monolithic is  `[LOCKED]`

A two-token reserve protocol on **Robinhood Chain** (chain 4663, Arbitrum Orbit L2).

- **$MONO** — speculative reserve token backed by an on-chain vault of tokenized stocks.
  Backing-per-token (NAV) is mechanically **non-decreasing**. Price above NAV (the
  premium) is **uncapped** — MONO can trade at 1.5×, 3×, 10× NAV. **Floor that only
  rises + upside never capped.**
- **$LITH** — fixed-supply equity layer. Staking it grants pro-rata rights to the
  harvest channel (the right to mint new MONO at a strike and keep the spread).
  Securitized exposure to MONO's premium.

**The thesis:** the empty quadrant — stock tokens have a floor but no dream, memecoins a
dream but no floor; MONO is built to be the only asset with both, on a chain whose users
already trade stocks like memes. **"Inverse DAT":** where DATs die at a discount to NAV
with no closing mechanism, MONO's wall arbs the discount away by contract.

Three organs, one rule each:
1. **Tax** (everywhere) → accrues to vault. Primary NAV engine.
2. **Wall** (below NAV) → buys MONO and burns it. Emergency floor defense; ratchets NAV.
3. **Harvest** (above NAV) → the only way new MONO is minted; proceeds to vault. Metered.

---

## 2. Glossary

- **NAV** — vault value ÷ MONO supply. The floor. Computed from balances, oracle-free
  (see §3.2 denomination).
- **mNAV** — market price ÷ NAV. The premium multiple. 1.0 = at book; 3.0 = 3× book.
- **Premium** — price − NAV (or as a %, mNAV − 1).
- **The wall** — standing protocol bid ~1% below NAV; fills are burned.
- **Strike** — the price a harvester pays to mint 1 MONO = NAV + k·premium.
- **k** — the premium-split parameter; prior 0.5 (vault gets NAV + half the premium).
- **Harvest capacity / rights** — the metered right to mint MONO at strike.
- **The tap** — the rate limit on *exercising* banked rights.
- **The engine** — optional contract that auto-harvests for a staker.
- **POL** — protocol-owned liquidity.
- **The wrapper / INDEX** (renamed from UNIT, D18) — the basket token, live from DAY 1 (see §5). Genesis recipe
  = 100% AAPLx, wrapped 1:1.
- **Backing asset** — INDEX, from block one. At launch INDEX is apple-in-a-shell
  (numerically identical to AAPLx); composition changes only by LITH vote, growth-only.

---

## 3. The MONO machine (deep mechanics)

### 3.1 The vault  `[LAW]`
Holds **INDEX only** (P4, effective day 1 via D14; + optional small USDG buffer — see
§6/`[GAP]` B3). Backing lives in the wrapper pot; the vault holds the claim tokens.
- **Inflows:** tax, harvest strikes (both denominated in INDEX).
- **Only outflow:** wall defense — and wall fills burn, so even the outflow raises
  NAV/token.
- **Covenants (immutable):** additive-only (never sells backing except wall defense);
  never counts MONO or its own LP as backing (anti-Olympus circularity); no
  discretionary trading.
- **Coverage ratio** (unencumbered assets ÷ NAV×supply) is a primary dashboard stat.
- **Solvency identity:** the wall pays < NAV per token retired, so the vault can always
  afford to buy the entire float — full capitulation ends with vault surplus.

### 3.2 NAV & denomination  `[LOCKED]`
NAV = vault ÷ supply (in INDEX per MONO). The trigger system reads **mNAV**, computed
**oracle-free** from pool state:
- The machine pool is **MONO/INDEX** (from day 1, D14), so the pool ratio *is*
  price-in-backing-units.
- mNAV = pool-ratio ÷ (vault-backing ÷ supply) — pure on-chain arithmetic, no external
  feed in the money path.
- **Why this matters:** the Chainlink AAPL feed on 4663 freezes ~70% of the calendar
  (nights/weekends; verified 32.6h stale). By denominating in the backing asset, the feed
  is needed only for the USD *display* and the small USDG buffer valuation — never for the
  wall, strike, gate, or fee triggers — plus the P6j deficit channel when (and only
  when) governance activates it. (Original "apple-denominated"; with INDEX as quote the
  same arithmetic is basket-denominated at any composition.)

### 3.3 The wall  `[LAW]` (mechanism) / `[SIM]` (tick)
Standing bid at **NAV × (1 − wallTick)**, wallTick ≈ 0.5–1% `[SIM]`. Fills are **burned**.

**The load-bearing arithmetic (why the floor only rises):**
```
supply 1000, vault $1000  →  NAV $1.000, wall bids $0.99
sell 100 into wall        →  vault $901, supply 900  →  NAV $1.0011
repeat                     →  NAV $1.0024 ...
```
Each fill retires a $1.00 claim for $0.99; the $0.01 redistributes to all remaining
tokens. The burn is what keeps the balance sheet honest (holding instead of burning would
make NAV circular). Sim-verified: NAV strictly non-decreasing across ~1,100 paths, 0
violations.

**Implementation note `[LOCKED direction]`:** build the wall as a **keeper-run vault bid**
(plain swaps, no custom accounting) OR as a **one-sided range order** at conservative-NAV
migrated up by a keeper. Either keeps MONO's pools in Uniswap's auto-routed tier (a
fee-only/no-return-delta hook auto-routes on uniswap.org; see §8). Wall bids off
**ex-buffer NAV** (buffer is surplus, not floor) so the published floor is strictly
non-decreasing in backing terms.

### 3.4 The tax  `[LOCKED]` (exists) / `[PENDING]` (shape + split)
Every pool trade pays a fee that accrues to the vault. Read off TWAP mNAV.

- **Current sketch (SPEC §4.3), zone-based:** floor zone (mNAV<1.15) buy 1.5%/sell 0.5%;
  mid (1.15–1.5) 1%/1%; premium (>1.5) buy 1%/sell 3%. Heavy extraction on
  profit-takers is the primary NAV engine; the vault DCAs in at the top of every cycle.
- **Harvester exemption `[LAW]`:** exits of harvest-minted MONO are exempt from the sell
  fee (already paid strike; don't double-charge the conveyor). Requires the harvest sell
  route to be provably selling only just-minted MONO.
- **Launch anti-snipe `[LOCKED]`:** the curve × a decaying multiplier (start ~95%,
  decay to terminal over the first minutes/hours). One mechanism, two jobs.
- **`[PENDING]` P2 — continuous curve:** the stepped zones paint a chart-visible
  resistance level at the 1.5 breakpoint (3× sell-fee jump, front-runnable). Direction
  liked: replace steps with fees varying *continuously* with premium. Shape/numbers not
  settled. → PROPOSALS P2.
- **`[PENDING]` P1 — company/treasury share:** tax may not route 100% to vault; a
  fraction (sketch ~1/3) funds dev/marketing/ops. Express as a fraction of tax, decide as
  one package with the tax-sunset question + referral funding. → PROPOSALS P1, DECISIONS.

### 3.5 The harvest channel (the deep one)
The only mint path for new MONO. Above NAV only, metered, proceeds to vault.

**Stage-1 mechanism `[RATIFIED D15]` — streaming premium-share auction.** Bidders
escrow INDEX and bid **x** (share of premium paid); price = **NAV + x·premium**,
recomputed per block from TWAP NAV + premium (formula bids can't go stale — this fixes
what killed the old fixed-price discrete auctions). Highest bid wins the per-block
drip, pay-your-bid; escrow drawn down to the vault each block. **No bid expiry** —
escrow exhaustion is the expiry; streaming payment = no default possible. Floors:
capacity meter sets how much, gate ≥15% pauses the drip, reserve x `[SIM]` (anchored
~20%, D2) stops x≈0 capture. **Treasury gets 20% of the excess above NAV+0.5·premium**
(vault take locked first; surplus-only; incidence-neutral; dies at cutover).
Anti-flicker (min increment / min active period / min deposit) `[SIM]`. Likely a
custom contract — CCA probably can't express formula bids (verify).
At stage-2 cutover the auction retires; stakers exercise at fixed k — and stage-1
clearing-x history is the dataset for choosing k (D10).

**Stage-1 auction contract — streaming-book design**
`[RATIFIED: the user FLOW below (D15 + refinements)]` / `[SUGGESTED: the contract
internals — a recommended implementation, not law; devs may build any design that
satisfies the flow + invariants]`
CCA is UNSUITABLE (finite-lot launch auction; we need a perpetual streaming book with
free entry/exit) → custom contract. **User flow (the spec the devs build to):**
1. **Enter any time:** choose bid `x` (pay NAV + x·premium), deposit USDG. Contract
   auto-zaps USDG → INDEX at entry (routing pool / RFQ engine; market execution, no
   oracle); **escrow is held in INDEX** — purchasing power stable in strike terms.
2. **Accrue while top:** only the highest FUNDED bid receives the capacity drip.
   Escrow draws down at `strike = NAV + x·premium` (fresh D17 window, sampled at
   checkpoints); vault receives the INDEX; treasury takes 20% of excess above
   NAV+0.5p per drawdown. Outbid → accrual stops, bid + escrow sit untouched.
   Rank 2+ accrues ZERO — dashboard must show rank + winning x brutally clearly.
3. **Manage any time:** raise x, top up, or withdraw escrow (partial or full;
   returned as INDEX, optional auto-zap to USDG). Anti-flicker: min increment Δx +
   min active period on head-affecting changes `[SIM]`. No bid expiry — escrow
   exhaustion is the only automatic exit.
4. **Claim any time:** accrued MONO was minted-and-paid-for at accrual; claim = pure
   transfer, no pricing, no deadline, no timing games (strike locks at accrual).
5. **Gate:** premium < 15% (long TWAP) pauses the drip globally; bids/escrow sit;
   auto-resume. Matches "come any time and wait."
**Mechanics:** sibling of the staking accumulator (§4.6). Sorted book; head accrues;
checkpoint on every head-change event (new top bid, head exhaustion, head withdrawal,
gate flip) + hourly keeper; per interval integrate `capacity × strike` piecewise
(rate + strike held constant per interval); escrow exhaustion moment is exactly
computable within an interval → clean partial fill, auto-drop to next bid. O(1) per
event, no per-block writes, no loops over bidders.

**Contract internals `[SUGGESTED implementation — dev reference, not final]`:**
```
Bid { owner, x ≥ reserveX, escrow (INDEX), accrued (MONO), headSince }
book: sorted by x desc (linked list + frontend position hints, O(1) verify)
samples @ lastCheckpoint: rate (medium TWAP), strikeInputs (NAV + fresh premium),
gate (long TWAP)

checkpoint():
  dt = now − lastCheckpoint
  while dt > 0 and book nonempty and gateSample == OPEN:      // ≤ N pops per call
    strike = NAV + head.x · premiumSample
    cost = rate·dt·strike
    if cost ≤ head.escrow: fill = rate·dt; dt = 0
    else: fill = head.escrow/strike; dt −= fill/rate          // exact exhaustion t*
    head.accrued += fill (MONO minted to contract);  head.escrow −= fill·strike
    payout: (NAV+0.5p)·fill + 80%·excess → vault; 20%·excess → treasury
    if head.escrow == 0: pop head                             // successor accrues from t*
  lastCheckpoint = now;  re-sample rate / strike / gate

entry points (ALL checkpoint() first, then mutate):
  bid(x, usdg): zap USDG→INDEX first; minDeposit + minIncrement checks; insert@hint
  raiseBid/topUp · withdraw (min-active-period on head-touching ops; returns INDEX)
  claim(): zero-then-transfer accrued MONO — never mints
  poke(): keeper, hourly + on gate crossings
```
Correctness: within any interval head/x/rate/strike are constants — every mutator
closes the interval first. Same audit invariant as §4.6, verbatim. Approximations:
interval-start samples of slow TWAPs, bounded by keeper cadence; gate flips take
effect at next event/poke. Hygiene: CEI around zap/claim; round escrow math DOWN;
empty book ⇒ capacity not created (mirrors totalStaked==0).

**(a) Accrual — how rights are created.  `[LOCKED]` shape / `[SIM]` numbers.**
Rights accrue to *staked LITH* (stage 2) / openly (stage 1), at a rate **proportional to
premium over the whole range** — never a hard on/off. Prior anchors: ~0.5%/wk of supply
at 15% premium, rising to a **hard ceiling of 2%/wk `[LAW ceiling]`** when the premium
runs hot, trickling toward 0 as premium → 0. (This is the "capacity escalator," ratified
2026-07-20; it *replaced* the old hard 15% arming gate — accrual is now a curve, always
on.) Accrual mints **nothing** — it is bookkeeping of future rights.

**(b) Banking — accumulating rights.  `[LOCKED]`.**
Rights accrue **unfunded** (no capital needed to accrue) and **bank indefinitely**. This
is deliberate: rights don't evaporate because you were idle or unfunded; accruing through
droughts is why stakers stay staked through the bear (loyalty pays, float stays locked
counter-cyclically). *Meter the tap, not the reservoir.*

**(c) Exercise gate — when rights can be USED.  `[LOCKED]`.**
Rights can be *exercised* (actually mint MONO) **only while premium ≥ ~15%** (measured on
the slow/stable TWAP — the "store hours" on/off signal). Purpose: without it a banker
waits for a quiet 1%-premium lull and mints at ≈ bare NAV, paying the vault ≈ nothing —
which is the rejected open-mint-at-NAV design sneaking through the exercise door. The gate
floors the vault's minimum take per mint at ≈ NAV + half of 15%.

**(d) The tap — rate limit on exercising.  `[LOCKED]` shape / `[SIM]` numbers.**
Exercise is flow-limited: **per-staker** outflow ≤ ~2–3× personal accrual rate `[SIM]`;
**global** instantaneous exercise (banks + fresh) ≤ the global capacity meter. The tap is
also **premium-proportional** (trickle just above threshold, full rate in strength) — so
a recovery crossing the 15% line meets a drizzle of banked supply, not a wall; the heavy
discharge happens deep in strength where the market absorbs it and the vault's take is
fattest. Keeps the drip-cap law true *instantaneously*, not just on average.

**(e) Strike — the price paid.  `[RATIFIED D16]` structure / `[PENDING]` the premium reading.**
Stage 2: `strike = NAV + 0.6·premium`, split **NAV + 0.5·premium → vault,
0.1·premium → treasury** (treasury % hardcoded max 10, admin can only REDUCE — one-way
ratchet down). Stage 1: auction-discovered x (D15), vault floor NAV + 0.5·premium +
80% of excess. Paid in INDEX, computed **at exercise** from live NAV + premium.
The 60 number = strong prior, sanity-checked vs stage-1 clearing-x before the
immutable cutover deploy.
- **Premium reading `[RATIFIED D17]`:** `strike = NAV + 0.6·max(spot, shortTWAP)` —
  fresh 30–60min window; spot captures real value with zero leak, the short TWAP is
  the anti-paint floor. Exact window [SIM]. (Closes the old P3 open question.)

**(f) Two harvester populations (behavioral model).**
- *Flippers* — exercise into strength, sell immediately, capture the high premium. The tap
  handles their bursts.
- *Bulls* — exercise at the cheapest allowed moment (the gate floor) as *discounted
  accumulation*, hold, sell as ordinary holders. No burst; their mint converts harvest
  capacity into buy-side demand, not sell pressure.

**(g) Why the premium doesn't grind to NAV (three brakes, `[LOCKED]`):**
1. Drip cap — max harvest sell pressure ≈ capacityRate (homeopathic vs memecoin churn).
2. Per-harvest accretion — each mint pays >NAV into vault → NAV rises on the same event →
   premium compresses *upward* (mNAV falls while price and floor both rise = victory).
3. The economics self-discover the premium level where harvesting stops being profitable.

### 3.6 TWAP discipline  `[LAW]` (TWAP-only triggers) / `[RATIFIED D17]` (three windows) / `[SIM]` (exact lengths)
**Every trigger reads a TWAP, never spot** (one exception below, in the safe
direction) — spot-painting one block must buy nothing. Computed from the pool's own
price accumulator (in v4 the accumulator lives in our hook). No Chainlink in this
path. **One accumulator, three read horizons (D17):**

| Consumer | Window | Why |
|---|---|---|
| Exercise gate (≥15%, on/off) | LONG 12–24h | binary threshold = most paintable; slowness is the defense; lag decides eligibility, not price |
| Strike reading (money path) | FRESH 30–60min, as **max(spot, shortTWAP)** | down-paint neutralized (takes the higher); up-paint overpays the vault; kills the pump-leak of a lagging strike |
| Accrual rate + tap refill | MEDIUM 1–4h | paint-farming accrual is a losing integral (tax + slippage vs minutes of drip, 2%/wk ceiling); reprices a real crash in ~an hour, not a day |

- **Sizing principle:** each window sized so moving that reading costs more than it
  buys. The spot leg in max() is the one spot read — safe because it can only raise
  what the harvester pays.
- **Manipulation framing (design intent):** holding a long TWAP displaced for hours,
  paying taxes the whole way, is *real sustained demand* — a customer, not an
  attacker. The lag exploit (spike, harvest against a stale strike, dump) is closed
  by max() + tap + taxes. Target property: **no way to influence the machine except
  by paying it.**

---

## 4. LITH & Stage 2  `[LOCKED]` architecture / open sub-decisions

### 4.1 LITH token  `[LAW]`
Fixed supply. **No perpetual emissions anywhere, ever.** Enters circulation only by:
earned (retro), vested (team/investors), sold (vault-capitalizing tranche), or
burn-to-mint expansion valve (off by default). Staking LITH → pro-rata harvest capacity.

### 4.2 Utility model  `[LOCKED via research]` / `[DECIDE]` final ratification
Research verdict (LITH-MODEL-RESEARCH.md): burn-vs-stake is the wrong axis; winners pair a
**stock sink** (staking that locks float for *utility access*, VVV-validated — the only
staking shape with a win) with a **flow sink**. For MONO:
- **Core = utility-access staking** (capacity credits, not cash yield). This is the
  current plan and the research-favored shape. Pure cash fee-share is dead (zero wins in
  sample, worst legal shape).
- **Optional flow = counter-cyclical, revenue-funded LITH buybacks, distributed** (NOT
  burn-as-fee — that has a theoretical kill + empirical graveyard). Already half in spec
  as "revenue-bought LITH streamed to long-staked MONO."
- **Rewards LAW:** *paid only from revenue or finite scheduled tranches — never uncapped
  emission tied to holding.*

### 4.3 The execution engine  `[LOCKED concept]` / `[PENDING]` fee + architecture
Optional convenience: stake LITH, and the engine auto-harvests. Two architectures
brainstormed (2026-07-22):
- **Option A `[LOCKED as chassis]`** — staker escrows funding (USDG), rights drip in,
  staker **takes delivery of MONO** and decides what to do. Rights-offering shape: no
  protocol discretion, no fund silhouette, no treasury inventory risk. Partial holding
  cuts sell pressure; per-user timing kills herded sell windows.
- **Option B `[REJECTED]`** — protocol fronts capital, sells the harvest, pays USDG yield.
  Rejected: protocol-as-harvester (banned), full performance-fee/fund shape, treasury
  inventory risk, herded sell flow, converts work-token → cash-yield (zero wins).
- **Synthesis:** build A; offer B's UX as a per-user **auto-sell d%** setting on A.
- **Fee `[RESOLVED by D16]`:** the old strike + 0.1·premium service-fee sketch is
  KILLED — the protocol-level 10-point treasury slice (D16) replaces it; everyone pays
  the same 60 ("hidden second k" gone, adverse selection gone). Engine runs
  free/at-cost. Still open: delegability fork; exercise-policy discretion (MEV /
  published neutral policy + jitter); engine must check spot-vs-strike profitability,
  not just the gate.
- **Banked-rights-on-unstake `[GAP]` B2:** recommend bank survives the 7-day cooldown,
  then decays on a short half-life unless restaked.

### 4.4 Staking hygiene  `[SIM]` priors
From HYPE (verified): instant-in, 1-day delegation lockup, 7-day unstake queue. LITH
needs **warmup on credit accrual** (~3–7d ramp — credits are worth most in manias, so
entry needs teeth, unlike HYPE's slow yield) + **7-day unstake cooldown**.

### 4.5 LITH tranches to MONO stakers  `[LOCKED]` (curve form)
Finite scheduled LITH tranches reward MONO staking. **Flow ∝ premium with a small drought
floor, never fully zero** (converted 2026-07-23 from the old hard "pause below threshold"
— a full stop made staking pointless in droughts → stakers leave when float-lock matters
most). Full rate in strength (finite budget concentrated where each LITH buys max
motivation and sells into depth), trickle at lows (loyalty never worthless), deferred
remainder extends the calendar. Trickle ≠ emission — total is a fixed budget re-timed.

### 4.6 Stage-2 staking contract — accumulator design  `[RECOMMENDED implementation, 2026-08-01]`
Synthetix/MasterChef accumulator pattern + two extensions (variable rate, tap bucket).
No loops over stakers; "per block" drip is an accounting fiction realized lazily.

**State.** Global: `accPerStake` (1e27 scale), `ratePerSec`, `lastUpdate`,
`totalStaked`. Per user: `shares`, `banked` (settled unexercised rights), `debt`
(accPerStake snapshot), `tapAllowance`/`tapLastUpdate`.

**checkpoint()** — closes the elapsed period at the OLD rate and OLD totalStaked
(`accPerStake += rate·Δt/totalStaked`), then re-samples
`ratePerSec = clamp(base + slope·(TWAP_premium − trigger)) · supply / WEEK`.
**settle(user)** — `banked += shares·(accPerStake − debt)`; `debt = accPerStake`.
Every mutating call (stake / unstake / exercise) runs `checkpoint(); settle(user);`
BEFORE touching shares.

**The audit invariant:** no state feeding the accumulator (rate, totalStaked, supply)
may change without the period being closed first in the same transaction — every
known bug in this contract family violates that ordering. Only the GLOBAL accumulator
closes periods; individual stakers stay untouched and implicitly exact
(claim = shares × diff of two accPerStake snapshots).

**Rate approximation:** piecewise-constant between checkpoints; rate reads the MEDIUM
(1–4h, D17) TWAP horizon → keeper checkpoints hourly + lazy checkpoints on every
interaction ⇒ drift stays small (checkpoint cadence should be ≲ the window). Rate-at-interval-start (locked before the interval) so
settlement timing can't inflate past accrual. Supply/parameter changes are contract
events that must themselves checkpoint ⇒ TWAP drift is the ONLY approximation.

**Exercise** (D16): gate ≥15% TWAP → refill personal token bucket
(`allowance += personalRate·tapMult·Δt`, capped) → check personal + global buckets →
pay NAV + 0.6·premium-at-exercise (50 vault / 10 treasury) → mint.

**Edges:** totalStaked==0 → skip accrual (capacity not created); round DOWN on settle
(dust stays in contract — never build a dust faucet); unstake settles first, B2 rule
then operates on `banked` only.

### 4.7 Genesis / distribution  `[LOCKED]`
LITH TGE at proof-of-premium, distributed **retroactively** against on-chain history
(stage-1 participants, held/staked MONO time incl. through drawdowns, volume). Retro
criteria undisclosed in advance (sybil defense), published at TGE. Split anchored on
comparables: ~60–70% community-retro, 20–25% team+investors vested (6mo cliff + 18mo),
5–10% tranche sale → seeds the vault, 1–2% airdrop.

**MONO staking itself `[GAP]` B1 — INCOMPLETE:** eligibility filter for tranches + a
flywheel node, but lockup/cooldown/warmup/accrual-math/wall-eligibility are unspecified.
Recommendation seed: staked MONO not sellable while staked (reduces panic float). Needs a
page before stage-2 contracts. Marked incomplete, return later.

---

## 5. The INDEX wrapper — DAY 1  `[RATIFIED D14]` / basket machinery mostly `[PENDING P4–P7]`
> Supersedes the mirror-wrapper design (BASKET-RESEARCH — historical). No stage-3
> migration exists; the wrapper launches with the protocol.

**The property it preserves:** vault appreciation multiplies into MONO's price at *any*
premium (price = ratio × backing-USD, independent multipliers). In a MONO/USDG pool this
is lost. Only a backing-embedded quote asset preserves it (Pinning Theorem — still valid).

**Architecture (P4 shape, effective day 1 via D14):**
- **One pot.** The wrapper holds the stocks; **the vault holds INDEX** (not raw stocks —
  the mirror design is dead). Machine pool = **MONO/INDEX from block one** →
  ratio = mNAV oracle-free at any N.
- **Genesis:** launch AAPLx wraps **1:1** into INDEX; recipe = 100% AAPL. Numerically
  identical to MONO/AAPLx at launch — INDEX is apple-in-a-shell until governance votes.
- **Public symmetric mint/redeem** at the current per-INDEX pot slice, in-kind. Both legs
  open (the closed-mint era is over — target-recipe minting made public mint safe).
- **Wrapper fee `[PENDING P7]`:** ~0.05% each way, charged in-kind; ~half to treasury as
  freshly-minted INDEX. Economic firewall against share-math games; part of the ONE
  REVENUE POLICY package (with P1 + engine-fee routing).
- **Composition covenant `[RATIFIED D12]` — NEVER REDUCE:** per-INDEX recipe quantities
  only increase (except atomic dual-recipe emergency ejections). No discretionary
  reduction, no in-fund rebalance (P6c REJECTED), no partial spin-offs. Weights fall
  only by growth around an asset.
- **Adding an asset `[PENDING P6j — principal-endorsed; pricing hardened D18]`:** LITH
  vote sets quantity targets (RAW units — split-safe) → the **deficit mint channel**
  opens: single-asset mint of the lacking stock, priced **bottom-up from constituent
  feeds, never any pool quote** — per-INDEX value = Σ(actual pot balance_i ×
  Chainlink feed_i) ÷ supply; deposit priced by its own feed; mint =
  value × (1 − 1% haircut, D20) ÷ perINDEX. Haircut > relative feed error (systematic
  drift divides out of the ratio) — the oracle can't dilute holders; mispricing hurts
  the minter, not the pot. Metered, market-hours-only, **every feed fresh or the
  channel closes** (per-feed staleness guard), deficit-only. **Termination (D19):**
  target = PER-INDEX raw quantity; `deficit = target×supply − balance`, live; open
  while > 0. Redemption/normal mint are ratio-neutral (pro-rata) → never undo
  progress; only deficit deposits move the ratio, monotonically. Absolute vote
  numbers convert at the vote block; the ratio is law.
  **Eligibility rule:** a stock is only votable if Robinhood-issuer-whitelisted AND
  has a live 4663 Chainlink feed with verified heartbeat/deviation. Dormant until a
  vote activates it; no protocol MATH ever depends on an INDEX trading venue (the
  routing pool is distribution infrastructure, not a price source).
- **Fire escape `[RATIFIED D12, emergency-only]`:** terminal assets only (issuer freeze,
  delisting, death). Sellable-dead → patient in-fund liquidation by treasury; frozen →
  mint pauses, redemption skips the leg with voluntary disclosed forfeit (P6g; IOU
  machinery deleted). Behind glass, never a management tool.
- **Dormant-module discipline `[D14]`:** everything above the plain wrap/unwrap ships
  day 1 but **inert** — deficit channel wakes only on a LITH governance vote; fire
  escape only on an emergency trigger. Composition is frozen at 100% AAPL until LITH
  exists and votes.
- **Routability `[updated D18 scope note]`:** three parallel entry paths — (1)
  **INDEX/USDG routing pool = PLANNED launch infrastructure** (fee-only hook,
  auto-routed; lets uniswap.org/aggregators multi-hop any-currency → USDG → INDEX →
  MONO into machine-pool depth; budgeted LVR bleed σ²/8·depth/yr; off-hours fee
  widening; day 1 it is effectively AAPL/USDG with our hook); (2) MONO/WETH satellite
  for pair-centric TG bots; (3) zap (currency → RFQ stocks → wrap) on our frontend.
  Depth/fee = launch-mechanics decision.
- **Token framing:** INDEX is infrastructure — never marketed. Anyone who ends up holding
  it has a fully-backed, redeemable basket claim — no trap state.

**The acquisition engine `[LOCKED]` — ships in stage 1:** one execution module —
user zaps (USDG/ETH → AAPLx → wrap), treasury RFQ accumulation keeper. 0x RFQ +
aggregator routes; atomic all-or-revert multicall; size-tiered; market-hours aware.

---

## 6. POL, treasury, liquidity  `[LOCKED]`

**Pool topology:**
- Machine pool: **MONO/INDEX from day 1** (D14). Reference-free ratio →
  no toxic arb/LVR against our POL (the one pool shape on this chain where stock-token
  liquidity isn't structurally unprofitable).
- Discovery satellite: MONO/WETH (small, POL) — what dexscreener/bots index and route.
- All liquidity protocol-owned.

**POL custody `[LOCKED]`:** held in a **flexible holder — multisig + timelock**, NOT a
burn (a true burn would make stage-3 re-denomination impossible; migration-only holder
rejected as over-constrained). Scanner LP-status optics = non-issue for a non-memecoin
protocol. **POL is NEVER counted in NAV** `[LAW]` (anti-Olympus: LP is half MONO →
self-referential floor; encumbered). One-way valve: pool→vault only (hook fees + skim of
depth above target → backing); vault→pool forbidden.

**Treasury tiers `[LOCKED]`:** Tier 0 floor defense (coverage ≥100%); Tier 1 dashboards;
Tier 2 low-risk surplus (USDG ladder under wall, off-hours quoting, lending idle backing —
surplus only, capped); Tier 3 (stage 2) tranche proceeds → vault, revenue → LITH buybacks.
SGOV (tokenized T-bills, live on 4663) is a tier-2 candidate. **Banned `[LAW]`:**
discretionary trading, rotation on views, holding own tokens as backing, marketing spend
from backing.

**USDG buffer `[GAP]` B3:** demoted to surplus, now has no intake path. Lean = **delete**.

---

## 7. Laws & parameters

**Bucket 1 — LAWS (immutable at deploy) `[LAW]`:**
no perpetual emissions; vault outflow = wall only; wall buys burn; issuance only via
harvest above NAV; LITH fixed supply; additive-only treasury; vault never holds
MONO/own-LP as backing; incentives never from backing; TWAP-only triggers; wall/harvest
mutual exclusion; harvester sell-fee exemption; capacity ceiling ≤ 2%/wk; rewards only
from revenue or finite tranches; **NEVER REDUCE (D12):** basket composition growth-only,
fire escape emergency-only; **vault and treasury are physically separate contracts**
(both hold INDEX — F2, explicit genesis split).

**Bucket 2 — comparable-anchored `[LOCKED]`:** LITH distribution split; team vesting
(6+18); launch decay curve; airdrop 1–2%.

**Bucket 3 — `[SIM]` priors (the sim's job):**

| param | prior | notes |
|---|---|---|
| k (strike premium share) | 0.6 total = 0.5 vault + ≤0.1 treasury | D16 ratified structure; treasury % reducible-only; sanity-check 60 vs stage-1 clearing-x |
| capacityRate (base) | 0.5%/wk @ 15% | curve to 2%/wk ceiling |
| capacity ceiling | 2%/wk | `[LAW]` hard cap |
| exercise gate | premium ≥ 15% | on the slow TWAP |
| tap multiple | 2–3× personal accrual | premium-proportional |
| wallTick | 0.5–1% | |
| deficit-channel haircut | 1% | D20 RATIFIED; build-time check: ≥2× worst relative feed error per feed, else bump |
| fee curve | zones / continuous (P2) | shape pending |
| company tax share | ~1/3 (P1) | pending |
| TWAP windows (D17) | gate 12–24h · strike 30–60min max(spot,TWAP) · rate 1–4h | structure ratified; lengths [SIM] |
| reserve x (auction floor) | ~20% of premium share | D15; replaces old GDA half-life dial |
| auction anti-flicker (min Δx, min active, min deposit) | tbd | D15 build params |
| staking warmup / cooldown | 3–7d / 7d | HYPE-anchored |
| tranche schedule | tbd, curve form | |

**Bucket 4 — mutability policy `[LOCKED]`:** immutable = all laws, LITH supply, k, routing
splits, wall mechanism. Timelocked within hard ceilings (48–72h, announced) = capacityRate
(≤2%/wk), fee levels (≤3%), gate threshold, half-lives. The stage-2 gate switch is the
only other admin function.

---

## 8. Chain facts (Robinhood Chain 4663)  `[VERIFIED 2026-07-19]`
Full detail + methodology in VERIFICATION.md. Re-verify before mainnet.

**Infra:** RPC `https://rpc.mainnet.chain.robinhood.com` (chainId 0x1237); explorer
`robinhoodchain.blockscout.com`.

**Key contracts (pin these; scam lookalikes exist):**
| what | address |
|---|---|
| AAPLx ($AAPL, 18dec, BeaconProxy) | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| Stock.sol impl (shared) | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` |
| AccessControlsRegistry = beacon | `0xe10b6f6B275de231345c20D14Ab812db62151b00` |
| USDG (6dec) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Chainlink AAPL/USD proxy | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` |
| CCA Factory | `0x00cCa200BF124dBfA848937c553864f4B4CE0632` |
| SPYx / QQQx (stage-3 candidates) | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` / `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` |

**Load-bearing facts:**
- **AAPLx custody CONFIRMED** — denylist (sanctions-only), not allowlist; contracts
  custody it in production. Vault CANNOT mint/redeem at reference (KYB'd APs only —
  BBVI) → secondary market / RFQ only.
- **Issuer risk SEVERE** — `adminBurn(any address)` works even while paused; global pause;
  blocklist; beacon upgrade. All single EOAs, no timelock. Accepted + disclosed; keeper
  must watch Blocked/Paused/Upgraded/AdminBurn events. Corporate actions via `uiMultiplier`
  (not rebase) — NAV code must be multiplier-aware.
- **Tax must live in a v4 HOOK, MONO stays a vanilla ERC-20** — token-level transfer tax
  is broken on v3/v4/UniswapX and unsupported by CCA.
- **Routing (UniRoute source):** fee-only/dynamic-fee hooks AUTO-ROUTE on uniswap.org;
  return-delta (custom-curve) hooks need Labs allowlist (active on 4663). → build tax as
  dynamic LP fees + wall as keeper/range bid = auto-routed tier.
- **Chainlink** live but heartbeat suspends off-hours (32.6h stale observed) — display/
  buffer only, not per-block triggers.
- **CCA** live on 4663. Open: does a CCA-launched custom-hook pool inherit the fee-bearing
  "CCA family"? Re-check the v4 fee-switch vote (closed ~Jul 26).
- **Naming clean:** monolithic.money/.finance/.fun + lith.money were unregistered;
  @monolithicmoney free (register). MONOHood dust squats the MONO ticker on-chain (claim
  the dexscreener listing early).

---

## 9. Security & adversarial posture
Full verdicts in ADVERSARIAL.md; coherence gaps in SYSTEM-REVIEW.md.

**Closed / sound:** wall identity & monotonicity (sim-proven); denomination (oracle-free
core); wall-bounce cycling (no zone combo profits the protocol's counterparty);
crumple-zone isolation (LITH failure can't propagate to MONO); no-emissions consistency
incl. tranche re-timing; weekend behavior (all triggers pool-driven); wash-trading
(self-financing); KYT (analytics-only today).

**Managed / disclosed:** AAPLx issuer guns (event sentinels + exposure caps + disclosure
— cannot be engineered away; it's the backing asset's counterparty risk).

**Open for campaign 2 / needs numbers:**
- TWAP-manipulation economics **with banking enabled** (C1 spot-pump exercise raid) — vs
  POL depth.
- Engine fee = hidden second k; adverse selection; delegability fork; exercise-policy MEV
  (batched sells = front-runnable windows → published neutral policy + jitter).
- D17 window lengths — sweep gate/strike/rate windows (leak vs paint-resistance vs
  crash-repricing) around the ratified three-window structure.
- Cutover-eve capacity rush (if stage-2 gating ratifies).

**Coherence fixes to apply (SYSTEM-REVIEW A-series):** stage-1 harvest must inherit the
exercise gate + tap from day one (A2); delete redundant suspension-at-NAV (A3); "defer not
cancel" → tranche-curve wording (A4); referral registry coupled to tax-sunset (A5).

**Engineering hygiene `[LAW-ish]`:** the "one curve read three times" (accrual, tap,
tranches) should be a single shared library function reading one TWAP — smaller audit
surface. Keeper must watch issuer events. Harvest sell route must provably sell only
just-minted MONO (protects the exemption).

---

## 10. Simulation status
Harness in `sim/` (agent-based hourly Monte Carlo, apple-denominated). Campaign 1 done
(results/RESULTS.md). Campaign 2 not yet run.

**Campaign-1 headlines:** floor monotonicity PASS (0 violations, ~1,100 paths); worst case
(panic + AAPL −22% + liquidity shock) still +8.9% NAV, wall absorbs 8.7% of supply, min
mNAV 1.012; premium half-life flat across capacityRate 0.1–2%/wk (drip-cap confirmed); tax
out-earns GDA fee ~20:1; GDA half-life is the primary capture dial.

**Campaign-2 required upgrades (SYSTEM-REVIEW F):** continuous accrual curve, per-cohort
banking state, exercise gate, premium-proportional tap, continuous fee curve, tranche
curve, engine auto-drip with d%, two harvester populations. Sweeps: k × engine fee, tap
multiple, drought floors, GDA half-life, POL vs manipulation-with-banking, LITH float
under staking vs burn controls, TGE sell-pressure vs vesting, strike-reading variants (P3).

---

## 11. Open decisions queue  `[DECIDE]`
1. **ONE REVENUE POLICY package** (P1 company tax share + tax-sunset + referral + P7
   wrapper fee + engine-fee routing — decide together). The auction line is already
   settled: 20% of excess above NAV+0.5·premium (D15).
2. Continuous fee curve shape (P2).
3. ~~k~~ — RESOLVED by D16 (60 total, 50/10 split, engine fee killed); only the
   pre-deploy sanity check vs stage-1 clearing-x remains.
4. LITH utility model final ratification (staking core; burn variants as sim controls).
5. ~~Strike premium reading~~ — RESOLVED by D17 (max(spot, 30–60min TWAP); window
   lengths [SIM]).
6. Formal ratification of the P4–P7 wrapper stack (P4/D14 in force; P6j
   principal-endorsed; P6h/P6i open; numbers everywhere `[SIM]`).
7. Launch mechanics: CCA vs POL seed; the v4 fee-switch/CCA-family outcome (vote
   closed ~Jul 26 — check).
8. MONO staking spec (B1) + banked-rights-on-unstake (B2).
9. USDG buffer: delete or define intake (B3).

## 12. Open proposals (pending, NOT accepted)
See PROPOSALS.md. P1 company tax share · P2 continuous fee curve · P3 strike premium
reading · P6h mint-at-final-slice · P6i deficit auctions (shelve-recommended) · P6j
deficit mint channel (endorsed) · P7 wrapper fee. (P4 vault-holds-INDEX is in force via
D14; P5's router logic superseded, quantity targets survive inside P6j; P6c rejected.)

---

## 13. Build scope & staging  `[LOCKED]` (rewritten for D13/D14)

**One architecture from block one; stages are switches, not migrations.**

**Day 1 (stage 1 — GDA era, target ~4 weeks, D13).** INDEX wrapper (wrap/unwrap +
in-kind mint/redeem at pot slice + P7 fee + dormant deficit channel + fire escape
behind glass) + MONO token (vanilla ERC-20) + v4 hook on MONO/INDEX (curve tax + launch
decay + harvest-exemption routing + TWAP accumulator) + Vault (INDEX custody, coverage,
wall keeper/range bid, burn; **separate contract from treasury**) + Harvest module
(accrual curve, banking, exercise gate ≥15%, premium tap, D15 auction book: formula
bids, top-of-book drip, escrow drawdown, 20%-of-excess treasury split) +
acquisition engine (zap: USDG/ETH → AAPLx → wrap; treasury RFQ keeper) + optional
ReferralRegistry + keeper (issuer-event sentinels, wall/harvest execution).
Proof-of-premium METRIC is the stage trigger; 4 weeks is a planning target, never
announced.

**Stage 2 — LITH TGE at proof-of-premium.** LITH ERC-20 + staking (warmup 3–7d /
cooldown 7d) + capacity gating (the ONE admin switch, timelocked) + execution engine
(Option A + d% auto-sell) + tranche scheduler (curve form) + revenue→buyback router.
**Must be deploy-ready DURING stage 1 (D13), not after.**

**No stage 3.** The old migration is DELETED (D14). Basket expansion = a LITH
governance vote waking the deficit channel; a routing pool (INDEX/USDG) is a later
optional add.

**Audit: mandatory** — wrapper + vault custody everything from day one; one
architecture = one audit.

---

*Handbook maintained alongside the source docs. When you change a decision, update the
source doc first (SPEC/DECISIONS/PROPOSALS), then reflect it here. Last aligned:
2026-08-01 (post D12–D14 / P4–P7 realignment).*
