// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Mono} from "../Mono.sol";

/// @title IMonoAuction
/// @notice Public surface of `src/MonoAuction.sol`: the geometric pay-as-bid tick book behind a
///         multi-market wrapper, bid in INDEX.
/// @dev Types, events and errors live here so the ABI has one definition. `Market` is not here:
///      it holds mappings, never crosses the ABI boundary, and so stays in the implementation.
///      See `agent-docs/MonoAuction.md` for the mechanism.
interface IMonoAuction {
    // ---------------------------------------------------------------- types

    /// @notice A price level in one market's persistent book.
    /// @dev `survival` and `epoch` are the depletion index. Nothing about a round boundary
    ///      touches them — that is the whole point.
    struct Tick {
        uint256 next; // next higher price (0 = none)
        uint256 prev; // next lower price (0 = none)
        uint256 demand; // live escrow here; always >= the sum of live positions
        uint256 survival; // Q128, scaled by (1 - filledFraction) on every partial fill
        uint64 epoch; // bumped on a 100% fill, where `survival` resets to SURVIVAL_ONE
        bool init;
    }

    /// @notice One bidder's standing offer at one price. Survives rounds untouched.
    struct Position {
        uint128 amount; // escrow as of `survivalAtEntry`; live escrow is derived, not stored
        uint128 tokensOwed; // harvested, unclaimed
        uint256 survivalAtEntry;
        uint64 epoch;
    }

    // ---------------------------------------------------------------- events

    event MarketCreated(uint256 indexed marketId, address token, address currency, uint256 floorPrice);
    event SupplyFunded(uint256 indexed marketId, uint128 amount);
    event RoundOpened(uint256 indexed marketId, uint64 indexed round, uint128 supply, uint64 endBlock);
    event BidSubmitted(uint256 indexed marketId, address indexed owner, uint256 indexed price, uint128 amount);
    event BidWithdrawn(uint256 indexed marketId, address indexed owner, uint256 indexed price, uint128 amount);
    event TickFilled(uint256 indexed marketId, uint256 indexed price, uint256 currencyFilled, bool marginal);
    event Settled(uint256 indexed marketId, uint64 indexed round, uint128 unsold);
    event Claimed(uint256 indexed marketId, address indexed owner, uint256 indexed price, uint128 tokens);
    event CurrencySwept(uint256 indexed marketId, address to, uint256 amount);
    event UnsoldTokensSwept(uint256 indexed marketId, address to, uint256 amount);

    // ---------------------------------------------------------------- errors

    error MarketNotFound();
    error InvalidParams();
    error NoOpenRound();
    error RoundStillOpen();
    error RoundOver();
    error RoundNotOver();
    error AlreadySettled();
    error SettleIncomplete();
    error BidTooLow();
    error BidTooHigh();
    error BidTooSmall();
    error TickNotAligned();
    error TickSpacingTooSmall();
    error BadPrevHint();
    error InvalidAmount();
    error NoPosition();
    error InvalidDecay();
    error InvalidWindow();
    error WindowTooNarrow();

    // ---------------------------------------------------------------- config

    /// @notice Bid prices must be a multiple of this. Set once at deploy; every market on this
    ///         contract shares the one grid.
    function tickSpacing() external view returns (uint256);

    /// @notice Per-tick decay `q`, in Q96. `Q96` is 1.0 (flat split); smaller concentrates supply
    ///         at the top of the book.
    function decayQ() external view returns (uint256);

    /// @notice How many grid steps below the top of book still receive supply. Also the size
    ///         bound on a settle window.
    function windowTicks() external view returns (uint256);

    /// @notice The v3 pool MONO's price is read from, and whether MONO is its token0.
    function monoPool() external view returns (address);
    function monoIsToken0() external view returns (bool);

    /// @notice The MONO token, which is also the vault. Source of NAV.
    function mono() external view returns (Mono);

    /// @notice The one currency bids may be placed and escrowed in: the INDEX basket token.
    function index() external view returns (address);

    // ---------------------------------------------------------------- state

    function nextMarketId() external view returns (uint256);

