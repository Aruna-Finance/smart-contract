// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVarianceAccumulator} from "../../src/interfaces/IVarianceAccumulator.sol";

/// @title MockAccumulator
/// @notice Test double for the variance oracle: the test pushes samples directly
///         (timestamp, cumulativeSumSq) so payout scenarios are exact. Enforces
///         monotonic cumulativeSumSq to mirror invariant I5.
contract MockAccumulator is IVarianceAccumulator {
    Sample[] internal _samples;

    error NonMonotonic();
    error OutOfRange();
    error NoSampleAtOrBefore();

    /// @notice Append a sample. cumulativeSumSq must not decrease (I5).
    function push(uint32 timestamp, uint128 cumulativeSumSq) external {
        if (_samples.length != 0 && cumulativeSumSq < _samples[_samples.length - 1].cumulativeSumSq) {
            revert NonMonotonic();
        }
        _samples.push(Sample({timestamp: timestamp, tickCumulative: int56(0), avgTick: int24(0), cumulativeSumSq: cumulativeSumSq}));
    }

    function poke() external {}

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
}
