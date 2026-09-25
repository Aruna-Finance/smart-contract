// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniswapV3PoolMinimal
/// @notice The slice of a Uniswap v3 pool Aruna reads. The vault reads token0/token1/
///         fee once at deploy to pin the pool it protects and to match positions
///         (invariant I8). The accumulator reads `observe` for TWAP; the settlement
///         path never touches `slot0` (design §3.5) — spot is only ever read by the
///         UI for an in/out-of-range badge, never by these contracts.
interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);

    /// @notice Cumulative tick & seconds-per-liquidity at each `secondsAgo`, for TWAP.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
