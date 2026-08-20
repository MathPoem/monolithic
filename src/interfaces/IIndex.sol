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

    /// @notice A new leg was listed and the deficit mint channel opened for it.
    /// @param targetPerIndex The raw quantity of `stock` that has to back one INDEX (1e18 shares)
    ///        before the channel closes. Struck once, here, and never recomputed (D19).
    event ReallocationStarted(address indexed stock, uint16 allocationBips, address priceFeed, uint256 targetPerIndex);

    /// @notice The channel met its per-INDEX target and closed itself. Ordinary minting resumes.
    event ReallocationCompleted(address indexed stock, uint256 potBalance);

    /// @notice A leg was marked for removal and the surplus redeem channel opened for it.
    event RemovalStarted(address indexed stock, uint256 potBalance);

    /// @notice A burn through the open removal channel, paid entirely in the exiting leg.
    event SurplusRedeemed(address indexed by, address indexed to, uint256 shares, uint256 amountOut);

    /// @notice The exiting leg was drained and delisted. Ordinary redemption resumes.
    event RemovalCompleted(address indexed stock);

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
    error RemovalActive();
    error NoRemoval();
    error SurplusExhausted();
    error LastAsset();

    /// @notice True while the deficit mint channel is open. Minting is not shut, it is repriced:
    ///         `costToMint` charges for the new leg alone until the target is met. `redeem` stays
    ///         pro-rata throughout, so it cannot undo the channel's progress.
    function reallocating() external view returns (bool);

    /// @notice The leg the open channel is filling. Stale once `reallocating` is false.
    function pendingAsset() external view returns (address);

    /// @notice Raw units of `pendingAsset` that must back one INDEX (1e18 shares). The channel's
    ///         termination condition (D19): a quantity, not a weight, so splits and ordinary
    ///         mint/redeem cannot move the goalposts.
    function targetPerIndex() external view returns (uint256);

    /// @notice Raw units of `pendingAsset` still missing. 0 when no channel is open.
    function deficit() external view returns (uint256);

    /// @notice True while the surplus redeem channel is open. Ordinary `mint` AND `redeem` are
    ///         shut; the only way out is `redeemSurplus`, which pays in the exiting leg alone.
    function removing() external view returns (bool);

    /// @notice The leg the open removal channel is draining. Stale once `removing` is false.
    function exitingAsset() external view returns (address);

    /// @notice Raw units of `exitingAsset` still in the pot. 0 when no removal is open.
    function surplus() external view returns (uint256);

    /// @notice The largest `shares` a `redeemSurplus` call can burn right now — the amount whose
    ///         payout is exactly what is left of the exiting leg. Ask for more and it reverts.
    function maxSurplusRedeem() external view returns (uint256);

    /// @notice Owner-only (standing in for the LITH vote). Mark `stock` for removal and open the
    ///         channel that drains it.
    /// @dev The mirror of `startReallocation`. This is a composition REDUCTION — D12 NEVER REDUCE
    ///      does not sanction it outside the fire escape, and it is here by explicit instruction.
    ///      What it does preserve is the other half of the covenant: the protocol never trades. The
    ///      pot takes no venue risk, pays no slippage and picks no moment — holders take delivery of
    ///      the exiting stock and sell it themselves, on their own terms.
    /// @param stock The leg to drain. Must be a current leg, and not the only one.
    function startRemoval(address stock) external;

    /// @notice Burn INDEX and be paid ONLY in the leg being removed.
    /// @dev Priced like the deficit channel and mirrored: pot value per INDEX from every leg's feed,
    ///      the payout converted at the exiting leg's own feed, less the D20 1% haircut — so the
    ///      redeemer, not the remaining holders, carries any oracle error.
    ///
    ///      Every burn moves the exiting leg's per-INDEX quantity down and every other leg's UP:
    ///      the whole payout comes out of one leg while supply falls against all of them. When the
    ///      leg is drained the channel closes, the leg is delisted, and ordinary redemption resumes.
    /// @param shares INDEX to burn. Reverts if the payout would exceed what is left of the leg —
    ///        size it with `maxSurplusRedeem`.
    /// @param to Who receives the exiting stock.
    function redeemSurplus(uint256 shares, address to) external returns (uint256 amountOut);

    /// @notice Owner-only. Set or replace a leg's Chainlink feed (`IAggregatorV3`).
    /// @dev Needed before the first reallocation: the genesis legs were listed without one, and the
    ///      channel prices the pot bottom-up off every leg's feed. A feed is the owner's word on
    ///      what a leg is worth — list only governance-vetted feeds (HANDBOOK eligibility rule).
    function setPriceFeed(address asset, address priceFeed) external;

    /// @notice Owner-only (standing in for the LITH vote). List `stock` as a new leg and open the
    ///         deficit mint channel that fills it.
    /// @dev Growth-only, so D12 NEVER REDUCE holds: the leg is appended, nothing existing is sold,
    ///      touched, or reduced. The pot holds none of it yet, so `costToMint` charges nothing for
    ///      it and `proceedsOfRedeem` returns nothing until deposits arrive.
    /// @param stock The new leg. Must not already be one.
    /// @param allocationBips The weight it should end up at, below 10_000. Converted here, once,
    ///        into the per-INDEX raw quantity that actually terminates the channel.
    /// @param priceFeed The new leg's Chainlink feed.
    function startReallocation(address stock, uint16 allocationBips, address priceFeed) external;

    /// @notice The most INDEX `mint` will issue through the open channel right now — the amount
    ///         whose deposit lands the new leg exactly on its per-INDEX target. 0 when closed.
    /// @dev Larger than `deficit()` implies, deliberately: the deposit mints shares, and those
    ///      shares raise the absolute target too, so the closing amount is the fixed point of that
    ///      loop rather than the raw shortfall.
    function maxDeficitMint() external view returns (uint256);


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
