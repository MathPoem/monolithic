// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";

/// HAZARD: `tickSpacing` as low as 2 wei is ACCEPTED (MIN_TICK_SPACING = 2, src/GenerousAuction.sol
/// L87-90 / L226), and the window is a PRICE band `[tau - windowTicks*tickSpacing, tau]`
/// (`_gather` L728-730). The only pairing check is `q^windowTicks <= 1%` (L232-234), which is
/// measured in GRID STEPS, not in price. So at spacing 2 wei / windowTicks 8 the whole q-curve
/// spans 16 wei of price: any bid more than 16 wei above the book is a separate window, and windows
/// are solved top-down in full (`_sync` L611-660) - i.e. the "generous" geometric split degenerates
/// into a strict price-priority pay-as-bid fill, and the `(1 - q)` soft anti-whale cap is escaped
/// for +18 wei (1.8e-15 %) with NO dust trick, no sybil, nothing but an honest bid.
contract Review7ConfigNarrowBandPriority is Review7ConfigBase {
    uint256 internal constant FLOOR = 1e18;

    function _deploySpacing(uint256 spacing) internal {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.tickSpacing = spacing;
        c.emissionPerRound = 100e18;
        c.roundBlocks = 100;
        _deployWith(c);
    }

    /// Same book shape, two grids. On the script's 1e16 grid a bid ONE tick above the floor is in
    /// the floor's window and the floor keeps q/(1+q) = 1/3. On the 2-wei grid a bid 18 wei above
    /// the floor (0.0000000000000018 % more) is OUTSIDE the band; the floor gets 0 until the
    /// higher bid is fully filled.
    function test_twoWeiSpacing_turnsGenerousIntoPriority() public {
        // ---- reference: the deploy script's grid ------------------------------------------
        _deploySpacing(1e16);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, FLOOR, 1000e18, FLOOR);
        _bid(bb, FLOOR + 1e16, 1000e18, FLOOR); // one grid step up
        vm.roll(block.number + 100);
        auction.sync(64);
        uint256 refFloor = _owed(aa);
        uint256 refTop = _owed(bb);
        assertApproxEqAbs(refFloor, uint256(100e18) / 3, 2, "reference grid: floor keeps q/(1+q) = 1/3");
        assertApproxEqAbs(refTop, uint256(200e18) / 3, 2, "reference grid: top gets 1/(1+q) = 2/3");

        // ---- hazard: the 2-wei grid, accepted by the constructor ---------------------------
        _deploySpacing(2);
        assertEq(auction.tickSpacing(), 2, "constructor accepted a 2-wei grid");
        assertEq(auction.windowTicks() * auction.tickSpacing(), 16, "the whole q-curve spans 16 wei of price");
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, FLOOR, 1000e18, FLOOR);
        _bid(bb, FLOOR + 18, 1000e18, FLOOR); // 18 wei up = 9 grid steps = outside the 8-step band
        vm.roll(block.number + 100);
        auction.sync(64);

        emit log_named_uint("2-wei grid: floor bidder owed", _owed(aa));
        emit log_named_uint("2-wei grid: +18 wei bidder owed", _owed(bb));

        // The mechanism's promise (a q-weighted split across the live book) does not survive the
        // grid: the +18-wei bidder takes 100% at its own price and the floor bidder is starved.
        assertEq(_owed(bb), 100e18, "top-of-book took the ENTIRE round at +18 wei");
        assertGt(_owed(aa), 0, "BUG: honest floor bidder starved by an 18-wei overbid (band = 16 wei)");
    }

    /// The soft cap is escaped by a chain of honest overbids, each 18 wei apart: with three bidders
    /// spread over 36 wei the book behaves as three separate windows filled top-down.
    function test_twoWeiSpacing_strictPriorityAcrossThreeBidders() public {
        _deploySpacing(2);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _stakeFor(cc, 1e18);
        _bid(aa, FLOOR, 1000e18, FLOOR);
        _bid(bb, FLOOR + 18, 1000e18, FLOOR);
        _bid(cc, FLOOR + 36, 40e18, FLOOR + 18); // small cap: 40 tokens
        vm.roll(block.number + 100);
        auction.sync(64);

        emit log_named_uint("cc (+36 wei, cap 40)", _owed(cc));
        emit log_named_uint("bb (+18 wei)", _owed(bb));
        emit log_named_uint("aa (floor)", _owed(aa));
        assertApproxEqAbs(_owed(cc), 40e18, 2000, "top window filled to its cap first");
        assertApproxEqAbs(_owed(bb), 60e18, 2000, "second window took every remaining token");
        assertEq(_owed(aa), 0, "floor got nothing: high-to-low priority fill, not a q-split");
    }

    /// The guard the constructor should have had: the band must be a material fraction of the
    /// floor in PRICE terms, e.g. `windowTicks * tickSpacing >= floorPrice / 100` (the script's
    /// own pairing gives 8%). Characterisation: the deploy that should be rejected is accepted.
    function test_guardMissing_bandBelowOneBpOfFloorIsAccepted() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.tickSpacing = 2;
        c.windowTicks = 8;
        GenerousAuction a = new GenerousAuction(c);
        uint256 bandBips = (a.windowTicks() * a.tickSpacing()) * 10_000 / a.floorPrice();
        emit log_named_uint("band width in bips of floor", bandBips);
        assertEq(bandBips, 0, "band is < 1 bp of the floor and the constructor accepted it");
    }
}
