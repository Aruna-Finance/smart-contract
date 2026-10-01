// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VarianceAccumulator} from "../VarianceAccumulator.sol";

/// @title AccumulatorDeployer
/// @notice Holds the VarianceAccumulator creation code so ArunaFactory does not have to
///         (plan "Arsitektur factory": factory without child creation code, every contract
///         under EIP-170). Its only job is `new VarianceAccumulator(...)`.
///
///         Callable by anyone on purpose: an accumulator created here but not through a
///         factory is simply not registered anywhere, so it is not part of any market. A
///         curator resolves a market's accumulator only via `ArunaFactory.accumulatorOf`.
///         Stateless, no owner, no admin.
contract AccumulatorDeployer {
    /// @notice Deploy an accumulator for `pool` sampling at most every `sampleInterval`
    ///         seconds. Parameter validation is the accumulator constructor's own.
    function deploy(address pool, uint32 sampleInterval) external returns (address) {
        return address(new VarianceAccumulator(pool, sampleInterval));
    }
}
