// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IIndex
/// @notice ABI surface of the basket wrapper (HANDBOOK §5) — the structs, events, errors and
///         functions a caller or an indexer has to decode.
/// @dev The ERC20 half of the surface (`name`, `symbol`, `transfer`, …) is solady's and is not
///      redeclared here; this interface is the Index-specific half only.
interface IIndex {
    /// @notice A pot leg: whether it is one of the basket's assets, and its target weight.
    /// @param enabled True for every address in `assets()` and nothing else — the O(1) membership
    ///        test for that array. Never cleared; false means "not a leg", not "suspended".
    /// @param allocationBips Target weight in basis points, summing to 10_000 across the legs.
    ///        Metadata only: mint and redeem price pro-rata off live `balanceOf`, never off this.
    struct Stock {
        bool enabled;
        uint16 allocationBips;
    }

    event Wrapped(address indexed by, address indexed to, uint256 shares);
    event Unwrapped(address indexed by, address indexed to, uint256 shares);

    error NoAssets();
    error InvalidAsset();
    error DuplicateAsset();
    error ZeroShares();
    error FirstMintTooSmall();
    error LengthMismatch();
    error InvalidAllocation();

    function assets() external view returns (address[] memory);

    function assetCount() external view returns (uint256);

    /// @notice Per-leg membership flag and target weight. Auto-getter over the `stocks` mapping.
    function stocks(address stock) external view returns (bool enabled, uint16 allocationBips);

    function potBalance(address asset) external view returns (uint256);

    function costToMint(uint256 shares) external view returns (uint256[] memory amounts);

    function proceedsOfRedeem(uint256 shares) external view returns (uint256[] memory amounts);

    function mint(uint256 shares, address to) external returns (uint256[] memory paid);

    function redeem(uint256 shares, address to) external returns (uint256[] memory got);
}
