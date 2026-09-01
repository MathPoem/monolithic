// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IMonoHook
/// @notice Public surface of the MONO/INDEX v4 hook: the price accumulator of HANDBOOK §3.6.
/// @dev v4 ships no oracle — `grep -i observ` over v4-core finds nothing — so the accumulator is
///      ours to keep. Three horizons off one update, per D17.
interface IMonoHook {
    /// @notice The three read horizons of HANDBOOK §3.6, in the roles that consume them.
    /// @dev `Short` is the strike leg (money path, used as `max(spot, short)` by the caller),
    ///      `Medium` the accrual rate, `Long` the exercise gate.
    enum Horizon {
        Short,
        Medium,
        Long
    }

    /// @notice One pool's accumulator. 64*3 + 32 + 8 = 232 bits, so it is a single storage slot.
    /// @dev The three EMAs are mean TICKS scaled by `PRECISION`, so the price they imply is a
    ///      geometric mean — the same thing v3's `tickCumulative` averages. There is no stored
    ///      tick: the price that has been standing since `lastUpdate` is the pool's live one, and
    ///      it is read from the PoolManager at the moment it is needed.
    struct Observation {
        int64 emaShort;
        int64 emaMedium;
        int64 emaLong;
        uint32 lastUpdate;
        bool initialized;
    }

    /// @notice A pool named this hook and was initialised. Fires once per pool.
    event ObservationSeeded(PoolId indexed id, int24 tick);

    error InvalidHorizons();
    error NotInitialized();

    /// @notice Fixed-point scale of the stored EMAs, in tick units.
    function PRECISION() external view returns (int256);

    /// @notice Time constants, in seconds. Strictly increasing.
    /// @dev These are `tau`, not window widths: a displacement held for `t` seconds moves the
    ///      reading `1 - exp(-t/tau)` of the way, so `tau` is roughly the 63% point. HANDBOOK's
    ///      windows are still `[SIM]`, which is why they are constructor arguments, not constants.
    function tauShort() external view returns (uint32);
    function tauMedium() external view returns (uint32);
    function tauLong() external view returns (uint32);

    function observations(PoolId id)
        external
        view
        returns (int64 emaShort, int64 emaMedium, int64 emaLong, uint32 lastUpdate, bool initialized);

    /// @notice The mean tick over `h`, brought up to the current block. Reverts `NotInitialized`
    ///         for a pool this hook has never been named by.
    function meanTick(PoolId id, Horizon h) external view returns (int24);

    /// @notice The same reading as a `sqrtPriceX96` — a drop-in for `slot0`'s, so a consumer's
    ///         existing price math needs no change beyond where it reads from.
    function meanSqrtPriceX96(PoolId id, Horizon h) external view returns (uint160);
}
