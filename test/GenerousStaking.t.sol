// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Staking and the stake-weighted intra-tick split of `src/GenerousAuction.sol`.
///
/// The anchor is the worked example of `docs/staked-generous-auction.md` §5: one tick at 1.00,
/// stakes 50/40/10 against budgets 5/100/100, a 95-token pour, published answer 5 / 72 / 18 —
/// the whale-by-stake dies on its own budget cap and its excess re-flows to its co-stakers.
contract GenerousStakingTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;

    uint256 internal constant P1 = FLOOR + SPACING;
    uint256 internal constant P0 = FLOOR;

    address internal aa = address(0xA1);
    address internal bb = address(0xA2);
    address internal cc = address(0xA3);

    function setUp() public {
        _deploy(95e18, 0);
    }

    function _deploy(uint128 emission, uint64 end) internal {
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
                endBlock: end,
                roundBlocks: K,
                emissionPerRound: emission,
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

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _round() internal {
        vm.roll(block.number + K);
        auction.sync(64);
    }

    // ------------------------------------------------------------------ the strict rule

    /// Escrow without stake does not even enter the book.
    function test_noStakeNoBid() public {
        cur.mint(aa, 10e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 10e18);
        vm.expectRevert(IGenerousAuction.NoStake.selector);
        auction.submitBid(P0, 10e18, aa, FLOOR);
        vm.stopPrank();
    }

    /// Un-staked escrow is not tick capacity: the tick goes zombie, the emission does NOT
    /// waterfall into it, and re-staking revives it — carry intact, nothing earned while dark.
    function test_unstakedEscrowIsNotCapacity() public {
        _deploy(50e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P1, uint128(101e17), FLOOR); // capacity 10 tokens at 1.01
        _bid(bb, P0, 100e18, FLOOR);

        // bb goes dark before the first round settles.
        vm.prank(bb);
        auction.unstake(1e18);
        (,, uint256 demand0,,,) = auction.ticks(P0);
        assertEq(demand0, 0, "un-staked escrow left the tick's capacity");

        _round();
        assertEq(_owed(aa), 10e18, "the staked tick filled to its cap");
        assertEq(_owed(bb), 0, "zero stake, zero fill, strictly");
        assertEq(auction.tokensSold(), 10e18, "the rest did NOT flow into the zombie tick");
        assertEq(auction.due(), 40e18, "it carried instead");

        // Re-stake: capacity returns, the carry pours, and nothing was earned retroactively.
        vm.prank(bb);
        mono.approve(address(auction), 0); // no-op, keeps the prank shape obvious
        _stakeFor(bb, 1e18);
        auction.sync(64);
        assertEq(_owed(bb), 40e18, "the carry, earned only once the stake was back");
    }

    // ------------------------------------------------------------------ the anchor

    /// `docs/staked-generous-auction.md` §5: stakes 50/40/10, budgets 5/100/100, pour 95 at 1.00.
    /// X's stake says 50% but its budget caps it at 5; the excess re-flows to Y and Z by stake.
    function test_stakeWeightedSplit_anchor() public {
        _stakeFor(aa, 50e18);
        _stakeFor(bb, 40e18);
        _stakeFor(cc, 10e18);
        _bid(aa, P0, 5e18, FLOOR);
        _bid(bb, P0, 100e18, FLOOR);
        _bid(cc, P0, 100e18, FLOOR);

        _round();

        assertApproxEqAbs(_owed(aa), 5e18, 2, "X: capped by budget, not stake");
        assertApproxEqAbs(_owed(bb), 72e18, 2, "Y: 40 + its share of X's excess");
        assertApproxEqAbs(_owed(cc), 18e18, 2, "Z: 10 + its share of X's excess");
        assertApproxEqAbs(auction.tokensSold(), 95e18, 4, "whole pour absorbed");
        assertApproxEqAbs(_live(aa), 0, 2, "X's escrow is spent");
        // Pay-as-bid at the tick price: raised covers exactly what was eaten, at 1.00.
        assertApproxEqAbs(auction.currencyRaised(), 95e18, 4, "raised = sold * price");
    }

    // ------------------------------------------------------------------ reweighing

    /// Stake moves reweigh FUTURE rounds only; settled rounds are untouchable by construction.
    function test_stakeReweighsBetweenRounds() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 3e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        _round();
        assertEq(_owed(aa), 75e18, "round 1 at 3:1");
        assertEq(_owed(bb), 25e18);

        vm.prank(aa);
        auction.unstake(2e18); // 3:1 -> 1:1, forward-only

        _round();
        assertEq(_owed(aa), 125e18, "75 + half of round 2");
        assertEq(_owed(bb), 75e18, "25 + half of round 2");
    }

    /// Going dark and coming back: rounds while inert are missed for good, never made up.
    function test_restakeEarnsNothingRetroactively() public {
        _deploy(100e18, 0);
        _stakeFor(aa, 1e18);
        _stakeFor(bb, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);
        _bid(bb, P0, 1000e18, FLOOR);

        _round();
        assertEq(_owed(bb), 50e18, "round 1 split evenly");

        vm.prank(bb);
        auction.unstake(1e18);
        _round();
        assertEq(_owed(aa), 150e18, "round 2 went to the only staked position");
        assertEq(_owed(bb), 50e18, "inert earned nothing");

        _stakeFor(bb, 1e18);
        _round();
        assertEq(_owed(aa), 200e18, "round 3 split evenly again");
        assertEq(_owed(bb), 100e18, "back in, forward-only");
    }

    // ------------------------------------------------------------------ one bid per owner

    function test_oneBidPerOwner() public {
        _stakeFor(aa, 1e18);
        _bid(aa, P1, 50e18, FLOOR);

        // A second price with live escrow refuses; the same price tops up.
        cur.mint(aa, 60e18);
        vm.startPrank(aa);
        cur.approve(address(auction), 60e18);
        vm.expectRevert(IGenerousAuction.BidExists.selector);
        auction.submitBid(P0, 10e18, aa, FLOOR);
        auction.submitBid(P1, 50e18, aa, FLOOR);
        vm.stopPrank();
        assertEq(_live(aa), 100e18, "same price grew the one position");

        // Withdraw closes it; the next bid may sit anywhere.
        vm.prank(aa);
        auction.withdrawBid();
        _bid(aa, P0, 10e18, FLOOR);
        (uint256 price,,,,) = auction.positions(aa);
        assertEq(price, P0, "re-bound after withdraw");
    }

    /// The seat cap is the gas bound on settling one tick.
    function test_tickSeatCapBinds() public {
        for (uint256 i; i < 32; ++i) {
            address who = address(uint160(0x2000 + i));
            _stakeFor(who, 1e18);
            _bid(who, P0, 10e18, FLOOR);
        }
        address extra = address(0x3000);
        _stakeFor(extra, 1e18);
        cur.mint(extra, 10e18);
        vm.startPrank(extra);
        cur.approve(address(auction), 10e18);
        vm.expectRevert(IGenerousAuction.TickFull.selector);
        auction.submitBid(P0, 10e18, extra, FLOOR);
        vm.stopPrank();

        assertEq(auction.tickPositions(P0).length, 32, "all seats taken");
    }

    // ------------------------------------------------------------------ the lock window

    /// Stakes move freely during the sale, freeze between `endBlock` and `finalize`, and move
    /// freely again after — the freeze is what keeps the lazy tail honest.
    function test_stakeLocksUntilFinalize() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 2e18);
        _bid(aa, P0, 1000e18, FLOOR); // absorbs both rounds in full

        vm.startPrank(aa);
        auction.unstake(1e18); // free while the sale runs
        mono.approve(address(auction), 1e18);
        auction.stake(1e18);
        vm.stopPrank();

        vm.roll(end);
        vm.startPrank(aa);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.stake(1e18);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(1e18);
        vm.stopPrank();

        // Too early only while something is still owed: drain it, then finalize.
        auction.finalize(64);
        assertTrue(auction.finalized(), "backlog drained, lock lifted");

        vm.prank(aa);
        auction.unstake(2e18);
        assertEq(mono.balanceOf(aa), 2e18, "stake returned in full");
    }

    function test_finalizeRefusesEarlyAndDrainsFirst() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(aa, 1e18);
        _bid(aa, P0, 1000e18, FLOOR);

        vm.expectRevert(IGenerousAuction.NotFinalizable.selector);
        auction.finalize(64); // the sale is still running

        vm.roll(end + 1);
        auction.finalize(64); // one call: syncs the tail, sees due()==0, flips
        assertTrue(auction.finalized());
        assertEq(_owed(aa), 200e18, "the tail was distributed on the way out");
    }

    /// A dead book cannot hold stakes hostage: past `endBlock` bids and stakes are frozen, so a
    /// complete sweep that sells nothing proves the carry will never move — and unlocks.
    function test_finalizeDeadBook() public {
        uint64 end = uint64(block.number) + 2 * K;
        _deploy(100e18, end);
        _stakeFor(cc, 5e18); // stakes, never bids

        vm.roll(end + 1);
        assertGt(auction.due(), 0, "carry stands");
        vm.prank(cc);
        vm.expectRevert(IGenerousAuction.StakeLocked.selector);
        auction.unstake(5e18);

        auction.finalize(1000);
        assertTrue(auction.finalized(), "nothing sellable, provably: unlock");

        vm.prank(cc);
        auction.unstake(5e18);
        assertEq(mono.balanceOf(cc), 5e18);
    }

    // ------------------------------------------------------------------ custody

    /// Staked MONO is bidders' property: claims are paid strictly out of minted packs, and the
    /// full stake walks out afterwards.
    function test_stakeNeverPaysClaims() public {
        _deploy(150e18, 0);
        _stakeFor(aa, 500e18);
        _bid(aa, P0, 20e18, FLOOR); // capacity 20 of the 150-token round

        _round();
        uint256 got = auction.claim(aa);
        assertApproxEqAbs(got, 20e18, 2, "paid what the escrow bought");
        assertGe(mono.balanceOf(address(auction)), auction.totalStaked(), "stake untouched by the pack");

        vm.prank(aa);
        auction.unstake(500e18);
        assertEq(mono.balanceOf(aa), got + 500e18, "claim plus the whole stake, separately");
    }
}
