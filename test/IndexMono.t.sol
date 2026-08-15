// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Index} from "../src/Index.sol";
import {Mono} from "../src/Mono.sol";
import {TestERC20} from "./TestERC20.sol";

contract IndexMonoTest is Test {
    Index internal index;
    Mono internal mono;
    TestERC20 internal aapl;
    TestERC20 internal nvda;

    address internal harvest = address(0x11A2);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);

    uint256 internal constant GENESIS_CAP = 1_000_000e18;

    function setUp() public {
        aapl = new TestERC20("Apple", "AAPLx");
        nvda = new TestERC20("Nvidia", "NVDAx");

        address[] memory legs = new address[](1); // genesis recipe: 100% AAPL (D14)
        legs[0] = address(aapl);
        index = new Index(legs);
        mono = new Mono(address(index), harvest, GENESIS_CAP);
    }

    function _wrap(address who, uint256 shares) internal {
        uint256[] memory cost = index.costToMint(shares);
        for (uint256 i; i < cost.length; ++i) {
            aapl.mint(who, cost[i]);
        }
        vm.startPrank(who);
        aapl.approve(address(index), type(uint256).max);
        index.mint(shares, who);
        vm.stopPrank();
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
        vm.expectRevert(Index.FirstMintTooSmall.selector);
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

        uint256[] memory cost = index.costToMint(second);
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
