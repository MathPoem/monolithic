// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Quote leg of a `MockPool`. The pot only ever reads its decimals, never moves it.
contract MockStable {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @notice Uniswap v3 pool stand-in: an ordered token pair and a settable spot price.
/// @dev Prices go in as 1e18 USD per whole `stock` and come out as `sqrtPriceX96`, so tests read
///      in dollars instead of Q96. Token order mirrors Uniswap's address sort, which means both
///      branches of `Index._poolPrice` get exercised depending on where the mocks land.
contract MockPool {
    address public token0;
    address public token1;
    address internal immutable stock;
    uint160 internal sqrtPriceX96;
    uint256 internal usd;
    /// @dev In-range `L`. Big enough by default that `premiumCloseAmount` returns a real number;
    ///      set it to 0 to stand in for a pool with nothing in the active tick.
    uint128 public liquidity = 1e24;

    constructor(address stock_, address quote, uint256 usd18) {
        stock = stock_;
        (token0, token1) = stock_ < quote ? (stock_, quote) : (quote, stock_);
        setPrice(usd18);
    }

    /// @notice Swap which side of the pair the stock sits on, holding the dollar price fixed.
    /// @dev Uniswap sorts by address, so which branch of `Index._poolPrice` runs is an accident of
    ///      deployment. This makes the other branch reachable on demand.
    function flip() external {
        (token0, token1) = (token1, token0);
        setPrice(usd);
    }

    /// @param usd18 USD per whole unit of the stock, 18 decimals. $200 is `200e18`.
    function setPrice(uint256 usd18) public {
        usd = usd18;
        address quote = stock == token0 ? token1 : token0;
        uint256 stockUnit = 10 ** IDecimals(stock).decimals();
        uint256 quoteUnit = 10 ** IDecimals(quote).decimals();

        // Raw token1 per raw token0 in Q192, square-rooted down into Q96.
        uint256 ratioX192 = stock == token0
            ? FixedPointMathLib.fullMulDiv(usd18 * quoteUnit, 1 << 192, 1e18 * stockUnit)
            : FixedPointMathLib.fullMulDiv(1e18 * stockUnit, 1 << 192, usd18 * quoteUnit);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(ratioX192));
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }
}
