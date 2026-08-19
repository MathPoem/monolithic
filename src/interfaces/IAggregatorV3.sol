// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAggregatorV3
/// @notice Chainlink's `AggregatorV3Interface`, verbatim — the price-feed ABI every listed leg's
///         feed has to answer to. Declared here rather than pulled in as a dependency because it is
///         five signatures and no code.
/// @dev `answer` carries the feed's own `decimals()`, not 18 — scale before using it. A consumer
///      must also check `updatedAt` for staleness and `answeredInRound >= roundId`; this repo does
///      neither yet (the P6j fill channel is where that guard belongs).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