    /// @notice Assets owed to markets (escrowed supply + live bids + unswept proceeds). A balance
    ///         above this is unspoken-for and is the only thing a new market may claim.
    function reserved(address asset) external view returns (uint256);

    // ---------------------------------------------------------------- prices

    /// @notice Spot price of 1 MONO in the pool's other token, 18 decimals.
    function monoPrice() external view returns (uint256);

    /// @notice Backing per MONO, in INDEX, 18 decimals — the floor.
    function nav() external view returns (uint256);

    /// @notice `price − NAV`, floored at 0. The number the strike is a share of.
    function premium() external view returns (uint256);

    // ---------------------------------------------------------------- market setup

    /// @notice Open a new market: one token, one floor, one persistent book. No round is open
    ///         yet; call `fund` and `openRound`.
    function createMarket(
        address token,
        address fundsRecipient,
        address tokensRecipient,
        uint256 floorPrice,
        uint64 idleBlocks_
    ) external returns (uint256 marketId);

    /// @notice Add sellable supply. Transfer the tokens in first; this only counts balance that
    ///         is not already owed to another market.
    function fund(uint256 marketId, uint128 amount) external;

    /// @notice Open the next selling round over the existing book. Copies nothing; O(1).
    function openRound(uint256 marketId, uint64 endBlock) external;

    // ---------------------------------------------------------------- bidding

    /// @notice Bid at `price`, escrowing `amount` of INDEX.
    /// @param owner Who controls and is paid by the position. May differ from `msg.sender`.
    /// @param prevTick Search hint: any initialized tick strictly below `price`.
    function submitBid(uint256 marketId, uint256 price, uint128 amount, address owner, uint256 prevTick) external;

    /// @notice Take back everything still live at `(msg.sender, price)`. Tokens already won stay
    ///         claimable.
    function withdrawBid(uint256 marketId, uint256 price) external returns (uint256 live);

    // ---------------------------------------------------------------- settle

    /// @notice Distribute the round's supply across the book by geometric weight. Permissionless
    ///         at or after `endBlock`, or early after `idleBlocks` of silence.
    /// @param maxTicks Budget in list nodes visited, not work inside a window. Resumable.
    function settle(uint256 marketId, uint256 maxTicks) external;

    // ---------------------------------------------------------------- payouts

    /// @notice Collect the tokens accrued at `(owner, price)`. Does NOT close the position.
    function claim(uint256 marketId, address owner, uint256 price) external returns (uint128 tokens);

    /// @notice Pay out this market's filled INDEX. Safe to call before bidders claim.
    function sweepCurrency(uint256 marketId) external;

    /// @notice Pull unsold supply back out. Only between rounds.
    function sweepUnsoldTokens(uint256 marketId, uint128 amount) external;

    // ---------------------------------------------------------------- views

    function markets(uint256 marketId)
        external
        view
        returns (
            address token,
            address currency,
            uint256 floorPrice,
            uint128 remaining,
            uint128 tokensUnclaimed,
            uint256 currencyRaised,
            uint256 highestTick,
            uint64 round,
            uint64 startBlock,
            uint64 endBlock,
            bool settleDone
        );

    function ticks(uint256 marketId, uint256 price)
        external
        view
        returns (uint256 next, uint256 prev, uint256 demand, uint256 survival, uint64 epoch, bool init);

    /// @notice What `(owner, price)` holds right now: escrow still competing, and tokens won.
    function positionOf(uint256 marketId, address owner, uint256 price)
        external
        view
        returns (uint256 live, uint256 tokensOwed);

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256);

    /// @notice What the next settle window would look like right now, without changing anything.
    function previewWindow(uint256 marketId)
        external
        view
        returns (uint256 tau, uint256 weightSum, uint256[] memory price, uint256[] memory tokens);

    /// @notice True when the market has been quiet long enough that `settle` may be called early.
    function idleTimedOut(uint256 marketId) external view returns (bool);

    function settleProgress(uint256 marketId) external view returns (bool started, bool done, uint256 cursor);
}
