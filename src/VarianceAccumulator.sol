// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVarianceAccumulator} from "./interfaces/IVarianceAccumulator.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/IUniswapV3PoolMinimal.sol";

/// @title VarianceAccumulator
/// @notice Measures realized variance of a Uniswap v3 pool from inter-sample TWAP ticks
///         and accumulates Σ r² (WAD) into a monotonic running total. One instance per
///         (factory, pool), shared across all tenors (SSOT §4.6). It holds no funds and
///         knows nothing about cohorts, policies, or premiums — it only grows (design §8.1).
///
///         Measurement per sample (design §3.2), using ONLY `observe([0])`:
///           tc_i       = pool tickCumulative now                     [stored]
///           avgTick_i  = floor((tc_i − tc_{i−1}) / Δt_i)             [TWAP over [t_{i−1}, t_i]]
///           r_i        = (avgTick_i − avgTick_{i−1}) · ln(1.0001)    [WAD log-return]
///           Σr²       += r_i² / WAD                                  [WAD variance, rounds down]
///
///         Because `avgTick` needs two cumulatives and a return needs two `avgTick`s:
///           - sample 0 is a baseline only (stores tc_0; avgTick = 0, Σr² = 0);
///           - sample 1 yields the first avgTick but no return (Σr² stays 0);
///           - the first return appears at sample 2.
///         Hence "≥ 2 returns after baseline s" (plan, R12) means `endIndex ≥ s + 2`, and
///         the window variance is `Σr²[end] − Σr²[s]`.
///
///         Only the current observation is read, so the pool needs no extra cardinality
///         and there is no "OLD" revert path (SC-07). `avgTick` is kept as an integer tick
///         (rounded toward −∞ like Uniswap's OracleLibrary), matching the design.
///
///         Conservatism (invariant I5, design §9): a late poke averages the whole missed
///         span into one TWAP, which smooths the path, so realized variance is UNDERSTATED,
///         never overstated. Each sample records `elapsed` (seconds since the previous
///         sample) so a vault can flag a degraded window, and `gapStats()` exposes global
///         staleness. There is deliberately no backfill path (design §8.1 deviation, see
///         v0 notes): it would add an injection surface for a quantity that must only ever
///         round down.
contract VarianceAccumulator is IVarianceAccumulator {
    /// @dev 1e18 fixed-point scale.
    uint256 internal constant WAD = 1e18;

    /// @dev ln(1.0001) scaled to WAD. A tick is log_{1.0001}(price), so a one-tick
    ///      move is a log-return of ln(1.0001). 0.00009999500033... * 1e18.
    int256 internal constant LN_1_0001_WAD = 99995000333308;

    /// @dev Uniswap v3 TickMath bounds. A real pool's average tick always lies inside;
    ///      the clamp only bounds the int24 cast against malformed oracle data.
    int56 internal constant MIN_TICK = -887272;
    int56 internal constant MAX_TICK = 887272;

    /// @notice The Uniswap v3 pool whose variance is measured.
    IUniswapV3PoolMinimal public immutable pool;

    /// @notice Minimum spacing between samples; also the TWAP basis (one sample = one
    ///         interval's TWAP when poked on time). `poke()` reverts before it elapses.
    uint32 public immutable sampleInterval;

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

    /// @param pool_ The Uniswap v3 pool to measure.
    /// @param sampleInterval_ Minimum seconds between samples (forwarded by the factory).
    constructor(address pool_, uint32 sampleInterval_) {
        if (pool_ == address(0) || sampleInterval_ == 0) revert BadConfig();
        pool = IUniswapV3PoolMinimal(pool_);
        sampleInterval = sampleInterval_;
    }

    // ---------------------------------------------------------------------
    // Mutating
    // ---------------------------------------------------------------------

    /// @inheritdoc IVarianceAccumulator
    /// @dev Reverts with IntervalNotElapsed while throttled; a reverting pool read
    ///      propagates. Keepers and the RC runbook use this to see failures loudly.
    function poke() external {
        (bool due, uint32 nextAllowedAt) = _due();
        if (!due) revert IntervalNotElapsed(nextAllowedAt);
        _record(_observeNow());
    }

    /// @inheritdoc IVarianceAccumulator
    /// @dev The vault path (R3): returns false instead of reverting when throttled or
    ///      when the pool read fails. A caller that forwards too little gas only loses
    ///      this one sample (which can only understate variance, never overstate it).
    function tryPoke() external returns (bool added) {
        (bool due,) = _due();
        if (!due) return false;

        try pool.observe(_nowOnly()) returns (int56[] memory tcs, uint160[] memory) {
            if (tcs.length == 0) return false;
            _record(tcs[0]);
            return true;
        } catch {
            return false;
        }
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
    /// @dev A gap is a sample taken ≥ 2·sampleInterval after its predecessor, i.e. at
    ///      least one whole interval was skipped. A poke a few seconds late is not a gap.
    function gapStats() external view returns (uint32 gapCount, uint32 maxGapSeconds) {
        return (_gapCount, _maxGapSeconds);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Throttle. The first poke (lastSampleAt == 0) is always due.
    function _due() internal view returns (bool due, uint32 nextAllowedAt) {
        uint32 last = lastSampleAt;
        if (last == 0) return (true, 0);
        nextAllowedAt = last + sampleInterval;
        due = uint32(block.timestamp) >= nextAllowedAt;
    }

    /// @dev `[0]`: the only `secondsAgos` this contract ever asks for.
    function _nowOnly() internal pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](1); // secondsAgos[0] == 0
    }

    /// @dev Current tickCumulative via observe([0]); reverts if the pool does.
    function _observeNow() internal view returns (int56) {
        (int56[] memory tcs,) = pool.observe(_nowOnly());
        return tcs[0];
    }

    /// @dev Append one sample from the current cumulative `tc`. Never reverts on
    ///      arithmetic: Δt ≥ sampleInterval > 0 (throttle; timestamps are monotonic), the
    ///      cumulative delta wraps like Uniswap's (int56 overflow is defined there), and
    ///      avgTick is clamped to the tick domain before the int24 cast. A very large Δt
    ///      (stalled keeper, odd sequencer clock) is simply one long TWAP: it is recorded
    ///      in `elapsed` / gapStats and never rejected.
    function _record(int56 tc) internal {
        uint32 nowTs = uint32(block.timestamp);
        uint256 count = _samples.length;

        if (count == 0) {
            // Baseline: only the cumulative is meaningful.
            _samples.push(
                Sample({
                    timestamp: nowTs, tickCumulative: tc, avgTick: 0, cumulativeSumSq: 0, elapsed: 0
                })
            );
            lastSampleAt = nowTs;
            emit Poked(0, nowTs, 0, 0);
            return;
        }

        Sample memory prev = _samples[count - 1];
        uint32 dt = nowTs - prev.timestamp; // ≥ sampleInterval > 0 by the throttle

        if (dt >= 2 * uint256(sampleInterval)) {
            unchecked {
                _gapCount++;
            }
            if (dt > _maxGapSeconds) _maxGapSeconds = dt;
        }

        int24 avgTick = _avgTick(prev.tickCumulative, tc, dt);

        // Sample 1 has no previous avgTick: it yields the first TWAP but no return.
        uint128 cum = prev.cumulativeSumSq;
        if (count >= 2) {
            // r = Δtick · ln(1.0001) in WAD; r² accrues (always ≥ 0, rounds down).
            // |Δtick| ≤ 2·887272 caps r² ≈ 3.15e22, far below uint128 max (3.4e38);
            // the uint128 add stays compiler-checked.
            int256 r = (int256(avgTick) - int256(prev.avgTick)) * LN_1_0001_WAD;
            cum += uint128(uint256(r * r) / WAD);
        }

        _samples.push(
            Sample({
                timestamp: nowTs,
                tickCumulative: tc,
                avgTick: avgTick,
                cumulativeSumSq: cum,
                elapsed: dt > type(uint16).max ? type(uint16).max : uint16(dt)
            })
        );
        lastSampleAt = nowTs;
        emit Poked(uint32(count), nowTs, avgTick, cum);
    }

    /// @dev floor((tc − prevTc) / dt), rounding toward −∞ like OracleLibrary.consult,
    ///      clamped to [MIN_TICK, MAX_TICK].
    function _avgTick(int56 prevTc, int56 tc, uint32 dt) internal pure returns (int24) {
        int56 delta;
        unchecked {
            delta = tc - prevTc; // Uniswap tickCumulative wraps; mirror its semantics
        }
        int56 d = int56(uint56(dt));
        int56 avg = delta / d;
        if (delta < 0 && delta % d != 0) avg--;
        if (avg < MIN_TICK) avg = MIN_TICK;
        else if (avg > MAX_TICK) avg = MAX_TICK;
        return int24(avg);
    }
}
