// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {TestERC20} from "./TestERC20.sol";

/// Checks for `src/GenerousAuction.sol`.
///
/// The anchor is the worked example in appendix A.9 of `generous-auction.md`: four ticks, `q = 0.5`,
/// a draw of 150 tokens, and the published answer 20 / 96 / 10 / 24. The prices below sit on this
/// contract's arithmetic grid rather than the paper's geometric ladder, which changes nothing that
/// matters — the allocation depends only on each tick's weight and its capacity in tokens, and both
/// are reproduced exactly.
contract GenerousAuctionTest is Test {
    GenerousAuction internal auction;
    TestERC20 internal token;
    TestERC20 internal cur;

    address internal seller = address(0xF1);

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2; // q = 0.5
    uint256 internal constant WINDOW = 8; // 0.5^8 = 0.4%, inside MAX_EDGE_WEIGHT
    uint64 internal constant K = 100; // blocks per emission round

    // The A.9 book. One grid step apart, so distances below the top are 0/1/2/3 and the weights are
    // 1 / 0.5 / 0.25 / 0.125.
    uint256 internal constant P3 = FLOOR + 3 * SPACING; // top of book, paper's tick 3
    uint256 internal constant P2 = FLOOR + 2 * SPACING;
    uint256 internal constant P1 = FLOOR + 1 * SPACING;
    uint256 internal constant P0 = FLOOR;

    address internal b3 = address(0xB3);
    address internal b2 = address(0xB2);
    address internal b1 = address(0xB1);
    address internal b0 = address(0xB0);

    function setUp() public {
        token = new TestERC20("Token", "TKN");
        cur = new TestERC20("Currency", "CUR");
        auction = new GenerousAuction(_config(0));
    }

    /// One round releases the paper's 150-token draw, so a single elapsed round reproduces A.9.
    function _config(uint64 end) internal view returns (IGenerousAuction.Config memory) {
        return IGenerousAuction.Config({
            token: address(token),
            currency: address(cur),
            fundsRecipient: seller,
            tokensRecipient: seller,
            admin: seller,
            floorPrice: FLOOR,
            tickSpacing: SPACING,
            decayQ: HALF,
            windowTicks: WINDOW,
            startBlock: uint64(block.number),
            endBlock: end,
            roundBlocks: K,
            emissionPerRound: 150e18
        });
    }

    // ------------------------------------------------------------------ helpers

    function _fund(uint256 supply) internal {
        token.mint(address(auction), supply);
    }

    /// Bid enough currency at `price` to buy exactly `capTokens` there.
    function _bidForCapacity(address who, uint256 price, uint256 capTokens) internal {
        uint128 amount = uint128((capTokens * price) / 1e18);
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function _a9Book() internal {
        _bidForCapacity(b3, P3, 20e18);
        _bidForCapacity(b2, P2, 200e18);
        _bidForCapacity(b1, P1, 10e18);
        _bidForCapacity(b0, P0, 100e18);
    }

    /// Let one emission round elapse and distribute it.
    function _settle() internal {
        vm.roll(block.number + K);
        auction.sync(64);
    }

    function _owed(address who, uint256 price) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who, price);
    }

    // ------------------------------------------------------------------ the anchor

    /// The published A.9 answer, read straight off the preview: 20 / 96 / 10 / 24, summing to the
    /// full 150-token draw.
    /// @dev The preview is over `due()`, not the balance, so it reports what a `sync` in *this*
    ///      block would pay — which is nothing until a round has elapsed.
    function test_A9_preview() public {
        _fund(150e18);
        _a9Book();

        (,,, uint256[] memory beforeRound) = auction.previewWindow();
        assertEq(beforeRound[0], 0, "nothing emitted yet, so nothing to preview");

        vm.roll(block.number + K);
        (uint256 tau,, uint256[] memory price, uint256[] memory tokens) = auction.previewWindow();
        assertEq(tau, P3, "top of book");
        assertEq(price.length, 4, "four live ticks");

        // `_gather` walks the list downward, so index 0 is the top.
        assertEq(price[0], P3);
        assertEq(price[1], P2);
        assertEq(price[2], P1);
        assertEq(price[3], P0);

        assertEq(tokens[0], 20e18, "tick 3 (dies first, capped)");
        assertEq(tokens[1], 96e18, "tick 2 (survivor, 0.5 * C)");
        assertEq(tokens[2], 10e18, "tick 1 (dies second, capped)");
        assertEq(tokens[3], 24e18, "tick 0 (survivor, 0.125 * C)");
        assertEq(tokens[0] + tokens[1] + tokens[2] + tokens[3], 150e18, "whole draw allocated");

        // Survivors sit on the same envelope: a_2 / a_0 = q^(-2) = 4.
        assertEq(tokens[1], tokens[3] * 4, "survivors on the q-envelope");

        // The lens is the execution: syncing in this same block pays what was previewed. The only
        // gap is the per-position wei `positionOf` rounds the bidder's way, which `claim` clamps.
        auction.sync(64);
        assertEq(_owed(b3, P3), tokens[0], "preview == payout, tick 3");
        assertApproxEqAbs(_owed(b2, P2), tokens[1], 1, "preview == payout, tick 2");
        assertEq(_owed(b1, P1), tokens[2], "preview == payout, tick 1");
        assertApproxEqAbs(_owed(b0, P0), tokens[3], 1, "preview == payout, tick 0");
    }

    /// Settlement pays exactly what the preview promised, and the two dead ticks spend their whole
    /// budget while the survivors keep the unspent remainder.
    function test_A9_settlement() public {
        _fund(150e18);
        _a9Book();
        _settle();

        assertEq(_owed(b3, P3), 20e18, "tick 3 tokens");
        assertApproxEqAbs(_owed(b2, P2), 96e18, 1, "tick 2 tokens");
        assertEq(_owed(b1, P1), 10e18, "tick 1 tokens");
        assertApproxEqAbs(_owed(b0, P0), 24e18, 1, "tick 0 tokens");

        // Exhausted ticks have nothing left competing; survivors keep budget minus what they spent.
        (uint256 live3,) = auction.positionOf(b3, P3);
        (uint256 live1,) = auction.positionOf(b1, P1);
        assertEq(live3, 0, "tick 3 exhausted");
        assertEq(live1, 0, "tick 1 exhausted");

        (uint256 live2,) = auction.positionOf(b2, P2);
        assertApproxEqAbs(live2, 204e18 - 96e18 * P2 / 1e18, 1, "tick 2 leftover escrow");

        // 20*1.03 + 96*1.02 + 10*1.01 + 24*1.00 = 152.62
        assertApproxEqAbs(auction.currencyRaised(), 15262e16, 4, "raised, pay-as-bid");
        assertEq(auction.remaining(), 0, "supply fully drawn");
        assertEq(auction.settleCursor(), 0, "swept in one call");
    }

    function test_claim_paysOwner() public {
        _fund(150e18);
        _a9Book();
        _settle();

        uint256 owed = _owed(b2, P2);
        uint256 got = auction.claim(b2, P2); // permissionless; pays the owner
        assertEq(got, owed, "claim pays what the view promised");
        assertEq(token.balanceOf(b2), owed, "tokens delivered to owner");
        assertEq(_owed(b2, P2), 0, "nothing owed twice");
    }

    // ------------------------------------------------------------------ rounds

    /// Escrow that does not fill is not migrated, re-keyed, or rewritten — it is simply still there
    /// next round, and the accrual from both rounds resolves in one read.
    function test_unfilledEscrowCompetesNextRound() public {
        _fund(20e18);
        _bidForCapacity(b3, P3, 20e18); // wants 20, top of book
        _bidForCapacity(b0, P0, 100e18); // wants 100, three steps down
        _settle();

        (uint256 liveAfter1, uint256 owedAfter1) = auction.positionOf(b0, P0);
        assertGt(liveAfter1, 0, "low tick only partly filled");
        assertGt(owedAfter1, 0, "but it did get a share, unlike a high->low fill");

        // Round two: nobody bids again, the standing escrow just keeps competing.
        _fund(50e18);
        _settle();

        (uint256 liveAfter2, uint256 owedAfter2) = auction.positionOf(b0, P0);
        assertLt(liveAfter2, liveAfter1, "escrow kept being consumed");
        assertGt(owedAfter2, owedAfter1, "accrual accumulates across rounds");

        // One division covers both rounds — the claim never walks history.
        assertEq(auction.claim(b0, P0), owedAfter2, "single O(1) claim across rounds");
    }

    function test_withdrawReturnsLiveEscrow() public {
        _fund(20e18);
        _bidForCapacity(b3, P3, 20e18);
        _bidForCapacity(b0, P0, 100e18);
        _settle();

        (uint256 live,) = auction.positionOf(b0, P0);
        vm.prank(b0);
        uint256 out = auction.withdrawBid(P0);
        assertEq(out, live, "withdraw returns exactly the live escrow");
        assertEq(cur.balanceOf(b0), out, "currency returned");
        assertGt(_owed(b0, P0), 0, "tokens already won stay claimable");
    }

    // ------------------------------------------------------------------ accounting

    /// `remaining()` is derived, so an unclaimed win can never be resold or swept out from under
    /// its winner.
    function test_unclaimedTokensAreNotSellable() public {
        _fund(150e18);
        _a9Book();
        _settle();

        assertEq(auction.remaining(), 0, "everything sold");
        // The pot holds the full draw. Per-position flooring loses a wei or two on the way out to
        // `tokensOwed`, which is why `claim` clamps rather than the pot being short.
        assertEq(auction.tokensUnclaimed(), 150e18, "held for winners");

        vm.expectRevert(IGenerousAuction.InvalidAmount.selector);
        auction.sweepUnsoldTokens(1);

        // A fresh round sees only genuinely new supply.
        _fund(10e18);
        assertEq(auction.remaining(), 10e18, "new supply only");
    }

    function test_sweepCurrencyPaysRecipient() public {
        _fund(150e18);
        _a9Book();
        _settle();

        uint256 raised = auction.currencyRaised();
        auction.sweepCurrency();
        assertEq(cur.balanceOf(seller), raised, "proceeds to fundsRecipient");
        assertEq(auction.currencyRaised(), 0);
    }

    // ------------------------------------------------------------------ emission schedule

    /// Emission is a schedule, not a transaction: nothing accrues before `startBlock`, one round's
    /// worth accrues per `K` blocks, and a trailing partial round never emits.
    function test_emissionAccruesPerRound() public {
        _fund(600e18);
        assertEq(auction.emittedToDate(), 0, "nothing at the start block");

        vm.roll(block.number + K - 1);
        assertEq(auction.emittedToDate(), 0, "partial round emits nothing");

        vm.roll(block.number + 1);
        assertEq(auction.emittedToDate(), 150e18, "one round");
        assertEq(auction.roundsElapsed(), 1);

        vm.roll(block.number + 3 * K + K / 2);
        assertEq(auction.emittedToDate(), 600e18, "four rounds, the half does not count");
        assertEq(auction.roundsElapsed(), 4);
    }

    /// A thousand silent rounds cost one sweep, and land where a thousand sweeps would: `_pour` is
    /// parameterised by the scalar `C` and relative weights do not depend on the anchor.
    function test_lazySyncEqualsRoundByRound() public {
        _fund(150e18);
        _a9Book();
        _settle();
        (uint256 lazyLive, uint256 lazyOwed) = auction.positionOf(b2, P2);
        uint256 lazyRaised = auction.currencyRaised();

        // Same book, same total supply, but drip-fed a third of a round at a time.
        setUp();
        _fund(150e18);
        _a9Book();
        vm.roll(block.number + K);
        auction.sync(64);
        auction.sync(64);
        auction.sync(64);
        (uint256 stepLive, uint256 stepOwed) = auction.positionOf(b2, P2);

        assertEq(stepLive, lazyLive, "escrow left, bit for bit");
        assertEq(stepOwed, lazyOwed, "tokens won, bit for bit");
        assertEq(auction.currencyRaised(), lazyRaised, "raised, bit for bit");
    }

    /// Carry: a round the book cannot absorb is owed, not burned.
    function test_unabsorbedEmissionCarries() public {
        _fund(600e18);

        // Two rounds elapse over an empty book. Nothing is sold, but the debt stands.
        vm.roll(block.number + 2 * K);
        auction.sync(64);
        assertEq(auction.tokensSold(), 0, "empty book absorbs nothing");
        assertEq(auction.emittedToDate(), 300e18, "but the schedule ran anyway");
        assertEq(auction.due(), 300e18, "carried, not burned");

        // The book shows up and takes the backlog plus its own round.
        _a9Book();
        vm.roll(block.number + K);
        auction.sync(64);
        assertEq(auction.tokensSold(), 330e18, "whole demand met from 450 emitted");
        assertEq(auction.due(), 120e18, "the rest is still carried");
    }

    /// `due()` is out of reach of the sweep, carry included — only future rounds can be pulled back.
    function test_sweepCannotTakeCarry() public {
        _fund(600e18);
        vm.roll(block.number + 2 * K);

        assertEq(auction.due(), 300e18, "two rounds owed to the book");
        vm.expectRevert(IGenerousAuction.InvalidAmount.selector);
        auction.sweepUnsoldTokens(300e18 + 1);

        auction.sweepUnsoldTokens(300e18); // exactly the unreleased half
        assertEq(token.balanceOf(seller), 300e18);
    }

    /// A rescheduled rate takes effect at the next boundary and never rewrites the past — even if
    /// nobody synced the rounds that elapsed under the old rate.
    function test_setRoundParamsIsNotRetroactive() public {
        _fund(1000e18);
        vm.roll(block.number + 2 * K + 10); // two rounds at 150, ten blocks into the third

        vm.prank(seller);
        auction.setRoundParams(K, 10e18);
        assertEq(auction.emittedToDate(), 300e18, "the two elapsed rounds keep the old rate");

        // The round in flight still finishes at 150.
        vm.roll(block.number + K - 10);
        assertEq(auction.emittedToDate(), 450e18, "round three at the rate it started under");

        vm.roll(block.number + K);
        assertEq(auction.emittedToDate(), 460e18, "round four at the new rate");
    }

    /// A second reschedule before the boundary replaces the first.
    function test_pendingParamsAreReplaced() public {
        vm.prank(seller);
        auction.setRoundParams(K, 10e18);
        vm.prank(seller);
        auction.setRoundParams(K, 20e18);

        vm.roll(block.number + 2 * K);
        assertEq(auction.emittedToDate(), 150e18 + 20e18, "first round old rate, second the last queued");
    }

    function test_setRoundParamsIsAdminOnly() public {
        vm.expectRevert(IGenerousAuction.Unauthorized.selector);
        auction.setRoundParams(K, 1e18);
    }

    function test_biddingClosesAtEndBlock() public {
        uint64 end = uint64(block.number) + 2 * K;
        auction = new GenerousAuction(_config(end));
        _fund(600e18);

        vm.roll(end);
        cur.mint(b3, 1e18);
        vm.startPrank(b3);
        cur.approve(address(auction), 1e18);
        vm.expectRevert(IGenerousAuction.AuctionEnded.selector);
        auction.submitBid(P3, 1e18, b3, FLOOR);
        vm.stopPrank();

        // The schedule froze at `endBlock`; later blocks add nothing.
        vm.roll(end + 10 * K);
        assertEq(auction.emittedToDate(), 300e18, "two rounds, then frozen");
    }

    /// Deployment pattern: ship with `emissionPerRound = 0` so nothing accrues while the sale is
    /// unfunded, then "start" it with `setRoundParams`. No carry can build up in the gap.
    function test_zeroEmissionThenStart() public {
        IGenerousAuction.Config memory c = _config(0);
        c.emissionPerRound = 0;
        auction = new GenerousAuction(c);

        _a9Book();

        // Ten rounds pass with the sale unfunded and the rate at zero.
        vm.roll(block.number + 10 * K);
        assertEq(auction.emittedToDate(), 0, "zero rate emits nothing");
        assertEq(auction.due(), 0, "so no carry accumulates");

        // Fund, then flip the switch.
        _fund(150e18);
        assertEq(auction.due(), 0, "funding alone releases nothing");

        vm.prank(seller);
        auction.setRoundParams(K, 150e18);
        assertEq(auction.emittedToDate(), 0, "not retroactive: the ten idle rounds stay at zero");

        // First full round under the new rate pays exactly one round, not a backlog.
        vm.roll(block.number + 2 * K);
        assertEq(auction.emittedToDate(), 150e18, "one round at the new rate");
        assertEq(auction.due(), 150e18, "and that is all that is owed");

        auction.sync(64);
        assertEq(_owed(b3, P3), 20e18, "A.9 allocation, unchanged by the deferred start");
    }
}
