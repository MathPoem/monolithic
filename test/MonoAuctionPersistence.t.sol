// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MonoAuction} from "../src/MonoAuction.sol";
import {IMonoAuction} from "../src/interfaces/IMonoAuction.sol";
import {TestERC20} from "./TestERC20.sol";

/// Does an unclaimed allocation survive later rounds and later markets?
contract MonoAuctionPersistenceTest is Test {
    MonoAuction internal auction;
    TestERC20 internal token;
    TestERC20 internal idx;

    address internal seller = address(0xF1);
    address internal patient = address(0xBEEF); // never claims until the very end
    address internal churner = address(0xCAFE); // bids every round

    uint256 constant FLOOR = 1e18;
    uint256 constant SPACING = 1e16;
    uint256 constant Q96 = 1 << 96;

    function setUp() public {
        token = new TestERC20("T", "T");
        idx = new TestERC20("I", "I");
        auction = new MonoAuction(address(0), address(0), address(idx), SPACING, Q96 / 2, 8);
    }

    function _bid(uint256 id, address who, uint256 price, uint128 amt) internal {
        idx.mint(who, amt);
        vm.startPrank(who);
        idx.approve(address(auction), amt);
        auction.submitBid(id, price, amt, who, FLOOR);
        vm.stopPrank();
    }

    function _fundAndSettle(uint256 id, uint128 supply) internal {
        token.mint(address(auction), supply);
        auction.fund(id, supply);
        (,,,,,,,,, uint64 end,) = auction.markets(id);
        if (block.number < end) vm.roll(end);
        auction.settle(id, type(uint256).max);
    }

    /// Ten rounds of other people bidding and settling. The patient bidder never claims.
    /// Their tokens must be exactly what accrued, not what is left over.
    function test_unclaimedSurvivesManyRoundsAndOtherBidders() public {
        uint256 id = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        auction.openRound(id, uint64(block.number + 50));
        _bid(id, patient, FLOOR + 2 * SPACING, 500e18);

        uint256 expected;
        for (uint256 r; r < 10; ++r) {
            _bid(id, churner, FLOOR + 3 * SPACING, 40e18); // outbids them, every round
            _fundAndSettle(id, 30e18);

            // What the index says the patient bidder is owed, without harvesting.
            (, uint256 owed) = auction.positionOf(id, patient, FLOOR + 2 * SPACING);
            assertGt(owed, expected, "accrual grows every round");
            expected = owed;

            auction.claim(id, churner, FLOOR + 3 * SPACING); // someone else keeps claiming
            auction.openRound(id, uint64(block.number + 50));
        }

        // A whole new market opens on the same contract, and settles.
        uint256 other = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        auction.openRound(other, uint64(block.number + 50));
        _bid(other, churner, FLOOR + SPACING, 100e18);
        _fundAndSettle(other, 50e18);

        // Only now does the patient bidder show up.
        uint256 got = auction.claim(id, patient, FLOOR + 2 * SPACING);
        assertEq(got, expected, "paid exactly what accrued, ten rounds later");
        assertEq(token.balanceOf(patient), expected, "and it actually arrived");
        assertGt(got, 0, "sanity: they did win tokens");
    }

    /// A second market may never draw on the first market's unclaimed tokens.
    function test_newMarketCannotTouchUnclaimed() public {
        uint256 id = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        auction.openRound(id, uint64(block.number + 50));
        _bid(id, patient, FLOOR, 100e18);
        _fundAndSettle(id, 50e18);

        (,,,, uint128 unclaimed,,,,,,) = auction.markets(id);
        assertGt(unclaimed, 0, "market 1 owes tokens");
        assertEq(auction.reserved(address(token)), unclaimed, "and they are reserved");

        // Fund a second market with a fresh transfer — it may only claim unreserved balance.
        uint256 other = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        token.mint(address(auction), 10e18);
        auction.fund(other, 10e18);
        assertEq(auction.reserved(address(token)), unclaimed + 10e18, "reserves stack, never share");

        // Over-funding market 2 from market 1's reserve must revert.
        vm.expectRevert(IMonoAuction.InvalidAmount.selector);
        auction.fund(other, 1);

        assertEq(auction.claim(id, patient, FLOOR), unclaimed, "market 1 still pays in full");
    }
}
