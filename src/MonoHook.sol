// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {IMonoHook} from "./interfaces/IMonoHook.sol";

/// @title MonoHook
/// @notice The price accumulator of HANDBOOK §3.6, living where the handbook says it must: in our
///         own v4 hook. Uniswap v4 has no oracle of its own, so every TWAP-gated trigger in this
///         protocol reads from here.
/// @dev The mechanism is `agent-docs/MonoHook.md`. Three things a reader needs:
///
///      1. IT IS AN EMA, NOT A RING BUFFER. v3's oracle stores an array of `tickCumulative`
///         samples and binary-searches it. That needs cardinality large enough to span the window,
///         which for a 12-24h horizon on a busy pool is thousands of cold slots — expensive to
///         grow, and it fails closed (`OLD`) when it has not been grown enough. An exponential
///         moving average in tick space holds the same information in ONE slot, at any horizon,
///         with no growth, no binary search and no cardinality to manage.
///
///      2. THE PRICE THAT ACCRUES IS THE PRE-SWAP ONE. `beforeSwap` reads the tick the pool is
///         sitting on — the price that has STOOD since `lastUpdate` — and accrues exactly that
///         over the elapsed seconds. The tick a swap is about to move to has been true for zero
///         seconds and is worth zero. So a price pushed and released inside one block contributes
///         nothing: to move this reading you have to hold the displacement across a block
///         boundary, exposed to arbitrage the whole time. That is §3.6's "no way to influence the
///         machine except by paying it".
///
///      3. THE HORIZONS ARE `tau`, NOT WINDOW WIDTHS. A displacement held `t` seconds moves the
///         reading `1 - exp(-t/tau)` of the way. They are constructor arguments because HANDBOOK's
///         exact lengths are still `[SIM]`.
///
///      Why the accumulator lives in `beforeSwap` and there is no `afterSwap`: point 2 means the
///      only tick this contract ever needs is the one standing BEFORE a swap, and between swaps
///      the standing tick is the pool's live one, which a view can read for itself. An `afterSwap`
///      leg would cost a second hook call and a stored tick to record something already knowable.
///      It also leaves `beforeSwap` — the bit the §3.4 tax needs for its dynamic-fee override —
///      already claimed, so adding the tax later does not change this hook's address, and so does
///      not force a new pool and a POL migration.
contract MonoHook is IMonoHook, BaseHook {
    using StateLibrary for IPoolManager;

    /// @dev 1e6 leaves the stored EMAs at most `887272e6` ~ 8.9e11, ten million times inside
    ///      `int64`, while resolving a millionth of a tick — a tick is already only 1bp.
    int256 public constant override PRECISION = 1e6;

    uint32 public immutable override tauShort;
    uint32 public immutable override tauMedium;
    uint32 public immutable override tauLong;

    mapping(PoolId id => Observation) public override observations;

    constructor(IPoolManager manager_, uint32 tauShort_, uint32 tauMedium_, uint32 tauLong_) BaseHook(manager_) {
        // Strictly increasing: the three horizons are only meaningful as fast/medium/slow, and a
        // deployment that transposed two of them would read plausibly and gate wrongly.
        if (tauShort_ == 0 || tauShort_ >= tauMedium_ || tauMedium_ >= tauLong_) revert InvalidHorizons();
        tauShort = tauShort_;
        tauMedium = tauMedium_;
        tauLong = tauLong_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            // Seed from the pool's opening price, so the oracle is live before the first swap
            // rather than dark until one arrives.
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- hooks

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId id = key.toId();
        int64 e = SafeCastLib.toInt64(int256(tick) * PRECISION);
        observations[id] =
            Observation({emaShort: e, emaMedium: e, emaLong: e, lastUpdate: uint32(block.timestamp), initialized: true});
        emit ObservationSeeded(id, tick);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Fold the seconds since `lastUpdate` into every horizon at the price that stood for
    ///      them, then stamp the clock. Several swaps in one block only reach the `dt == 0` case,
    ///      so the block's closing price is what starts accruing next block.
    ///
    ///      Returns fee override 0, which carries no `OVERRIDE_FEE_FLAG`, so the pool keeps its
    ///      own LP fee. That is where the §3.4 tax curve goes when its shape is settled.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Observation memory o = observations[id];

        uint32 nowTs = uint32(block.timestamp);
        uint32 dt;
        // Wraps in 2106, and wraps correctly: modular subtraction still gives the true elapsed
        // seconds unless a pool sits unswapped for 136 years. Same assumption v3 makes.
        unchecked {
            dt = nowTs - o.lastUpdate;
        }

        // `initialized` is always true here — this hook is inside the pool's own key, so
        // `afterInitialize` ran first — but accruing against a zero tick would silently mean a
        // price of 1:1, which is worth one branch to make impossible.
        if (o.initialized && dt != 0) {
            (, int24 tick,,) = poolManager.getSlot0(id);
            int256 target = int256(tick) * PRECISION;
            o.emaShort = _decay(o.emaShort, target, dt, tauShort);
            o.emaMedium = _decay(o.emaMedium, target, dt, tauMedium);
            o.emaLong = _decay(o.emaLong, target, dt, tauLong);
            o.lastUpdate = nowTs;
            observations[id] = o;
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IMonoHook
    function meanTick(PoolId id, Horizon h) public view override returns (int24) {
        Observation memory o = observations[id];
        if (!o.initialized) revert NotInitialized();

        int64 ema;
        uint32 tau;
        if (h == Horizon.Short) {
            (ema, tau) = (o.emaShort, tauShort);
        } else if (h == Horizon.Medium) {
            (ema, tau) = (o.emaMedium, tauMedium);
        } else {
            (ema, tau) = (o.emaLong, tauLong);
        }

        uint32 dt;
        unchecked {
            dt = uint32(block.timestamp) - o.lastUpdate;
        }
        int256 settled = int256(ema);
        if (dt != 0) {
            // The same accrual `_beforeSwap` would do, against the same live tick — so a pool
            // nobody has swapped in hours reads as the price actually standing rather than as a
            // stale average, and reading never disagrees with the next swap's write.
            (, int24 tick,,) = poolManager.getSlot0(id);
            settled = int256(_decay(ema, int256(tick) * PRECISION, dt, tau));
        }

        // Round half away from zero. Solidity truncates towards zero, so the sign has to be
        // carried into the bias or negative ticks would round the wrong way.
        int256 half = settled >= 0 ? PRECISION / 2 : -PRECISION / 2;
        return SafeCastLib.toInt24((settled + half) / PRECISION);
    }

    /// @inheritdoc IMonoHook
    function meanSqrtPriceX96(PoolId id, Horizon h) external view override returns (uint160) {
        return TickMath.getSqrtPriceAtTick(meanTick(id, h));
    }

    // ---------------------------------------------------------------- internals

    /// @dev One EMA step: `ema' = target + (ema - target) * exp(-dt/tau)`.
    ///
    ///      The cheap alternative is the Padé form `tau / (dt + tau)`, which needs no exponential.
    ///      It is not used: it is only first-order, so over a long silence it leaves a residual
    ///      gap of `tau / (dt + tau)` where the truth is `exp(-dt/tau)` — a pool untouched for a
    ///      month would still read 2.4% of the way back to a price a month stale. `expWad` is one
    ///      solady call, already a dependency, and it is exact. What a quiet pool reads is a money
    ///      input, so that is not a close call.
    ///
    ///      `expWad` saturates to 0 below `exp(-41.4)` rather than reverting, which is the right
    ///      behaviour: past ~41 time constants the old reading genuinely is gone.
    function _decay(int64 ema, int256 target, uint32 dt, uint32 tau) internal pure returns (int64) {
        int256 factor = FixedPointMathLib.expWad(-(int256(uint256(dt)) * 1e18) / int256(uint256(tau)));
        // A convex combination of `ema` and `target`, so it is bounded by the wider of the two and
        // cannot leave the tick range both came from.
        return SafeCastLib.toInt64(target + (int256(ema) - target) * factor / 1e18);
    }
}
