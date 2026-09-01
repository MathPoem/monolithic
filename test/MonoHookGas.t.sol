// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MonoHook} from "../src/MonoHook.sol";
import {TestERC20} from "./TestERC20.sol";

contract MonoHookGasTest is Test {
    PoolManager manager;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest liq;
    PoolKey hooked;
    PoolKey bare;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapper = new PoolSwapTest(IPoolManager(address(manager)));
        liq = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        address flagged =
            address(uint160(0x4444 << 144) | uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "MonoHook.sol:MonoHook",
            abi.encode(IPoolManager(address(manager)), uint32(2700), uint32(7200), uint32(64800)),
            flagged
        );

        TestERC20 a = new TestERC20("A", "A");
        TestERC20 b = new TestERC20("B", "B");
        (address t0, address t1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        TestERC20(t0).mint(address(this), 1e30);
        TestERC20(t1).mint(address(this), 1e30);
        TestERC20(t0).approve(address(swapper), type(uint256).max);
        TestERC20(t1).approve(address(swapper), type(uint256).max);
        TestERC20(t0).approve(address(liq), type(uint256).max);
        TestERC20(t1).approve(address(liq), type(uint256).max);

        vm.warp(1_700_000_000);
        hooked = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(flagged));
        bare = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(address(0)));
        manager.initialize(hooked, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(bare, TickMath.getSqrtPriceAtTick(0));
        liq.modifyLiquidity(hooked, ModifyLiquidityParams(-60000, 60000, 1e21, bytes32(0)), "");
        liq.modifyLiquidity(bare, ModifyLiquidityParams(-60000, 60000, 1e21, bytes32(0)), "");
        // warm both
        _swap(hooked);
        _swap(bare);
        vm.warp(block.timestamp + 60);
    }

    function _swap(PoolKey memory k) internal {
        swapper.swap(
            k, SwapParams(true, -1e16, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    /// What the accumulator costs a swapper, measured against the identical pool with no hook.
    /// The bound is a regression guard, not a target — see `agent-docs/MonoHook.md`.
    function test_accumulatorOverheadPerSwap() public {
        // Warm every account and slot inside THIS transaction first; otherwise whichever pool is
        // measured first simply pays the cold-access bill for both.
        _swap(bare);
        _swap(hooked);
        vm.warp(block.timestamp + 60);

        uint256 g0 = gasleft();
        _swap(bare);
        uint256 bareGas = g0 - gasleft();
        vm.warp(block.timestamp + 60);
        g0 = gasleft();
        _swap(hooked);
        uint256 hookGas = g0 - gasleft();
        emit log_named_uint("bare swap  ", bareGas);
        emit log_named_uint("hooked swap", hookGas);
        uint256 overhead = hookGas - bareGas;
        emit log_named_uint("overhead   ", overhead);
        assertLt(overhead, 25_000, "accumulator got materially more expensive");
    }
}
