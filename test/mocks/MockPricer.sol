// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPremiumPricer} from "../../src/interfaces/IPremiumPricer.sol";

/// @title MockPricer
/// @notice Returns a settable flat premium so vault tests can assert exact cash flows
///         independently of pricing calibration.
contract MockPricer is IPremiumPricer {
    uint128 public premium;

    function setPremium(uint128 premium_) external {
        premium = premium_;
    }

    function quote(uint128, uint64, uint32, uint128, uint128, uint128)
        external
        view
        returns (uint128)
    {
        return premium;
    }
}
