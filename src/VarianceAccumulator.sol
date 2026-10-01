// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVarianceAccumulator} from "./interfaces/IVarianceAccumulator.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/IUniswapV3PoolMinimal.sol";

/// @title VarianceAccumulator
/// @notice Measures realized variance of a Uniswap v3 pool from TWAP ticks and
///         accumulates Σ r² (WAD) into a monotonic running total. One instance per
///         pool, shared across all tenors (SSOT §4.6). It holds no funds and knows
///         nothing about cohorts, policies, or premiums — it only grows (design §8.1).
///
///         Measurement per sample:
///           avgTick_i = TWAP tick over the fixed window [t_i - twapWindow, t_i]
///                       via pool.observe() — never spot slot0() (SSOT §4.4).
///           r_i       = (avgTick_i - avgTick_{i-1}) * ln(1.0001)     [WAD log-return]
///           Σr²      += r_i * r_i / WAD                              [WAD variance]
///
///         Conservatism (invariant I5, design §9): a late poke measures one clean
///         fixed-window TWAP and skips the missed span, so realized variance is
///         UNDERSTATED, never overstated. `gapStats()` makes any staleness visible
///         rather than silent. There is deliberately no backfill overload for the
///         MVP: it would add an injection surface for a quantity that must only ever
///         round down. (Deviation from design §8.1's `poke(uint32[])`; folded here
///         while writing the contract and to be reconciled back into the design doc.)
contract VarianceAccumulator is IVarianceAccumulator {
    /// @dev 1e18 fixed-point scale.
    uint256 internal constant WAD = 1e18;

    /// @dev ln(1.0001) scaled to WAD. A tick is log_{1.0001}(price), so a one-tick
    ///      move is a log-return of ln(1.0001). 0.00009999500033... * 1e18.
    int256 internal constant LN_1_0001_WAD = 99995000333308;

    /// @notice The Uniswap v3 pool whose variance is measured.
    IUniswapV3PoolMinimal public immutable pool;

    /// @notice Minimum spacing between samples. `poke()` reverts before this elapses.
    uint32 public immutable sampleInterval;

    /// @notice TWAP averaging window for each sample's `avgTick`.
    uint32 public immutable twapWindow;

    /// @dev All samples, in strictly increasing timestamp order (append-only).
    Sample[] internal _samples;

    /// @notice Timestamp of the most recent sample (0 until the first poke).
    uint32 public lastSampleAt;

    /// @dev Liveness telemetry (see gapStats()).
    uint32 internal _gapCount;
    uint32 internal _maxGapSeconds;

    error IntervalNotElapsed(uint32 nextAllowedAt);
    error IndexOutOfRange(uint32 index, uint32 count);
    error NoSampleAtOrBefore(uint64 ts);
    error BadConfig();

    constructor(address pool_, uint32 sampleInterval_, uint32 twapWindow_) {
        if (pool_ == address(0) || sampleInterval_ == 0 || twapWindow_ == 0) revert BadConfig();
        pool = IUniswapV3PoolMinimal(pool_);
        sampleInterval = sampleInterval_;
        twapWindow = twapWindow_;
    }

    // ---------------------------------------------------------------------
    // Mutating
    // ---------------------------------------------------------------------

    /// @inheritdoc IVarianceAccumulator
    function poke() external {
        uint32 nowTs = uint32(block.timestamp);

        // Throttle. The first poke (lastSampleAt == 0) always passes and only
        // establishes the baseline tick — no return can be formed without a prior.
        if (lastSampleAt != 0) {
            uint32 nextAllowedAt = lastSampleAt + sampleInterval;
            if (nowTs < nextAllowedAt) revert IntervalNotElapsed(nextAllowedAt);
        }

        (int24 avgTick, int56 currentTickCumulative) = _observe(twapWindow);

        uint256 count = _samples.length;
        if (count == 0) {
            // Baseline sample: no previous tick, so no variance is accrued yet.
            _samples.push(
                Sample({
                    timestamp: nowTs,
                    tickCumulative: currentTickCumulative,
                    avgTick: avgTick,
                    cumulativeSumSq: 0
                })
            );
        } else {
            Sample memory prev = _samples[count - 1];

            // Record the gap for liveness telemetry.
            uint32 gap = nowTs - prev.timestamp;
            if (gap > sampleInterval) {
                unchecked {
                    _gapCount++;
                }
                if (gap > _maxGapSeconds) _maxGapSeconds = gap;
            }

            // r = Δtick * ln(1.0001) in WAD; r² accrues (always ≥ 0, rounds down).
            int256 deltaTick = int256(avgTick) - int256(prev.avgTick);
            int256 r = deltaTick * LN_1_0001_WAD;
            uint256 rSquared = uint256(r * r) / WAD;

            // Safe: |Δtick| ≤ 2·887272 caps rSquared ≈ 3.1e22, far below uint128 max
            // (3.4e38). The uint128 + uint128 add is checked by the compiler.
            uint128 newCumulative = prev.cumulativeSumSq + uint128(rSquared);
            _samples.push(
                Sample({
                    timestamp: nowTs,
                    tickCumulative: currentTickCumulative,
                    avgTick: avgTick,
                    cumulativeSumSq: newCumulative
                })
            );
        }

        lastSampleAt = nowTs;
        Sample memory s = _samples[_samples.length - 1];
        emit Poked(uint32(_samples.length - 1), s.timestamp, s.avgTick, s.cumulativeSumSq);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IVarianceAccumulator
    function sampleCount() external view returns (uint32) {
        return uint32(_samples.length);
    }

    /// @inheritdoc IVarianceAccumulator
    function sampleAt(uint32 i) external view returns (Sample memory) {
        if (i >= _samples.length) revert IndexOutOfRange(i, uint32(_samples.length));
        return _samples[i];
    }

    /// @inheritdoc IVarianceAccumulator
    /// @dev Binary search for the largest index whose timestamp ≤ `ts`.
    function indexAtOrBefore(uint64 ts) external view returns (uint32) {
        uint256 count = _samples.length;
        if (count == 0 || ts < _samples[0].timestamp) revert NoSampleAtOrBefore(ts);

        uint256 lo = 0;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2; // upper mid: converges to the answer
            if (_samples[mid].timestamp <= ts) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return uint32(lo);
    }

    /// @inheritdoc IVarianceAccumulator
    function gapStats() external view returns (uint32 gapCount, uint32 maxGapSeconds) {
        return (_gapCount, _maxGapSeconds);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev One `observe()` yields both the fixed-window TWAP tick and the pool's
    ///      current cumulative tick. `avgTick` is over [now - window, now], rounded
    ///      toward negative infinity to match Uniswap's OracleLibrary convention.
    /// @return avgTick The window TWAP tick.
    /// @return currentTickCumulative The pool's cumulative tick right now (for audit).
    function _observe(uint32 window)
        internal
        view
        returns (int24 avgTick, int56 currentTickCumulative)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        currentTickCumulative = tickCumulatives[1];
        int56 delta = tickCumulatives[1] - tickCumulatives[0];

        int56 avg = delta / int56(uint56(window));
        // Round toward negative infinity (floor) for negative, non-exact deltas.
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) {
            avg--;
        }
        avgTick = int24(avg);
    }
}
