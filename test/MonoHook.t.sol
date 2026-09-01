// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {MonoHook} from "../src/MonoHook.sol";
import {IMonoHook} from "../src/interfaces/IMonoHook.sol";
import {TestERC20} from "./TestERC20.sol";

contract MonoHookTest is Test {
    using StateLibrary for IPoolManager;

    uint32 constant TAU_SHORT = 45 minutes;
    uint32 constant TAU_MEDIUM = 2 hours;
    uint32 constant TAU_LONG = 18 hours;

    PoolManager manager;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest liquidity;
    MonoHook hook;
    PoolKey key;
    PoolId id;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapper = new PoolSwapTest(IPoolManager(address(manager)));
        liquidity = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // A v4 hook's permissions ARE its address, so the test has to deploy to a matching one.
        // `BaseHook`'s constructor validates the match, which makes this an assertion too.
        address flagged =
            address(uint160(0x4444 << 144) | uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(manager)), TAU_SHORT, TAU_MEDIUM, TAU_LONG),
            flagged
        );
        hook = MonoHook(flagged);

        TestERC20 a = new TestERC20("A", "A");
        TestERC20 b = new TestERC20("B", "B");
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        TestERC20(t0).mint(address(this), 1e30);
        TestERC20(t1).mint(address(this), 1e30);
        TestERC20(t0).approve(address(swapper), type(uint256).max);
        TestERC20(t1).approve(address(swapper), type(uint256).max);
        TestERC20(t0).approve(address(liquidity), type(uint256).max);
        TestERC20(t1).approve(address(liquidity), type(uint256).max);

        key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(flagged));
        id = key.toId();

        vm.warp(1_700_000_000);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1e21, bytes32(0)), "");
    }

    // ---------------------------------------------------------------- helpers

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _liveTick() internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(id);
    }

    function _mean(IMonoHook.Horizon h) internal view returns (int24) {
        return hook.meanTick(id, h);
    }

    // ---------------------------------------------------------------- tests

    /// The oracle is live from initialize, not from the first swap.
    function test_seedsAtInitializeSoThereIsNoDarkWindow() public view {
        assertEq(_mean(IMonoHook.Horizon.Short), 0);
        assertEq(_mean(IMonoHook.Horizon.Medium), 0);
        assertEq(_mean(IMonoHook.Horizon.Long), 0);
    }

    function test_unknownPoolReverts() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert(IMonoHook.NotInitialized.selector);
        hook.meanTick(other.toId(), IMonoHook.Horizon.Long);
    }

    /// The whole point of three horizons: the same displacement reaches them at different speeds.
    function test_shortLeadsMediumLeadsLong() public {
        _swap(true, 1e19); // push the tick well below 0
        int24 live = _liveTick();
        assertLt(live, -100, "setup: price did not move");

        vm.warp(block.timestamp + 1 hours);
        _swap(true, 1); // nudge, to force an accrual

        int24 s = _mean(IMonoHook.Horizon.Short);
        int24 m = _mean(IMonoHook.Horizon.Medium);
        int24 l = _mean(IMonoHook.Horizon.Long);

        // All moved down from 0 towards `live`, and strictly in horizon order.
        assertLt(s, m, "short must lead medium");
        assertLt(m, l, "medium must lead long");
        assertLt(l, 0, "long must have moved at all");
        assertGt(s, live, "short cannot overshoot the live tick");
    }

    /// A displacement pushed and released inside ONE block moves nothing: the tick that accrues is
    /// the one that STOOD for the elapsed seconds, and this one stood for zero.
    function test_intraBlockSpikeCostsTheOracleNothing() public {
        _swap(true, 1e19);
        assertLt(_liveTick(), -100, "setup: price did not move");
        _swap(false, 1e19); // same block, back up

        vm.warp(block.timestamp + 12 hours);
        // Not exactly 0: the round trip pays the LP fee twice, so the pool does not land back on
        // tick 0. That residue is real price movement, and a couple of ticks of it is all there is.
        assertApproxEqAbs(_mean(IMonoHook.Horizon.Long), int256(0), 5, "an intra-block round trip must be near-free");
    }

    /// The control for the test above: the SAME displacement, held across a block boundary, does
    /// move the reading — so the test above is measuring intra-block-ness, not a dead oracle.
    function test_heldDisplacementDoesMoveTheReading() public {
        _swap(true, 1e19);
        vm.warp(block.timestamp + 12 hours);
        // 12h against tau = 18h is 1 - exp(-2/3) = 49% of the way to a tick near -199.
        assertLt(_mean(IMonoHook.Horizon.Long), -90, "a held displacement must move the long reading");
    }

    /// A quiet pool reads as the price actually standing, not as a stale average — the read folds
    /// in the elapsed seconds even though nobody has swapped.
    function test_readAccruesWithoutASwap() public {
        _swap(true, 1e19);
        int24 before = _mean(IMonoHook.Horizon.Short);
        vm.warp(block.timestamp + 30 minutes);
        assertLt(_mean(IMonoHook.Horizon.Short), before, "read must accrue on time alone");
    }

    /// Left alone for many time constants, every horizon converges on the standing price.
    function test_convergesToTheStandingPrice() public {
        _swap(true, 1e19);
        int24 live = _liveTick();
        vm.warp(block.timestamp + 30 days);
        assertApproxEqAbs(_mean(IMonoHook.Horizon.Long), live, 1, "long must converge");
        assertApproxEqAbs(_mean(IMonoHook.Horizon.Short), live, 1, "short must converge");
    }

    /// `meanSqrtPriceX96` is a drop-in for `slot0`'s: same units, same orientation.
    function test_sqrtPriceMatchesTheMeanTick() public view {
        assertEq(
            hook.meanSqrtPriceX96(id, IMonoHook.Horizon.Long),
            TickMath.getSqrtPriceAtTick(_mean(IMonoHook.Horizon.Long))
        );
    }

    /// @dev Asserts only that it does not deploy. `BaseHook`'s address check is a base-constructor
    ///      and runs first, so the surfaced error is its one, not `InvalidHorizons` — which is why
    ///      this cannot expect a specific selector.
    /// The view and the write must agree: what `meanTick` shows a second before a swap is exactly
    /// what that swap's `beforeSwap` commits to storage. Otherwise the preview lies.
    function test_readAgreesWithTheNextWrite() public {
        _swap(true, 1e19);
        vm.warp(block.timestamp + 3 hours);

        int24 previewed = _mean(IMonoHook.Horizon.Medium);
        _swap(true, 1); // nudge: forces the accrual the preview just predicted
        assertEq(_mean(IMonoHook.Horizon.Medium), previewed, "preview must equal the committed value");
    }

    function test_transposedHorizonsDoNotDeploy() public {
        vm.expectRevert();
        this.deployWithHorizons(2 hours, 1 hours, 18 hours);
    }

    function deployWithHorizons(uint32 s_, uint32 m_, uint32 l_) external {
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(manager)), s_, m_, l_),
            address(uint160(0x5555 << 144) | uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG))
        );
    }
}
