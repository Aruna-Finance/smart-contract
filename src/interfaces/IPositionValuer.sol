// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPositionValuer
/// @notice Derives `varNotional` from a Uniswap v3 position's gamma exposure —
///         a function of its liquidity and range width (design §8.4). This is the
///         mechanism that makes protection position-attached rather than a naked
///         variance call: the notional a buyer hedges is NOT their input, it falls
///         out of the position they actually hold. Narrow-range and wide-range
///         positions no longer get the same hedge per dollar.
///
///         Stateless and `view`. The mapping knots are calibration (§6.4); the design
///         decision fixed here is only that varNotional MUST descend from the
///         position, never be typed by the caller.
interface IPositionValuer {
    /// @return varNotional Settlement-token base units paid per 1 unit of variance
    ///         (WAD), per the §6.0 unit convention.
    function varNotionalFor(uint256 positionTokenId) external view returns (uint128 varNotional);
}
