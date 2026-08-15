// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MonoAuction} from "../src/MonoAuction.sol";
import {IMonoAuction} from "../src/interfaces/IMonoAuction.sol";
import {TestERC20} from "./TestERC20.sol";

contract MonoAuctionTest is Test {
    MonoAuction internal auction;
    TestERC20 internal token;
    TestERC20 internal idx;

    address internal seller = address(0xF1);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    address internal carol = address(0xC3);

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e17;

    /// q = 1 in Q96 is the q -> 0 limit: ticks below the top weigh 2^-96, which floors to zero
    /// tokens at any realistic supply, so settle degenerates to the strict high -> low fill.
    uint256 internal constant STRICT_Q = 1;
    uint256 internal constant WINDOW = 16;

    function setUp() public {
        token = new TestERC20("Token", "TKN");
        idx = new TestERC20("Index", "INDEX");
        auction = new MonoAuction(address(0), address(0), address(idx), SPACING, STRICT_Q, WINDOW);
    }

    // ------------------------------------------------------------------ helpers

    function _market(uint128 supply, uint64 idle) internal returns (uint256 id) {
        id = auction.createMarket(address(token), seller, seller, FLOOR, idle);
        if (supply > 0) {
            token.mint(address(auction), supply);
            auction.fund(id, supply);
        }
    }

    function _open(uint256 id, uint64 span) internal {
        auction.openRound(id, uint64(block.number + span));
    }

    function _bid(uint256 id, address who, uint256 price, uint128 amount, uint256 hint) internal {
        idx.mint(who, amount);
        vm.startPrank(who);
        idx.approve(address(auction), amount);
        auction.submitBid(id, price, amount, who, hint);
        vm.stopPrank();
    }

    function _endAndSettle(uint256 id) internal {
        (,,,,,,,,, uint64 endBlock,) = auction.markets(id);
        if (block.number < endBlock) vm.roll(endBlock);
        auction.settle(id, type(uint256).max);
    }

    /// Settle in fixed-size chunks until the round is done, without over-calling.
    function _settleChunked(uint256 id, uint256 chunk) internal {
        while (true) {
            (, bool done,) = auction.settleProgress(id);
            if (done) break;
            auction.settle(id, chunk);
        }
    }

    function _remaining(uint256 id) internal view returns (uint128 r) {
        (,,, r,,,,,,,) = auction.markets(id);
    }

    function _raised(uint256 id) internal view returns (uint256 c) {
        (,,,,, c,,,,,) = auction.markets(id);
    }

    function _round(uint256 id) internal view returns (uint64 r) {
        (,,,,,,, r,,,) = auction.markets(id);
    }

    // ------------------------------------------------------------------ core fill

    /// Highest price is served first and completely; lower ticks get what is left.
    function test_fillsHighToLow() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);
        _bid(id, alice, 3e18, 90e18, FLOOR);
        _bid(id, bob, 2e18, 100e18, FLOOR);
        _bid(id, carol, 2e18, 60e18, FLOOR);

        _endAndSettle(id);

        // Alice's tick clears whole: 90 / 3.0 = 30 tokens, 70 left.
        // Tick 2.0 wants 160 / 2.0 = 80 tokens but only 70 remain -> marginal, 140 of 160 spent.
        assertEq(_raised(id), 230e18, "90 + 140");
        assertEq(_remaining(id), 0, "supply exhausted");

        auction.claim(id, alice, 3e18);
        auction.claim(id, bob, 2e18);
        auction.claim(id, carol, 2e18);

        assertEq(token.balanceOf(alice), 30e18, "full fill at the top tick");
        assertEq(token.balanceOf(bob), 43.75e18, "87.5% of 50");
        assertEq(token.balanceOf(carol), 26.25e18, "87.5% of 30");
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), 100e18);
    }

    /// Two bidders at one price are cut by the same factor, regardless of order or size.
    function test_sameTickProRata() public {
        uint256 id = _market(50e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 100e18, FLOOR);
        _bid(id, bob, 2e18, 100e18, FLOOR);

        _endAndSettle(id);
        auction.claim(id, alice, 2e18);
        auction.claim(id, bob, 2e18);

        assertEq(token.balanceOf(alice), 25e18);
        assertEq(token.balanceOf(bob), 25e18);
        // Half the escrow was spent; the other half is still live and competing.
        (uint256 aliceLive,) = auction.positionOf(id, alice, 2e18);
        assertEq(aliceLive, 50e18, "unspent escrow stays in the book");
    }

    /// Pay-as-bid: two bidders in one round pay different prices for the same token.
    function test_payAsBidNotUniform() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);
        _bid(id, alice, 4e18, 40e18, FLOOR); // 10 tokens at 4.0
        _bid(id, bob, 2e18, 100e18, FLOOR); // 50 tokens at 2.0

        _endAndSettle(id);
        auction.claim(id, alice, 4e18);
        auction.claim(id, bob, 2e18);

        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(_raised(id), 140e18, "40 at 4.0 plus 100 at 2.0, not a single clearing price");
    }

    // ------------------------------------------------------------------ continuity

    /// THE point of the design: an unfilled bid survives the round boundary with no migration,
    /// no new record, and no copying — and fills in the next round.
    function test_unfilledBidSurvivesRoundWithNoMigration() public {
        uint256 id = _market(10e18, 0);
        _open(id, 100);
        _bid(id, alice, 5e18, 50e18, FLOOR); // takes all 10 tokens
        _bid(id, bob, 2e18, 100e18, FLOOR); // below the clear, gets nothing

        _endAndSettle(id);
        assertEq(_remaining(id), 0);

        // Bob's escrow is untouched and still sitting at his own tick.
        (uint256 bobLive, uint256 bobTokens) = auction.positionOf(id, bob, 2e18);
        assertEq(bobLive, 100e18, "escrow intact");
        assertEq(bobTokens, 0, "nothing won");
        (,, uint256 demand,,,) = auction.ticks(id, 2e18);
        assertEq(demand, 100e18, "tick demand intact");

        // Round 2: fund more supply and reopen. No bid is re-submitted.
        token.mint(address(auction), 40e18);
        auction.fund(id, 40e18);
        _open(id, 100);
        assertEq(_round(id), 2);

        _endAndSettle(id);

        // Bob's standing offer filled this round without him touching it.
        auction.claim(id, bob, 2e18);
        assertEq(token.balanceOf(bob), 40e18, "100 INDEX at 2.0 would be 50; only 40 supply existed");
        // 1 wei under 20e18: live escrow rounds DOWN by design (see _harvest).
        (uint256 bobLiveAfter,) = auction.positionOf(id, bob, 2e18);
        assertApproxEqAbs(bobLiveAfter, 20e18, 1, "80 of 100 spent, 20 still competing");
    }

    /// A position partially filled in several consecutive rounds depletes multiplicatively.
    function test_proportionalDepletionAcrossRounds() public {
        uint256 id = _market(25e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 100e18, FLOOR);

        // Round 1: 25 tokens = 50 INDEX of the 100 -> half spent.
        _endAndSettle(id);
        (uint256 live,) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 50e18, "half consumed");

        // Round 2: 12.5 tokens = 25 INDEX of the remaining 50 -> half again.
        token.mint(address(auction), 12.5e18);
        auction.fund(id, 12.5e18);
        _open(id, 100);
        _endAndSettle(id);
        (live,) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 25e18, "multiplicative, not additive");

        auction.claim(id, alice, 2e18);
        assertEq(token.balanceOf(alice), 37.5e18, "25 + 12.5 across two rounds");
    }

    /// A tick that clears 100% bumps its epoch; a stale position reads as fully consumed.
    function test_fullFillBumpsEpoch() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 50e18, FLOOR);

        (,,,, uint64 epochBefore,) = auction.ticks(id, 2e18);
        _endAndSettle(id);
        (,, uint256 demand, uint256 survival, uint64 epochAfter,) = auction.ticks(id, 2e18);

        assertEq(epochAfter, epochBefore + 1, "epoch bumped on a whole clear");
        assertEq(demand, 0, "nothing live left");
        assertEq(survival, 1 << 128, "index reset, not zeroed");

        (uint256 live, uint256 owed) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 0);
        assertEq(owed, 25e18, "50 INDEX at 2.0");
        auction.claim(id, alice, 2e18);
        assertEq(token.balanceOf(alice), 25e18);
    }

    /// Bidding again at the same price harvests first, then grows one record.
    function test_topUpHarvestsBeforeResizing() public {
        uint256 id = _market(25e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 100e18, FLOOR);
        _endAndSettle(id);

        // 50 spent, 50 live, 25 tokens owed but unclaimed.
        (uint256 live, uint256 owed) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 50e18);
        assertEq(owed, 25e18);

        token.mint(address(auction), 100e18);
        auction.fund(id, 100e18);
        _open(id, 100);
        _bid(id, alice, 2e18, 50e18, FLOOR); // top up to 100 live

        (live, owed) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 100e18, "50 live + 50 new");
        assertEq(owed, 25e18, "earlier winnings preserved, not recomputed");

        _endAndSettle(id);
        auction.claim(id, alice, 2e18);
        assertEq(token.balanceOf(alice), 75e18, "25 from round 1 + 50 from round 2");
    }

    // ------------------------------------------------------------------ withdraw & claim

    function test_withdrawReturnsLiveEscrowOnly() public {
        uint256 id = _market(25e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 100e18, FLOOR);
        _endAndSettle(id);

        vm.prank(alice);
        uint256 got = auction.withdrawBid(id, 2e18);
        assertEq(got, 50e18, "only the unspent half comes back");
        assertEq(idx.balanceOf(alice), 50e18);

        (,, uint256 demand,,,) = auction.ticks(id, 2e18);
        assertEq(demand, 0, "tick demand released");

        // Tokens won before withdrawing are still claimable.
        auction.claim(id, alice, 2e18);
        assertEq(token.balanceOf(alice), 25e18);

        vm.prank(alice);
        vm.expectRevert(IMonoAuction.NoPosition.selector);
        auction.withdrawBid(id, 2e18);
    }

    function test_withdrawBlockedMidSettleOnly() public {
        // 20 supply: tick 3.0 clears (10 tokens), tick 2.0 is marginal and keeps escrow live.
        uint256 id = _market(20e18, 0);
        _open(id, 100);
        _bid(id, alice, 3e18, 30e18, FLOOR);
        _bid(id, bob, 2e18, 30e18, FLOOR);

        // Mid-settle: one tick processed, book still being consumed.
        vm.roll(block.number + 100);
        auction.settle(id, 1);
        (bool started, bool done,) = auction.settleProgress(id);
        assertTrue(started && !done, "settle in progress");

        vm.prank(bob);
        vm.expectRevert(IMonoAuction.AlreadySettled.selector);
        auction.withdrawBid(id, 2e18);

        // Once complete, withdrawal is open again.
        auction.settle(id, type(uint256).max);
        vm.prank(bob);
        assertApproxEqAbs(auction.withdrawBid(id, 2e18), 10e18, 1, "marginal tick left escrow live");
    }

    /// Claim does not close a position; the live remainder keeps competing.
    function test_claimDoesNotClosePosition() public {
        uint256 id = _market(25e18, 0);
        _open(id, 100);
        _bid(id, alice, 2e18, 100e18, FLOOR);
        _endAndSettle(id);

        auction.claim(id, alice, 2e18);
        assertEq(token.balanceOf(alice), 25e18);
        (uint256 live, uint256 owed) = auction.positionOf(id, alice, 2e18);
        assertEq(live, 50e18, "still in the book");
        assertEq(owed, 0, "harvested");

        // Claiming twice pays nothing extra.
        assertEq(auction.claim(id, alice, 2e18), 0);
        assertEq(token.balanceOf(alice), 25e18);
    }

    /// Live escrow rounds DOWN, so the sum of positions can never exceed the tick's demand.
    /// The shortfall is unrecoverable dust, never a claim on someone else's escrow.
    function test_roundingFavoursThePot() public {
        uint256 id = _market(10e18, 0);
        _open(id, 100);
        // Three co-bidders at one tick, marginal fill, denominator that does not divide evenly.
        _bid(id, alice, 3e18, 30e18, FLOOR);
        _bid(id, bob, 3e18, 30e18, FLOOR);
        _bid(id, carol, 3e18, 30e18, FLOOR);

        _endAndSettle(id);

        (,, uint256 demand,,,) = auction.ticks(id, 3e18);
        (uint256 a,) = auction.positionOf(id, alice, 3e18);
        (uint256 b,) = auction.positionOf(id, bob, 3e18);
        (uint256 c,) = auction.positionOf(id, carol, 3e18);
        assertLe(a + b + c, demand, "positions never over-claim the tick");
        assertApproxEqAbs(a + b + c, demand, 3, "at most 1 wei lost per position");

        // And the contract stays solvent in the currency after everyone exits.
        vm.prank(alice);
        auction.withdrawBid(id, 3e18);
        vm.prank(bob);
        auction.withdrawBid(id, 3e18);
        vm.prank(carol);
        auction.withdrawBid(id, 3e18);
        assertLe(auction.reserved(address(idx)), idx.balanceOf(address(auction)), "index solvent");
    }

    // ------------------------------------------------------------------ safety

    /// One market may never spend another's escrow.
    function test_marketsAreIsolated() public {
        uint256 victim = _market(100e18, 0);
        uint256 attackerMarket = _market(0, 0);

        _open(victim, 100);
        _bid(victim, alice, 2e18, 100e18, FLOOR);

        // The attacker's market has no supply of its own, and cannot borrow the victim's.
        vm.expectRevert(IMonoAuction.InvalidAmount.selector);
        auction.fund(attackerMarket, 100e18);

        assertEq(auction.reserved(address(token)), 100e18, "only the victim's supply is reserved");
        assertLe(auction.reserved(address(token)), token.balanceOf(address(auction)), "token solvent");
        assertLe(auction.reserved(address(idx)), idx.balanceOf(address(auction)), "index solvent");
    }

    /// The token invariant: reserved == remaining + tokensUnclaimed, at every stage.
    function test_tokenInvariantHolds() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);
        _bid(id, alice, 3e18, 90e18, FLOOR);
        _bid(id, bob, 2e18, 100e18, FLOOR);
        _assertTokenInvariant(id);

        _endAndSettle(id);
        _assertTokenInvariant(id);

        auction.claim(id, alice, 3e18);
        _assertTokenInvariant(id);
        auction.claim(id, bob, 2e18);
        _assertTokenInvariant(id);

        auction.sweepCurrency(id);
        assertEq(idx.balanceOf(seller), 190e18);
        assertLe(auction.reserved(address(idx)), idx.balanceOf(address(auction)), "index solvent");
    }

    function _assertTokenInvariant(uint256 id) internal view {
        (,,, uint128 remaining, uint128 unclaimed,,,,,,) = auction.markets(id);
        assertEq(auction.reserved(address(token)), uint256(remaining) + unclaimed, "token invariant");
    }

    /// Escrow left in the book after a round is still withdrawable — never trapped.
    function test_escrowNeverTrappedBetweenRounds() public {
        uint256 id = _market(10e18, 5);
        _open(id, 1000);
        _bid(id, alice, 5e18, 50e18, FLOOR);
        _bid(id, bob, 2e18, 100e18, FLOOR);

        // Idle timeout lets anyone settle early.
        vm.roll(block.number + 6);
        assertTrue(auction.idleTimedOut(id));
        auction.settle(id, type(uint256).max);

        vm.prank(bob);
        assertEq(auction.withdrawBid(id, 2e18), 100e18, "unfilled escrow is not stuck");
    }

    // ------------------------------------------------------------------ book mechanics

    function test_bidValidation() public {
        uint256 id = _market(100e18, 0);

        idx.mint(alice, 1000e18);
        vm.startPrank(alice);
        idx.approve(address(auction), type(uint256).max);

        // No round open yet.
        vm.expectRevert(IMonoAuction.NoOpenRound.selector);
        auction.submitBid(id, 2e18, 10e18, alice, FLOOR);
        vm.stopPrank();

        _open(id, 100);

        vm.startPrank(alice);
        vm.expectRevert(IMonoAuction.BidTooLow.selector);
        auction.submitBid(id, FLOOR - SPACING, 10e18, alice, FLOOR);

        vm.expectRevert(IMonoAuction.BidTooHigh.selector);
        auction.submitBid(id, FLOOR * 1e4 + SPACING, 10e18, alice, FLOOR);

        vm.expectRevert(IMonoAuction.TickNotAligned.selector);
        auction.submitBid(id, 2e18 + 1, 10e18, alice, FLOOR);

        // 1 wei of escrow cannot buy 1 wei of token at this price.
        vm.expectRevert(IMonoAuction.BidTooSmall.selector);
        auction.submitBid(id, 2e18, 1, alice, FLOOR);

        // Hint must be an initialized tick strictly below the price.
        vm.expectRevert(IMonoAuction.BadPrevHint.selector);
        auction.submitBid(id, 2e18, 10e18, alice, 9e18);
        vm.stopPrank();
    }

    /// A round cannot be reopened while the previous one is unsettled.
    function test_roundLifecycle() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);

        vm.expectRevert(IMonoAuction.RoundStillOpen.selector);
        _open(id, 100);

        // Settle is gated on the end block when idle is disabled.
        vm.expectRevert(IMonoAuction.RoundNotOver.selector);
        auction.settle(id, 1);

        _endAndSettle(id);
        vm.expectRevert(IMonoAuction.AlreadySettled.selector);
        auction.settle(id, 1);

        // Bidding is shut between rounds.
        idx.mint(alice, 10e18);
        vm.startPrank(alice);
        idx.approve(address(auction), 10e18);
        vm.expectRevert(IMonoAuction.RoundOver.selector);
        auction.submitBid(id, 2e18, 10e18, alice, FLOOR);
        vm.stopPrank();

        _open(id, 100);
        assertEq(_round(id), 2);
    }

    /// Settle chunks and resumes from the cursor without double-spending a tick.
    function test_chunkedSettleMatchesSingleShot() public {
        uint256 idA = _market(100e18, 0);
        _open(idA, 100);
        for (uint256 k = 1; k <= 8; ++k) {
            _bid(idA, address(uint160(0x100 + k)), FLOOR + k * SPACING, 30e18, FLOOR + (k - 1) * SPACING);
        }
        vm.roll(block.number + 100);
        auction.settle(idA, type(uint256).max);

        uint256 idB = _market(100e18, 0);
        _open(idB, 100);
        for (uint256 k = 1; k <= 8; ++k) {
            _bid(idB, address(uint160(0x200 + k)), FLOOR + k * SPACING, 30e18, FLOOR + (k - 1) * SPACING);
        }
        vm.roll(block.number + 100);
        _settleChunked(idB, 3);

        assertEq(_raised(idA), _raised(idB), "chunking changes nothing");
        assertEq(_remaining(idA), _remaining(idB));
    }

    /// Unsold supply can be pulled back between rounds, never during one.
    function test_sweepUnsoldOnlyBetweenRounds() public {
        uint256 id = _market(100e18, 0);
        _open(id, 100);

        vm.expectRevert(IMonoAuction.RoundStillOpen.selector);
        auction.sweepUnsoldTokens(id, 1e18);

        _endAndSettle(id);
        auction.sweepUnsoldTokens(id, 40e18);
        assertEq(token.balanceOf(seller), 40e18);
        assertEq(_remaining(id), 60e18);
        _assertTokenInvariant(id);

        vm.expectRevert(IMonoAuction.InvalidAmount.selector);
        auction.sweepUnsoldTokens(id, 61e18);
    }

    function test_tickSpacingFloor() public {
        vm.expectRevert(IMonoAuction.TickSpacingTooSmall.selector);
        new MonoAuction(address(0), address(0), address(idx), 1, STRICT_Q, WINDOW);
        vm.expectRevert(IMonoAuction.InvalidParams.selector);
        new MonoAuction(address(0), address(0), address(0), SPACING, STRICT_Q, WINDOW);
    }

    function test_currencyIsAlwaysIndex() public {
        assertEq(auction.index(), address(idx));
        uint256 id = _market(100e18, 0);
        (, address currency,,,,,,,,,) = auction.markets(id);
        assertEq(currency, address(idx));

        // INDEX cannot also be the token being sold.
        vm.expectRevert(IMonoAuction.InvalidParams.selector);
        auction.createMarket(address(idx), seller, seller, FLOOR, 0);
    }
}
