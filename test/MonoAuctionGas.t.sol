// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MonoAuction} from "../src/MonoAuction.sol";
import {IMonoAuction} from "../src/interfaces/IMonoAuction.sol";
import {TestERC20} from "./TestERC20.sol";

/// @dev Regression tests for the two gas properties the continuous design exists to guarantee:
///      a round boundary is O(1), and no unbounded list walk is reachable on a third party's gas.
///      Run with --isolate for realistic cold-access pricing.
contract MonoAuctionGasTest is Test {
    MonoAuction internal auction;
    TestERC20 internal token;
    TestERC20 internal idx;

    address internal seller = address(0xF1);
    address internal victim = address(0xC1C1);
    address internal attacker = address(0xBAD);

    // The grid script/DeployLocal.s.sol actually ships — the one the old wedge was measured on.
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e17;

    function setUp() public {
        token = new TestERC20("Token", "TKN");
        idx = new TestERC20("Index", "INDEX");
        auction = new MonoAuction(address(0), address(0), address(idx), SPACING, 1, 16);
        idx.mint(attacker, 1_000_000e18);
        idx.mint(victim, 1_000_000e18);
        vm.prank(attacker);
        idx.approve(address(auction), type(uint256).max);
        vm.prank(victim);
        idx.approve(address(auction), type(uint256).max);
    }

    function _market(uint128 supply) internal returns (uint256 id) {
        id = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        token.mint(address(auction), supply);
        auction.fund(id, supply);
        auction.openRound(id, uint64(block.number + 50));
    }

    /// The old design rebuilt the child's book one bid at a time (~200k gas each), which is what
    /// made a roll O(n) and wedgeable. A round boundary must now be flat in book depth.
    function test_roundBoundaryIsConstantInBookDepth() public {
        uint256 small = _market(1);
        vm.startPrank(attacker);
        for (uint256 k = 1; k <= 25; ++k) {
            auction.submitBid(small, FLOOR + k * SPACING, 1e18, attacker, FLOOR + (k - 1) * SPACING);
        }
        vm.stopPrank();
        vm.roll(block.number + 50);
        auction.settle(small, type(uint256).max);
        uint256 g0 = gasleft();
        auction.openRound(small, uint64(block.number + 50));
        uint256 smallCost = g0 - gasleft();

        uint256 big = _market(1);
        vm.startPrank(attacker);
        for (uint256 k = 1; k <= 400; ++k) {
            auction.submitBid(big, FLOOR + k * SPACING, 1e18, attacker, FLOOR + (k - 1) * SPACING);
        }
        vm.stopPrank();
        vm.roll(block.number + 50);
        auction.settle(big, type(uint256).max);
        g0 = gasleft();
        auction.openRound(big, uint64(block.number + 50));
        uint256 bigCost = g0 - gasleft();

        emit log_named_uint("openRound with  25 ticks", smallCost);
        emit log_named_uint("openRound with 400 ticks", bigCost);
        // 16x the book, same cost. The old roll would have been ~16x more expensive.
        assertApproxEqAbs(bigCost, smallCost, 500, "round boundary is O(1) in book depth");
    }

    /// The wedge: an attacker plants ticks so a *third party's* operation must walk them. In the
    /// old design that walk lived inside the migration pass, could be pushed past a block gas
    /// limit, and froze every claim on the parent permanently. There is no migration pass now, so
    /// the victim's costs must be flat in book depth — asserted by comparing a 50-tick book against
    /// a 1000-tick one rather than against an arbitrary absolute number.
    function test_deepBookCannotWedgeAnyoneElse() public {
        (uint256 claimShallow, uint256 withdrawShallow, uint256 reopenShallow) = _victimCosts(50, address(0xDEC0));
        (uint256 claimDeep, uint256 withdrawDeep, uint256 reopenDeep) = _victimCosts(1_000, address(0xDEC1));

        emit log_named_uint("claim    @   50 ticks", claimShallow);
        emit log_named_uint("claim    @ 1000 ticks", claimDeep);
        emit log_named_uint("withdraw @   50 ticks", withdrawShallow);
        emit log_named_uint("withdraw @ 1000 ticks", withdrawDeep);
        emit log_named_uint("reopen   @   50 ticks", reopenShallow);
        emit log_named_uint("reopen   @ 1000 ticks", reopenDeep);

        // 20x the book, same cost. The old design was linear here, and unboundedly so.
        assertApproxEqAbs(claimDeep, claimShallow, 2_000, "claim is O(1) in book depth");
        assertApproxEqAbs(withdrawDeep, withdrawShallow, 2_000, "withdraw is O(1) in book depth");
        assertApproxEqAbs(reopenDeep, reopenShallow, 2_000, "reopen is O(1) in book depth");
    }

    /// Build a market with `plantCount` attacker ticks and a victim holding one position that
    /// clears and one at the floor that is never reached, then measure the victim's exits.
    /// @param who A fresh address per run: an ERC20 recipient whose balance slot goes zero ->
    ///            nonzero pays 20k for that SSTORE, nonzero -> nonzero pays 2.9k. Reusing one
    ///            address across runs shows up as a 17k "difference" that is not about book depth.
    function _victimCosts(uint256 plantCount, address who)
        internal
        returns (uint256 claimCost, uint256 withdrawCost, uint256 reopenCost)
    {
        idx.mint(who, 100e18);
        vm.prank(who);
        idx.approve(address(auction), type(uint256).max);
        // Supply clears the victim's top tick and one planted tick, then runs out — so settle depth
        // is the same for both book sizes and only the *book* differs.
        uint256 id = _market(1e16);
        // Constant across book sizes, so the victim's position takes the SAME _harvest branch in
        // both runs and only book depth varies. (Varying it compares a full clear against a partial
        // fill, which differ by ~9.5k gas for reasons that have nothing to do with depth.)
        uint256 topPrice = FLOOR + 1_100 * SPACING;

        vm.startPrank(who);
        auction.submitBid(id, topPrice, 1e18, who, FLOOR); // top of book -> clears
        auction.submitBid(id, FLOOR, 1e18, who, FLOOR); // bottom -> never reached
        vm.stopPrank();

        vm.startPrank(attacker);
        for (uint256 k = 1; k <= plantCount; ++k) {
            auction.submitBid(id, FLOOR + k * SPACING, 1e18, attacker, FLOOR + (k - 1) * SPACING);
        }
        vm.stopPrank();

        vm.roll(block.number + 50);
        while (true) {
            (, bool done,) = auction.settleProgress(id);
            if (done) break;
            auction.settle(id, 256);
        }

        uint256 g0 = gasleft();
        uint128 claimed = auction.claim(id, who, topPrice);
        claimCost = g0 - gasleft();
        assertGt(claimed, 0, "the top position really did fill");

        g0 = gasleft();
        vm.prank(who);
        uint256 got = auction.withdrawBid(id, FLOOR);
        withdrawCost = g0 - gasleft();
        assertEq(got, 1e18, "the floor position was never touched");

        g0 = gasleft();
        auction.openRound(id, uint64(block.number + 50));
        reopenCost = g0 - gasleft();
    }

    /// The remaining list walk is only reachable from submitBid, where the caller chooses the hint
    /// and pays for it. A good hint is O(1) no matter how deep the book is.
    function test_insertWalkIsPaidByTheBidderWhoChoseTheHint() public {
        uint256 id = _market(1e18);
        vm.startPrank(attacker);
        for (uint256 k = 1; k <= 400; ++k) {
            auction.submitBid(id, FLOOR + k * SPACING, 1e18, attacker, FLOOR + (k - 1) * SPACING);
        }
        vm.stopPrank();

        // Good hint: the tick immediately below.
        vm.startPrank(victim);
        uint256 g0 = gasleft();
        auction.submitBid(id, FLOOR + 401 * SPACING, 1e18, victim, FLOOR + 400 * SPACING);
        uint256 goodHint = g0 - gasleft();

        // Worst legal hint: walk the whole book from the floor.
        g0 = gasleft();
        auction.submitBid(id, FLOOR + 402 * SPACING, 1e18, victim, FLOOR);
        uint256 badHint = g0 - gasleft();
        vm.stopPrank();

        emit log_named_uint("bid with good hint", goodHint);
        emit log_named_uint("bid with floor hint (400-tick walk)", badHint);
        assertLt(goodHint, 300_000, "a good hint is O(1)");
        assertGt(badHint, goodHint, "the walk is real, and the bidder pays for it");
    }
}
