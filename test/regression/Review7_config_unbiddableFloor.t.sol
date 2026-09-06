// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IMono} from "../../src/interfaces/IMono.sol";
import {GenerousAuction as GenerousAuction_} from "../../src/GenerousAuction.sol";

/// HAZARD: the constructor never compares `floorPrice` with `Mono.nav()` (src/GenerousAuction.sol
/// L227-229 only check `floorPrice != 0`, `<= uint128.max`, aligned). But `submitBid` floors every
/// bid at `nav()` (L535) AND caps every bid at `floorPrice * MAX_PRICE_MULTIPLE` (L530, 1e4x).
/// So any deploy with `floorPrice * 1e4 < nav()` is accepted and NO price is ever biddable:
/// everything below NAV is `BelowNav`, everything above `1e4 * floor` is `BidTooHigh`, and the two
/// bands do not touch. The constructor already reads `IMono(c.token)` for the premium gate
/// (L253, L258) so `floorPrice >= nav()` was a one-line check.
contract Review7ConfigUnbiddableFloor is Review7ConfigBase {
    function _deployFloor(uint256 floor, uint256 spacing) internal {
        _freshMono(); // NAV = 1.0 (1e18): 1M MONO against 1M INDEX
        IGenerousAuction.Config memory c = _defaultConfig();
        c.floorPrice = floor;
        c.tickSpacing = spacing;
        _deployWith(c);
    }

    /// A floor written in "gwei" units (1e9) against a NAV of 1e18: accepted, and every bid on the
    /// grid reverts one way or the other.
    function test_floorTimesMaxMultipleBelowNav_isAcceptedAndUnbiddable() public {
        _deployFloor(1e9, 1e7);
        uint256 nav = IMono(address(mono)).nav();
        uint256 maxPrice = auction.floorPrice() * 1e4;
        emit log_named_uint("nav()", nav);
        emit log_named_uint("max biddable price (floor * 1e4)", maxPrice);
        assertLt(maxPrice, nav, "the biddable band [floor, 1e4*floor] sits entirely below NAV");

        uint256 floor = auction.floorPrice();
        _stakeFor(aa, 1e18);
        cur.mint(aa, 1e24);
        vm.startPrank(aa);
        cur.approve(address(auction), 1e24);

        // Highest price the cap allows: BelowNav.
        vm.expectRevert(IGenerousAuction.BelowNav.selector);
        auction.submitBid(maxPrice, 1e21, aa, floor);
        // Lowest price NAV allows (on grid): BidTooHigh.
        vm.expectRevert(IGenerousAuction.BidTooHigh.selector);
        auction.submitBid(nav, 1e21, aa, floor);
        // The floor itself: BelowNav.
        vm.expectRevert(IGenerousAuction.BelowNav.selector);
        auction.submitBid(floor, 1e21, aa, floor);
        vm.stopPrank();

        // Emission accrues to a book that cannot exist: `due()` grows, nothing can ever be sold.
        vm.roll(block.number + 1000);
        auction.sync(64);
        assertEq(auction.tokensSold(), 0, "nothing sold");
        assertGt(auction.due(), 0, "schedule keeps accruing into a sale nobody can bid on");
    }

    /// The assertion that SHOULD hold at deploy and does not: a deploy with an unbiddable grid
    /// should revert. This is the bug-form of the finding: it FAILS on current code.
    function test_BUG_constructorAcceptsFloorBelowNavOverMaxMultiple() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.floorPrice = 1e9;
        c.tickSpacing = 1e7;
        vm.expectRevert(); // any revert: the guard is missing entirely
        new GenerousAuction_(c);
    }

    /// The milder, more likely variant: floor BELOW NAV but within 1e4x. Accepted; the floor tick
    /// (the one tick the constructor initialises, L280) and every grid point under NAV are dead
    /// on arrival - `highestTick` starts on a price nobody can bid at.
    function test_floorBelowNav_floorTickDeadOnArrival() public {
        _deployFloor(1e17, 1e15);
        uint256 nav = IMono(address(mono)).nav();
        assertLt(auction.floorPrice(), nav, "floor is below NAV at deploy");
        uint256 floor = auction.floorPrice();
        _stakeFor(aa, 1e18);
        cur.mint(aa, 1e24);
        vm.startPrank(aa);
        cur.approve(address(auction), 1e24);
        vm.expectRevert(IGenerousAuction.BelowNav.selector);
        auction.submitBid(floor, 1e21, aa, floor);
        vm.stopPrank();
        // Dead prices between floor and NAV on this grid:
        uint256 dead = (nav - auction.floorPrice()) / auction.tickSpacing();
        emit log_named_uint("grid points below NAV that can never be bid", dead);
        assertEq(dead, 900, "900 of the grid's first 1000 prices are unbiddable from block one");
    }
}
