// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IIndex
/// @notice ABI surface of the basket wrapper (HANDBOOK §5) — the structs, events, errors and
///         functions a caller or an indexer has to decode.
/// @dev The ERC20 half of the surface (`name`, `symbol`, `transfer`, …) is solady's and is not
///      redeclared here; this interface is the Index-specific half only.
interface IIndex {
    /// @notice A basket leg: the stock token, its target weight, and its Chainlink feed.
    /// @param asset The stock token.
    /// @param allocationBips Target weight in basis points. All legs must sum to 10_000 (100%).
    /// @param priceFeed The leg's governance-approved Chainlink feed. Set at construction;
    ///        replaceable via `setPriceFeed`.
    struct Stock {
        address asset;
        uint16 allocationBips;
        address priceFeed;
    }

    /// @notice A new leg was listed and the deficit mint channel opened for it.
    /// @param targetPerIndex The raw quantity of `stock` that has to back one INDEX (1e18 shares)
    ///        before the channel closes. Struck once, here, and never recomputed (D19).
    event ReallocationStarted(address indexed stock, uint16 allocationBips, address priceFeed, uint256 targetPerIndex);

    /// @notice The channel met its per-INDEX target and closed itself. Ordinary minting resumes.
    event ReallocationCompleted(address indexed stock, uint256 potBalance);

    /// @notice A leg's Chainlink feed was set or replaced.
    event PriceFeedSet(address indexed asset, address priceFeed);

    event Wrapped(address indexed by, address indexed to, uint256 shares);
    event Unwrapped(address indexed by, address indexed to, uint256 shares);

    error NoAssets();
    error InvalidAsset();
    error DuplicateAsset();
    error ZeroShares();
    error FirstMintTooSmall();
    error LengthMismatch();
    error InvalidAllocation();
    error InvalidPriceFeed();
    error MissingPriceFeed();
    error InvalidPrice();
    error StalePrice();
    error ReallocationActive();
    error ExceedsDeficit();
    error EmptyPot();

    /// @notice True while the deficit mint channel is open. Minting is not shut, it is repriced:
    ///         `calculateAmountOfAssetsToMintIndex` charges for the new leg alone until the target is met. `burn` stays
    ///         pro-rata throughout, so it cannot undo the channel's progress.
    function reallocating() external view returns (bool);

    /// @notice The leg the open channel is filling. Stale once `reallocating` is false.
    function pendingAsset() external view returns (address);

    /// @notice Raw units of `pendingAsset` that must back one INDEX (1e18 shares). The channel's
    ///         termination condition (D19): a quantity, not a weight, so splits and ordinary
    ///         mint/burn cannot move the goalposts.
    function targetPerIndex() external view returns (uint256);

    /// @notice Raw units of `pendingAsset` still missing. 0 when no channel is open.
    function deficit() external view returns (uint256);

    /// @notice Owner-only. Replace a leg's Chainlink feed (`IAggregatorV3`).
    /// @dev Every leg receives a feed at construction. A feed is the owner's word on what a leg is
    ///      worth — list only governance-vetted feeds (HANDBOOK eligibility rule).
    function setPriceFeed(address asset, address priceFeed) external;

    /// @notice Owner-only (standing in for the LITH vote). Apply a complete target allocation,
    ///         list its one new leg and open the deficit mint channel that fills it.
    /// @dev Growth-only, so D12 NEVER REDUCE holds: the leg is appended, nothing existing is sold,
    ///      touched, or reduced. The pot holds none of it yet, so `calculateAmountOfAssetsToMintIndex` charges nothing for
    ///      it and `proceedsOfRedeem` returns nothing until deposits arrive.
    /// @param allocation Complete post-reallocation basket. It must contain every current leg and
    ///        exactly one new leg, contain no duplicates, and sum to 10_000 basis points.
    function startReallocation(Stock[] calldata allocation) external;

    /// @notice The most INDEX `mint` will issue through the open channel right now — the amount
    ///         whose deposit lands the new leg exactly on its per-INDEX target. 0 when closed.
    /// @dev Larger than `deficit()` implies, deliberately: the deposit mints shares, and those
    ///      shares raise the absolute target too, so the closing amount is the fixed point of that
    ///      loop rather than the raw shortfall.
    function maxDeficitMint() external view returns (uint256);


    function assets() external view returns (address[] memory);

    function assetCount() external view returns (uint256);

    /// @notice Per-leg metadata. Auto-getter over the `stocks` mapping. An unlisted address
    ///         returns zeroes.
    function stocks(address stock) external view returns (address asset, uint16 allocationBips, address priceFeed);

    function indexAssetBalance(address asset) external view returns (uint256);

    function calculateAmountOfAssetsToMintIndex(uint256 shares) external view returns (uint256[] memory amounts);

    function proceedsOfRedeem(uint256 shares) external view returns (uint256[] memory amounts);

    function mint(uint256 shares, address to) external returns (uint256[] memory paid);

    /// @notice Burn INDEX and receive the caller's pro-rata slice of every basket asset.
    function burn(uint256 shares, address to) external returns (uint256[] memory got);
}
