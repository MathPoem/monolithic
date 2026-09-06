# Regression suite for the round-6/7 review findings of `GenerousAuction.sol`

Every test here pins a defect found by the two tests-first review rounds (57 findings, dossiers in
the research repo) and asserts the *correct* behaviour. The suite was committed RED on
`staking-hardening` (`764b051`: 21 failing tests) and turned green defect by defect on the fix
branch; it stays as the regression net. Tests that used to assert the buggy intermediate state
were rewritten to the fixed expectation, scenarios unchanged.

```
forge test --match-path 'test/regression/*'
```

Every scenario uses the deploy script's own parameters (floor 1.00, tick 1e16, q = 1/2, window 8,
`emissionPerRound` 50-100 MONO per 100 blocks) unless the test is *about* a parameter.

## Map: defect -> test (all green after the fixes)

### A. Tick-list splice leaves stale interior links (blocker)

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_organic_selfLoopBrick` | `test_honestRebidSelfLoopsTheBookAndBricksEverything` | 5 bidders, 4 small seats exhaust, two honest re-bids at old prices with the hint the book itself shows: `ticks[p].prev == p`, every entry point panics 0x32 forever | none |
| `Review7_organic_unbiddablePrices` | `test_oldPriceHasNoUsableHint` | Same book one step earlier: an initialised price has no hint that is accepted without corrupting the list | none |
| `Review6_integration_splicedHintOrphan` | `test_splicedTickAcceptedAsPrevHint`, `test_orphanedTickNeverFills` | Two bidders withdraw, one sync splices; a bid using the event-derived hint is accepted instead of `BadPrevHint`, and a later correct re-insert orphans it | none |
| `Review6_storage_staleRidgeOrphan` | `test_orphan_bidAtSplicedInteriorPriceIsNeverPoured`, `test_orphan_staleTopHidesHonestLiveTick` | Re-bid at a spliced interior price with the correct live-list hint: accepted, never linked, never poured; as `highestTick` it hides a live tick below | ridge built by bid+withdraw (any user) |
| `Review6_storage_ridgeReexposure` | `test_ridgeReexposure_oneDustBidRewalksWholeRidge` | One dust bid at a stale interior node re-exposes a 1000-tick dead ridge to every sweep and locks bids out with `SettleFirst` | yes (cheap) |
| `Review7_chain_orphanFinalizeDestroysCarry` | `test_chain_finalizeDestroysHiddenCarry` | Orphaned `highestTick` makes a full sweep sell nothing; `finalize` flips and the hidden live tick's emission is destroyed | yes |

### B. Fixed window band is not shift-invariant

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_fairness_syncCadence` | `test_cadenceChangesAllocation` | Top tick dries; a tick just under the band gets 0 with one sync and 29.67% with per-block syncs | none |
| `Review6_whale_dust-top-excludes-band` | `test_strategy_dustTopStarvesHonestTick` | A 2-wei dust bid `windowTicks` above the whale pushes the honest tick out of the band: 1/3 -> 0 | yes (2 wei) |
| `Review7_config_narrowBandPriority` | `test_twoWeiSpacing_turnsGenerousIntoPriority` | `tickSpacing = 2 wei` is accepted; the band is 16 wei and a +18 wei bid takes 100% | none (config) |

### C. Rounding direction: escrow shortfall

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review7_rounding_integralPriceShortfall` | `test_oneRound_atFloor_bricksEveryClaim`, `test_oneRound_atFloor_claimReverts` | Three bidders at the 1.00 floor, one round, all withdraw: `currencyRaised` exceeds escrow by 2 wei, `mintPack` and every `claim` revert until someone donates | none |
| `Review7_rounding_pourClampReachable` | `testFuzz_sumOfFloorsClaim` | The "unreachable" budget clamp in `_pour` binds on ~1 in a few hundred windows and shorts the lowest tick | none |

### D. Keeper / succession

| Test | Failing function | Scenario | Adversary |
| --- | --- | --- | --- |
| `Review6_keeper_zero-budget-sync-parks-cursor` | `test_zeroBudgetSyncBlocksBids` | `sync(0)` parks the cursor with no work; the next bid fast-fails `SettleFirst` | yes (~30k gas/block) |
| `Review6_succession_runbook_finalized_is_not_packed` | `test_runbookFollowedLiterally_claimStillBricks` | Following the succession runbook literally revokes the predecessor's minter role before its finalize-sold tail is packed; every claim reverts | none (operator) |

### E. Constructor sanity checks

| Test | Failing function | Scenario |
| --- | --- | --- |
| `Review7_config_staleStartBlock` | `test_BUG_staleStart_wholeSaleDueAtDeploy` | `startBlock` 2.3 days in the past: 100% of `saleSupply` is due at deploy |
| `Review7_config_roundLongerThanLife` | `test_BUG_adminRescheduleNeverTakesEffect` | `roundBlocks` longer than the sale: `setRoundParams` queues past `endBlock` forever |
| `Review7_config_unbiddableFloor` | `test_BUG_constructorAcceptsFloorBelowNavOverMaxMultiple` | `floor * 1e4 < nav()`: no price is biddable |
| `Review7_config_emissionExtremes` | `test_BUG_zeroEmissionAccepted`, `test_BUG_maxEmissionSentinel_secondRescheduleReverts` | `emissionPerRound = 0` accepted; `uint128.max` bricks `setRoundParams` after one change |

## Not in this suite

Pause-leak (re-armable sybils, round-6 #6/#10), heap-depth gas, pooled-pack haircuts and the carry
ponytails are **characterisations** (they pass with measured numbers) and live in
`experiments/monolithic-review6` / `-review7` of the research repo, together with the organic
population simulations (need `--gas-limit 1000000000000 --threads 1`) and the 10k-pour rounding
drift measurements. Promote one here by flipping its assertion once the behaviour is declared a bug.
