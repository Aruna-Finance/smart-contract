// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVarianceAccumulator} from "../../src/interfaces/IVarianceAccumulator.sol";

/// @title MockAccumulator
/// @notice Test double for the variance oracle. Two ways to add samples:
///         - `push(ts, cumSq)`: direct, exact (payout scenarios fix the numbers);
///         - `poke()` / `tryPoke()`: append at block.timestamp, honoring a configurable
///           throttle (`sampleInterval`), with cumulativeSumSq advanced by a settable
///           `pokeIncrement` (0 by default = quiet market). `tryPoke` never reverts
///           (plan: "Poke tidak pernah menggagalkan aksi", R3).
///         Enforces monotonic cumulativeSumSq to mirror invariant I5.
contract MockAccumulator is IVarianceAccumulator {
    Sample[] internal _samples;

    /// @notice Minimum spacing between poked samples (0 = only strictly increasing time).
    uint32 public sampleInterval;
    /// @notice Added to the last cumulativeSumSq by each successful poke.
    uint128 public pokeIncrement;

    error NonMonotonic();
    error OutOfRange();
    error NoSampleAtOrBefore();
    error IntervalNotElapsed(uint32 nextAllowedAt);

    function setSampleInterval(uint32 interval) external {
        sampleInterval = interval;
    }

    function setPokeIncrement(uint128 increment) external {
        pokeIncrement = increment;
    }

    /// @notice Append a sample. cumulativeSumSq must not decrease (I5).
    function push(uint32 timestamp, uint128 cumulativeSumSq) external {
        if (_samples.length != 0 && cumulativeSumSq < _samples[_samples.length - 1].cumulativeSumSq)
        {
            revert NonMonotonic();
        }
        _append(timestamp, cumulativeSumSq);
    }

    /// @notice Append a sample now; reverts while the throttle has not elapsed.
    function poke() external {
        (bool ok, uint32 nextAllowedAt) = _canPoke();
        if (!ok) revert IntervalNotElapsed(nextAllowedAt);
        _pokeNow();
    }

    /// @notice Like `poke` but returns false instead of reverting when throttled.
    function tryPoke() external returns (bool sampled) {
        (bool ok,) = _canPoke();
        if (!ok) return false;
        _pokeNow();
        return true;
    }

    /// @notice Timestamp of the latest sample (0 if none).
    function lastSampleAt() external view returns (uint32) {
        uint256 n = _samples.length;
        return n == 0 ? 0 : _samples[n - 1].timestamp;
    }

    function sampleCount() external view returns (uint32) {
        return uint32(_samples.length);
    }

    function sampleAt(uint32 i) external view returns (Sample memory) {
        if (i >= _samples.length) revert OutOfRange();
        return _samples[i];
    }

    function indexAtOrBefore(uint64 ts) external view returns (uint32) {
        uint256 n = _samples.length;
        for (uint256 i = n; i > 0; i--) {
            if (_samples[i - 1].timestamp <= ts) return uint32(i - 1);
        }
        revert NoSampleAtOrBefore();
    }

    function gapStats() external pure returns (uint32, uint32) {
        return (0, 0);
    }

    // ---------------------------------------------------------------------

    function _canPoke() internal view returns (bool ok, uint32 nextAllowedAt) {
        uint256 n = _samples.length;
        if (n == 0) return (true, 0);
        uint32 spacing = sampleInterval == 0 ? 1 : sampleInterval;
        nextAllowedAt = _samples[n - 1].timestamp + spacing;
        ok = block.timestamp >= nextAllowedAt;
    }

    function _pokeNow() internal {
        uint256 n = _samples.length;
        uint128 prev = n == 0 ? 0 : _samples[n - 1].cumulativeSumSq;
        _append(uint32(block.timestamp), prev + pokeIncrement);
    }

    function _append(uint32 timestamp, uint128 cumulativeSumSq) internal {
        _samples.push(
            Sample({
                timestamp: timestamp,
                tickCumulative: int56(0),
                avgTick: int24(0),
                cumulativeSumSq: cumulativeSumSq,
                elapsed: uint16(0)
            })
        );
        emit Poked(uint32(_samples.length - 1), timestamp, int24(0), cumulativeSumSq);
    }
}
