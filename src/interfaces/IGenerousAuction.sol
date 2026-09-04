// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGenerousAuction
/// @notice Public surface of `src/GenerousAuction.sol`: a geometric pay-as-bid tick book run as
///         one continuous sale over a persistent book, emitting `emissionPerRound` every
///         `roundBlocks` blocks.
/// @dev Types, events and errors live here so the ABI has one definition. Implementation notes
///      stay in the contract; see `agent-docs/GenerousAuction.md` for the mechanism.
interface IGenerousAuction {
    // ---------------------------------------------------------------- types

    /// @notice Everything a deployment is. All of it becomes immutable except the last two, which
    ///         are the initial emission schedule and the only thing `admin` can ever change.
    /// @dev One struct rather than fourteen positional arguments: at that arity the constructor
    ///      does not fit the stack, and a deployer transposing two `uint64`s would not either.
    struct Config {
        address token;
        address currency;
        address admin;
        uint256 floorPrice;
        uint256 tickSpacing;
        uint256 decayQ; // q, Q96
        uint256 windowTicks;
        uint64 startBlock;
        uint64 endBlock; // 0 = open-ended
        uint64 roundBlocks;
        uint128 emissionPerRound;
        /// @dev The premium MONO must be trading at, in basis points, for this sale to open at
        ///      all. Checked once, in the constructor. `1500` is the intended 15%.
        uint16 minPremiumBips;
        /// @dev The sale this one succeeds, or `address(0)` for the first. Its constructor calls
        ///      `mintPack()` on it, so the outgoing sale's supply is minted before this one opens.
        ///      That auction must still hold `MINTER_ROLE` at that moment — deploy first, then
        ///      grant to this one, then revoke from it.
        address previousAuction;
    }

    /// @notice A price level in the persistent book.
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
    /// @dev Live escrow is `amount * Tick.survival / survivalAtEntry`, so the pair
    ///      `(amount, survivalAtEntry)` is only readable together and only within one epoch.
    struct Position {
        uint128 amount; // escrow as of `survivalAtEntry`; live escrow is derived, not stored
        uint128 tokensOwed; // harvested, unclaimed
        uint256 survivalAtEntry; // snapshot of `Tick.survival` when `amount` was last written
        // Snapshot of `Tick.epoch` at that same moment. A 100% fill cannot express itself as a
        // survival ratio — the honest factor is zero, which would both wipe the index for every
        // later entrant and make the division that prices them undefined. So a full clear resets
        // `Tick.survival` to SURVIVAL_ONE and bumps `Tick.epoch` instead, and this field is what
        // makes that reset readable after the fact: a position left behind at an older epoch was,
        // by definition, consumed in full, so its whole `amount` converts to tokens and no ratio
        // is ever taken across the boundary.
        uint64 epoch;
    }

    /// @notice One settle window: the live ticks inside the price band `[tau - span, tau]`, where
    ///         `span = windowTicks * tickSpacing`. Memory-only.
    /// @dev A band that wide holds at most `windowTicks + 1` distinct tick prices, so every array
    ///      here is sized once and the gather walk cannot outrun it.
    struct Window {
        uint256 n; // live ticks collected
        uint256 tau; // price of the highest live tick — this window's top of book
        uint256 weightSum; // W = sum(w_i), Q96
        uint256 resume; // price to begin the next window from (0 = list exhausted)
        uint256 steps; // list nodes visited, charged against the caller's budget
        uint256[] price;
        uint256[] demand;
        uint256[] weight; // q^d in Q96, always in (0, Q96]
    }

    // ---------------------------------------------------------------- events

    event BidSubmitted(address indexed owner, uint256 indexed price, uint128 amount);
    event BidWithdrawn(address indexed owner, uint256 indexed price, uint256 amount);
    event TickFilled(uint256 indexed price, uint256 currencyFilled, bool marginal);
    event Synced(uint256 emittedToDate, uint256 sold, uint256 carried);
    event RoundParamsQueued(uint64 fromBlock, uint64 roundBlocks, uint128 emissionPerRound);
    /// @param tokens MONO minted to `owner`. May be under what the fill owed, if NAV rose past the
    ///        bid price between the fill and the claim — see `GenerousAuction.claim`.
    event Claimed(address indexed owner, uint256 indexed price, uint256 tokens, uint256 assetsIn);
    /// @notice A pack was minted: `tokens` MONO now held here, bought with `assetsIn` of escrow
    ///         paid into the vault.
    event PackMinted(uint256 tokens, uint256 assetsIn);

    // ---------------------------------------------------------------- errors

    error InvalidParams();
    error AuctionEnded();
    error Unauthorized();
    error BidTooLow();
    error BidTooHigh();
    error BidTooSmall();
    error TickNotAligned();
    error TickSpacingTooSmall();
    error BadPrevHint();
    error BelowNav();
    error NoPosition();
    error InvalidDecay();
    error InvalidWindow();
    error WindowTooNarrow();
    error PremiumTooLow();
    error NothingToSell();

    // ---------------------------------------------------------------- config

    /// @notice The token being sold.
    function token() external view returns (address);

    /// @notice The one currency bids may be placed and escrowed in. 18 decimals assumed.
    function currency() external view returns (address);

    /// @notice Lowest biddable price, and the one tick initialised at deploy.
    function floorPrice() external view returns (uint256);

    /// @notice Bid prices must be a multiple of this.
    function tickSpacing() external view returns (uint256);

    /// @notice Per-tick decay `q`, in Q96. `Q96` is 1.0 (flat split); smaller concentrates
    ///         supply at the top of the book.
    function decayQ() external view returns (uint256);

