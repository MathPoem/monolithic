// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MonoAuction} from "../src/MonoAuction.sol";

/// @dev Stands in for the v4 hook that does not exist yet. `sqrtPriceX96 = 2^96` is price 1.0,
///      `2 * 2^96` is price 4.0 — exact integers, so the expectations need no sqrt.
contract MockPool {
    address public token0;
    uint160 internal sqrtPriceX96;

    constructor(address token0_, uint160 sqrtPriceX96_) {
        token0 = token0_;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }
}

contract MockMono {
    uint256 public nav;

    constructor(uint256 nav_) {
        nav = nav_;
    }
}

contract MonoPriceTest is Test {
    uint160 internal constant Q96 = uint160(1) << 96;

    function _auction(bool monoIsToken0, uint160 sqrtPriceX96, uint256 nav)
        internal
        returns (MonoAuction)
    {
        address mono = address(new MockMono(nav));
        address token0 = monoIsToken0 ? mono : address(0xdead);
        return new MonoAuction(address(new MockPool(token0, sqrtPriceX96)), mono, address(0xbeef), 1e18, 1, 16);
    }

    function test_priceWhenMonoIsToken0() public {
        assertEq(_auction(true, Q96, 1e18).monoPrice(), 1e18);
        assertEq(_auction(true, 2 * Q96, 1e18).monoPrice(), 4e18);
    }

    /// @dev The inversion is the whole reason ordering is read off the pool instead of passed in.
    function test_priceWhenMonoIsToken1() public {
        assertEq(_auction(false, Q96, 1e18).monoPrice(), 1e18);
        assertEq(_auction(false, 2 * Q96, 1e18).monoPrice(), 0.25e18);
    }

    function test_orderingIsDerivedFromPool() public {
        assertTrue(_auction(true, Q96, 1e18).monoIsToken0());
        assertFalse(_auction(false, Q96, 1e18).monoIsToken0());
    }

    function test_premiumIsPriceOverNav() public {
        // price 4.0, NAV 1.0 → premium 3.0
        assertEq(_auction(true, 2 * Q96, 1e18).premium(), 3e18);
    }

    /// @dev Below NAV the premium is 0, not negative — the wall's job, not the harvest's.
    function test_premiumFloorsAtZeroBelowNav() public {
        assertEq(_auction(true, Q96, 4e18).premium(), 0);
        assertEq(_auction(true, Q96, 1e18).premium(), 0);
    }

    function test_navIsReadFromTheVault() public {
        assertEq(_auction(true, Q96, 7e18).nav(), 7e18);
    }
}
