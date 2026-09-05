// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IGenerousAuction} from "./interfaces/IGenerousAuction.sol";
import {IMono} from "./interfaces/IMono.sol";

/// @title GenerousAuction
/// @notice The harvest channel (HANDBOOK §3.5): bidders escrow INDEX, the schedule releases MONO,
///         and every claim mints it against the escrow it filled from — so the strike lands in the
///         vault in the same transaction the supply is created.
/// @notice One token, one currency, one persistent book, emitting continuously: every
///         `roundBlocks` blocks releases `emissionPerRound` tokens, split across every live tick
///         by geometric weight `q^d` instead of filling high → low. WITHIN a tick the split is by
///         STAKE of the sale token, capped by each bidder's own escrow — no stake, no fill, and
///         un-staked escrow is not tick capacity either. Escrow that does not fill stays where it
///         is and competes again next round. Nobody has to open or close anything.
/// @dev The mechanism is `agent-docs/GenerousAuction.md`; the rule and its derivation are
///      `human-docs/generous-auction.md`. Read one of those before changing anything here.
///
///      The five things a reader needs before reaching `_sync`:
///
///      1. EMISSION IS A SCHEDULE. `emittedToDate()` is a closed form of the block number, so a
///         thousand silent rounds are one division and one sweep — not a thousand of either. What
///         the book could not absorb stays owed in `due()` rather than being burned (carry).
///      2. ONE SWEEP, SOLVED NOT ITERATED — TWICE. `_pour` parameterises a window's pour by a
///         scalar `C`; tick `i` exhausts at `kappa_i = cap_i / w_i`. Sort by `kappa`, walk once.
///         `_pourTick` then runs the SAME shape inside the tick: weights are stakes, caps are
///         each position's escrow, the scalar is `Tick.acc`. Exhaustion order is not price (or
///         stake) order in either layer, which is why both sort and neither iterates to converge.
///      3. CLAIMS NEVER ITERATE. `Tick.acc` is an additive depletion index (tokens per unit of
///         stake, Q128); a position's consumption is `min(cap, stake * (acc - accAtEntry))` — one
///         closed form across unlimited rounds, and `min` prices its own death. The pour reads
///         ONLY the positions that die (heap head pops) and writes only the tick's aggregates —
///         seats are unlimited.
///      4. ROUNDING IS DOWN EVERYWHERE tokens flow out, UP where escrow is charged. A sum of
///         floors is no greater than the floor of the sum, so allocations can never exceed the
///         supply they are drawn from; charging up keeps `currencyRaised` covered by escrow
///         actually spent. The shortfall is dust, never insolvency.
///      5. THE SALE IS NOT PRE-FUNDED. `token` must be a `Mono` whose `index` is `currency`, and
///         this contract must be its owner. `claim` calls `Mono.mint`, which refuses any mint
///         that would lower NAV — so `submitBid` floors bids at `nav()` and `claim` clamps rather
///         than reverting. There is no `sweepCurrency`: escrow leaves only as a strike payment.
///         Stake is the same MONO the sale sells; `totalStaked` is held apart and can never pay a
///         claim or a pack.
///
///      ponytail: unbounded carry. A long dry spell hands the first bidder back a large backlog at
///      their own price; cap the per-sync draw if that turns out to be worth gaming.
///      ponytail: death segments can book up to a token-wei more than the positions in them
///      crystallise (the kappa ceil vs the per-position floors), leaving `currencyRaised` ahead
///      of collectable charges by dust. One-sided and bounded per death; seed the contract with
///      a few wei of currency at deploy if the last-withdrawal wei ever matters.
///      ponytail: positions that exhaust exactly at a pour's stopping point stay seated with
///      `kappa == acc` until the next pour pops them for free — stale seats read correctly and
///      cost one no-op pop each, never a wrong number.
contract GenerousAuction is IGenerousAuction, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    uint256 internal constant Q96 = 1 << 96;

    /// @notice Scale of `Tick.acc`: tokens per unit of stake, Q128 so dust stakes on long sales
    ///         still resolve to distinct consumption values.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Bids may not exceed this multiple of the floor price.
    /// @dev Keeps the tick list from being seeded at absurd prices, and stops a bid paying in full
    ///      for zero tokens.
    uint256 internal constant MAX_PRICE_MULTIPLE = 1e4;

    /// @notice Keeps `floorPrice * MAX_PRICE_MULTIPLE` far from overflowing.
    uint256 internal constant MAX_FLOOR_PRICE = type(uint128).max;

    /// @notice Floor on `tickSpacing`. Only rules out the degenerate grids (0 bricks the modulo,
    ///         1 is no grid at all).
    uint256 internal constant MIN_TICK_SPACING = 2;

    /// @notice Low bits of a `_pour` sort key, holding the tick's index within the window.
    /// @dev The key is `(kappa << IDX_BITS) | i`, so one sort orders the exhaustions and carries
    ///      the index with them. `MAX_WINDOW_TICKS` is what keeps `i` inside this field.
    uint256 internal constant IDX_BITS = 8;
    uint256 internal constant IDX_MASK = (1 << IDX_BITS) - 1;

    /// @notice Hard ceiling on `windowTicks`. Gas is the real limit long before this, but the
    ///         packing in `_pour` needs the index to fit in `IDX_BITS`.
    uint256 internal constant MAX_WINDOW_TICKS = 255;

    /// @notice Position deaths one SYNC processes before pausing — a global budget across every
    ///         tick the sweep pours, not per tick, so a window of half-dead ticks cannot multiply
    ///         it. Deaths are amortised — one per position per lifetime — but a huge backlog can
    ///         owe thousands at once; the pause keeps a single sync inside a sane gas envelope,
    ///         and the cursor resumes exactly where it stopped.
    uint256 internal constant MAX_DEATHS_PER_SYNC = 128;

    /// @notice Largest edge weight `q^windowTicks` a deployment may leave unserved.
    /// @dev The window truncates the curve, so the tick just past the edge loses a share of
    ///      `q^windowTicks / W`. Requiring that to be under 1% stops a deployment from silently
    ///      cutting the book in half — pick `q` and `windowTicks` together. Exempt when `q == ONE`,
    ///      where a flat split across exactly `windowTicks` levels is the intended reading.
    uint256 internal constant MAX_EDGE_WEIGHT = Q96 / 100;

    /// @notice Tick budget the implicit syncs inside `submitBid`/`withdrawBid`/`claim`/`stake`/
    ///         `unstake` run under.
    /// @dev Bounds how many WINDOWS and dead ticks such a sync walks, NOT the work inside one
    ///      window — `_gather` step 2 always collects its whole band, so a single window of up to
    ///      `windowTicks + 1` live ticks runs to completion whatever this is set to. So the real
    ///      ceiling on what one bidder pays for the backlog is `windowTicks` (times the per-tick
    ///      position scan), and that is a deployment choice. Running out of budget is not an
    ///      error — the sync saves `settleCursor` and the rest stays in `due()`.
    uint256 internal constant SYNC_TICKS = 128;

    // ---------------------------------------------------------------- immutable config

    /// @dev 18 decimals assumed on `currency` — the WAD fill math is not decimal-agnostic.
    address public immutable token;
    address public immutable currency;

    /// @dev The only privileged role, and it can do exactly one thing: re-schedule emission from a
    ///      future round boundary. It cannot touch the book, the escrow, the stakes, or anything
    ///      already owed.
    address public immutable admin;

    /// @notice First block that accrues emission, and the last. `endBlock == 0` is open-ended.
    /// @dev A trailing partial round never emits — the schedule floors — so an auction whose life
    ///      is not a whole multiple of `roundBlocks` simply stops one boundary early.
    uint64 public immutable startBlock;
    uint64 public immutable endBlock;

    /// @dev `floorPrice` is the one tick initialised in the constructor.
    uint256 public immutable floorPrice;

    /// @dev Right `tickSpacing`: fine enough that rounding to a tick costs a bidder less than the
    ///      gas to bid, coarse enough that a live book is a few hundred ticks.
    uint256 public immutable tickSpacing;

    /// @dev Calibrate `decayQ` WITH `tickSpacing`, not separately: weights decay per grid step, so
    ///      on this arithmetic grid `q`'s reach is an absolute price band of
    ///      `windowTicks * tickSpacing`. A fine grid needs `q` near 1 for a sensible band, which
    ///      in turn softens the `(1 - q)` soft cap the top tick gets. Window width and top-cap
    ///      strength are one knob. Immutable because changing it would reprice every standing bid.
    uint256 public immutable decayQ;

    uint256 public immutable windowTicks;

    /// @notice The premium MONO had to be trading at for this sale to be deployed, in bips.
    ///         Kept on-chain so the bar a live sale cleared is readable, not just in the deploy tx.
    uint16 public immutable minPremiumBips;

    /// @notice The whole supply of this sale: the MONO it takes to close the premium that was
    ///         standing when it was deployed. Struck once, in the constructor, and never
    ///         recomputed — the sale sells a fixed quantity, not whatever the gap is today.
    uint256 public immutable saleSupply;

    // ---------------------------------------------------------------- state

    mapping(uint256 price => Tick) public ticks;

    /// @dev ONE bid per owner, whole book — which is also what makes the stake → tick attachment
    ///      unambiguous: the whole of `stakes[owner]` weighs at the one price the owner stands at.
    mapping(address owner => Position) public positions;

    /// @dev Each live tick's positions as a min-heap on `Position.kappa` (1-based; seat index
    ///      lives in `Position.heapIdx`). The pour pops only the positions that actually exhaust,
    ///      so a tick seats ANY number of bidders and settling costs O(deaths), not O(seats).
    mapping(uint256 price => mapping(uint256 idx => address)) internal heap;

    mapping(address owner => uint256) public stakes;
    uint256 public totalStaked;
    bool public finalized;

    uint256 public tokensUnclaimed;
    uint256 public currencyRaised;
    uint256 public tokensSold;
    /// @dev What `mintPack` has already packed. Both cumulative; the deltas against `tokensSold`
    ///      and `currencyRaised` are exactly what the next pack mints.
    uint256 public tokensMinted;
    uint256 public currencyMinted;
    uint256 public highestTick;
    uint256 public settleCursor;

    /// @dev The emission schedule, as an anchor plus a rate. `anchorEmitted` is the cumulative
    ///      emission at `anchorBlock`, so a rate change never has to rewrite history: it only
    ///      re-anchors. One queued generation at a time, effective from `pendingFrom`.
    ///      The groups below are exactly one storage slot each — keep them that way.

    // slot: 64 + 128 + 64
    uint64 internal anchorBlock;
    uint128 internal anchorEmitted;
    uint64 public roundBlocks;

    // slot: 128 + 64 + 64
    uint128 public emissionPerRound;
    uint64 public pendingFrom; // 0 = nothing queued
    uint64 public pendingRoundBlocks;

    uint128 public pendingEmission;

    constructor(Config memory c) {
        if (c.token == address(0) || c.currency == address(0)) revert InvalidParams();
        // Same asset on both sides would make the fill math circular.
        if (c.token == c.currency) revert InvalidParams();
        // The escrow token has to be the vault's backing asset, or `mint` would pull nothing.
        if (c.currency != address(IMono(c.token).index())) revert InvalidParams();
        if (c.admin == address(0)) revert InvalidParams();
        if (c.startBlock == 0 || c.roundBlocks == 0) revert InvalidParams();
        if (c.endBlock != 0 && c.endBlock <= c.startBlock) revert InvalidParams();
        if (c.tickSpacing < MIN_TICK_SPACING) revert TickSpacingTooSmall();
        if (c.floorPrice == 0 || c.floorPrice > MAX_FLOOR_PRICE) revert InvalidParams();
        if (c.floorPrice % c.tickSpacing != 0) revert TickNotAligned();
        if (c.decayQ == 0 || c.decayQ > Q96) revert InvalidDecay();
        if (c.windowTicks == 0 || c.windowTicks > MAX_WINDOW_TICKS) revert InvalidWindow();
        // Refuse a pairing that would strand real demand just past the window edge. A flat book
        // (q == 1) is exempt: there the window IS the intended participation set.
        if (c.decayQ != Q96 && FixedPointMathLib.rpow(c.decayQ, c.windowTicks, Q96) > MAX_EDGE_WEIGHT) {
            revert WindowTooNarrow();
        }

        // The harvest only makes sense into a premium: it mints MONO against escrow at NAV and the
        // market pays above it. With MONO at or under book there is no spread to harvest, and the
        // sale is just supply. Requires `Mono.setPool` to have run — deploy order is Mono, pool,
        // setPool, then this. Reverts `PoolNotSet` otherwise.
        //
        // ponytail: checked ONCE, here, against a SPOT `slot0` read. It stops a sale being opened
        // into a flat market; it does not keep one honest afterwards, and a deployer who controls
        // the pool can push it for one block. Move this to `submitBid` once the v4 TWAP hook lands
        // (HANDBOOK 3.6) — gating every bid on a spot price today just hands anyone a cheap DoS.
        if (IMono(c.token).premiumBips() < int256(uint256(c.minPremiumBips))) revert PremiumTooLow();

        // The premium, restated as supply: how much MONO sold into the pool would carry its price
        // back down to NAV. That is exactly what this sale exists to sell, so it is the sale's
        // whole size — the emission schedule paces it out, and `due()` stops at it.
        saleSupply = IMono(c.token).premiumCloseAmount();
        // A premium the pool has no liquidity to absorb is not a sale.
        if (saleSupply == 0) revert NothingToSell();

        token = c.token;
        currency = c.currency;
        admin = c.admin;
        floorPrice = c.floorPrice;
        tickSpacing = c.tickSpacing;
        decayQ = c.decayQ;
        windowTicks = c.windowTicks;
        minPremiumBips = c.minPremiumBips;
        startBlock = c.startBlock;
        endBlock = c.endBlock;
        highestTick = c.floorPrice;

        anchorBlock = c.startBlock;
        roundBlocks = c.roundBlocks;
        emissionPerRound = c.emissionPerRound;

        // One approval for the life of the sale. `Mono` only ever pulls the amount its caller —
        // this contract, in `claim` — passes it, so an unbounded allowance grants it nothing extra.
        c.currency.safeApprove(c.token, type(uint256).max);

        // Close the outgoing sale before this one opens: mint its supply against the escrow its
        // fills spent, so its claimants are paid out of a finished pack rather than competing with
        // this sale's mints. It must still hold `MINTER_ROLE` here — deploy this, THEN grant to
        // this one and revoke from it. Cleaning the old role up first reverts right here.
        if (c.previousAuction != address(0)) IGenerousAuction(c.previousAuction).mintPack();

        ticks[c.floorPrice].init = true;
    }

    // ---------------------------------------------------------------- emission schedule

    /// @notice Cumulative tokens released by completed rounds as of now.
    function emittedToDate() public view returns (uint256) {
        return _emittedAt(block.number);
    }

    /// @notice What a `sync` right now would distribute.
    /// @dev The gap between the schedule and what has actually been sold — so a round the book
    ///      could not absorb stays owed here rather than being burned. Capped at `saleSupply`:
    ///      the schedule paces the sale, the premium sizes it, and whichever binds first wins.
    ///      Once the schedule passes `saleSupply` this returns 0 forever and the sale is over.
    function due() public view returns (uint256) {
        // A finalized sale is OVER: whatever carry the dead book never absorbed is not owed to
        // anyone, and a post-finalize re-stake must not vacuum it at post-unlock weights.
        if (finalized) return 0;
        uint256 sold = tokensSold;
        uint256 target = _emittedAt(block.number);
        uint256 cap = saleSupply;
        if (target > cap) target = cap;
        return target <= sold ? 0 : target - sold;
    }

    /// @notice MONO of this sale still unsold. Hits 0 when the premium that sized it is spent.
    function remaining() public view returns (uint256) {
        uint256 sold = tokensSold;
        return sold >= saleSupply ? 0 : saleSupply - sold;
    }

    function roundsElapsed() external view returns (uint256) {
        uint256 t = _scheduleBlock(block.number);
        uint64 from = startBlock;
        return t > from ? (t - from) / roundBlocks : 0;
    }

    /// @dev Cumulative emission at `blockNo`. Closed form, so a thousand silent rounds are one
    ///      division rather than a thousand iterations, and reading it costs nothing.
    function _emittedAt(uint256 blockNo) internal view returns (uint256) {
        uint256 t = _scheduleBlock(blockNo);
        uint64 anchor = anchorBlock;
        if (t <= anchor) return anchorEmitted;

        uint64 from = pendingFrom;
        // A queued generation only bites past its boundary, and everything before it stays priced
        // at the old rate — which is what makes `setRoundParams` non-retroactive even when nobody
        // synced in between.
        if (from != 0 && t >= from) {
            return _accrue(anchorEmitted, anchor, roundBlocks, emissionPerRound, from)
                + ((t - from) / pendingRoundBlocks) * pendingEmission;
        }
        return _accrue(anchorEmitted, anchor, roundBlocks, emissionPerRound, t);
    }

    /// @dev Clamp to the auction's life. Past `endBlock` the schedule is frozen, not reversed.
    function _scheduleBlock(uint256 blockNo) internal view returns (uint256) {
        uint64 end = endBlock;
        return (end != 0 && blockNo > end) ? end : blockNo;
    }

    /// @dev Cumulative emission at `until`, given `base` already emitted as of `from` and a rate of
    ///      `perRound` every `blocksPerRound` blocks since. Floors: a partial round emits nothing.
    function _accrue(uint256 base, uint256 from, uint256 blocksPerRound, uint256 perRound, uint256 until)
        internal
        pure
        returns (uint256)
    {
        return base + ((until - from) / blocksPerRound) * perRound;
    }

    /// @notice Queue a new emission schedule, effective from the next round boundary.
    /// @dev No sync needed first: `_emittedAt` is exact for every past block regardless of what is
    ///      queued, so rounds already elapsed keep their old rate whether or not anyone settled
    ///      them. A second call before the boundary simply replaces the first.
    function setRoundParams(uint64 roundBlocks_, uint128 emissionPerRound_) external override {
        if (msg.sender != admin) revert Unauthorized();
        if (roundBlocks_ == 0) revert InvalidParams();

        // A queued generation that has already taken effect becomes the anchor, so the boundary
        // below is measured under the rate actually running.
        uint64 from = pendingFrom;
        if (from != 0 && block.number >= from) {
            // Clamp the fold to the sale's life: a pending boundary past `endBlock` must not
            // materialise emission the frozen schedule would never have released.
            uint256 tf = _scheduleBlock(from);
            anchorEmitted = uint128(_accrue(anchorEmitted, anchorBlock, roundBlocks, emissionPerRound, tf));
            anchorBlock = uint64(tf);
            roundBlocks = pendingRoundBlocks;
            emissionPerRound = pendingEmission;
        }

        // Strictly the next boundary: the round in flight finishes at the rate it started under.
        uint256 t = _scheduleBlock(block.number);
        uint64 anchor = anchorBlock;
        uint256 elapsed = t > anchor ? (t - anchor) / roundBlocks : 0;
        uint64 next = uint64(anchor + (elapsed + 1) * roundBlocks);

        pendingFrom = next;
        pendingRoundBlocks = roundBlocks_;
        pendingEmission = emissionPerRound_;

        emit RoundParamsQueued(next, roundBlocks_, emissionPerRound_);
    }

    // ---------------------------------------------------------------- staking

    /// @inheritdoc IGenerousAuction
    /// @dev Settles the book, harvests the caller's position at the OLD stake, then applies the
    ///      new one — so a stake weighs exactly the rounds it stood for, nothing retroactive.
    ///      The rounds already settled are untouchable by construction; that is also why the
    ///      lock below only needs to cover the lazy tail after `endBlock`.
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert InvalidParams();
        _requireStakeOpen();
        _sync(SYNC_TICKS);

        (Position storage p, uint256 live) = _harvest(msg.sender);
        uint256 sOld = stakes[msg.sender];
        uint256 sNew = sOld + amount;
        live; // the reseat below reads the harvested position directly
        _reseat(msg.sender, p, sOld, sNew);

        stakes[msg.sender] = sNew;
        totalStaked += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev Unstaking to zero with a live bid is legal and leaves the bid inert: `_harvest` has
    ///      already crystallised everything the old stake earned, the escrow leaves the tick's
    ///      capacity, and the consumption formula reads 0 from then on. Re-staking re-anchors.
    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert InvalidParams();
        _requireStakeOpen();
        uint256 sOld = stakes[msg.sender];
        if (amount > sOld) revert InsufficientStake();
        _sync(SYNC_TICKS);

        (Position storage p, uint256 live) = _harvest(msg.sender);
        uint256 sNew = sOld - amount;
        live; // the reseat below reads the harvested position directly
        _reseat(msg.sender, p, sOld, sNew);

        stakes[msg.sender] = sNew;
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev The lock exists for correctness, not ceremony: the lazy sync may settle pre-`endBlock`
    ///      rounds AFTER `endBlock`, reading weights from current stakes — moving stake in that
    ///      window would reprice rounds that already happened. Once everything owed is distributed
    ///      (or provably never will be), the weights have no more work to do and the lock lifts.
    function finalize(uint256 maxTicks) external override nonReentrant returns (bool done) {
        uint64 end = endBlock;
        if (end == 0 || block.number < end || finalized) revert NotFinalizable();

        uint256 sold = _sync(maxTicks);
        // Done when nothing is owed — or when a COMPLETE sweep (cursor back at top) sold nothing:
        // bids and stakes are both frozen past `endBlock`, so a book that cannot absorb the carry
        // now never will, and holding stakes hostage to it serves nobody. A call that is neither
        // returns false WITHOUT reverting — a revert would roll back the very progress the sync
        // just made, and the tail would never drain. Call again.
        if (due() == 0 || (sold == 0 && settleCursor == 0)) {
            finalized = true;
            emit Finalized();
            return true;
        }
    }

    /// @dev Stakes move freely during the sale and after finalization; only the settlement tail
    ///      between the two is locked.
    function _requireStakeOpen() internal view {
        if (!_stakeOpen()) revert StakeLocked();
    }

    function _stakeOpen() internal view returns (bool) {
        return endBlock == 0 || block.number < endBlock || finalized;
    }

    /// @dev Bring `owner`'s seat in line with its current `(amount, stake)` after a harvest has
    ///      re-anchored the position. Handles every transition — join, leave, re-key, top-up — as
    ///      an unseat (contribution unwound with the OLD stake that built `kappa`) followed by a
    ///      fresh seat when the position is countable: stake > 0 and escrow that still buys at
    ///      least a wei of token. Everything else — no stake, dust — is inert: not capacity, not
    ///      weight, not in the heap. The strict rule lives here.
    function _reseat(address owner, Position storage p, uint256 sOld, uint256 sNew) internal {
        uint256 price = p.price;
        if (price == 0) return;
        Tick storage t = ticks[price];
        uint256 acc = t.acc;

        if (p.heapIdx != 0) {
            uint256 k = p.kappa;
            uint256 capOld = k > acc ? _tokensFor(sOld, k - acc) : 0;
            uint256 ct = t.capTokens;
            t.capTokens = ct > capOld ? ct - capOld : 0;
            t.stakeSum -= sOld;
            _heapRemove(price, t, p);
            // No stake left behind the tick: whatever capacity dust the floor-unwind left is
            // phantom — zero it so an empty tick cannot anchor a window or hold `tau`.
            if (t.stakeSum == 0) t.capTokens = 0;
        }

        uint256 amount = p.amount; // post-harvest, anchored at `acc`
        if (sNew == 0 || amount == 0) return;
        uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
        if (cap == 0) return;
        p.kappa = _kappa(acc, cap, sNew);
        t.capTokens += cap;
        t.stakeSum += sNew;
        _heapInsert(price, t, p, owner);
        // Revived capacity must be REACHABLE. A sweep that saw this tick empty may have dropped
        // `highestTick` below it, and a truncated sweep's cursor claims everything above itself
        // is dry — both statements just became false, so both marks reset here.
        if (price > highestTick) highestTick = price;
        uint256 cursor = settleCursor;
        if (cursor != 0 && price > cursor) settleCursor = 0;
    }

    // ---------------------------------------------------------------- bidding

    /// @inheritdoc IGenerousAuction
    /// @dev ONE bid per owner. Same price tops the position up (harvesting first — the index pair
    ///      is only meaningful for one amount); a different price with live escrow reverts, and
    ///      with nothing live re-binds the position there. `prevTick` is ignored when `price` is
    ///      already initialized.
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external override nonReentrant {
        if (endBlock != 0 && block.number >= endBlock) revert AuctionEnded();
        if (amount == 0 || owner == address(0)) revert InvalidParams();
        if (price < floorPrice) revert BidTooLow();
        if (price > floorPrice * MAX_PRICE_MULTIPLE) revert BidTooHigh();
        if (price % tickSpacing != 0) revert TickNotAligned();
        // Must buy at least 1 wei of token, else the bid pays in full for nothing.
        if (uint256(amount) * WAD < price) revert BidTooSmall();
        // No mint below backing (HANDBOOK §3.1). `floorPrice` is immutable and NAV only rises, so
        // the live floor is NAV, not the constructor's — this is what keeps `claim` from clamping.
        if (price < IMono(token).nav()) revert BelowNav();
        // The strict rule, at the door: escrow without stake would buy nothing and count for
        // nothing, so it does not enter.
        uint256 s = stakes[owner];
        if (s == 0) revert NoStake();

        // Settle what the old book already earned BEFORE this bid joins it. Without this a bidder
        // could arrive after a long silence and take a share of emission that accrued while they
        // were not in the book at all.
        _sync(SYNC_TICKS);

        currency.safeTransferFrom(msg.sender, address(this), amount);

        // Harvest before resizing: `(amount, accAtEntry)` is only meaningful for one amount.
        (Position storage p, uint256 live) = _harvest(owner);
        uint256 oldPrice = p.price;
        // Moving with live escrow is withdraw-then-bid, one decision at a time.
        if (oldPrice != 0 && oldPrice != price && live != 0) revert BidExists();

        // Unseat wherever the position currently sits (still keyed by its old price), then
        // re-bind and seat fresh — two `_reseat` calls cover every transition without cases.
        _reseat(owner, p, s, 0);

        _initializeTick(prevTick, price);
        if (price > highestTick) highestTick = price;
        if (oldPrice != price) {
            p.price = price;
            p.accAtEntry = ticks[price].acc;
        }

        uint256 newAmount = live + amount;
        if (newAmount > type(uint128).max) revert InvalidParams();
        p.amount = uint128(newAmount);
        _reseat(owner, p, 0, s);

        emit BidSubmitted(owner, price, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev ponytail: a free cancel option outside settlement. That is the price of never trapping
    ///      escrow — an offer that never clears must always have an exit. Charge a cancel fee here
    ///      if the option turns out to be worth gaming.
    function withdrawBid() external override nonReentrant returns (uint256 live) {
        // Pay for the emission this escrow was standing behind before taking it out.
        _sync(SYNC_TICKS);
        // The lock window freezes WEIGHTS, and a withdrawal moves them too: with pre-`endBlock`
        // rounds still undrained, pulling escrow out would reprice the frozen backlog onto the
        // remaining stakers. Once the tail is drained (or the book provably dead — `finalize`)
        // the withdrawal is free.
        if (!_stakeOpen() && due() != 0) revert StakeLocked();

        Position storage p;
        (p, live) = _harvest(msg.sender);
        if (live == 0) revert NoPosition();

        uint256 price = p.price;
        _reseat(msg.sender, p, stakes[msg.sender], 0);
        p.amount = 0;
        p.price = 0;

        currency.safeTransfer(msg.sender, live);

        emit BidWithdrawn(msg.sender, price, live);
    }

    // ---------------------------------------------------------------- sync

    /// @notice Distribute everything the schedule has released and the book has not yet absorbed.
    /// @dev Permissionless and always callable — it only ever moves the book to where the schedule
    ///      already says it should be, so who calls it and when decides nothing but who pays the
    ///      gas.
    function sync(uint256 maxTicks) external override nonReentrant {
        _sync(maxTicks);
    }

    /// @dev Processes one window at a time from the top of book down. Each window is solved exactly
    ///      and in full — a window is never left half-poured, because a partial `W` would misprice
    ///      every tick in it. `maxTicks` therefore budgets *list nodes visited*, not work inside a
    ///      window; a truncated sweep saves `settleCursor` and leaves the rest in `due()`.
    ///
    ///      A later window only ever runs once every tick above it is dry, so resuming from the
    ///      cursor is the same computation as never having stopped: the new top of book is exactly
    ///      where the previous window ended.
    ///
    ///      The whole backlog goes in as ONE supply figure rather than round by round. That is not
    ///      an approximation: `_pour` is parameterised by the scalar `C` and relative weights are
    ///      anchor-independent, so `N*R` in one sweep lands where `N` sweeps of `R` would.
    /// @return sold Tokens actually distributed by this call.
    function _sync(uint256 maxTicks) internal returns (uint256 sold) {
        if (finalized) return 0; // the sale is over; see `due()`
        // Inlined `due()` so the schedule is read once rather than again for the event. The
        // `saleSupply` clamp mirrors `due()` exactly — without it a long schedule would keep
        // selling past the size the premium set.
        uint256 emitted = _emittedAt(block.number);
        uint256 cap = saleSupply;
        if (emitted > cap) emitted = cap;
        uint256 alreadySold = tokensSold;
        if (emitted <= alreadySold) return 0;
        uint256 supply = emitted - alreadySold;

        uint256 price = settleCursor;
        bool fromTop = price == 0;
        if (fromTop) price = highestTick;

        uint256 steps;
        uint256 deathsLeft = MAX_DEATHS_PER_SYNC;
        bool drained;
        while (price != 0 && supply > 0 && steps < maxTicks) {
            Window memory w = _gather(price, maxTicks - steps);
            steps += w.steps;
            if (w.n == 0) {
                // Either the list ran out below `price`, or the budget did while skipping dead
                // ticks. Both are "stop here"; `w.resume` is 0 in the first case and the cursor to
                // resume from in the second, which is exactly what `settleCursor` wants below.
                price = w.resume;
                break;
            }
            if (fromTop) {
                // Drop the high-water mark onto the real top of book. Dead ticks are never
                // unlinked, so without this a spammer's abandoned run above the book would be
                // re-walked by every sync forever and could starve the live ticks below it.
                if (w.tau != highestTick) highestTick = w.tau;
                fromTop = false;
            }
            uint256 poured;
            uint256 pausedAt;
            (poured, drained, pausedAt, deathsLeft) = _pourWindow(w, supply, deathsLeft);
            supply -= poured;
            sold += poured;
            if (pausedAt != 0) {
                // The death budget ran out mid-tick. Park the cursor on the WINDOW's top, not on
                // the paused tick: ticks above the pause point in this window may have survived
                // their pour with capacity, and a cursor below them would starve them ("above
                // the cursor is dry" must stay true). The partial advance of the paused tick's
                // `acc` is exact; deaths are just deferred pops.
                settleCursor = w.tau;
                tokensSold += sold;
                emit Synced(emitted, sold, supply);
                return sold;
            }
            price = w.resume;
            // The supply ran out inside this window, so no tick below it can be reached. Stopping
            // here matters: per-tick flooring leaves a few wei behind, and without this the walk
            // would chase that dust down the entire book — the exact unbounded traversal the
            // high → low fill avoided by zeroing `remaining` on its marginal tick.
            if (drained) break;
        }

        // 0 means "start from the top next time". Anything else is a genuinely truncated sweep,
        // where the ticks above the cursor are known dry and only the budget ran out.
        settleCursor = (drained || supply == 0 || price == 0) ? 0 : price;
        // Cumulative, and only ever credited with what was actually distributed. Whatever the book
        // could not take stays in `due()` — that is the carry.
        tokensSold += sold;

        emit Synced(emitted, sold, supply);
    }

    /// @dev Collect the live ticks of the next window, walking down from `start`.
    /// @param budget List nodes the skip walk in step 1 may visit before giving up — whatever is
    ///        left of the caller's `maxTicks`. It guards that walk and nothing else, because that
    ///        walk is the only stretch here with no structural limit: dead ticks are never unlinked,
    ///        so an old book can hold an unbounded run of them above the first live tick. Step 2 is
    ///        bounded by `windowTicks` instead and always runs to completion — a half-collected band
    ///        would misprice every tick in it — so `w.steps` reports what was actually visited and
    ///        can exceed `budget` by up to `windowTicks + 1`. Running out is not an error: `w.n`
    ///        comes back 0 and `w.resume` marks where to pick up.
    function _gather(uint256 start, uint256 budget) internal view returns (Window memory w) {
        // 1. Find the top of book. This is the only unbounded stretch — an untouched high-water
        //    `highestTick` can sit far above any live tick — so it is the part the budget guards.
        uint256 price = start;
        while (price != 0 && ticks[price].capTokens == 0) {
            if (w.steps >= budget) {
                w.resume = price; // budget out: `w.n` stays 0, resume from here next time
                return w;
            }
            price = ticks[price].prev;
            unchecked {
                ++w.steps;
            }
        }
        if (price == 0) return w; // resume stays 0: the book below is empty

        w.tau = price;

        // 2. Collect the band. Bounded by construction, not by `budget`: `low` is a price, and a
        //    band of `windowTicks` grid steps contains at most that many further tick prices.
        uint256 span = windowTicks * tickSpacing;
        uint256 low = price > span ? price - span : 0;
        uint256 size = windowTicks + 1;
        w.price = new uint256[](size);
        w.cap = new uint256[](size);
        w.weight = new uint256[](size);

        while (price != 0 && price >= low) {
            Tick storage t = ticks[price];
            uint256 dem = t.capTokens;
            if (dem != 0) {
                uint256 wt = _weight((w.tau - price) / tickSpacing);
                if (wt == 0) break; // q^d has rounded away; nothing further down can reach the book
                w.price[w.n] = price;
                w.cap[w.n] = dem;
                w.weight[w.n] = wt;
                w.weightSum += wt;
                unchecked {
                    ++w.n;
                }
            }
            price = t.prev;
            unchecked {
                ++w.steps;
            }
        }
        w.resume = price;
    }

    /// @dev Solve the window's inter-tick split, then run each tick's own stake-weighted pour.
    /// @return sold Tokens actually taken by this window (model allocation minus intra-tick dust).
    /// @return drained True when the supply ran out inside this window rather than the window
    ///         running dry — i.e. nothing below it can be reached, so settle is finished.
    /// @return pausedAt Price of a tick whose pour hit the death budget mid-way, 0 otherwise.
    ///         The sweep must resume from it; ticks after it in this window were not poured.
    /// @return deathsLeft What remains of the sync-wide death budget after this window.
    function _pourWindow(Window memory w, uint256 supply, uint256 deathsBudget)
        internal
        returns (uint256 sold, bool drained, uint256 pausedAt, uint256 deathsLeft)
    {
        (uint256[] memory tokens,, uint256 dry) = _pour(w, supply);
        // A survivor means the supply ran out, not the window. All dry: the book below can still
        // be served, so the sweep keeps walking.
        drained = dry < w.n;
        deathsLeft = deathsBudget;

        for (uint256 i; i < w.n; ++i) {
            if (tokens[i] == 0) continue;
            (uint256 poured, uint256 left, bool paused) = _pourTick(w.price[i], tokens[i], deathsLeft);
            sold += poured;
            deathsLeft = left;
            if (paused) {
                pausedAt = w.price[i];
                break;
            }
        }
    }

    /// @dev The intra-tick pour: the window's rule one level down, with stakes for weights and
    ///      each position's escrow for a cap (`generous-auction.md` §A.6 shape, stake-weighted).
    ///      Advancing `acc` by `dA` hands every seated position `stake * dA` tokens; position
    ///      `p` exhausts at its stored `kappa`. The tick's heap orders those, so the pour walks
    ///      HEAD POPS ONLY: each step either reaches the next exhaustion (pop it, drop its stake,
    ///      keep pouring — the intra-tick waterfall) or runs out of tokens, which fixes `acc` and
    ///      ends it. Cost is O(deaths this pour), one death per position per lifetime — seats are
    ///      unlimited and settling never scans them.
    ///
    ///      POSITIONS ARE READ ONLY AT THEIR OWN DEATH (the pop). Consumption stays folded in the
    ///      index; a position crystallises on its own next touch, with the same formula the seat
    ///      accounting used. `capTokens` is charged exactly what was poured, and zeroed when the
    ///      heap empties so per-death flooring dust cannot linger as phantom capacity.
    /// @return poured Tokens actually consumed here (can trail `got` by flooring dust when
    ///         everyone exhausts; the shortfall stays in `due()`). `tokensUnclaimed` and
    ///         `currencyRaised` are updated in place — pay-as-bid at one price, so the whole
    ///         pour is charged at `price` (per-position ceil charges sum to at least this).
    /// @return deathsLeft What remains of the sync-wide death budget.
    /// @return paused True when that budget ran out: the pour stopped exactly at a death
    ///         boundary, the advance so far is exact, and the sweep must resume at this tick.
    function _pourTick(uint256 price, uint256 got, uint256 deathsBudget)
        internal
        returns (uint256 poured, uint256 deathsLeft, bool paused)
    {
        Tick storage t = ticks[price];
        uint256 S = t.stakeSum;
        uint256 acc = t.acc;
        uint256 left = got;
        deathsLeft = deathsBudget;
        while (left != 0 && S != 0 && t.heapSize != 0) {
            if (deathsLeft == 0) {
                paused = true;
                break;
            }
            address head = heap[price][1];
            uint256 hk = positions[head].kappa;
            if (hk > acc) {
                uint256 dT = _tokensFor(S, hk - acc);
                if (dT >= left) {
                    // Advance by the CEIL index step: the collective consumption then covers
                    // everything booked (a floored step would book tokens no position can ever
                    // crystallise — charging escrow for supply never handed out — while leaving
                    // a remainder in `due()` that re-grinds the index on every later sync).
                    // Positions clamp at their own caps, so the ≤1-wei overshoot is absorbed
                    // there, in the contract's favour.
                    acc += FixedPointMathLib.fullMulDivUp(left, Q128, S);
                    left = 0;
                    break;
                }
                left -= dT;
                acc = hk;
            }
            _heapPopHead(price, t);
            S -= stakes[head];
            unchecked {
                --deathsLeft;
            }
        }
        poured = got - left;
        t.acc = acc;
        t.stakeSum = S;
        uint256 cap = t.capTokens;
        cap = cap > poured ? cap - poured : 0;
        t.capTokens = t.heapSize == 0 ? 0 : cap;

        uint256 spent = FixedPointMathLib.fullMulDiv(poured, price, WAD);
        tokensUnclaimed += poured;
        currencyRaised += spent;
        emit TickFilled(price, spent, t.capTokens != 0);
    }

    // ---------------------------------------------------------------- the tick heap

    /// @dev Seat `owner` in `price`'s min-heap on `Position.kappa`. O(log seats) sift-up, paid by
    ///      the owner whose seat it is.
    function _heapInsert(uint256 price, Tick storage t, Position storage p, address owner) internal {
        uint256 i = uint256(t.heapSize) + 1;
        t.heapSize = uint32(i);
        uint256 k = p.kappa;
        while (i > 1) {
            uint256 parent = i >> 1;
            address po = heap[price][parent];
            if (positions[po].kappa <= k) break;
            heap[price][i] = po;
            positions[po].heapIdx = uint32(i);
            i = parent;
        }
        heap[price][i] = owner;
        p.heapIdx = uint32(i);
    }

    /// @dev Remove `p` from its seat: the last leaf fills the hole and sifts to its place.
    function _heapRemove(uint256 price, Tick storage t, Position storage p) internal {
        uint256 i = p.heapIdx;
        p.heapIdx = 0;
        uint256 size = t.heapSize;
        t.heapSize = uint32(size - 1);
        if (i == size) return;
        _siftInto(price, i, size - 1, heap[price][size]);
    }

    /// @dev Pop the head — the next position to exhaust. The caller reads it before popping.
    function _heapPopHead(uint256 price, Tick storage t) internal {
        positions[heap[price][1]].heapIdx = 0;
        uint256 size = t.heapSize;
        t.heapSize = uint32(size - 1);
        if (size > 1) _siftInto(price, 1, size - 1, heap[price][size]);
    }

    /// @dev Place `moved` into the hole at `i` of a heap holding `size` seats: sift up, then down.
    function _siftInto(uint256 price, uint256 i, uint256 size, address moved) internal {
        uint256 k = positions[moved].kappa;
        while (i > 1) {
            uint256 parent = i >> 1;
            address po = heap[price][parent];
            if (positions[po].kappa <= k) break;
            heap[price][i] = po;
            positions[po].heapIdx = uint32(i);
            i = parent;
        }
        while (true) {
            uint256 c = i << 1;
            if (c > size) break;
            address co = heap[price][c];
            uint256 ck = positions[co].kappa;
            if (c < size) {
                address co2 = heap[price][c + 1];
                uint256 ck2 = positions[co2].kappa;
                if (ck2 < ck) {
                    c = c + 1;
                    co = co2;
                    ck = ck2;
                }
            }
            if (ck >= k) break;
            heap[price][i] = co;
            positions[co].heapIdx = uint32(i);
            i = c;
        }
        heap[price][i] = moved;
        positions[moved].heapIdx = uint32(i);
    }

    /// @dev `stake * dAcc / 2^128`, clamped at `cap` — a position's consumption, saturating
    ///      instead of reverting when a dust stake left the index deltas astronomically large.
    function _consumed(uint256 s, uint256 dAcc, uint256 cap) internal pure returns (uint256) {
        if (s != 0 && dAcc / Q128 >= type(uint256).max / s) return cap;
        uint256 c = FixedPointMathLib.fullMulDiv(s, dAcc, Q128);
        return c > cap ? cap : c;
    }

    /// @dev Tokens the whole live set eats while `acc` advances by `dAcc`, saturating on the
    ///      "never dies" kappas a dust stake produces.
    function _tokensFor(uint256 S, uint256 dAcc) internal pure returns (uint256) {
        if (dAcc / Q128 >= type(uint256).max / S) return type(uint256).max;
        return FixedPointMathLib.fullMulDiv(S, dAcc, Q128);
    }

    /// @dev The index value at which a position exhausts. Ceil so the death lands at-or-after the
    ///      exact point (`min` clamps any overshoot). Clamped at 2^240 — far past any reachable
    ///      index — both to saturate the dust-stake "never dies" case and to keep the value
    ///      packable above IDX_BITS without loss.
    function _kappa(uint256 aE, uint256 cap, uint256 s) internal pure returns (uint256) {
        uint256 max = 1 << 240;
        if (aE >= max || cap / s >= 1 << 112) return max;
        uint256 k = aE + FixedPointMathLib.fullMulDivUp(cap, Q128, s);
        return k >= max ? max : k;
    }

    /// @dev The inter-tick distribution, `human-docs/generous-auction.md` §A.6, in one sweep.
    ///
    ///      Write `a_i = w_i * C` for a scalar `C` measured in tokens per unit weight; pouring
    ///      `dT` tokens advances `C` by `dT / W`. Tick `i` runs dry at `C = kappa_i = cap_i / w_i`,
    ///      a value fixed before the pour starts. So: sort by `kappa`, walk it, and each step is
    ///      either "reach the next exhaustion" (drop that tick from `W` and carry on — this is the
    ///      waterfall of §1.2, with the remainder re-flowing by renormalised weights) or "the
    ///      supply runs out first", which fixes `C` and ends it. No iteration to convergence.
    ///
    ///      Every result is floored. A sum of floors is an integer no greater than the floor of the
    ///      sum, so `sum(tokens) <= supply` holds without needing to check it.
    /// @return tokens Allocation per tick, indexed as `w`.
    /// @return isDry Which ticks exhausted, indexed as `w`.
    /// @return dry How many of them. `dry == w.n` means the window ran dry rather than the supply.
    function _pour(Window memory w, uint256 supply)
        internal
        pure
        returns (uint256[] memory tokens, bool[] memory isDry, uint256 dry)
    {
        uint256 n = w.n;

        // Each key is `kappa_i` in the high bits with `i` in the low `IDX_BITS`, so one sort orders
        // the exhaustions and carries the tick index along with them.
        uint256[] memory cap = new uint256[](n);
        uint256[] memory keys = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 c = w.cap[i];
            // A tick can never buy more than the entire supply. Clamping keeps `kappa` under 2^224
            // so the index packs into the low bits, and cannot change the outcome: a tick capped
            // here would need more tokens than exist, so the supply runs out before it does.
            if (c > supply) c = supply;
            cap[i] = c;
            keys[i] = (FixedPointMathLib.fullMulDiv(c, Q96, w.weight[i]) << IDX_BITS) | i;
        }
        LibSort.sort(keys);

        uint256 weightLeft = w.weightSum;
        uint256 C;
        uint256 left = supply;
        for (uint256 k; k < n; ++k) {
            uint256 kappa = keys[k] >> IDX_BITS;
            uint256 dT = FixedPointMathLib.fullMulDiv(weightLeft, kappa - C, Q96);
            if (dT >= left) {
                // Supply runs out inside this segment: `C` stops partway and everyone still
                // standing is served off the same curve.
                C += FixedPointMathLib.fullMulDiv(left, Q96, weightLeft);
                left = 0;
                break;
            }
            C = kappa;
            left -= dT;
            weightLeft -= w.weight[keys[k] & IDX_MASK];
            unchecked {
                ++dry; // the first `dry` entries of `keys` are the ticks that exhausted
            }
        }

        tokens = new uint256[](n);
        isDry = new bool[](n);
        for (uint256 k; k < dry; ++k) {
            isDry[keys[k] & IDX_MASK] = true;
        }

        // The running `budget` is belt-and-braces: the flooring argument above already gives
        // `sum(tokens) <= supply`, so the clamp is unreachable. It costs a few gas per tick and
        // stops a future edit from breaking that argument silently.
        uint256 budget = supply;
        for (uint256 i; i < n; ++i) {
            uint256 a = isDry[i] ? cap[i] : FixedPointMathLib.fullMulDiv(w.weight[i], C, Q96);
            if (a > budget) a = budget;
            tokens[i] = a;
            budget -= a;
        }
    }

    /// @dev `q^d` in Q96. Exponentiation by squaring, so cost is logarithmic in the distance —
    ///      about one cold SLOAD at the far edge of any usable window.
    function _weight(uint256 d) internal view returns (uint256) {
        return FixedPointMathLib.rpow(decayQ, d, Q96);
    }

    /// @inheritdoc IGenerousAuction
    function mintPack() external override returns (uint256 minted) {
        return _mintPack();
    }

    /// @dev Mints the unpacked delta and holds it here. The escrow those fills spent goes to the
    ///      vault in the same call, so supply and backing still arrive together and NAV cannot
    ///      fall — the batching moves WHEN that happens, never whether.
    ///
    ///      The clamp: `Mono.mint` refuses anything dilutive, and NAV ratchets up as other packs
    ///      land. A fill priced below the NAV that now stands cannot mint its full share, so the
    ///      pack takes `maxIssuable` instead of reverting and stranding every claimant behind it.
    ///      All of the escrow is still paid in — it bought less MONO than the book promised, and
    ///      the difference raises NAV for everyone rather than sitting here unspendable.
    function _mintPack() internal returns (uint256 minted) {
        uint256 shares = tokensSold - tokensMinted;
        uint256 assets = currencyRaised - currencyMinted;
        if (shares == 0 || assets == 0) return 0;

        uint256 cap = IMono(token).maxIssuable(assets);
        minted = shares > cap ? cap : shares;
        if (minted == 0) return 0;

        // `tokensMinted` takes what was actually minted, not what was owed — the gap between it
        // and `tokensSold` IS the shortfall, and `claim` reads the ratio off exactly that pair.
        // `currencyMinted` takes the whole delta regardless: the escrow is spent either way, and
        // leaving it unpacked would re-offer it against a NAV that has only risen since.
        tokensMinted += minted;
        currencyMinted += assets;

        IMono(token).mint(minted, assets, address(this));
        emit PackMinted(minted, assets);
    }

    // ---------------------------------------------------------------- payouts

    /// @inheritdoc IGenerousAuction
    /// @dev MONO is not minted per claim. `_mintPack` mints the WHOLE unpacked sale at once,
    ///      against the escrow its fills spent, and this transfers one claimant's share out of it.
    ///      So the first claim pays the vault for everybody and every later one is a transfer.
    ///
    ///      Packing is deliberately NOT done in `_sync`. A pack lifts NAV, and `submitBid` floors
    ///      bids at `nav()`, so packing on every sync would ratchet the floor out from under the
    ///      bottom tick mid-sale — a bid at `floorPrice` would revert `BelowNav` the moment anyone
    ///      synced. Bidding must be able to happen at a still price.
    ///
    ///      The shortfall clamp: a pack whose fills priced below the NAV standing when it is
    ///      minted buys less MONO than the book promised (see `_mintPack`). The balance held here
    ///      is then short of `tokensUnclaimed` and this pays what there is — NET OF STAKE, which
    ///      is bidders' property and never part of any pack.
    function claim(address owner) external override nonReentrant returns (uint256 tokens) {
        tokens = _claim(owner);
        if (tokens != 0) token.safeTransfer(owner, tokens);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev Caller-only, unlike `claim` — nobody may force someone else's winnings into a stake.
    ///      Inside the lock window the stake leg would revert, and winnings must always flow, so
    ///      it degrades to a plain claim there. The reweigh mirrors `stake()`: `_claim` has just
    ///      harvested (and re-anchored) the position, so the new weight applies forward only.
    function claimAndStake() external override nonReentrant returns (uint256 tokens) {
        tokens = _claim(msg.sender);
        if (tokens == 0) return 0;

        if (!_stakeOpen()) {
            token.safeTransfer(msg.sender, tokens);
            return tokens;
        }

        uint256 sOld = stakes[msg.sender];
        uint256 sNew = sOld + tokens;
        _reseat(msg.sender, positions[msg.sender], sOld, sNew);
        stakes[msg.sender] = sNew;
        totalStaked += tokens;

        emit Staked(msg.sender, tokens);
    }

    /// @dev The whole of a claim except the payout leg: settle, pack, harvest, clamp, book.
    ///      Returns what the caller must now deliver — by transfer (`claim`) or by crediting the
    ///      stake account (`claimAndStake`).
    function _claim(address owner) internal returns (uint256 tokens) {
        // Bring the book up to date first, so a claim never pays out less than the schedule owes,
        // then mint whatever it just sold. Both are no-ops once someone else has been through.
        _sync(SYNC_TICKS);
        _mintPack();

        (Position storage p,) = _harvest(owner);

        uint256 owed = p.tokensOwed;
        // Per-position rounding is in the bidder's favour, so it is absorbed here, not in the pot.
        if (owed > tokensUnclaimed) owed = tokensUnclaimed;
        if (owed == 0) return 0;

        // Pro-rata against the REMAINING pot, not a cumulative ratio: each claim takes
        // `owed * held / unclaimed`, which leaves the ratio `held/unclaimed` invariant — so a
        // shortfall (a NAV-clamped pack) gives every claimant the same haircut REGARDLESS of
        // claim order. The cumulative `tokensMinted/tokensSold` ratio looked fair but was not:
        // claims made before the shortfall took ratio 1 and the deficit fell entirely on
        // whoever claimed last.
        uint256 unclaimed = tokensUnclaimed;
        uint256 held = token.balanceOf(address(this)) - totalStaked;
        tokens = held >= unclaimed ? owed : FixedPointMathLib.fullMulDiv(owed, held, unclaimed);
        if (tokens == 0) return 0;

        p.tokensOwed -= uint128(owed);
        tokensUnclaimed = unclaimed - owed;

        // The escrow this position spent, for the log only — it left for the vault when the pack
        // was minted, not now.
        emit Claimed(owner, p.price, tokens, FixedPointMathLib.fullMulDivUp(owed, p.price, WAD));
    }

    // ---------------------------------------------------------------- internals

    /// @dev Materialise whatever the depletion index says this position has consumed since its
    ///      anchor — tokens owed up, escrow charged (ceil) — and re-anchor. O(1), idempotent, and
    ///      bit-identical to the in-memory math `_pourTick` runs, which is what lets the pour skip
    ///      writing positions at all.
    function _harvest(address owner) internal returns (Position storage p, uint256 live) {
        p = positions[owner];
        uint256 price = p.price;
        uint256 amount = p.amount;
        if (price == 0 || amount == 0) return (p, 0);

        Tick storage t = ticks[price];
        uint256 s = stakes[owner];
        if (s != 0) {
            uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
            uint256 eaten = _consumed(s, t.acc - p.accAtEntry, cap);
            if (eaten != 0) {
                uint256 charged = FixedPointMathLib.fullMulDivUp(eaten, price, WAD);
                p.tokensOwed += uint128(eaten);
                amount -= charged;
                p.amount = uint128(amount);
            }
        }
        // Re-anchor in every case — including `s == 0`, where nothing accrued and nothing may
        // accrue retroactively when the owner stakes again.
        p.accAtEntry = t.acc;
        live = amount;
    }

    /// @dev Insert `price` into the sorted list. `prevPrice` must be the **exact** predecessor —
    ///      initialized, below `price`, and with nothing between it and `price`. That is checkable in
    ///      O(1), so there is no walk: an off-by-one hint reverts instead of being repaired on-chain.
    ///      Only ever reached from `submitBid`.
    /// ponytail: a stale hint reverts; the caller re-reads the book and retries.
    function _initializeTick(uint256 prevPrice, uint256 price) internal {
        if (ticks[price].init) return;
        if (prevPrice >= price) revert BadPrevHint();
        if (!ticks[prevPrice].init) revert BadPrevHint();

        uint256 nextPrice = ticks[prevPrice].next;
        if (nextPrice != 0 && nextPrice < price) revert BadPrevHint();

        Tick storage t = ticks[price];
        t.next = nextPrice;
        t.prev = prevPrice;
        t.init = true;

        ticks[prevPrice].next = price;
        if (nextPrice != 0) ticks[nextPrice].prev = price;
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IGenerousAuction
    /// @dev Read-only mirror of `_harvest`, so callers see the truth without anyone harvesting.
    ///      The raw `positions` getter shows only the already-crystallised half.
    function positionOf(address owner) external view override returns (uint256 live, uint256 tokensOwed) {
        Position storage p = positions[owner];
        tokensOwed = p.tokensOwed;
        uint256 price = p.price;
        uint256 amount = p.amount;
        if (price == 0 || amount == 0) return (0, tokensOwed);

        live = amount;
        uint256 s = stakes[owner];
        if (s != 0) {
            uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
            uint256 eaten = _consumed(s, ticks[price].acc - p.accAtEntry, cap);
            if (eaten != 0) {
                tokensOwed += eaten;
                live = amount - FixedPointMathLib.fullMulDivUp(eaten, price, WAD);
            }
        }
    }

    /// @inheritdoc IGenerousAuction
    function tickPositions(uint256 price) external view override returns (address[] memory out) {
        uint256 n = ticks[price].heapSize;
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = heap[price][i + 1];
        }
    }

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256) {
        return _weight(d);
    }

    /// @notice What the next sync window would look like right now, without changing anything.
    /// @dev The honest preview: `tokens[i]` is what tick `price[i]` would receive from a `sync` in
    ///      this block, carry included. Mirrors `_gather` + `_pour` over the same `due()` the sync
    ///      would use, so a UI never has to reimplement the curve. The intra-tick split of each
    ///      figure is by stake — read `tickPositions` + `stakes` for that. Reverts nothing on an
    ///      empty book — the arrays simply come back empty.
    function previewWindow()
        external
        view
        returns (uint256 tau, uint256 weightSum, uint256[] memory price, uint256[] memory tokens)
    {
        uint256 start = settleCursor;
        if (start == 0) start = highestTick;

        Window memory w = _gather(start, type(uint256).max);
        tau = w.tau;
        weightSum = w.weightSum;
        if (w.n == 0) return (tau, weightSum, new uint256[](0), new uint256[](0));

        (uint256[] memory alloc,,) = _pour(w, due());
        price = new uint256[](w.n);
        tokens = new uint256[](w.n);
        for (uint256 i; i < w.n; ++i) {
            price[i] = w.price[i];
            tokens[i] = alloc[i];
        }
    }
}
