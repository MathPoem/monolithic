# Fire escape — what it is, why it exists, how to build it (2026-08-01)

Written for the dev. Plain language first, function shapes at the end.

## Why it exists

"The pot never sells" is the trust product — but the issuer can freeze, blocklist,
or kill any stock token (verified powers). The fire escape is the ONE exception:
a voted, timelocked, emergency-only exit for a TERMINAL asset. Ships day 1, no
valid caller until governance is installed. It is NOT a rebalancing tool —
discretionary reduction was explicitly rejected; the code must make it impossible,
not just discouraged.

## The three situations, in plain words

**Situation A — a stock is dying but still tradeable.**
Example: Robinhood announces they're discontinuing the GME token in 90 days. It
still transfers and still has a market, but holding it to the end means holding
trash. → **Mode 1: sell it slowly from inside the pot and replace it.**

**Situation B — a stock is frozen.**
Example: the issuer blocklists our pot address, or globally pauses the token.
Transfers revert. We can't sell it, can't distribute it, can't do anything with it.
→ **Standing rules kick in automatically** (no vote needed): minting pauses, and
people who exit just leave the frozen sliver behind (details below). Everyone
waits. If it unfreezes — everything returns to normal by itself.

**Situation C — a frozen stock is declared permanently dead.**
The freeze isn't temporary; the instrument is gone for good. → **Mode 2: hand each
holder their share of the dead stock directly and remove it from the pot.**

## The standing rules (build these into the wrapper itself — always on)

These are not a "mode" — they're how the wrapper must behave any time some stock's
transfers revert. This is fix #1 from the Index.sol review:

**Redemption must never be hostage to one frozen stock.** Today `burn()` sends the
user their slice of every stock in one transaction — so if ONE stock's transfer
reverts, the whole redemption reverts, and every holder of INDEX is locked in until
the issuer unfreezes. That's unacceptable: someone with 10 stocks in the pot loses
access to 10 because of 1.

The fix: pay out leg by leg, and if one leg's transfer fails, **skip it** — the
user gets the other 9 stocks, and their share of the frozen one stays in the pot.
Emit an event for the skipped amount. Important nuance: the exiting user *chooses*
to burn anyway knowing they forfeit the frozen sliver (show it in the UI); the
sliver they leave behind belongs to the remaining holders. There are deliberately
NO IOUs — we considered and killed that design; IOU bookkeeping is a swamp.

Minting during a freeze pauses on its own (a mint needs every leg to transfer in),
just make sure the error is clean, not a random revert.

## Mode 1 — replace a dying (but sellable) stock

**Goal:** swap stock X for other stocks WITHOUT the pot's value, INDEX supply, or
anyone's balances changing. The pot trades with the market through the treasury's
execution desk; the pot itself just sees X leave and replacement value come back.

**Why slowly, in slices?** We measured the real pools on this chain: selling $250k
of a stock token in one clip loses ~47% to slippage; selling small clips loses ~1%.
So the sale must dribble: take at most ~1% of pot value of X at a time, sell it,
return the proceeds the same day, repeat for days or weeks. Patience is not
politeness here — it's the difference between losing 1% and losing half.

**Why proceeds go back in via a special door:** the wrapper's only normal inbound
path is minting (which creates new INDEX). Here nothing should be minted — value is
*returning*, not being contributed by an outsider. So the wrapper needs one
privileged function that accepts assets WITHOUT minting: `returnProceeds`. It must
be callable only by the fire-escape module — if it were public, anyone could dump
random tokens into the pot's accounting.

**Why the "recipe" must update in one atomic step at the end:** the pot has a
composition ledger (which stocks, what per-INDEX amounts) used by both minting and
redemption. If the mint-side and redeem-side compositions ever differ, someone can
loop mint→redeem (or redeem→mint) and extract the difference — a money pump. So
when X is finally removed, both sides change in the same transaction. Never write
one without the other.

**What users see meanwhile:** redemption keeps paying actual pot balances, so the
slice currently "in transit" at the desk is briefly invisible to redeemers. Capped
at ~1% of pot, for hours — acceptable, and the dashboard must show "in transit"
so it reads as an operation, not a hole.

## Mode 2 — remove a permanently dead, frozen stock

We can't sell it (frozen), so we give it away — to the people who own it anyway.
Every INDEX holder is, through the pot, a pro-rata owner of the dead stock. Mode 2
makes that ownership direct: snapshot the entitlement per INDEX, move the dead
stock to an escrow, remove it from both recipe sides atomically (same pump rule as
above), and let owners **claim** their share.

**Why claim and not just send?** Because a lot of INDEX doesn't sit in normal
wallets. The biggest holder is a Uniswap pool — tokens pushed at the PoolManager
are credited to nobody and lost forever. Vaults and contracts can't handle surprise
tokens either. So: escrow + claim function; each owner pulls their share when ready.
Unclaimed remainders sweep to the treasury after a long, disclosed deadline (years).

Special claimants to wire up:
- **the vault** (our reserve, largest INDEX holder): its claim routes to the
  treasury desk, because the vault itself is forbidden to hold or sell raw stocks —
  it only holds INDEX. The desk handles the carcass; if the stock ever revives, the
  desk converts and re-mints INDEX back to the vault.
- **our own liquidity positions**: claimed by the POL multisig.
- **the staking engine** (stage 2): claims once, credits its users internally.

**The honest price step:** at the snapshot block, INDEX gets less valuable —
because a slice of its backing left. Holders lose nothing: they now hold the claim
to that slice directly. INDEX repricing happens once, visibly, at a known block.
The rest of the machine doesn't flinch (it reads pool ratios and balances, never
this event).

## Who can pull the handle

- A LITH governance vote + a long timelock. Nothing else. Not the team multisig.
- Until LITH governance exists (stage 2), the functions have **no valid caller** —
  the address that may call them starts unset and is installed exactly once, later.
  This "dormant but deployed" pattern is deliberate: one codebase, one audit, and a
  provable statement that nobody — including us — can touch compositions today.
- The vote must name the asset and the mode; the machinery must refuse any asset
  not named by the vote.

## Functions to add to the wrapper (shapes, feel free to improve)

```
returnProceeds(asset, amount)  fire-escape module only. Accept `amount` of `asset`
                               into the pot WITHOUT minting; register the asset if
                               it's new. The only non-mint inbound door.

escrowSlice(asset, amount)     fire-escape module only; asset must be vote-flagged.
                               Move ≤ maxSlice (≈1% of pot value) of `asset` to the
                               liquidation/distribution escrow.

deregister(asset)              fire-escape module only; only when the pot's balance
                               of `asset` is zero; removes it from the registry and
                               fixes allocations — mint and redeem sides in the
                               same transaction.
```
Plus the standing skip-leg behavior inside `burn()` (always on, not gated).

## Tests that prove it's right

1. Freeze 1 of 3 stocks (mock a reverting token) → `burn()` pays the other 2,
   emits the skip, pot keeps the sliver.
2. No sequence of calls changes mint-side composition without redeem-side in the
   same tx (the pump test: mint→redeem and redeem→mint round trips never profit).
3. `returnProceeds`/`escrowSlice`/`deregister` all revert before the governance
   address is installed, and for any asset not flagged by the vote after it is.
4. Mode 1 end-to-end: pot value before ≈ after (minus execution costs), INDEX
   supply unchanged, vault INDEX balance unchanged.
5. Mode 2: Σ(claims) + swept remainder = escrowed amount exactly; INDEX slice
   steps down exactly once, at the snapshot block.
6. Tokens pushed to the escrow by strangers don't corrupt entitlement math.
```