    /// @notice How many grid steps below the top of book still receive supply. Also the size
    ///         bound on a settle window.
    function windowTicks() external view returns (uint256);

    /// @notice The only address that may re-schedule emission.
    function admin() external view returns (address);

    /// @notice First block that accrues emission.
    function startBlock() external view returns (uint64);

    /// @notice Last block that accrues emission. 0 = open-ended.
    function endBlock() external view returns (uint64);

    // ---------------------------------------------------------------- state

    function ticks(uint256 price)
        external
        view
        returns (uint256 next, uint256 prev, uint256 demand, uint256 survival, uint64 epoch, bool init);

    function positions(address owner, uint256 price)
        external
        view
        returns (uint128 amount, uint128 tokensOwed, uint256 survivalAtEntry, uint64 epoch);

    /// @notice Sold and not yet minted — the sum of every position's `tokensOwed`.
    function tokensUnclaimed() external view returns (uint256);

    /// @notice Currency taken out of escrow by fills, cumulative. Never decreases — it is the
    ///         numerator `mintPack` measures against, not a live balance.
    function currencyRaised() external view returns (uint256);

    /// @notice Tokens minted into this contract by `mintPack`, cumulative. Trails `tokensSold` by
    ///         whatever the last fill has not been packed yet, and by any NAV-clamp shortfall.
    function tokensMinted() external view returns (uint256);

    /// @notice Currency already paid into the vault by `mintPack`, cumulative.
    function currencyMinted() external view returns (uint256);

    /// @notice Mint the MONO for every fill that has not been packed yet, backed by the escrow
    ///         those fills spent, and hold it here for claimants. Permissionless and idempotent:
    ///         it mints the delta, so calling it twice in a block is a no-op the second time.
    /// @dev Implicit at the tail of every `sync`, so the pack tracks fills round by round rather
    ///      than landing in one lump. Also callable directly — which is how the next sale's
    ///      constructor closes this one out.
    function mintPack() external returns (uint256 minted);

    /// @notice High-water mark of initialised ticks. May sit above every live tick.
    function highestTick() external view returns (uint256);

    /// @notice Where a `sync` truncated by its tick budget resumes. 0 = start from the top.
    function settleCursor() external view returns (uint256);

    /// @notice Tokens distributed since deploy, cumulative. Never decreases.
    function tokensSold() external view returns (uint256);

    /// @notice Blocks per emission round, and the tokens each completed round releases.
    function roundBlocks() external view returns (uint64);
    function emissionPerRound() external view returns (uint128);

    /// @notice Queued schedule, effective from `pendingFrom`. `pendingFrom == 0` = none queued.
    function pendingFrom() external view returns (uint64);
    function pendingRoundBlocks() external view returns (uint64);
    function pendingEmission() external view returns (uint128);

    /// @notice Cumulative tokens the schedule has released by now, over completed rounds only.
    function emittedToDate() external view returns (uint256);

    /// @notice What a `sync` right now would distribute: everything emitted and not yet sold,
    ///         including the carry from rounds the book could not absorb. Uncapped — the schedule
    ///         is the supply, because the auction mints.
    function due() external view returns (uint256);

    /// @notice Completed emission rounds since `startBlock`.
    function roundsElapsed() external view returns (uint256);

    // ---------------------------------------------------------------- emission

    /// @notice Distribute everything emitted and not yet sold across the book.
    /// @dev Permissionless and always callable. Also runs at the head of `submitBid`,
    ///      `withdrawBid` and `claim`, so the book is never stale when it changes shape.
    /// @param maxTicks Budget in list nodes visited, not work inside a window. A truncated sync
    ///                 saves `settleCursor` and the undistributed part stays in `due()`.
    function sync(uint256 maxTicks) external;

    /// @notice Queue a new emission schedule, effective from the next round boundary.
    /// @dev Admin only. Never retroactive: rounds already elapsed keep the rate they ran under,
    ///      whether or not anyone has synced them. A second call before the boundary replaces the
    ///      first.
    function setRoundParams(uint64 roundBlocks_, uint128 emissionPerRound_) external;

    // ---------------------------------------------------------------- bidding

    /// @notice Bid at `price`, escrowing `amount` of currency.
    /// @param owner Who controls and is paid by the position. May differ from `msg.sender`.
    /// @param prevTick The exact predecessor of `price` in the book: the highest initialized tick
    ///                 below it. A wrong or stale value reverts with `BadPrevHint`. Walk the public
    ///                 `ticks` getter to find it.
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external;

    /// @notice Take back everything still live at `(msg.sender, price)`. Tokens already won
    ///         stay claimable.
    function withdrawBid(uint256 price) external returns (uint256 live);

    // ---------------------------------------------------------------- payouts

    /// @notice Mint the tokens accrued at `(owner, price)` and send the escrow that paid for them
    ///         to the vault. Does NOT close the position — escrow still live keeps competing in
    ///         later rounds. Permissionless; pays `owner`.
    function claim(address owner, uint256 price) external returns (uint256 tokens);

    // ---------------------------------------------------------------- views

    /// @notice What `(owner, price)` holds right now: escrow still competing, and tokens won.
    /// @dev The raw `positions` getter shows only the already-crystallised half; this adds the
    ///      part still folded into the tick's index.
    function positionOf(address owner, uint256 price) external view returns (uint256 live, uint256 tokensOwed);

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256);

    /// @notice What the next sync window would look like right now, without changing anything.
    function previewWindow()
        external
        view
        returns (uint256 tau, uint256 weightSum, uint256[] memory price, uint256[] memory tokens);
}
