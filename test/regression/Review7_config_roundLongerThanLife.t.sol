// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// HAZARD: `roundBlocks` may be anything up to uint32.max (src/GenerousAuction.sol L216) and
/// `endBlock` need only exceed `startBlock` (L223). A bounded sale whose life is SHORTER than one
/// round is accepted. Consequences, all from `setRoundParams` (L349-384) + `_emittedAt`
/// (L322-337):
///   - the next boundary is `startBlock + roundBlocks > endBlock`, `_scheduleBlock` clamps every
///     read at `endBlock`, so `pendingFrom` is never reached: the admin's ONLY power - pacing -
///     is inert for the whole life of the sale, while `RoundParamsQueued` is emitted as if the
///     change were coming;
///   - `roundsElapsed()` reads 0 forever;
///   - the sale emits the pro-rata fraction `life / roundBlocks` of ONE round and nothing else.
/// The guard: `endBlock == 0 || endBlock - startBlock >= roundBlocks`.
contract Review7ConfigRoundLongerThanLife is Review7ConfigBase {
    function _deployShortLife() internal {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.roundBlocks = 10_000;
        c.emissionPerRound = 100e18;
        c.endBlock = uint64(block.number + 5_000);
        _deployWith(c);
    }

    /// BUG-form: the admin's reschedule must take effect somewhere inside the sale's life. FAILS.
    function test_BUG_adminRescheduleNeverTakesEffect() public {
        _deployShortLife();
        vm.roll(block.number + 10);
        vm.prank(address(0xF1));
        auction.setRoundParams(1, 1e18); // "1 MONO per block from the next boundary"
        uint64 from = auction.pendingFrom();
        emit log_named_uint("pendingFrom", from);
        emit log_named_uint("endBlock", auction.endBlock());
        assertLe(from, auction.endBlock(), "BUG: RoundParamsQueued points past endBlock; the change can never bite");
    }

    /// Characterisation: emission over the whole life is exactly one half-round, and the
    /// re-schedule (to 1 MONO/block, 5000 MONO over the life) changed nothing.
    function test_shortLife_emitsHalfARoundAndIgnoresAdmin() public {
        _deployShortLife();
        vm.roll(block.number + 10);
        vm.prank(address(0xF1));
        auction.setRoundParams(1, 1e18);
        vm.roll(auction.endBlock() + 100);
        emit log_named_uint("emittedToDate at end", auction.emittedToDate());
        emit log_named_uint("roundsElapsed at end", auction.roundsElapsed());
        assertEq(auction.emittedToDate(), 50e18, "5000/10000 of one 100-MONO round, admin change ignored");
        assertEq(auction.roundsElapsed(), 0, "the sale never completes a round");
        // A second admin call after the end folds the pending generation at `endBlock` and
        // re-queues past it again: still inert, still emitting the event.
        vm.prank(address(0xF1));
        auction.setRoundParams(1, 1e18);
        assertGt(auction.pendingFrom(), auction.endBlock(), "re-queued past the end again");
        assertEq(auction.emittedToDate(), 50e18, "unchanged");
    }
}
