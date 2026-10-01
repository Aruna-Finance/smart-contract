// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IVarianceAccumulator
/// @notice One accumulator per (factory, pool), shared across all tenors (SSOT §4.6,
///         design §5.2). It knows nothing about cohorts, policies, or money — it only
///         grows. The vault maps time ranges to sample indices (design §8.1).
///
///         Sample semantics (inter-sample TWAP, design §3.2):
///           - sample 0 is a baseline only: it stores the pool's tickCumulative, and its
///             `avgTick` is meaningless (0);
///           - sample 1 yields the first `avgTick` (TWAP over [t_0, t_1]) but no return;
///           - sample i ≥ 2 yields return r_i = (avgTick_i − avgTick_{i−1})·ln(1.0001).
///         So the first log return lands at sample 2, and for any index s,
///         `sampleAt(e).cumulativeSumSq − sampleAt(s).cumulativeSumSq` is Σ r_i² over
///         i ∈ (s, e], i.e. exactly e − s returns when s ≥ 1.
interface IVarianceAccumulator {
    /// @dev Packs into a single 256-bit storage slot: 32 + 56 + 24 + 128 + 16 = 256 bits.
    struct Sample {
        uint32 timestamp; // when this sample was taken
        int56 tickCumulative; // pool tickCumulative at `timestamp`, from observe([0])
        int24 avgTick; // TWAP tick over [prev.timestamp, timestamp]; 0 for sample 0
        uint128 cumulativeSumSq; // Σ r², WAD, since deploy (monotonic — invariant I5)
        uint16 elapsed; // seconds since the previous sample, saturating at 65535; 0 for sample 0
    }

    event Poked(uint32 indexed index, uint32 timestamp, int24 avgTick, uint128 cumulativeSumSq);

    /// @notice Take one sample now. Permissionless; reverts unless the throttle elapsed.
    function poke() external;

    /// @notice Take one sample now if the throttle has elapsed. Never reverts on a
    ///         throttled call or a failing pool read — returns whether a sample was added
    ///         (plan: a poke never fails a vault action, R3).
    function tryPoke() external returns (bool added);

    /// @notice Timestamp of the most recent sample (0 before the first sample).
    function lastSampleAt() external view returns (uint32);

    /// @notice Minimum spacing between samples, in seconds (also the TWAP basis).
    function sampleInterval() external view returns (uint32);

    /// @notice Number of samples recorded so far.
    function sampleCount() external view returns (uint32);

    /// @notice Sample at index `i` (reverts if out of range).
    function sampleAt(uint32 i) external view returns (Sample memory);

    /// @notice Largest sample index whose timestamp is ≤ `ts`.
    function indexAtOrBefore(uint64 ts) external view returns (uint32);

    /// @notice Liveness telemetry for the /proof page: how many samples arrived after at
    ///         least one whole interval was missed, and the worst gap, so a stale oracle
    ///         is visible rather than silent.
    function gapStats() external view returns (uint32 gapCount, uint32 maxGapSeconds);
}
