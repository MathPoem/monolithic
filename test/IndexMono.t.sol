// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {Mono} from "../src/Mono.sol";
import {TestERC20} from "./TestERC20.sol";

contract IndexMonoTest is Test {
    Index internal index;
    Mono internal mono;
    TestERC20 internal aapl;
    TestERC20 internal nvda;

    address internal harvest = address(0x11A2);
    MockFeed internal aaplFeed;
    MockFeed internal nvdaFeed;
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);

    uint256 internal constant GENESIS_CAP = 1_000_000e18;

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        nvda = new TestERC20("Nvidia", "NVDAx");
        aaplFeed = new MockFeed(200e8); // $200
        nvdaFeed = new MockFeed(100e8); // $100

        address[] memory legs = new address[](1); // genesis recipe: 100% AAPL (D14)
        legs[0] = address(aapl);
        uint16[] memory bips = new uint16[](1);
        bips[0] = 10_000;
        index = new Index(legs, bips);
        mono = new Mono(address(index), harvest, GENESIS_CAP);
    }

    function _wrap(address who, uint256 shares) internal {
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        for (uint256 i; i < cost.length; ++i) {
            aapl.mint(who, cost[i]);
        }
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    // ----------------------------------------------------- REALLOCATION

    /// @dev Fills the open channel to the last wei, in one mint.
    function _fill(address who) internal returns (uint256 shares) {
        shares = index.maxDeficitMint();
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        nvda.mint(who, cost[1]);
        vm.startPrank(who);
        nvda.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
    }

    function _openChannel(uint16 bips) internal {
        index.startReallocation(_allocation(address(nvda), bips, address(nvdaFeed)));
    }

    function _allocation(address newAsset, uint16 newBips, address newFeed)
        internal
        view
        returns (IIndex.StockAllocation[] memory allocation)
    {
        allocation = new IIndex.StockAllocation[](2);
        allocation[0] = IIndex.StockAllocation({
            asset: address(aapl), allocationBips: uint16(10_000 - newBips), priceFeed: address(aaplFeed)
        });
        allocation[1] = IIndex.StockAllocation({asset: newAsset, allocationBips: newBips, priceFeed: newFeed});
    }

    function test_channelFillsToTargetThenClosesItself() public {
        _wrap(alice, 100e18); // 100 AAPL @ $200 = $20_000, $200 per INDEX
        _openChannel(4_000);

        assertTrue(index.reallocating());
        assertEq(index.pendingAsset(), address(nvda));
        // 40% of $200 per INDEX = $80 per INDEX, at $100 = 0.8 NVDA per INDEX.
        assertEq(index.targetPerIndex(), 0.8e18);
        assertGt(index.deficit(), 0);

        _fill(bob);

        assertFalse(index.reallocating());
        assertEq(index.deficit(), 0);
        // Nothing was sold: the AAPL leg is untouched, exactly as D12 requires.
        assertEq(index.potBalance(address(aapl)), 100e18);
        // And the new leg landed on its weight, within the haircut.
        uint256 aaplValue = index.potBalance(address(aapl)) * 200;
        uint256 nvdaValue = index.potBalance(address(nvda)) * 100;
        assertApproxEqRel(nvdaValue * 10_000 / (aaplValue + nvdaValue), 4_000, 0.02e18);
    }

    function test_mintChargesTheNewLegAloneWhileTheChannelIsOpen() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        // Minting still works — it just costs NVDA and nothing else.
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(10e18);
        assertEq(cost[0], 0);
        assertGt(cost[1], 0);

        nvda.mint(alice, cost[1]);
        vm.startPrank(alice);
        nvda.approve(address(index), type(uint256).max);
        index.mint(10e18, alice);
        vm.stopPrank();
        assertEq(index.potBalance(address(nvda)), cost[1]);
        assertEq(index.potBalance(address(aapl)), 100e18); // untouched

        // Deficit-only: the channel refuses to overshoot its target.
        uint256 tooMany = index.maxDeficitMint() + 1e18;
        vm.expectRevert(IIndex.ExceedsDeficit.selector);
        index.mint(tooMany, alice);

        // Redeem is never gated while the channel is open.
        vm.prank(alice);
        index.redeem(10e18, alice);
        assertGt(aapl.balanceOf(alice), 0);

        _fill(bob);

        // ...and once it closes, minting takes every leg again.
        cost = index.calculateAmountOfAssetsToMintIndex(10e18);
        assertGt(cost[0], 0);
        assertGt(cost[1], 0);
        aapl.mint(alice, cost[0]);
        nvda.mint(alice, cost[1]);
        uint256 before = index.balanceOf(alice);
        vm.startPrank(alice);
        aapl.approve(address(index), type(uint256).max);
        nvda.approve(address(index), type(uint256).max);
        index.mint(10e18, alice);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), before + 10e18);
    }

    function test_depositorPaysTheHaircut() public {
        _wrap(alice, 100e18);
        _openChannel(4_000);

        uint256 shares = 10e18;
        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(shares);
        nvda.mint(bob, cost[1]);
        vm.startPrank(bob);
        nvda.approve(address(index), type(uint256).max);
        index.mint(shares, bob);
        vm.stopPrank();

        // 10 INDEX at $200 each = $2_000, grossed up 1% and bought at $100 a unit.
        assertEq(cost[1], (shares * 200 * 10_000) / (100 * 9_900) + 1); // +1: rounds up, pot never loses
        assertEq(index.balanceOf(bob), shares);
        // Existing holders were not diluted: their slice of the pot is worth no less than before.
        assertEq(index.potBalance(address(aapl)), 100e18);
    }

    function test_reallocation_reverts() public {
        _wrap(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.startReallocation(_allocation(address(nvda), 4_000, address(nvdaFeed)));

        // Every proposed leg needs a feed before the pot can be valued.
        IIndex.StockAllocation[] memory missingFeed = _allocation(address(nvda), 4_000, address(nvdaFeed));
        missingFeed[0].priceFeed = address(0);
        vm.expectRevert(IIndex.InvalidPriceFeed.selector);
        index.startReallocation(missingFeed);

        vm.expectRevert(IIndex.InvalidAllocation.selector);
        IIndex.StockAllocation[] memory badTotal = _allocation(address(nvda), 4_000, address(nvdaFeed));
        badTotal[0].allocationBips = 5_999;
        index.startReallocation(badTotal);

        vm.expectRevert(IIndex.DuplicateAsset.selector);
        index.startReallocation(_allocation(address(aapl), 4_000, address(aaplFeed)));

        vm.expectRevert(IIndex.InvalidPriceFeed.selector);
        index.startReallocation(_allocation(address(nvda), 4_000, address(0)));

        index.startReallocation(_allocation(address(nvda), 4_000, address(nvdaFeed)));
        vm.expectRevert(IIndex.ReallocationActive.selector);
        index.startReallocation(_allocation(address(0xDEAD), 100, address(nvdaFeed)));

        vm.warp(block.timestamp + 2 hours); // every feed is now stale
        vm.expectRevert(IIndex.StalePrice.selector);
        index.mint(1e18, alice);
    }

    // --------------------------------------------------------- REMOVAL

    /// @dev Wraps, fills a 40% NVDA channel, then opens a removal on NVDA.
    function _openRemoval() internal {
        _wrap(alice, 100e18);
        _openChannel(4_000);
        _fill(bob);
        index.startRemoval(address(nvda));
    }

    function test_removalDrainsTheLegAndDelistsIt() public {
        _openRemoval();
        assertTrue(index.removing());
        assertEq(index.exitingAsset(), address(nvda));
        assertEq(index.surplus(), index.potBalance(address(nvda)));

        uint256 aaplBefore = index.potBalance(address(aapl));

        // Bob holds the shares the channel minted him; burning them takes NVDA and nothing else.
        uint256 burn = FixedPointMathLib.min(index.maxSurplusRedeem(), index.balanceOf(bob));
        vm.prank(bob);
        index.redeemSurplus(burn, bob);
        assertGt(nvda.balanceOf(bob), 0);
        assertEq(aapl.balanceOf(bob), 0);

        // Whoever is left finishes the job.
        uint256 rest = FixedPointMathLib.min(index.maxSurplusRedeem(), index.balanceOf(alice));
        if (rest > 0) {
            vm.prank(alice);
            index.redeemSurplus(rest, alice);
        }

        assertFalse(index.removing());
        assertEq(index.assetCount(), 1);
        assertEq(index.potBalance(address(nvda)), 0);
        (bool enabled,,) = index.stocks(address(nvda));
        assertFalse(enabled);
        // The pot never sold: every unit of AAPL is still there, now backing fewer shares.
        assertEq(index.potBalance(address(aapl)), aaplBefore);
    }

    function test_removalLiftsTheRemainingLegsPerIndexClaim() public {
        _openRemoval();
        uint256 supplyBefore = index.totalSupply();
        uint256 aaplPerIndexBefore = (index.potBalance(address(aapl)) * 1e18) / supplyBefore;

        uint256 half = index.balanceOf(bob) / 2;
        vm.prank(bob);
        index.redeemSurplus(half, bob);

        uint256 aaplPerIndexAfter = (index.potBalance(address(aapl)) * 1e18) / index.totalSupply();
        assertGt(aaplPerIndexAfter, aaplPerIndexBefore);
    }

    function test_bothOrdinaryLegsAreShutWhileDraining() public {
        _openRemoval();

        vm.prank(alice);
        vm.expectRevert(IIndex.RemovalActive.selector);
        index.redeem(1e18, alice);

        vm.prank(alice);
        vm.expectRevert(IIndex.RemovalActive.selector);
        index.mint(1e18, alice);

        vm.expectRevert(IIndex.RemovalActive.selector);
        index.startReallocation(_allocation(address(0xDEAD), 1_000, address(nvdaFeed)));
    }

    function test_removal_reverts() public {
        _wrap(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        index.startRemoval(address(aapl));

        // Draining the only leg would leave nothing behind.
        vm.expectRevert(IIndex.LastAsset.selector);
        index.startRemoval(address(aapl));

        vm.expectRevert(IIndex.InvalidAsset.selector);
        index.startRemoval(address(nvda));

        vm.expectRevert(IIndex.NoRemoval.selector);
        index.redeemSurplus(1e18, alice);

        _openChannel(4_000);
        _fill(bob);
        index.startRemoval(address(nvda));

        vm.expectRevert(IIndex.RemovalActive.selector);
        index.startRemoval(address(aapl));

        // Asking for more than the leg can pay is a revert, not a partial fill.
        uint256 tooMuch = index.maxSurplusRedeem() + 1e18;
        vm.prank(alice);
        vm.expectRevert(IIndex.SurplusExhausted.selector);
        index.redeemSurplus(tooMuch, alice);
    }

    // ------------------------------------------------------------- INDEX

    /// Genesis wraps AAPLx 1:1 into INDEX.
    function test_genesisWrapsOneToOne() public {
        _wrap(alice, 1_000e18);
        assertEq(index.balanceOf(alice), 1_000e18 - 1e3, "minus locked dust");
        assertEq(aapl.balanceOf(address(index)), 1_000e18, "pot holds the stock 1:1");
        assertEq(index.totalSupply(), 1_000e18);
    }

    function test_firstMintMustClearTheFloor() public {
        aapl.mint(alice, 1e18);
        vm.startPrank(alice);
        aapl.approve(address(index), type(uint256).max);
        vm.expectRevert(IIndex.FirstMintTooSmall.selector);
        index.mint(1e17, alice);
        vm.stopPrank();
    }

    /// The core wrapper invariant: wrapping then unwrapping can never profit the caller.
    function testFuzz_roundTripNeverProfits(uint96 first, uint96 second, uint96 donation) public {
        first = uint96(bound(first, 1e18, 1e24));
        second = uint96(bound(second, 1e12, 1e24));
        donation = uint96(bound(donation, 0, 1e24));

        _wrap(alice, first);
        if (donation > 0) aapl.mint(address(index), donation); // hostile donation

        uint256[] memory cost = index.calculateAmountOfAssetsToMintIndex(second);
        aapl.mint(bob, cost[0]);
        vm.startPrank(bob);
        aapl.approve(address(index), type(uint256).max);
        index.mint(second, bob);
        uint256 spent = cost[0];
        uint256[] memory got = index.proceedsOfRedeem(index.balanceOf(bob));
        index.redeem(index.balanceOf(bob), bob);
        vm.stopPrank();

        assertLe(got[0], spent, "round trip must never return more than it cost");
    }

    /// Redemption is always open — INDEX is never a trap state.
    function test_redeemAlwaysOpen() public {
        _wrap(alice, 1_000e18);
        vm.prank(alice);
        index.redeem(500e18, alice);
        assertEq(aapl.balanceOf(alice), 500e18);
        assertEq(index.balanceOf(alice), 500e18 - 1e3);
    }

    /// A corporate action arrives as a pot balance change; every holder rescales for free.
    function test_potGrowthAccruesProRata() public {
        _wrap(alice, 1_000e18);
        _wrap(bob, 1_000e18);
        aapl.mint(address(index), 2_000e18); // pot doubles (uiMultiplier / stock split shape)

        uint256[] memory got = index.proceedsOfRedeem(index.balanceOf(alice));
        assertApproxEqRel(got[0], 2_000e18, 1e12, "alice's claim doubled");
    }

    /// NEVER REDUCE (D12) is enforced by absence: no such function exists.
    function test_noCompositionReductionInBytecode() public view {
        assertEq(index.assetCount(), 1);
        // Guard against a future edit quietly adding one.
        assertFalse(_hasSelector(address(index), "removeAsset(address)"));
        assertFalse(_hasSelector(address(index), "setRecipe(address,uint256)"));
        assertFalse(_hasSelector(address(index), "rebalance(address,address,uint256)"));
    }

    // -------------------------------------------------------------- MONO

    function _genesis(uint256 shares, uint256 assetsIn) internal {
        _wrap(harvest, assetsIn + 1e18); // extra covers the locked MIN_LIQUIDITY dust
        vm.startPrank(harvest);
        index.approve(address(mono), type(uint256).max);
        mono.genesis(shares, assetsIn, harvest);
        vm.stopPrank();
    }

    function test_genesisSetsOpeningNav() public {
        _genesis(1_000e18, 1_000e18);
        assertEq(mono.nav(), 1e18, "opening NAV is 1 INDEX per MONO");
        assertEq(mono.totalAssets(), 1_000e18);
        assertEq(mono.asset(), address(index));
    }

    function test_genesisIsOneShotAndCapped() public {
        _genesis(1_000e18, 1_000e18);
        vm.prank(harvest);
        vm.expectRevert(Mono.AlreadyGenesis.selector);
        mono.genesis(1, 1, harvest);

        Mono fresh = new Mono(address(index), harvest, 100e18);
        vm.prank(harvest);
        vm.expectRevert(Mono.AboveGenesisCap.selector);
        fresh.genesis(101e18, 101e18, harvest);
    }

    /// The whole thesis: no operation may lower NAV.
    function test_issueCannotDiluteNav() public {
        _genesis(1_000e18, 1_000e18); // NAV 1.0

        _wrap(harvest, 2_000e18);
        vm.startPrank(harvest);
        index.approve(address(mono), type(uint256).max);

        // Paying exactly NAV is the boundary and is allowed.
        mono.issue(100e18, 100e18, harvest);
        assertEq(mono.nav(), 1e18);

        // One wei below NAV is not.
        vm.expectRevert(Mono.Dilutive.selector);
        mono.issue(100e18, 100e18 - 1, harvest);

        // Above NAV — a real harvest strike — raises it.
        mono.issue(100e18, 150e18, harvest);
        vm.stopPrank();
        assertGt(mono.nav(), 1e18, "harvest above NAV accretes");
    }

    function testFuzz_navNeverDecreases(uint96[8] calldata shares, uint96[8] calldata premiums) public {
        _genesis(1_000e18, 1_000e18);
        _wrap(harvest, 1e26);
        vm.startPrank(harvest);
        index.approve(address(mono), type(uint256).max);

        uint256 last = mono.nav();
        for (uint256 i; i < 8; ++i) {
            uint256 s = bound(shares[i], 1e12, 1e20);
            uint256 premium = bound(premiums[i], 0, 1e20);
            uint256 need = mono.previewMint(s);
            if (need + premium > index.balanceOf(harvest)) break;
            mono.issue(s, need + premium, harvest);
            uint256 now_ = mono.nav();
            assertGe(now_, last, "NAV decreased on issue");
            last = now_;
        }
        vm.stopPrank();
    }

    /// Burning retires a claim without touching the pot — this is how wall fills accrete.
    function test_burnRaisesNav() public {
        _genesis(1_000e18, 1_000e18);
        vm.prank(harvest);
        mono.burn(100e18);
        assertApproxEqRel(mono.nav(), 1.1111e18, 1e15, "NAV rises as supply shrinks");
        assertEq(mono.totalAssets(), 1_000e18, "pot untouched");
    }

    /// Only the harvest module may mint.
    function test_onlyIssuerMints() public {
        _genesis(1_000e18, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(Mono.NotIssuer.selector);
        mono.issue(1e18, 1e18, alice);
    }

    /// 4626 reads are live; 4626 writes are shut. Both matter.
    function test_erc4626SurfaceIsReadOnly() public {
        _genesis(1_000e18, 2_000e18); // NAV 2.0

        assertEq(mono.convertToAssets(1e18), 2e18, "1 MONO is worth 2 INDEX");
        assertEq(mono.convertToShares(2e18), 1e18);
        assertEq(mono.previewRedeem(1e18), 2e18);
        assertEq(mono.previewMint(1e18), 2e18);

        assertEq(mono.maxDeposit(alice), 0);
        assertEq(mono.maxMint(alice), 0);
        assertEq(mono.maxWithdraw(harvest), 0);
        assertEq(mono.maxRedeem(harvest), 0);

        vm.startPrank(harvest);
        vm.expectRevert(Mono.Closed.selector);
        mono.deposit(1e18, harvest);
        vm.expectRevert(Mono.Closed.selector);
        mono.mint(1e18, harvest);
        vm.expectRevert(Mono.Closed.selector);
        mono.withdraw(1e18, harvest, harvest);
        vm.expectRevert(Mono.Closed.selector);
        mono.redeem(1e18, harvest, harvest);
        vm.stopPrank();
    }

    /// The vault has no exit at all — not for admin, not for the issuer, not for anyone.
    function test_vaultHasNoOutflow() public {
        _genesis(1_000e18, 1_000e18);
        assertFalse(_hasSelector(address(mono), "withdrawForWall(uint256)"));
        assertFalse(_hasSelector(address(mono), "rescue(address,uint256)"));
        assertFalse(_hasSelector(address(mono), "sweep(address)"));
        assertFalse(_hasSelector(address(mono), "setIssuer(address)"));
        assertEq(mono.totalAssets(), 1_000e18);
    }

    /// A plain transfer in is the tax sweep: NAV rises, nobody is privileged.
    function test_taxSweepRaisesNav() public {
        _genesis(1_000e18, 1_000e18);
        _wrap(alice, 100e18);
        uint256 bal = index.balanceOf(alice);
        vm.prank(alice);
        index.transfer(address(mono), bal);
        assertGt(mono.nav(), 1e18, "donated INDEX accrues to every holder");
    }

    /// The asset list and the `stocks` mapping agree, and the constructor rejects a bad list.
    function test_assetListGuards() public {
        (bool enabled, uint16 bips,) = index.stocks(address(aapl));
        assertTrue(enabled, "genesis leg enabled");
        assertEq(bips, 10_000, "100% AAPL at genesis");
        (enabled, bips,) = index.stocks(address(nvda));
        assertFalse(enabled, "unlisted stock is not a leg");
        assertEq(bips, 0);

        address[] memory two = new address[](2);
        two[0] = address(aapl);
        two[1] = address(nvda);
        uint16[] memory split = new uint16[](2);
        split[0] = 6_000;
        split[1] = 4_000;

        // Duplicate leg.
        address[] memory dupe = new address[](2);
        dupe[0] = address(aapl);
        dupe[1] = address(aapl);
        vm.expectRevert(IIndex.DuplicateAsset.selector);
        new Index(dupe, split);

        // Zero address leg.
        vm.expectRevert(IIndex.InvalidAsset.selector);
        new Index(new address[](1), _bips(10_000));

        // Empty list.
        vm.expectRevert(IIndex.NoAssets.selector);
        new Index(new address[](0), new uint16[](0));

        // Arrays out of step.
        vm.expectRevert(IIndex.LengthMismatch.selector);
        new Index(two, _bips(10_000));

        // Weights that do not sum to 10_000.
        split[1] = 3_999;
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        new Index(two, split);

        // A zero weight is not a leg.
        split[1] = 0;
        vm.expectRevert(IIndex.InvalidAllocation.selector);
        new Index(two, split);

        // The good two-leg case, for contrast.
        split[0] = 6_000;
        split[1] = 4_000;
        Index pair = new Index(two, split);
        assertEq(pair.assetCount(), 2);
        (, bips,) = pair.stocks(address(nvda));
        assertEq(bips, 4_000);
    }

    function _bips(uint16 only) internal pure returns (uint16[] memory out) {
        out = new uint16[](1);
        out[0] = only;
    }

    function _hasSelector(address target, string memory sig) internal view returns (bool) {
        bytes4 sel = bytes4(keccak256(bytes(sig)));
        bytes memory code = target.code;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }
}

/// @notice Chainlink feed stand-in: one settable answer, 8 decimals.
contract MockFeed {
    int256 internal answer;
    uint256 internal updatedAt;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
