// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Math
/// @notice Fixed-direction multiply-then-divide. Design §9.3 forbids bare
///         `a * b / c` anywhere on the money path: the rounding direction must be
///         readable on every line, not inferred. Every caller picks `mulDivDown`
///         (favors the vault by paying/crediting less) or `mulDivUp` (favors the
///         vault by charging/reserving more) per the §9.2 rounding table.
///
///         Aruna's money-path products are small (variance ≈ 1e16 WAD, notionals in
///         6-decimal USDC), so the intermediate `a * b` never approaches 2^256. A
///         full 512-bit mulDiv would be dead weight here; the checked multiply the
///         compiler inserts is the correct guard.
library Math {
    /// @dev floor(a * b / denominator). Reverts on div-by-zero (design intends
    ///      denominator to be a non-zero capital/time quantity at every call site).
    function mulDivDown(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        return (a * b) / denominator;
    }

    /// @dev ceil(a * b / denominator). Uses the identity
    ///      ceil(x/d) = floor((x + d - 1)/d) with x = a*b, valid for d > 0.
    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        uint256 product = a * b;
        // (product + denominator - 1) cannot overflow for Aruna's bounded inputs;
        // the checked add guards the pathological case rather than assuming it away.
        return product == 0 ? 0 : (product - 1) / denominator + 1;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
