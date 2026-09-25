// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVarianceAccumulator
/// @notice One accumulator per pool, shared across all tenors (SSOT §4.6, design §5.2).
///         It knows nothing about cohorts, policies, or money — it only grows.
///         The vault maps time ranges to sample indices (design §8.1).
interface IVarianceAccumulator {
    /// @dev Packs into a single 256-bit storage slot: 32 + 56 + 24 + 128 = 240 bits.
    struct Sample {
        uint32 timestamp; // when this sample was taken
        int56 tickCumulative; // raw from pool.observe(), for auditability
        int24 avgTick; // TWAP tick over the interval ending at `timestamp`
        uint128 cumulativeSumSq; // Σ r², WAD, since deploy (monotonic — invariant I5)
    }

    event Poked(uint32 indexed index, uint32 timestamp, int24 avgTick, uint128 cumulativeSumSq);

    /// @notice Take one sample now. Permissionless; reverts unless throttle elapsed.
    function poke() external;

    /// @notice Number of samples recorded so far.
    function sampleCount() external view returns (uint32);

    /// @notice Sample at index `i` (reverts if out of range).
    function sampleAt(uint32 i) external view returns (Sample memory);

    /// @notice Largest sample index whose timestamp is ≤ `ts`. Used by the vault to
    ///         resolve a cohort's endIndex and a policy's start index.
    function indexAtOrBefore(uint64 ts) external view returns (uint32);

    /// @notice Liveness telemetry for the /proof page: how many intervals were missed
    ///         and the worst gap, so a stale oracle is visible rather than silent.
    function gapStats() external view returns (uint32 gapCount, uint32 maxGapSeconds);
}
