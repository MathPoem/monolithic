// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MonoAuction} from "../src/MonoAuction.sol";
import {IMonoAuction} from "../src/interfaces/IMonoAuction.sol";
import {TestERC20} from "./TestERC20.sol";

/// Distribution tests for the geometric rule in `generous-auction.pdf`.
///
/// The anchor is the worked example in appendix A.9 / §5 of that document: four ticks, `q = 0.5`,
/// a draw of 150 tokens, and the published answer 20 / 96 / 10 / 24. The prices below sit on this
/// contract's arithmetic grid rather than the paper's geometric ladder, which changes nothing that
/// matters — the allocation depends only on each tick's weight and its capacity in tokens, and both
/// are reproduced exactly.
contract MonoAuctionGeometricTest is Test {
    MonoAuction internal auction;
    TestERC20 internal token;
    TestERC20 internal idx;

    address internal seller = address(0xF1);

    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2; // q = 0.5
    uint256 internal constant WINDOW = 8; // 0.5^8 = 0.4% edge weight, inside MAX_EDGE_WEIGHT

    // The A.9 book. Prices one grid step apart, so distances below the top are 0/1/2/3 and the
    // weights are 1 / 0.5 / 0.25 / 0.125 exactly as in the paper.
    uint256 internal constant P3 = FLOOR + 3 * SPACING; // top of book
    uint256 internal constant P2 = FLOOR + 2 * SPACING;
    uint256 internal constant P1 = FLOOR + 1 * SPACING;
    uint256 internal constant P0 = FLOOR;

    function setUp() public {
        token = new TestERC20("Token", "TKN");
        idx = new TestERC20("Index", "INDEX");
        auction = new MonoAuction(address(0), address(0), address(idx), SPACING, HALF, WINDOW);
    }

    // ------------------------------------------------------------------ helpers

    function _market(uint128 supply) internal returns (uint256 id) {
        id = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        token.mint(address(auction), supply);
        auction.fund(id, supply);
    }

    /// Bid enough currency at `price` to buy exactly `capTokens` there.
    function _bidForCapacity(uint256 id, address who, uint256 price, uint256 capTokens) internal {
        uint128 amount = uint128((capTokens * price) / 1e18);
        idx.mint(who, amount);
        vm.startPrank(who);
        idx.approve(address(auction), amount);
        auction.submitBid(id, price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function _settle(uint256 id) internal {
        (,,,,,,,,, uint64 endBlock,) = auction.markets(id);
        if (block.number < endBlock) vm.roll(endBlock);
        auction.settle(id, type(uint256).max);
    }

    function _remaining(uint256 id) internal view returns (uint128 r) {
        (,,, r,,,,,,,) = auction.markets(id);
    }

    function _unclaimed(uint256 id) internal view returns (uint128 u) {
        (,,,, u,,,,,,) = auction.markets(id);
    }

    function _live(uint256 id, address who, uint256 price) internal view returns (uint256 l) {
        (l,) = auction.positionOf(id, who, price);
    }

    /// Build the A.9 book: capacities 20 / 200 / 10 / 100 tokens at P3 / P2 / P1 / P0.
    function _a9Book(uint128 supply) internal returns (uint256 id) {
        id = _market(supply);
        auction.openRound(id, uint64(block.number + 100));
        _bidForCapacity(id, address(0xA3), P3, 20e18);
        _bidForCapacity(id, address(0xA2), P2, 200e18);
        _bidForCapacity(id, address(0xA1), P1, 10e18);
        _bidForCapacity(id, address(0xA0), P0, 100e18);
    }

    // ------------------------------------------------------------------ the paper's example

    /// The published answer, to the wei. Nothing is approximate here: the sweep is exact.
    function test_matchesPaperWorkedExample() public {
        uint256 id = _a9Book(150e18);
        _settle(id);

        auction.claim(id, address(0xA3), P3);
        auction.claim(id, address(0xA2), P2);
        auction.claim(id, address(0xA1), P1);
        auction.claim(id, address(0xA0), P0);

        assertEq(token.balanceOf(address(0xA3)), 20e18, "tick 3 = 20");
        assertEq(token.balanceOf(address(0xA2)), 96e18, "tick 2 = 96");
        assertEq(token.balanceOf(address(0xA1)), 10e18, "tick 1 = 10");
        assertEq(token.balanceOf(address(0xA0)), 24e18, "tick 0 = 24");
        assertEq(_remaining(id), 0, "the whole draw was distributed");
    }

    /// The structural claim that forces the sort: a rich low tick outlives a poor high tick, so
    /// exhaustion order is not price order. Here P1 runs dry while P2 AND P0 — one above it, one
    /// below — are both still standing.
    function test_exhaustionOrderIsNotPriceOrder() public {
        uint256 id = _a9Book(150e18);
        _settle(id);

        assertEq(_live(id, address(0xA3), P3), 0, "top tick exhausted");
        assertEq(_live(id, address(0xA1), P1), 0, "P1 exhausted despite being mid-book");

        assertGt(_live(id, address(0xA2), P2), 0, "P2 survives, though priced above P1");
        assertGt(_live(id, address(0xA0), P0), 0, "P0 survives, though priced below P1");
    }

    /// The waterfall: P2's opening share of the draw is w/W = 0.5/1.875 = 26.7%, i.e. 40 tokens.
    /// It receives 96 because the ticks that exhausted re-flowed their unmet share onto it.
    function test_waterfallReflowsOntoSurvivors() public {
        uint256 id = _a9Book(150e18);

        (, uint256 weightSum,,) = auction.previewWindow(id);
        assertEq(weightSum, Q96 + Q96 / 2 + Q96 / 4 + Q96 / 8, "W = 1.875");

        uint256 openingShare = (150e18 * (Q96 / 2)) / weightSum; // 40e18
        assertEq(openingShare, 40e18, "opening share is 40");

        _settle(id);
        auction.claim(id, address(0xA2), P2);
        assertEq(token.balanceOf(address(0xA2)), 96e18, "re-flow lifts 40 -> 96");
    }

    /// `previewWindow` must agree with what settling actually does, or every UI built on it lies.
    function test_previewMatchesSettlement() public {
        uint256 id = _a9Book(150e18);
        (,, uint256[] memory prices, uint256[] memory tokens) = auction.previewWindow(id);
        assertEq(prices.length, 4);

        _settle(id);
        address[4] memory who = [address(0xA3), address(0xA2), address(0xA1), address(0xA0)];
        for (uint256 i; i < 4; ++i) {
            auction.claim(id, who[i], prices[i]);
            assertEq(token.balanceOf(who[i]), tokens[i], "preview == settlement");
        }
    }

    // ------------------------------------------------------------------ structural properties

    /// Path independence: the accumulator moves piecewise, so splitting a draw into rounds cannot
    /// change the outcome. Four rounds of 70 must land exactly where one draw of 280 does.
    function test_pathIndependence() public {
        uint256 oneShot = _a9Book(280e18);
        _settle(oneShot);

        // The same book, but the supply genuinely arrives 70 at a time over four rounds — the
        // market never holds more than one round's worth, so each settle really is a 70 draw.
        uint256 staged = auction.createMarket(address(token), seller, seller, FLOOR, 0);
        auction.openRound(staged, uint64(block.number + 100));
        _bidForCapacity(staged, address(0xA3), P3, 20e18);
        _bidForCapacity(staged, address(0xA2), P2, 200e18);
        _bidForCapacity(staged, address(0xA1), P1, 10e18);
        _bidForCapacity(staged, address(0xA0), P0, 100e18);

        for (uint256 r; r < 4; ++r) {
            token.mint(address(auction), 70e18);
            auction.fund(staged, 70e18);
            (,,,,,,,,, uint64 endBlock,) = auction.markets(staged);
            if (block.number < endBlock) vm.roll(endBlock);
            auction.settle(staged, type(uint256).max);
            assertEq(_remaining(staged), 0, "each round's 70 was fully absorbed");
            auction.openRound(staged, uint64(block.number + 100));
        }

        address[4] memory who = [address(0xA3), address(0xA2), address(0xA1), address(0xA0)];
        uint256[4] memory price = [P3, P2, P1, P0];
        uint256 totalOne;
        uint256 totalMany;
        for (uint256 i; i < 4; ++i) {
            (uint256 liveOne, uint256 owedOne) = auction.positionOf(oneShot, who[i], price[i]);
            (uint256 liveMany, uint256 owedMany) = auction.positionOf(staged, who[i], price[i]);
            totalOne += owedOne;
            totalMany += owedMany;
            // Exact in real arithmetic; on integers each round boundary can floor a wei either
            // way, so four rounds admit a few wei of drift per tick. `claim` clamps against
            // `tokensUnclaimed`, so a wei of excess here is absorbed rather than paid out twice.
            assertApproxEqAbs(owedMany, owedOne, 8, "tokens are path independent up to dust");
            assertApproxEqAbs(liveMany, liveOne, 8, "escrow is path independent up to dust");
        }
        // What actually left the pot is identical on both paths — 280 tokens, to the wei.
        assertEq(_unclaimed(staged), _unclaimed(oneShot), "the same total is distributed");
        assertEq(_unclaimed(staged), 280e18, "and it is the whole supply");

        // The sum of *recorded* claims may run a wei ahead of the pot: `_harvest` floors live
        // escrow, so `spent` rounds up, in the bidder's favour. That is v1 behaviour and is why
        // `claim` clamps against `tokensUnclaimed` — assert the direction rather than hide it.
        assertGe(totalMany, totalOne, "staging can only round in the bidder's favour");
        assertApproxEqAbs(totalMany, _unclaimed(staged), 8, "claims track the pot to within dust");
    }

    /// `q = 1` is the flat limit: every tick in the window splits the draw evenly, price ignored.
    function test_flatQSplitsEvenly() public {
        auction = new MonoAuction(address(0), address(0), address(idx), SPACING, Q96, WINDOW);
        uint256 id = _market(300e18);
        auction.openRound(id, uint64(block.number + 100));
        // Generous budgets so nothing exhausts and the split is purely by weight.
        _bidForCapacity(id, address(0xB2), P2, 1_000e18);
        _bidForCapacity(id, address(0xB1), P1, 1_000e18);
        _bidForCapacity(id, address(0xB0), P0, 1_000e18);

        _settle(id);
        auction.claim(id, address(0xB2), P2);
        auction.claim(id, address(0xB1), P1);
        auction.claim(id, address(0xB0), P0);

        assertEq(token.balanceOf(address(0xB2)), 100e18, "even split, top");
        assertEq(token.balanceOf(address(0xB1)), 100e18, "even split, middle");
        assertEq(token.balanceOf(address(0xB0)), 100e18, "even split, bottom");
    }

    /// Two independent things bound participation, and they bite at very different distances.
    /// The band (`windowTicks`) is the one that matters in practice; Q96 underflow is far away.
    function test_windowBoundIsTheBandNotUnderflow() public {
        assertEq(auction.weightAt(0), Q96, "the top of book weighs 1");
        assertEq(auction.weightAt(1), Q96 / 2, "one step down halves it");
        // `rpow` rounds to nearest, so the weight clings to 1 wei well past the point where
        // rounding down would have killed it: zero arrives only at 98 steps.
        assertEq(auction.weightAt(97), 1, "still 1 wei at 97 steps");
        assertEq(auction.weightAt(98), 0, "underflow at 98");
        // The band cuts in long before that, at windowTicks = 8.
        assertGt(auction.weightAt(40), 0, "q^40 is small but nowhere near zero");
    }

    /// A tick outside the band does not dilute the window above it — it is served afterwards, from
    /// a window of its own, exactly as if the ticks above had never existed.
    function test_distantTickIsServedInItsOwnWindow() public {
        uint256 id = _market(50e18);
        auction.openRound(id, uint64(block.number + 100));
        uint256 far = FLOOR + 40 * SPACING; // 40 steps above the floor, band is 8
        _bidForCapacity(id, address(0xC1), far, 10e18);
        _bidForCapacity(id, address(0xC0), FLOOR, 10e18);

        (,, uint256[] memory prices,) = auction.previewWindow(id);
        assertEq(prices.length, 1, "only the far tick is in the first window");
        assertEq(prices[0], far, "and it is the top of book");

        _settle(id);
        auction.claim(id, address(0xC1), far);
        auction.claim(id, address(0xC0), FLOOR);

        assertEq(token.balanceOf(address(0xC1)), 10e18, "far tick takes its whole capacity first");
        assertEq(token.balanceOf(address(0xC0)), 10e18, "floor tick then fills from a fresh window");
        assertEq(_remaining(id), 30e18, "the rest is genuinely unsold");
    }

    // ------------------------------------------------------------------ invariants

    /// Conservation, the property that keeps the contract solvent: allocations are floored per
    /// tick, so their sum can never exceed the supply they were drawn from.
    function testFuzz_neverOverAllocates(uint96[4] memory caps, uint96 supply) public {
        supply = uint96(bound(supply, 1e12, 1e24));
        uint256 id = _market(supply);
        auction.openRound(id, uint64(block.number + 100));

        uint256[4] memory price = [P3, P2, P1, P0];
        for (uint256 i; i < 4; ++i) {
            uint256 c = bound(caps[i], 1e12, 1e24);
            _bidForCapacity(id, address(uint160(0xD0 + i)), price[i], c);
        }

        _settle(id);

        assertEq(uint256(_remaining(id)) + _unclaimed(id), supply, "nothing created, nothing lost");
        assertEq(auction.reserved(address(token)), uint256(_remaining(id)) + _unclaimed(id), "token invariant");
    }

    /// Chunked settlement must be indistinguishable from settling in one shot — a window is either
    /// poured whole or not at all, so a resumed walk sees exactly the book it would have seen.
    function testFuzz_chunkedEqualsOneShot(uint96 supply) public {
        supply = uint96(bound(supply, 1e15, 1e24));

        uint256 a = _a9Book(supply);
        _settle(a);

        uint256 b = _a9Book(supply);
        (,,,,,,,,, uint64 endBlock,) = auction.markets(b);
        vm.roll(endBlock);
        for (uint256 i; i < 20; ++i) {
            (, bool done,) = auction.settleProgress(b);
            if (done) break;
            auction.settle(b, 1);
        }

        uint256[4] memory price = [P3, P2, P1, P0];
        for (uint256 i; i < 4; ++i) {
            (uint256 lA, uint256 oA) = auction.positionOf(a, address(uint160(0xA0 + (3 - i))), price[i]);
            (uint256 lB, uint256 oB) = auction.positionOf(b, address(uint160(0xA0 + (3 - i))), price[i]);
            assertEq(oB, oA, "chunking does not move tokens");
            assertEq(lB, lA, "chunking does not move escrow");
        }
    }

    // ------------------------------------------------------------------ calibration guards

    function test_rejectsMiscalibratedWindow() public {
        // q = 0.99 with an 8-tick window leaves 92% of the curve past the edge.
        uint256 q99 = (Q96 * 99) / 100;
        vm.expectRevert(IMonoAuction.WindowTooNarrow.selector);
        new MonoAuction(address(0), address(0), address(idx), SPACING, q99, 8);
    }

    function test_rejectsDegenerateParams() public {
        vm.expectRevert(IMonoAuction.InvalidDecay.selector);
        new MonoAuction(address(0), address(0), address(idx), SPACING, 0, WINDOW);
        vm.expectRevert(IMonoAuction.InvalidDecay.selector);
        new MonoAuction(address(0), address(0), address(idx), SPACING, Q96 + 1, WINDOW);
        vm.expectRevert(IMonoAuction.InvalidWindow.selector);
        new MonoAuction(address(0), address(0), address(idx), SPACING, HALF, 0);
        vm.expectRevert(IMonoAuction.InvalidWindow.selector);
        new MonoAuction(address(0), address(0), address(idx), SPACING, HALF, 256);
    }
}
