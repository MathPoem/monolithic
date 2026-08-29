// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The slice of a Uniswap v3 pool needed to read a price. `sqrtPriceX96` IS the price —
///         no oracle wrapper, no aggregator interface.
/// @dev STUB. The real machine pool is v4 MONO/INDEX with the TWAP accumulator living in our own
///      hook (HANDBOOK §3.6), and that hook does not exist yet. This is a placeholder so the
///      auction can be built against a price source in the meantime.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}
