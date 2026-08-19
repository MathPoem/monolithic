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
    /// @param priceFeed The leg's Chainlink `AggregatorV3Interface` feed, for the fill channel to
    ///        price single-asset deposits off. Zero for the genesis legs, which predate it.
    struct Stock {
        bool enabled;
        uint16 allocationBips;
        address priceFeed;
    }

    /// @notice The admin opened a reallocation: `stock` is now a leg, with a target weight of its
    ///         own, and the pot holds none of it until the fill channel delivers.
    event ReallocationStarted(address indexed stock, uint16 allocationBips, address priceFeed);

    event Wrapped(address indexed by, address indexed to, uint256 shares);
    event Unwrapped(address indexed by, address indexed to, uint256 shares);

    error NoAssets();
    error InvalidAsset();
    error DuplicateAsset();
    error ZeroShares();
    error FirstMintTooSmall();
    error LengthMismatch();
    error InvalidAllocation();
    error ReallocationActive();
    error InvalidPriceFeed();

    /// @notice True while a reallocation is open — a leg has been listed but not yet filled.
    function reallocating() external view returns (bool);

    /// @notice Owner-only (OpenZeppelin `Ownable`; the deployer, unless transferred). List `stock` as a new leg and open the reallocation period.
    /// @dev Growth-only (D12): the leg is appended, nothing existing is touched. The pot holds zero
    ///      of it until the fill channel delivers, so `costToMint` charges nothing for it and
    ///      `proceedsOfRedeem` returns nothing — mint and redeem stay honest throughout.
    /// @param stock The new leg. Must not already be one.
    /// @param allocationBips Its target weight. Metadata only, like every other weight here.
    /// @param priceFeed The leg's Chainlink feed (`IAggregatorV3`). Recorded, not read — pricing is
    ///        the fill channel's job.
    function startReallocation(address stock, uint16 allocationBips, address priceFeed) external;

    function assets() external view returns (address[] memory);

    function assetCount() external view returns (uint256);

    /// @notice Per-leg membership flag and target weight. Auto-getter over the `stocks` mapping.
    function stocks(address stock) external view returns (bool enabled, uint16 allocationBips, address priceFeed);

    function potBalance(address asset) external view returns (uint256);

    function costToMint(uint256 shares) external view returns (uint256[] memory amounts);

    function proceedsOfRedeem(uint256 shares) external view returns (uint256[] memory amounts);

    function mint(uint256 shares, address to) external returns (uint256[] memory paid);

    function redeem(uint256 shares, address to) external returns (uint256[] memory got);
}
