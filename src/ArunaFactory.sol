// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VarianceAccumulator} from "./VarianceAccumulator.sol";
import {CoverVault} from "./CoverVault.sol";

/// @title ArunaFactory
/// @notice Permissionless deployer and registry (design §2): one VarianceAccumulator
///         per Uniswap v3 pool — reused across every tenor of that pool — and one
///         CoverVault per (pool, tenor). It holds no funds and makes no pricing
///         decision; it only wires immutable dependencies together and records the
///         addresses so the frontend and integration layer resolve a market from
///         (pool, tenor) alone.
///
///         Layer split honored here (design §2 line 24): the two contracts the factory
///         constructs are the measurer (accumulator) and the custodian (vault). The
///         PRICER is calibrated per tenor (§6.4: a new tenor is a new deployment plus
///         two calibrated g tables, not a code change) and the VALUER carries per-market
///         gamma calibration, so both are deployed OUTSIDE and passed in per call — the
///         factory never bakes calibration. `positionManager` and `settlementToken` are
///         chain-level infrastructure (one NFPM, one settlement token per deployment),
///         so they are factory immutables set once at construction.
///
///         "Satu vault per (pool, tenor)" (§2 line 39) is enforced literally: a second
///         create for the same pair reverts. Immutability is the whole safety story —
///         nothing here can retarget or reprice a market once it exists.
contract ArunaFactory {
    /// @notice Uniswap v3 position manager every vault reads positions from.
    address public immutable positionManager;
    /// @notice Settlement token (e.g. USDC) every vault custodies.
    address public immutable settlementToken;

    /// @notice The single accumulator for a pool (0 until the pool's first vault).
    mapping(address => address) public accumulatorOf;
    /// @notice The vault for a (pool, tenor) pair (0 until created).
    mapping(address => mapping(uint32 => address)) public vaultOf;
    /// @dev Every vault ever deployed, in creation order.
    address[] public allVaults;

    /// @notice Per-call market parameters. Grouped in a struct so the wiring stays
    ///         readable and the call never hits stack-too-deep. The accumulator config
    ///         (sampleInterval) is consulted ONLY when the pool has no
    ///         accumulator yet; on later tenors of the same pool it is ignored.
    struct VaultParams {
        address pool;
        uint32 tenor;
        uint32 gap; // settlement gap (plan R8); U7 moves time params to the factory constructor
        address pricer; // per-tenor calibration, deployed outside
        address valuer; // per-market gamma calibration, deployed outside
        uint64 anchor; // startsAt(n) = anchor + n * (tenor + gap)
        uint16 maxUtilizationBps;
        uint128 maxExcessVariance;
        uint16 ewmaAlphaBps;
        uint128 seedVariance;
        uint32 sampleInterval; // accumulator: first vault per pool only
    }

    error BadConfig();
    error VaultExists(address pool, uint32 tenor, address existing);

    event AccumulatorCreated(address indexed pool, address accumulator);
    event VaultCreated(
        address indexed pool, uint32 indexed tenor, address vault, address accumulator
    );

    /// @param positionManager_ Uniswap v3 NFPM address (chain infrastructure).
    /// @param settlementToken_ Settlement token address (chain infrastructure).
    constructor(address positionManager_, address settlementToken_) {
        if (positionManager_ == address(0) || settlementToken_ == address(0)) revert BadConfig();
        positionManager = positionManager_;
        settlementToken = settlementToken_;
    }

    /// @notice Deploy the (pool, tenor) market, deploying the pool's accumulator first
    ///         if this is its first tenor. Permissionless. Reverts if the pair exists.
    /// @return vault The newly deployed CoverVault. Deep parameter validation is left to
    ///         the vault's own constructor, which is the single source of that truth.
    function createVault(VaultParams calldata p) external returns (address vault) {
        if (
            p.pool == address(0) || p.tenor == 0 || p.pricer == address(0) || p.valuer == address(0)
        ) {
            revert BadConfig();
        }
        address existing = vaultOf[p.pool][p.tenor];
        if (existing != address(0)) revert VaultExists(p.pool, p.tenor, existing);

        // One accumulator per pool, shared by all tenors: deploy lazily, reuse after.
        address acc = accumulatorOf[p.pool];
        if (acc == address(0)) {
            acc = address(new VarianceAccumulator(p.pool, p.sampleInterval));
            accumulatorOf[p.pool] = acc;
            emit AccumulatorCreated(p.pool, acc);
        }

        vault = address(
            new CoverVault(
                p.pool,
                acc,
                p.pricer,
                p.valuer,
                positionManager,
                settlementToken,
                p.tenor,
                p.gap,
                p.anchor,
                p.maxUtilizationBps,
                p.maxExcessVariance,
                p.ewmaAlphaBps,
                p.seedVariance
            )
        );

        vaultOf[p.pool][p.tenor] = vault;
        allVaults.push(vault);
        emit VaultCreated(p.pool, p.tenor, vault, acc);
    }

    /// @notice Number of vaults deployed across all pools and tenors.
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }
}
