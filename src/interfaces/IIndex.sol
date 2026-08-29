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

    /// @notice An authorised sale campaign: the pot may sell `sellToken` into `buyToken` in clips.
    /// @dev Bounds live here rather than in the caller, because the caller is a keeper arming a
    ///      60-second quote and cannot itself be timelocked. What the vote authorises is this
    ///      struct; what the keeper chooses is only *when*, inside it.
    /// @param buyToken The replacement stock. Must be listed, so the proceeds land inside
    ///        `_assets` and NAV is continuous across settlement. Zero means no open campaign.
    /// @param dailyCap Raw units of `sellToken` that may be armed per 24h window. The blast radius
    ///        if the keeper key is lost.
    /// @param soldToday Raw units armed inside the current window.
    /// @param windowStart When the current 24h window opened.
    /// @param maxSlipBips Worst price the pot will sign, against its own feeds.
    struct Sale {
        address buyToken;
        uint256 dailyCap;
        uint256 soldToday;
        uint256 windowStart;
        uint16 maxSlipBips;
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

    /// @notice A `burn` leg could not be transferred (frozen token, blocklisted recipient) and was
    ///         booked to `owner`'s claim ledger instead of being paid out. Collect it with `claim`
    ///         once the token moves again. Nothing is forfeited and nothing is lost.
    /// @param owner The `to` of the burn — the address the leg is claimable by.
    event LegDeferred(address indexed owner, address indexed asset, uint256 amount);

    /// @notice A deferred leg was collected.
    event Claimed(address indexed owner, address indexed asset, address indexed to, uint256 amount);

    /// @notice The in-kind mint fee changed. Rate is per 100_000 (see `feeRate`).
    event FeeRateSet(uint256 feeRate);

    /// @notice Collected fee swept to `to` by the owner.
    event FeesWithdrawn(address indexed asset, address indexed to, uint256 amount);

    /// @notice A timelocked call was queued. `eta` is the earliest timestamp it can execute.
    /// @param id `keccak256(data)` — the handle for `cancel` and `execute`.
    event Queued(bytes32 indexed id, bytes data, uint256 eta);

    /// @notice A queued call was dropped before executing.
    event Cancelled(bytes32 indexed id);

    /// @notice A queued call ran after its notice period.
    event Executed(bytes32 indexed id);

    /// @notice A stock was removed from the basket and its pot balance handed to `to`.
    event FireEscaped(address indexed asset, address indexed to, uint256 amount);

    /// @notice A sale campaign was authorised: `sellToken` may now be sold down into `buyToken`.
    event SaleOpened(address indexed sellToken, address indexed buyToken, uint256 dailyCap, uint16 maxSlipBips);

    /// @notice A sale campaign was revoked. Any armed intent dies with it.
    event SaleClosed(address indexed sellToken);

    /// @notice The pot vouched for one Arcus intent. `digest` is what Permit2 will ask about.
    event SaleArmed(
        bytes32 indexed digest,
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 deadline
    );

    /// @notice The armed intent was dropped before its deadline.
    event SaleDisarmed(bytes32 indexed digest);

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
    error NothingOwed();
    error FeeTooHigh();
    error AlreadyQueued();
    error NotQueued();
    error TimelockPending();
    error NotTimelocked();
    error LastAsset();
    error NoOpenSale();
    error SaleCapExceeded();
    error SlippageTooWide();
    error PriceFloorTooLow();
    error IntentExpired();
    error IntentTooLong();
    error SaleExceedsBalance();

    /// @notice True while the deficit mint channel is open. Minting is not shut, it is repriced:
    ///         `calculateAmountOfAssetsToMintIndex` charges for the new stock alone until the target is met. `burn` stays
    ///         pro-rata throughout, so it cannot undo the channel's per-INDEX progress.
    function reallocating() external view returns (bool);

    /// @notice The stock the open channel is filling. Stale once `reallocating` is false.
    function pendingAsset() external view returns (address);

    /// @notice Raw units of `pendingAsset` that must back one INDEX (1e18 shares). The channel's
    ///         termination condition (D19): a quantity, not a weight, so splits and ordinary
    ///         mint/burn cannot move the goalposts.
    function targetPerIndex() external view returns (uint256);

    /// @notice Raw units of `pendingAsset` still missing. 0 when no channel is open.
    function deficit() external view returns (uint256);

    /// @notice Notice period every timelocked change serves before it can execute.
    function TIMELOCK_DELAY() external view returns (uint256);

    /// @notice When a queued call was queued, by `keccak256(data)`. Zero if not queued.
    function queuedAt(bytes32 id) external view returns (uint256);

    /// @notice Owner-only. Start the clock on a timelocked call.
    /// @dev `data` is an ABI-encoded call to one of this contract's `timelocked` functions —
    ///      `addStock` or `setFeeRate`. Identical calldata cannot be queued twice at once; wait for
    ///      the first to execute or cancel it.
    /// @return id `keccak256(data)`, the handle for `cancel` and `execute`.
    function queue(bytes calldata data) external returns (bytes32 id);

    /// @notice Owner-only. Drop a queued call before it executes.
    function cancel(bytes calldata data) external;

    /// @notice Owner-only. Run a queued call once its notice period has elapsed.
    /// @dev Reverts with the target's own error if the underlying call fails, so a queued change
    ///      that has become invalid fails legibly rather than as an opaque call failure.
    function execute(bytes calldata data) external returns (bytes memory result);

    /// @notice Owner-only. Replace a stock's Chainlink feed (`IAggregatorV3`).
    /// @dev Every stock receives a feed at construction. A feed is the owner's word on what a stock is
    ///      worth — list only governance-vetted feeds (HANDBOOK eligibility rule).
    function setPriceFeed(address asset, address priceFeed) external;

    /// @notice Timelocked (standing in for the LITH vote). List one new stock and open the deficit
    ///         mint channel that fills it. Reachable only via `queue` then `execute`.
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

    function calculateAmountOfAssetsToMintIndex(uint256 shares) external view returns (uint256[] memory amounts);

    function proceedsOfRedeem(uint256 shares) external view returns (uint256[] memory amounts);

    function mint(uint256 shares, address to) external returns (uint256[] memory paid);

    /// @notice Burn INDEX and receive the caller's pro-rata slice of every basket asset.
    /// @dev A leg whose transfer fails is not fatal: it is booked to `to`'s claim ledger (see
    ///      `LegDeferred` / `claim`) so one frozen stock cannot hold the other legs hostage.
    /// @return got Raw units actually TRANSFERRED per stock, in `assets()` order. A deferred leg
    ///         reads 0 here — read `owed` for it, or an integrator will over-credit the redeemer.
    function burn(uint256 shares, address to) external returns (uint256[] memory got);

    /// @notice Timelocked. Emergency exit for a terminal stock (FIRE-ESCAPE.md): removes `asset`
    ///         from the basket and transfers the pot's balance of it to the owner, who liquidates
    ///         it off-chain and returns value by transferring replacement stock back in.
    /// @dev Both sides of the composition move in the same transaction — mint and redeem both read
    ///      `_assets` — so there is no window in which they disagree and no money pump.
    ///
    ///      Only the pot's OWN balance leaves. `reserved` (claimants' deferred legs) and `fees`
    ///      are netted out and stay behind, and `claim` / `withdrawFees` keep working on a removed
    ///      asset because they read `owed` / `fees` rather than `_assets`.
    ///
    ///      This deviates from FIRE-ESCAPE.md, which requires a governance-only caller, a per-clip
    ///      cap, and a vote naming the asset. Here the owner takes the whole balance after the
    ///      timelock. The notice period is the only protection holders get.
    /// @param asset The stock to remove. Must be listed, must not be the last one, and no channel
    ///        may be open.
    /// @return amount Raw units transferred out.
    function fireEscape(address asset) external returns (uint256 amount);

    /// @notice The open sale campaign for `sellToken`, if any.
    function sales(address sellToken)
        external
        view
        returns (address buyToken, uint256 dailyCap, uint256 soldToday, uint256 windowStart, uint16 maxSlipBips);

    /// @notice The single Permit2 digest the pot currently vouches for. Zero means none.
    function armedIntent() external view returns (bytes32);

    /// @notice Authorise selling `sellToken` down into `buyToken`. Timelocked.
    /// @dev FIRE-ESCAPE.md Mode 1, executed from inside the pot instead of through a desk. Both
    ///      tokens must be listed: the sell leg leaves and the buy leg arrives in ONE settlement
    ///      transaction, so as long as both are in `_assets`, `_potValue` never sees a hole and
    ///      there is no "in transit" slice invisible to redeemers.
    /// @param sellToken The stock being wound down. Must be listed.
    /// @param buyToken The replacement. Must be listed and different from `sellToken`.
    /// @param dailyCap Raw units of `sellToken` armable per 24h. Non-zero.
    /// @param maxSlipBips Worst acceptable price against the feeds. Hard-capped by the contract.
    function openSale(address sellToken, address buyToken, uint256 dailyCap, uint16 maxSlipBips) external;

    /// @notice Revoke the campaign for `sellToken` and kill any armed intent. Timelocked.
    function closeSale(address sellToken) external;

    /// @notice Vouch for one Arcus intent, and let Permit2 pull that clip.
    /// @dev The terms go in and the digest comes out — the pot rebuilds the EIP-712 digest itself
    ///      rather than stamping an opaque hash, so the keeper cannot sign terms the campaign did
    ///      not authorise. `minBuyAmount` is floored against the pot's own Chainlink feeds, which
    ///      is what stops a keeper selling the basket cheaply to a friendly maker.
    ///      Take `nonce` and `deadline` from the router's quote; they are Permit2's, not ours.
    /// @return digest The Permit2 digest now armed. The caller must check it against the digest it
    ///         derived from the quote before submitting anything.
    function armSale(address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256 nonce, uint256 deadline)
        external
        returns (bytes32 digest);

    /// @notice The least `buyToken` the pot will accept for `sellAmount` of `sellToken`, priced
    ///         off its own Chainlink feeds and the campaign's `maxSlipBips`.
    /// @dev Reverts if no campaign is open, or if either feed is missing or stale — `armSale`
    ///      therefore fails closed on a bad oracle rather than signing against one. Also what the
    ///      off-chain keeper reads to build `minBuyAmount` before it asks the router for a quote.
    function saleFloor(address sellToken, uint256 sellAmount) external view returns (uint256);

    /// @notice Drop the armed intent and revoke `sellToken`'s Permit2 allowance.
    function disarmSale(address sellToken) external;

    /// @notice ERC-1271. Permit2 calls this with the digest it computed; a match means the terms
    ///         it is about to enforce are the terms `armSale` authorised.
    /// @dev The signature bytes are ignored. There is no key here — `armedIntent` is the signature.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

    /// @notice Raw units of `asset` that `owner`'s past burns booked but never received.
    function owed(address owner, address asset) external view returns (uint256);

    /// @notice Raw units of `asset` sitting in the contract that belong to claimants, not to the
    ///         pot. Every valuation nets this out of the raw balance, so an uncollected leg can
    ///         never be paid twice — once to its claimant and once to the next redeemer.
    function reserved(address asset) external view returns (uint256);

    /// @notice The in-kind fee charged on ordinary mint (P7). Burn is free.
    /// @dev NOT basis points. The denominator is 100_000, so `1755` = 1.755% and `50` = 0.05%.
    ///      Hard-capped at 5_000 (5%) on every set. Starts at 0 — a deployment charges nothing
    ///      until the owner sets a rate.
    ///
    ///      Charged in kind on the way IN only: a mint pays `1 + feeRate` of its pro-rata cost, and
    ///      the surplus is booked to `fees`, which every pot valuation nets out. So it is not holder
    ///      accretion — NAV per share is flat across a fee-charging mint and flat again when the
    ///      owner sweeps. `burn` is untouched: a redeemer receives their full pro-rata slice.
    ///      Two mints are exempt:
    ///      - the genesis wrap (empty pot) is exempt — there are no holders for it to accrue to;
    ///      - deficit-channel mints are exempt, they pay the 1% D20 haircut instead. This answers
    ///        `human-docs/discrepancies.md` E8: P7 is NOT additive to the haircut.
    function feeRate() external view returns (uint256);

    /// @notice Timelocked. Set the in-kind fee rate. Reverts above 5_000 (5%). Holders get
    ///         `TIMELOCK_DELAY` of notice before a rate change can land.
    /// @param feeRate_ The new rate, per 100_000.
    function setFeeRate(uint256 feeRate_) external;

    /// @notice Fee of `asset` collected and not yet withdrawn. Never counted as pot backing.
    function fees(address asset) external view returns (uint256);

    /// @notice Owner-only. Sweep collected fees. Reaches `fees` only — the pot's own balance and
    ///         claimants' `reserved` legs are not withdrawable by anyone, including the owner.
    /// @param assets_ Assets to sweep. Reverts if any has nothing collected.
    /// @param to Recipient.
    function withdrawFees(address[] calldata assets_, address to) external returns (uint256[] memory amounts);

    /// @notice Collect deferred legs. Reverts if any listed asset owes the caller nothing, so a
    ///         repeated asset in one call cannot double-spend and a stale list fails loudly.
    /// @param assets_ The assets to collect. A still-frozen token reverts and stays on the books.
    /// @param to Recipient of the collected legs.
    function claim(address[] calldata assets_, address to) external returns (uint256[] memory amounts);
}
