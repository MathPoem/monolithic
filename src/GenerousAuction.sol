// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IGenerousAuction} from "./interfaces/IGenerousAuction.sol";

/// @title GenerousAuction
/// @notice One token, one currency, one persistent book, emitting continuously: every
///         `roundBlocks` blocks releases `emissionPerRound` tokens, split across every live tick
///         by geometric weight `q^d` instead of filling high → low. Escrow that does not fill
///         stays where it is and competes again next round. Nobody has to open or close anything.
/// @dev The mechanism is `agent-docs/GenerousAuction.md`; the rule and its derivation are
///      `human-docs/generous-auction.md`. Read one of those before changing anything here.
///
///      The four things a reader needs before reaching `_sync`:
///
///      1. EMISSION IS A SCHEDULE. `emittedToDate()` is a closed form of the block number, so a
///         thousand silent rounds are one division and one sweep — not a thousand of either. What
///         the book could not absorb stays owed in `due()` rather than being burned (carry).
///      2. ONE SWEEP, SOLVED NOT ITERATED. `_pour` parameterises the whole pour by a scalar `C`;
///         tick `i` exhausts at `kappa_i = cap_i / w_i`. Sort by `kappa`, walk once. Exhaustion
///         order is NOT price order, which is why the sort exists and a bitmap would not do.
///      3. NOTHING ITERATES BIDS. `Tick.survival` is a multiplicative depletion index; a position's
///         live escrow is `amount * tick.survival / survivalAtEntry`. O(1) across unlimited rounds.
///      4. ROUNDING IS DOWN EVERYWHERE. A sum of floors is no greater than the floor of the sum, so
///         allocations can never exceed the supply they are drawn from. The shortfall is dust,
///         never insolvency.
///
///      ponytail: unbounded carry. A long dry spell hands the first bidder back a large backlog at
///      their own price; cap the per-sync draw if that turns out to be worth gaming.
contract GenerousAuction is IGenerousAuction, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    /// @notice Scale of `Tick.survival`. Q128 rather than WAD so the multiplicative index has ~38
    ///         decimal digits of headroom before repeated partial fills could round it to zero.
    uint256 internal constant SURVIVAL_ONE = 1 << 128;

    /// @notice Bids may not exceed this multiple of the floor price.
    /// @dev Keeps the tick list from being seeded at absurd prices, and stops a bid paying in full
    ///      for zero tokens.
    uint256 internal constant MAX_PRICE_MULTIPLE = 1e4;

    /// @notice Keeps `floorPrice * MAX_PRICE_MULTIPLE` far from overflowing.
    uint256 internal constant MAX_FLOOR_PRICE = type(uint128).max;

    uint256 internal constant Q96 = 1 << 96;

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

    /// @notice Largest edge weight `q^windowTicks` a deployment may leave unserved.
    /// @dev The window truncates the curve, so the tick just past the edge loses a share of
    ///      `q^windowTicks / W`. Requiring that to be under 1% stops a deployment from silently
    ///      cutting the book in half — pick `q` and `windowTicks` together. Exempt when `q == ONE`,
    ///      where a flat split across exactly `windowTicks` levels is the intended reading.
    uint256 internal constant MAX_EDGE_WEIGHT = Q96 / 100;

    /// @notice Tick budget the implicit syncs inside `submitBid`/`withdrawBid`/`claim` run under.
    /// @dev Bounds how many WINDOWS and dead ticks such a sync walks, NOT the work inside one
    ///      window — `_gather` step 2 always collects its whole band, so a single window of up to
    ///      `windowTicks + 1` live ticks runs to completion whatever this is set to. So the real
    ///      ceiling on what one bidder pays for the backlog is `windowTicks`, and that is a
    ///      deployment choice: measured ~9-17k gas per live tick, a bid drags ~150k behind it at
    ///      `windowTicks = 8` and ~2.3M at the 255 maximum. Pick `windowTicks` with that in mind.
    ///      Running out of budget is not an error — the sync saves `settleCursor` and the rest
    ///      stays in `due()`.
    uint256 internal constant SYNC_TICKS = 128;

    // ---------------------------------------------------------------- immutable config

    /// @dev 18 decimals assumed on `currency` — the WAD fill math is not decimal-agnostic.
    address public immutable token;
    address public immutable currency;
    address public immutable fundsRecipient;
    address public immutable tokensRecipient;

    /// @dev The only privileged role, and it can do exactly one thing: re-schedule emission from a
    ///      future round boundary. It cannot touch the book, the escrow, or anything already owed.
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

    // ---------------------------------------------------------------- state

    mapping(uint256 price => Tick) public ticks;
    mapping(address owner => mapping(uint256 price => Position)) public positions;

    uint256 public tokensUnclaimed;
    uint256 public currencyRaised;
    uint256 public tokensSold;
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
        if (c.fundsRecipient == address(0) || c.tokensRecipient == address(0)) revert InvalidParams();
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

        token = c.token;
        currency = c.currency;
        fundsRecipient = c.fundsRecipient;
        tokensRecipient = c.tokensRecipient;
        admin = c.admin;
        floorPrice = c.floorPrice;
        tickSpacing = c.tickSpacing;
        decayQ = c.decayQ;
        windowTicks = c.windowTicks;
        startBlock = c.startBlock;
        endBlock = c.endBlock;
        highestTick = c.floorPrice;

        anchorBlock = c.startBlock;
        roundBlocks = c.roundBlocks;
        emissionPerRound = c.emissionPerRound;

        Tick storage floorTick = ticks[c.floorPrice];
        floorTick.init = true;
        floorTick.survival = SURVIVAL_ONE;
    }

    /// @dev Derived rather than stored: sending `token` in funds the sale, and there is no second
    ///      ledger to keep in step. Holding `tokensUnclaimed` back is what stops a later sync
    ///      reselling tokens already won.
    function remaining() public view returns (uint256) {
        return token.balanceOf(address(this)) - tokensUnclaimed;
    }

    // ---------------------------------------------------------------- emission schedule

    /// @notice Cumulative tokens released by completed rounds as of now.
    function emittedToDate() public view returns (uint256) {
        return _emittedAt(block.number);
    }

    /// @notice What a `sync` right now would distribute.
    /// @dev The gap between the schedule and what has actually been sold — so a round the book
    ///      could not absorb stays owed here rather than being burned. Capped by what the contract
    ///      actually holds, because a schedule promising more than was ever funded is not a debt.
    function due() public view returns (uint256) {
        uint256 sold = tokensSold;
        uint256 target = _emittedAt(block.number);
        if (target <= sold) return 0;
        // `remaining()` is a cold external `balanceOf`, and every bid and claim runs an implicit
        // sync — so it stays behind the early return, off the path where nothing is owed.
        uint256 owed = target - sold;
        uint256 avail = remaining();
        return owed < avail ? owed : avail;
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
    function setRoundParams(uint64 roundBlocks_, uint128 emissionPerRound_) external {
        if (msg.sender != admin) revert Unauthorized();
        if (roundBlocks_ == 0) revert InvalidParams();

        // A queued generation that has already taken effect becomes the anchor, so the boundary
        // below is measured under the rate actually running.
        uint64 from = pendingFrom;
        if (from != 0 && block.number >= from) {
            anchorEmitted = uint128(_accrue(anchorEmitted, anchorBlock, roundBlocks, emissionPerRound, from));
            anchorBlock = from;
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

    // ---------------------------------------------------------------- bidding

    /// @inheritdoc IGenerousAuction
    /// @dev A position is keyed by `(owner, price)`. Bidding again at the same price harvests the
    ///      existing accrual and grows the position; it never creates a second record.
    ///      `prevTick` is ignored when `price` is already initialized.
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external nonReentrant {
        if (endBlock != 0 && block.number >= endBlock) revert AuctionEnded();
        if (amount == 0 || owner == address(0)) revert InvalidParams();
        if (price < floorPrice) revert BidTooLow();
        if (price > floorPrice * MAX_PRICE_MULTIPLE) revert BidTooHigh();
        if (price % tickSpacing != 0) revert TickNotAligned();
        // Must buy at least 1 wei of token, else the bid pays in full for nothing.
        if (uint256(amount) * WAD < price) revert BidTooSmall();

        // Settle what the old book already earned BEFORE this bid joins it. Without this a bidder
        // could arrive after a long silence and take a share of emission that accrued while they
        // were not in the book at all.
        _sync(SYNC_TICKS);

        currency.safeTransferFrom(msg.sender, address(this), amount);

        _initializeTick(prevTick, price);
        if (price > highestTick) highestTick = price;

        Tick storage t = ticks[price];
        // Harvest before resizing: `survivalAtEntry` is only meaningful for one `amount`.
        (Position storage p, uint256 live) = _harvest(t, positions[owner][price], price);
        p.amount = uint128(live + amount);
        p.survivalAtEntry = t.survival;
        p.epoch = t.epoch;
        t.demand += amount;

        emit BidSubmitted(owner, price, amount);
    }

    /// @notice Take back everything still live at `(msg.sender, price)`. Tokens already won stay
    ///         claimable.
    /// @dev ponytail: a free cancel option outside settlement. That is the price of never trapping
    ///      escrow — an offer that never clears must always have an exit. Charge a cancel fee here
    ///      if the option turns out to be worth gaming.
    function withdrawBid(uint256 price) external nonReentrant returns (uint256 live) {
        // Pay for the emission this escrow was standing behind before taking it out.
        _sync(SYNC_TICKS);

        Tick storage t = ticks[price];
        Position storage p;
        (p, live) = _harvest(t, positions[msg.sender][price], price);
        if (live == 0) revert NoPosition();

        p.amount = 0;
        t.demand -= live;

        currency.safeTransfer(msg.sender, live);

        emit BidWithdrawn(msg.sender, price, live);
    }

    // ---------------------------------------------------------------- sync

    /// @notice Distribute everything the schedule has released and the book has not yet absorbed.
    /// @dev Permissionless and always callable — it only ever moves the book to where the schedule
    ///      already says it should be, so who calls it and when decides nothing but who pays the
    ///      gas.
    function sync(uint256 maxTicks) external nonReentrant {
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
    function _sync(uint256 maxTicks) internal {
        // Inlined `due()` so the schedule is read once rather than again for the event.
        uint256 emitted = _emittedAt(block.number);
        uint256 alreadySold = tokensSold;
        if (emitted <= alreadySold) return;
        uint256 supply = emitted - alreadySold;
        uint256 avail = remaining();
        if (supply > avail) supply = avail;
        if (supply == 0) return;

        uint256 price = settleCursor;
        bool fromTop = price == 0;
        if (fromTop) price = highestTick;

        uint256 sold;
        uint256 steps;
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
            (poured, drained) = _pourWindow(w, supply);
            supply -= poured;
            sold += poured;
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
        while (price != 0 && ticks[price].demand == 0) {
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
        w.demand = new uint256[](size);
        w.weight = new uint256[](size);

        while (price != 0 && price >= low) {
            Tick storage t = ticks[price];
            uint256 dem = t.demand;
            if (dem != 0) {
                uint256 wt = _weight((w.tau - price) / tickSpacing);
                if (wt == 0) break; // q^d has rounded away; nothing further down can reach the book
                w.price[w.n] = price;
                w.demand[w.n] = dem;
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

    /// @dev Solve the window exactly, then write the result back through the depletion index.
    /// @return sold Tokens allocated in this window.
    /// @return drained True when the supply ran out inside this window rather than the window
    ///         running dry — i.e. nothing below it can be reached, so settle is finished.
    function _pourWindow(Window memory w, uint256 supply) internal returns (uint256 sold, bool drained) {
        (uint256[] memory tokens, bool[] memory isDry, uint256 dry) = _pour(w, supply);
        // A survivor means the supply ran out, not the window. All dry: the book below can still
        // be served, so the sweep keeps walking.
        drained = dry < w.n;

        uint256 raised;
        for (uint256 i; i < w.n; ++i) {
            uint256 got = tokens[i];
            if (got == 0) continue;
            uint256 dem = w.demand[i];
            uint256 spent = FixedPointMathLib.fullMulDiv(got, w.price[i], WAD);

            Tick storage t = ticks[w.price[i]];
            // `isDry` comes from the sweep, NOT from comparing `got` to `cap`: `cap` is clamped to
            // the supply, so a tick that merely soaked up everything on offer would otherwise look
            // exhausted and be charged its entire budget for a partial fill.
            if (isDry[i] || spent >= dem) {
                // Whole tick clears, and pays its whole budget.
                _clearTick(t);
                raised += dem;
                emit TickFilled(w.price[i], dem, false);
            } else {
                uint256 keep = dem - spent;
                uint256 survival = FixedPointMathLib.fullMulDiv(t.survival, keep, dem);
                if (survival == 0) {
                    // ponytail: unreachable in practice — Q128 needs ~128 consecutive halvings
                    // of one tick to land here, by which point every position at it retains
                    // under 2^-128 of its escrow. Treated as a full clear so `demand` can never
                    // outlive the index that prices it; `keep` becomes unrecoverable dust.
                    _clearTick(t);
                } else {
                    t.demand = keep;
                    t.survival = survival;
                }
                raised += spent;
                emit TickFilled(w.price[i], spent, true);
            }
            sold += got;
        }

        tokensUnclaimed += sold;
        currencyRaised += raised;
    }

    /// @dev Retire a tick that filled 100%. Driving `survival` to zero would break both future
    ///      entries and the division that prices them, so the epoch is bumped and the index reset
    ///      instead: every position below the new epoch is by definition fully consumed.
    function _clearTick(Tick storage t) internal {
        t.demand = 0;
        t.epoch += 1;
        t.survival = SURVIVAL_ONE;
    }

    /// @dev The distribution itself, `human-docs/generous-auction.md` §A.6, in one sweep.
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
            uint256 c = FixedPointMathLib.fullMulDiv(w.demand[i], WAD, w.price[i]);
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

    // ---------------------------------------------------------------- payouts

    /// @notice Collect the tokens accrued at `(owner, price)`. Does NOT close the position — escrow
    ///         still live keeps competing in later rounds.
    /// @dev Permissionless; tokens always go to `owner`.
    function claim(address owner, uint256 price) external nonReentrant returns (uint256 tokens) {
        // Bring the book up to date first, so a claim never pays out less than the schedule owes.
        _sync(SYNC_TICKS);

        Tick storage t = ticks[price];
        (Position storage p,) = _harvest(t, positions[owner][price], price);

        tokens = p.tokensOwed;
        // Per-position rounding is in the bidder's favour, so it is absorbed here, not in the pot.
        if (tokens > tokensUnclaimed) tokens = tokensUnclaimed;
        if (tokens == 0) return 0;

        p.tokensOwed -= uint128(tokens);
        tokensUnclaimed -= tokens;

        token.safeTransfer(owner, tokens);

        emit Claimed(owner, price, tokens);
    }

    /// @notice Pay out the filled currency. Safe to call before bidders claim.
    function sweepCurrency() external nonReentrant {
        uint256 amount = currencyRaised;
        if (amount == 0) return;
        currencyRaised = 0;
        currency.safeTransfer(fundsRecipient, amount);

        emit CurrencySwept(fundsRecipient, amount);
    }

    /// @notice Pull back supply the schedule has not released.
    /// @dev Two things are out of reach: `tokensUnclaimed`, which `remaining()` already excludes,
    ///      and `due()` — which under carry includes emission from rounds the book could not
    ///      absorb. So this can only ever take tokens that are funding *future* rounds.
    function sweepUnsoldTokens(uint256 amount) external nonReentrant {
        _sync(SYNC_TICKS);
        if (amount == 0 || amount > remaining() - due()) revert InvalidAmount();

        token.safeTransfer(tokensRecipient, amount);

        emit UnsoldTokensSwept(tokensRecipient, amount);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Materialise whatever the depletion index says this position has spent, converting it to
    ///      `tokensOwed`, and return what is still live. O(1) and idempotent (§3.2).
    function _harvest(Tick storage t, Position storage p, uint256 price)
        internal
        returns (Position storage, uint256 live)
    {
        uint128 amount = p.amount;
        if (amount == 0) {
            // Nothing live: re-base so a later deposit reads the current index.
            p.survivalAtEntry = t.survival;
            p.epoch = t.epoch;
            return (p, 0);
        }

        if (p.epoch != t.epoch) {
            // The tick cleared whole at some point while this position was in it.
            p.tokensOwed += uint128(FixedPointMathLib.fullMulDiv(amount, WAD, price));
            p.amount = 0;
            p.survivalAtEntry = t.survival;
            p.epoch = t.epoch;
            return (p, 0);
        }

        // Round live escrow DOWN so the sum of positions can never exceed `Tick.demand`; the dust
        // that leaves behind is unrecoverable rather than insolvent.
        live = FixedPointMathLib.fullMulDiv(amount, t.survival, p.survivalAtEntry);
        uint256 spent = amount - live;
        if (spent > 0) {
            p.tokensOwed += uint128(FixedPointMathLib.fullMulDiv(spent, WAD, price));
            p.amount = uint128(live);
            p.survivalAtEntry = t.survival;
        }
        return (p, live);
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
        t.survival = SURVIVAL_ONE;
        t.init = true;

        ticks[prevPrice].next = price;
        if (nextPrice != 0) ticks[nextPrice].prev = price;
    }

    // ---------------------------------------------------------------- views

    /// @notice What `(owner, price)` holds right now: escrow still competing, and tokens won.
    /// @dev Read-only mirror of `_harvest` (§3.2), so callers see the truth without anyone
    ///      harvesting. The raw `positions` getter shows only the already-crystallised half.
    function positionOf(address owner, uint256 price) external view returns (uint256 live, uint256 tokensOwed) {
        Tick storage t = ticks[price];
        Position storage p = positions[owner][price];

        uint256 amount = p.amount;
        tokensOwed = p.tokensOwed;
        if (amount == 0) return (0, tokensOwed);

        if (p.epoch != t.epoch) {
            return (0, tokensOwed + FixedPointMathLib.fullMulDiv(amount, WAD, price));
        }
        live = FixedPointMathLib.fullMulDiv(amount, t.survival, p.survivalAtEntry);
        uint256 spent = amount - live;
        if (spent > 0) tokensOwed += FixedPointMathLib.fullMulDiv(spent, WAD, price);
    }

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256) {
        return _weight(d);
    }

    /// @notice What the next sync window would look like right now, without changing anything.
    /// @dev The honest preview: `tokens[i]` is what tick `price[i]` would receive from a `sync` in
    ///      this block, carry included. Mirrors `_gather` + `_pour` over the same `due()` the sync
    ///      would use, so a UI never has to reimplement the curve. Reverts nothing on an empty
    ///      book — the arrays simply come back empty.
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
