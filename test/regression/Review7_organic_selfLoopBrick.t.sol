// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 7 / organic-UX lens — NO adversary. A deterministic 8-step replay of what the random
/// honest-population simulation (`Review7_organic_Base.t.sol`, keeper sync(64) every 25 blocks,
/// 36 users) reached on its own at block ~11,400: a self-loop in the tick list that bricks every
/// entry point, escrow and stakes included.
///
/// Mechanism (all `src/GenerousAuction.sol`):
///   - `_splice(hi, lo)` (l.725) rewrites only `ticks[hi].prev` and `ticks[lo].next`; the OLD
///     `lo.next` and `hi.prev` partners keep pointing at `lo`/`hi`. When the same `lo` is spliced
///     to a second `hi'` (after a trap node was re-exposed and died), `lo.next` moves to `hi'`
///     while `hi.prev` still says `lo` — so `hi` now FAILS `_initializeTick`'s back-pointer check
///     (l.1233) although it is the top of the list.
///   - The exact chain predecessor of `hi` is `lo` (its `prev`), but `ticks[lo].next < hi`, so
///     the correct hint reverts `BadPrevHint` (l.1239). The ONLY init tick `x < hi` with
///     `next >= hi` is the stale node whose `.next == hi`. `_initializeTick` accepts
///     `nextPrice == price` (the check is `nextPrice < price`, l.1239) and then executes
///     `ticks[nextPrice].prev = price` (l.1247) — i.e. `ticks[hi].prev = hi`.
///   - `submitBid` lifts `highestTick` onto `hi` (l.580). Every `_gather` (l.741) now walks
///     `hi -> hi -> hi ...`, `w.n` outruns the `windowTicks + 1` arrays and the call panics
///     0x32. `_sync` runs first in `sync`/`submitBid`/`withdrawBid`/`claim`/`stake`/`unstake`/
///     `finalize`, so all of them revert forever. There is no admin path that touches links.
contract Review7OrganicSelfLoopBrick is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    uint256 internal constant P7 = FLOOR + 7 * SPACING;
    uint256 internal constant P9 = FLOOR + 9 * SPACING;
    uint256 internal constant P10 = FLOOR + 10 * SPACING;
    uint256 internal constant P11 = FLOOR + 11 * SPACING;
    uint256 internal constant P12 = FLOOR + 12 * SPACING;

    address internal alice = address(0xA11CE); // long-lived bidder at 1.07
    address internal b9 = address(0xB9);
    address internal b10 = address(0xB10);
    address internal b11 = address(0xB11);
    address internal b12 = address(0xB12);
    address internal carol = address(0xCA201); // honest re-bid at 1.10 (an old price)
    address internal dave = address(0xDA4E); // honest re-bid at 1.12 (an old price)

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: 50e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));

        address[7] memory all = [alice, b9, b10, b11, b12, carol, dave];
        for (uint256 i; i < 7; ++i) {
            mono.transfer(all[i], 1e18);
            cur.mint(all[i], 10_000e18);
            vm.startPrank(all[i]);
            mono.approve(address(auction), type(uint256).max);
            cur.approve(address(auction), type(uint256).max);
            auction.stake(1e18);
            vm.stopPrank();
        }
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 hint)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(who);
        (ok, ret) = address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (price, amount, who, hint)));
    }

    /// What a UI computes: the top of the list via `next` from `highestTick`, then the first
    /// node below `price` walking `prev`.
    function _chainHint(uint256 price) internal view returns (uint256 p) {
        p = auction.highestTick();
        for (uint256 i; i < 64; ++i) {
            (uint256 nx,,,,,,) = auction.ticks(p);
            if (nx == 0) break;
            p = nx;
        }
        for (uint256 i; i < 64 && p != 0; ++i) {
            if (p < price) return p;
            (, uint256 pv,,,,,) = auction.ticks(p);
            p = pv;
        }
        return FLOOR;
    }

    /// The documented recovery ("re-read the book and retry"): every init tick below `price`
    /// that `_initializeTick` would accept as `prevPrice`.
    function _acceptedHints(uint256 price) internal view returns (uint256[] memory out, uint256 n) {
        out = new uint256[](16);
        for (uint256 d; d <= 14; ++d) {
            uint256 x = FLOOR + d * SPACING;
            if (x >= price) break;
            (uint256 nx,,,,,, bool init) = auction.ticks(x);
            if (!init) continue;
            if (nx == 0 || nx >= price) out[n++] = x;
        }
    }

    function _links(string memory tag) internal {
        emit log_string(tag);
        for (uint256 d; d <= 12; ++d) {
            uint256 p = FLOOR + d * SPACING;
            (uint256 nx, uint256 pv, uint256 cap,,,, bool init) = auction.ticks(p);
            if (!init) continue;
            emit log_string(string.concat(
                    "  d",
                    vm.toString(d),
                    ": next d",
                    vm.toString(nx / 1e16),
                    " prev d",
                    vm.toString(pv / 1e16),
                    cap != 0 ? "  LIVE" : ""
                ));
        }
        emit log_named_uint("  highestTick d", auction.highestTick() / 1e16);
    }

    /// FAILS on current code: after eight honest steps the sale is bricked.
    function test_honestRebidSelfLoopsTheBookAndBricksEverything() public {
        // 1. A normal book: a long-lived bidder at 1.07 and four small bidders above it.
        (bool ok,) = _bid(alice, P7, 1000e18, FLOOR);
        assertTrue(ok);
        (ok,) = _bid(b9, P9, 2e18, P7);
        assertTrue(ok);
        (ok,) = _bid(b10, P10, 2e18, P9);
        assertTrue(ok);
        (ok,) = _bid(b11, P11, 2e18, P10);
        assertTrue(ok);
        (ok,) = _bid(b12, P12, 2e18, P11);
        assertTrue(ok);

        // 2. One round: the four small positions exhaust; alice absorbs the rest.
        vm.roll(block.number + K);
        auction.sync(64);
        // 3. Next round: the sweep walks the dead run 12-11-10-9 and splices it out.
        vm.roll(block.number + K);
        auction.sync(64);
        _links("after splice(12, 7):");
        (, uint256 pv12,,,,,) = auction.ticks(P12);
        (uint256 nx7,,,,,,) = auction.ticks(P7);
        assertEq(pv12, P7, "12.prev = 7");
        assertEq(nx7, P12, "7.next = 12");

        // 4. carol re-bids at 1.10 — a price that used to be live. `_initializeTick` sees
        //    `ticks[9].next == 10` and treats it as linked (the interior-node trap, round 6).
        //    `highestTick` is lifted onto it.
        (ok,) = _bid(carol, P10, 2e18, _chainHint(P10));
        assertTrue(ok, "carol's re-bid at 1.10 is accepted");
        assertEq(auction.highestTick(), P10);

        // 5. carol's small position exhausts; 6. the next sweep starts at 10 (dead), walks
        //    10 -> 9 -> 7 and splices AGAIN onto 7: `7.next` moves from 12 to 10.
        vm.roll(block.number + K);
        auction.sync(64);
        vm.roll(block.number + K);
        auction.sync(64);
        _links("after splice(10, 7):");
        (nx7,,,,,,) = auction.ticks(P7);
        (, pv12,,,,,) = auction.ticks(P12);
        assertEq(nx7, P10, "7.next = 10 now");
        assertEq(pv12, P7, "...but 12.prev is still 7: 12 fails the back-pointer check");

        // 7. dave re-bids at 1.12 with the exact predecessor the list shows (7) -> BadPrevHint.
        uint256 hint = _chainHint(P12);
        assertEq(hint, P7, "the list says 7 is the predecessor of 12");
        bytes memory ret;
        (ok, ret) = _bid(dave, P12, 2e18, hint);
        assertFalse(ok);
        assertEq(bytes4(ret), IGenerousAuction.BadPrevHint.selector, "exact predecessor is rejected");

        // The documented recovery: re-read the book. The ONLY hint the contract accepts is 11,
        // and `ticks[11].next == 12` — the price itself.
        (uint256[] memory hints, uint256 n) = _acceptedHints(P12);
        assertEq(n, 1, "exactly one accepted hint");
        assertEq(hints[0], P11);
        (uint256 nx11,,,,,,) = auction.ticks(P11);
        assertEq(nx11, P12, "and its .next IS the price");

        // 8. dave retries with it. Accepted: `nextPrice < price` is false for nextPrice == price.
        (ok,) = _bid(dave, P12, 2e18, P11);
        assertTrue(ok, "the retry is accepted");
        _links("after dave's retry:");
        (uint256 nx12, uint256 pv12b,,,,,) = auction.ticks(P12);
        assertEq(pv12b, P12, "ticks[12].prev == 12: SELF-LOOP");
        assertEq(nx12, P12, "ticks[12].next == 12");
        assertEq(auction.highestTick(), P12, "and the sweep now starts there");

        // 9. Everything is dead. One block of accrual and every entry point panics 0x32.
        vm.roll(block.number + 1);
        bytes memory panic = abi.encodeWithSignature("Panic(uint256)", 0x32);

        (bool syncOk, bytes memory syncRet) = address(auction).call(abi.encodeCall(IGenerousAuction.sync, (64)));
        emit log_named_bytes("sync(64) revert data", syncRet);
        assertEq(syncRet, panic, "sync panics");

        (bool pvOk, bytes memory pvRet) = address(auction).staticcall(abi.encodeCall(GenerousAuction.previewWindow, ()));
        assertFalse(pvOk);
        assertEq(pvRet, panic, "previewWindow panics");

        vm.prank(alice);
        (bool wOk, bytes memory wRet) = address(auction).call(abi.encodeCall(IGenerousAuction.withdrawBid, ()));
        assertFalse(wOk);
        assertEq(wRet, panic, "alice cannot withdraw her escrow");

        vm.prank(alice);
        (bool uOk, bytes memory uRet) = address(auction).call(abi.encodeCall(IGenerousAuction.unstake, (1e18)));
        assertFalse(uOk);
        assertEq(uRet, panic, "alice cannot unstake");

        (bool cOk, bytes memory cRet) = address(auction).call(abi.encodeCall(IGenerousAuction.claim, (alice)));
        assertFalse(cOk);
        assertEq(cRet, panic, "alice cannot even claim what she already won");

        (uint256 live, uint256 owed) = auction.positionOf(alice);
        emit log_named_uint("alice escrow locked", live);
        emit log_named_uint("alice tokens owed, unclaimable", owed);
        emit log_named_uint("totalStaked locked", auction.totalStaked());
        emit log_named_uint("currency held by auction", cur.balanceOf(address(auction)));

        // The claim this test makes on the contract:
        assertTrue(syncOk, "an honest bid with a contract-accepted hint must never brick the sale");
    }
}
