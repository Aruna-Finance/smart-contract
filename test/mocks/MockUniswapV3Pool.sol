// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

/// @title MockUniswapV3Pool
/// @notice Test double for a Uniswap v3 pool's oracle. The pool has a current tick, and tickCumulative
///         advances by `tick · Δt` with block time, exactly like Uniswap's oracle.
///         `setTick` first checkpoints the cumulative at now, then switches tick, so
///         `observe([0])` deltas between two samples give the inter-sample TWAP
///         (design §3.2). `observe(secondsAgo > 0)` is reconstructed from the
///         checkpoints; asking for a time before the first checkpoint reverts "OLD",
///         as Uniswap does when the oracle history is too short.
contract MockUniswapV3Pool is IUniswapV3PoolMinimal {
    struct Checkpoint {
        uint32 timestamp;
        int56 tickCumulative; // cumulative at `timestamp`
        int24 tick; // tick in force from `timestamp` until the next checkpoint
    }

    Checkpoint[] internal _checkpoints;

    // --- pool identity (settable so factory/vault pool matching can be tested) ---
    address public token0;
    address public token1;
    uint24 public fee = 3000;

    error OLD();

    constructor() {
        _checkpoints.push(Checkpoint(uint32(block.timestamp), 0, 0));
    }

    function setTokens(address token0_, address token1_, uint24 fee_) external {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    /// @notice Checkpoint the cumulative at now, then switch the tick.
    function setTick(int24 tick_) external {
        uint32 nowTs = uint32(block.timestamp);
        int56 cumNow = _cumulativeAt(nowTs);
        Checkpoint storage last = _checkpoints[_checkpoints.length - 1];
        if (last.timestamp == nowTs) {
            last.tick = tick_; // same-second update: latest tick wins
        } else {
            _checkpoints.push(Checkpoint(nowTs, cumNow, tick_));
        }
    }

    /// @notice Current tick.
    function currentTick() public view returns (int24) {
        return _checkpoints[_checkpoints.length - 1].tick;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            uint32 ago = secondsAgos[i];
            if (ago > block.timestamp) revert OLD();
            tickCumulatives[i] = _cumulativeAt(uint32(block.timestamp - ago));
        }
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, currentTick(), 0, 0, 0, 0, true);
    }

    /// @dev Cumulative at `t`: the latest checkpoint at-or-before `t`, extrapolated
    ///      linearly with the tick in force since then.
    function _cumulativeAt(uint32 t) internal view returns (int56) {
        uint256 n = _checkpoints.length;
        for (uint256 i = n; i > 0; i--) {
            Checkpoint memory c = _checkpoints[i - 1];
            if (c.timestamp <= t) {
                return c.tickCumulative + int56(c.tick) * int56(uint56(t - c.timestamp));
            }
        }
        revert OLD();
    }
}
