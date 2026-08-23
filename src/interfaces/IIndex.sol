// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IIndex
/// @notice ABI surface of the basket wrapper (HANDBOOK §5) — the structs, events, errors and
///         functions a caller or an indexer has to decode.
/// @dev The ERC20 half of the surface (`name`, `symbol`, `transfer`, …) is solady's and is not
///      redeclared here; this interface is the Index-specific half only.
interface IIndex {
    /// @notice A basket stock: the token, its target weight, and its Chainlink feed.
    /// @param asset The stock token.
    /// @param allocationBips Target weight in basis points. All stocks must sum to 10_000 (100%).
    /// @param priceFeed The stock's governance-approved Chainlink feed. Set at construction;
    ///        replaceable via `setPriceFeed`.
    struct Stock {
        address asset;
        uint16 allocationBips;
        address priceFeed;
    }

    /// @notice A new stock was listed and the deficit mint channel opened for it.
    /// @param targetPerIndex The raw quantity of `stock` that has to back one INDEX (1e18 shares)
    ///        before the channel closes. Struck once, here, and never recomputed (D19).
    event StockAdded(address indexed stock, uint16 allocationBips, address priceFeed, uint256 targetPerIndex);

    /// @notice The channel met its per-INDEX target and closed itself. Ordinary minting resumes.
    event ReallocationCompleted(address indexed stock, uint256 potBalance);

    /// @notice A stock's Chainlink feed was set or replaced.
    event PriceFeedSet(address indexed asset, address priceFeed);

    event Wrapped(address indexed by, address indexed to, uint256 shares);
    event Unwrapped(address indexed by, address indexed to, uint256 shares);

    error NoAssets();
    error InvalidAsset();
    error DuplicateAsset();
    error ZeroShares();
    error FirstMintTooSmall();
    error InvalidAllocation();
    error InvalidPriceFeed();
    error MissingPriceFeed();
    error InvalidPrice();
    error StalePrice();
    error ReallocationActive();
    error ExceedsDeficit();
    error EmptyPot();

    /// @notice True while the deficit mint channel is open. Minting is not shut, it is repriced:
    ///         `calculateAmountOfAssetsToMintIndex` charges for the new stock alone until the target is met. `burn` stays
    ///         pro-rata throughout, so it cannot undo the channel's progress.
    function reallocating() external view returns (bool);

    /// @notice The stock the open channel is filling. Stale once `reallocating` is false.
    function pendingAsset() external view returns (address);

    /// @notice Raw units of `pendingAsset` that must back one INDEX (1e18 shares). The channel's
    ///         termination condition (D19): a quantity, not a weight, so splits and ordinary
    ///         mint/burn cannot move the goalposts.
    function targetPerIndex() external view returns (uint256);

    /// @notice Raw units of `pendingAsset` still missing. 0 when no channel is open.
    function deficit() external view returns (uint256);

    /// @notice Owner-only. Replace a stock's Chainlink feed (`IAggregatorV3`).
    /// @dev Every stock receives a feed at construction. A feed is the owner's word on what a stock is
    ///      worth — list only governance-vetted feeds (HANDBOOK eligibility rule).
    function setPriceFeed(address asset, address priceFeed) external;

    /// @notice Owner-only (standing in for the LITH vote). List one new stock and open the deficit
    ///         mint channel that fills it.
    /// @dev Growth-only, so D12 NEVER REDUCE holds: the stock is appended, nothing existing is sold
    ///      or removed from the pot. Incumbent target weights are rescaled down proportionally to
    ///      make room; rounding dust lands on the first incumbent. The pot holds none of the new
    ///      stock yet, so `calculateAmountOfAssetsToMintIndex` charges nothing for it and
    ///      `proceedsOfRedeem` returns nothing until deposits arrive.
    /// @param stock The stock to list. Must not already be in the basket. `allocationBips` is its
    ///        post-add target weight; incumbent weights shrink to fit.
    function addStock(Stock calldata stock) external;

    /// @notice The most INDEX `mint` will issue through the open channel right now — the amount
    ///         whose deposit lands the new stock exactly on its per-INDEX target. 0 when closed.
    /// @dev Larger than `deficit()` implies, deliberately: the deposit mints shares, and those
    ///      shares raise the absolute target too, so the closing amount is the fixed point of that
    ///      loop rather than the raw shortfall.
    function deficitToMint() external view returns (uint256);


    function assets() external view returns (address[] memory);

    function assetCount() external view returns (uint256);

    /// @notice Per-stock metadata. Auto-getter over the `stocks` mapping. An unlisted address
    ///         returns zeroes.
    function stocks(address stock) external view returns (address asset, uint16 allocationBips, address priceFeed);

    function indexAssetBalance(address asset) external view returns (uint256);

    function calculateAmountOfAssetsToMintIndex(uint256 shares) external view returns (uint256[] memory amounts);

    function proceedsOfRedeem(uint256 shares) external view returns (uint256[] memory amounts);

    function mint(uint256 shares, address to) external returns (uint256[] memory paid);

    /// @notice Burn INDEX and receive the caller's pro-rata slice of every basket asset.
    function burn(uint256 shares, address to) external returns (uint256[] memory got);
}
