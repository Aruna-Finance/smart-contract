// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

/// @title MockUniswapV3Pool
/// @notice Test double for a Uniswap v3 pool's `observe()`. The test drives the
///         window TWAP tick directly via `setAvgTick`: for a call
///         `observe([window, 0])` it returns tickCumulatives such that
///         (tc[1] - tc[0]) / window == avgTick, i.e. tc[0]=0, tc[1]=avgTick*window.
contract MockUniswapV3Pool is IUniswapV3PoolMinimal {
    int24 public avgTick;
    int56 public baseCumulative; // added to tc[1] so stored tickCumulative can advance

    function setAvgTick(int24 avgTick_) external {
        avgTick = avgTick_;
    }

    function setBaseCumulative(int56 base_) external {
        baseCumulative = base_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        // secondsAgos is expected to be [window, 0]. tc at `window` ago = base;
        // tc now = base + avgTick*window, so the delta over the window == avgTick*window.
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            uint32 ago = secondsAgos[i];
            if (ago == 0) {
                // "now": include the full window's worth of avgTick on top of base.
                tickCumulatives[i] = baseCumulative;
            } else {
                // `ago` seconds back: base minus avgTick*ago.
                tickCumulatives[i] = baseCumulative - int56(avgTick) * int56(uint56(ago));
            }
        }
    }

    // --- unused surface, present to satisfy the interface ---

    function slot0()
        external
        pure
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (0, 0, 0, 0, 0, 0, true);
    }

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function fee() external pure returns (uint24) {
        return 3000;
    }
}
