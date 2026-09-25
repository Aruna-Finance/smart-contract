// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";

/// @title MockValuer
/// @notice Returns a settable varNotional so vault tests fix the position-derived
///         notional directly (the real derivation is calibration, tested elsewhere).
contract MockValuer is IPositionValuer {
    uint128 public varNotional;

    function setVarNotional(uint128 v) external {
        varNotional = v;
    }

    function varNotionalFor(uint256) external view returns (uint128) {
        return varNotional;
    }
}
