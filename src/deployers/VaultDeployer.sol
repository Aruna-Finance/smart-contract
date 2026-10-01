// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CoverVault} from "../CoverVault.sol";

/// @title VaultDeployer
/// @notice Holds the CoverVault creation code so ArunaFactory does not have to (plan
///         "Arsitektur factory": the v2 vault is large, and embedding its init code pushed
///         the factory past EIP-170). Its only job is `new CoverVault(...)`.
///
///         Callable by anyone on purpose: a vault deployed here directly is not registered
///         in any factory and is therefore not a market — curators and the indexer only
///         recognize vaults the factory lists (`ArunaFactory.isVault`, `VaultCreated`).
///         Stateless, no owner, no admin. All validation lives in the vault constructor.
contract VaultDeployer {
    /// @notice CoverVault constructor arguments, in constructor order. A struct keeps the
    ///         call readable and away from stack-too-deep.
    struct Args {
        address pool;
        address accumulator;
        address pricer;
        address valuer;
        address positionManager;
        address settlementToken;
        uint32 tenor;
        uint32 gap;
        uint64 anchor;
        uint16 maxUtilizationBps;
        uint128 maxExcessVariance;
        uint16 ewmaAlphaBps;
        uint128 seedVariance;
        uint32 policyCap;
        uint16 keeperShareBps;
        uint128 pokeBounty;
        uint128 finalizeBounty;
        uint128 settleBounty;
    }

    /// @notice Deploy a CoverVault with exactly `a`.
    function deploy(Args calldata a) external returns (address) {
        return address(
            new CoverVault(
                a.pool,
                a.accumulator,
                a.pricer,
                a.valuer,
                a.positionManager,
                a.settlementToken,
                a.tenor,
                a.gap,
                a.anchor,
                a.maxUtilizationBps,
                a.maxExcessVariance,
                a.ewmaAlphaBps,
                a.seedVariance,
                a.policyCap,
                a.keeperShareBps,
                a.pokeBounty,
                a.finalizeBounty,
                a.settleBounty
            )
        );
    }
}
