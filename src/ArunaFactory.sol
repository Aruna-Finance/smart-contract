// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultDeployer} from "./deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "./deployers/AccumulatorDeployer.sol";
import {IVarianceAccumulator} from "./interfaces/IVarianceAccumulator.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/IUniswapV3PoolMinimal.sol";
import {IUniswapV3FactoryMinimal} from "./interfaces/IUniswapV3FactoryMinimal.sol";

/// @title ArunaFactory (v2)
/// @notice Permissionless deployer and registry (design §2; plan "Arsitektur factory").
///         One VarianceAccumulator per (factory, pool) — shared by every vault this factory
///         creates on that pool — and any number of CoverVaults per (pool, tenor). It holds
///         no funds, has no admin, and makes no pricing decision.
///
///         - **No child creation code.** Vaults and accumulators are created by two tiny
///           deployer contracts whose addresses are immutables here, so the factory stays
///           far below EIP-170 however large the vault grows.
///         - **Time parameters are factory immutables** (R28): the allowed tenor set, the
///           settlement gap and the sample interval are fixed once at construction and
///           forwarded to every accumulator and vault. A release factory and a sandbox
///           factory differ only in these constructor arguments.
///         - **No canonical slot** (AE11): `createVault` always deploys a new vault; the
///           registry lists vaults globally and per (pool, tenor). `VaultCreated` emits
///           every market parameter so curators can verify a market from the log alone
///           (R22, R25).
///         - **On-chain validation despite permissionlessness:** the pool must be the one
///           the NFPM's own Uniswap factory lists for its (token0, token1, fee) and must
///           hold the settlement token; keeper bps and bounties are capped by constructor
///           bounds so a market creator cannot drain underwriter premiums via bounties.
///
///         The PRICER and VALUER carry per-tenor / per-market calibration (§6.4, §8.4), so
///         they are deployed outside and passed in per call — the factory bakes none.
contract ArunaFactory {
    // --- chain infrastructure ---
    /// @notice Uniswap v3 position manager every vault reads positions from.
    address public immutable positionManager;
    /// @notice Settlement token (e.g. USDC) every vault custodies.
    address public immutable settlementToken;
    /// @notice Deploys CoverVaults (holds their creation code).
    address public immutable vaultDeployer;
    /// @notice Deploys VarianceAccumulators (holds their creation code).
    address public immutable accumulatorDeployer;

    // --- time parameters (R28) ---
    /// @notice Settlement gap between endsAt(n) and startsAt(n+1), seconds, every vault.
    uint32 public immutable gap;
    /// @notice Accumulator sample interval (also the inter-sample TWAP basis, §3.2).
    uint32 public immutable sampleInterval;

    // --- keeper economics upper bounds (U6 parameters, capped here) ---
    uint16 public immutable maxKeeperShareBps;
    uint128 public immutable maxPokeBounty;
    uint128 public immutable maxFinalizeBounty;
    uint128 public immutable maxSettleBounty;

    /// @dev Allowed tenors, written once in the constructor and never again.
    uint32[] internal _allowedTenors;
    /// @notice Whether `tenor` (seconds) is in the allowed set.
    mapping(uint32 => bool) public isAllowedTenor;

    /// @notice The single accumulator for a pool in this factory (0 until first vault).
    mapping(address => address) public accumulatorOf;
    /// @notice True for every vault this factory created — the only vaults that are markets.
    mapping(address => bool) public isVault;
    /// @dev Vaults per (pool, tenor), in creation order.
    mapping(address => mapping(uint32 => address[])) internal _vaultsOf;
    /// @notice Every vault ever deployed by this factory, in creation order.
    address[] public allVaults;

    /// @notice Per-call market parameters. Time parameters (gap, sample interval) are not
    ///         here: they are factory immutables.
    struct VaultParams {
        address pool;
        uint32 tenor; // must be in the allowed set
        address pricer; // per-tenor calibration, deployed outside
        address valuer; // per-market gamma calibration, deployed outside
        uint64 anchor; // startsAt(n) = anchor + n * (tenor + gap)
        uint16 maxUtilizationBps;
        uint128 maxExcessVariance;
        uint16 ewmaAlphaBps;
        uint128 seedVariance;
        uint32 policyCap; // max live policies per cohort (R24)
        uint16 keeperShareBps; // <= maxKeeperShareBps
        uint128 pokeBounty; // <= maxPokeBounty
        uint128 finalizeBounty; // <= maxFinalizeBounty
        uint128 settleBounty; // <= maxSettleBounty
    }

    error BadConfig();
    error TenorNotAllowed(uint32 tenor);
    error PoolNotCanonical(address pool, address canonical);
    error PoolLacksSettlementToken(address pool);
    error KeeperShareTooHigh(uint16 keeperShareBps, uint16 max);
    error BountyTooHigh(uint128 bounty, uint128 max);

    event AccumulatorCreated(address indexed pool, address accumulator);
    /// @notice Every market parameter, so the log alone verifies a market (R22, R25).
    ///         `params` carries pricer, valuer, anchor, utilization, maxExcessVariance,
    ///         EWMA alpha, seed, policy cap, keeper bps and the three bounties.
    event VaultCreated(
        address indexed pool,
        uint32 indexed tenor,
        address indexed vault,
        address accumulator,
        uint32 gap,
        uint32 sampleInterval,
        VaultParams params
    );

    /// @param positionManager_ Uniswap v3 NFPM (chain infrastructure).
    /// @param settlementToken_ Settlement token (chain infrastructure).
    /// @param vaultDeployer_ VaultDeployer address.
    /// @param accumulatorDeployer_ AccumulatorDeployer address.
    /// @param allowedTenors_ Allowed tenor set (seconds): non-empty, no zero, no duplicates.
    ///        (The vault constructor still bounds tenor / sampleInterval for its scan.)
    /// @param gap_ Settlement gap (seconds, > 0).
    /// @param sampleInterval_ Accumulator sample interval (seconds, > 0).
    /// @param maxKeeperShareBps_ Upper bound on per-vault keeper share (<= 10000).
    constructor(
        address positionManager_,
        address settlementToken_,
        address vaultDeployer_,
        address accumulatorDeployer_,
        uint32[] memory allowedTenors_,
        uint32 gap_,
        uint32 sampleInterval_,
        uint16 maxKeeperShareBps_,
        uint128 maxPokeBounty_,
        uint128 maxFinalizeBounty_,
        uint128 maxSettleBounty_
    ) {
        if (
            positionManager_ == address(0) || settlementToken_ == address(0)
                || vaultDeployer_ == address(0) || accumulatorDeployer_ == address(0)
                || allowedTenors_.length == 0 || gap_ == 0 || sampleInterval_ == 0
                || maxKeeperShareBps_ > 10_000
        ) revert BadConfig();

        for (uint256 i = 0; i < allowedTenors_.length; i++) {
            uint32 t = allowedTenors_[i];
            if (t == 0 || isAllowedTenor[t]) revert BadConfig();
            isAllowedTenor[t] = true;
            _allowedTenors.push(t);
        }

        positionManager = positionManager_;
        settlementToken = settlementToken_;
        vaultDeployer = vaultDeployer_;
        accumulatorDeployer = accumulatorDeployer_;
        gap = gap_;
        sampleInterval = sampleInterval_;
        maxKeeperShareBps = maxKeeperShareBps_;
        maxPokeBounty = maxPokeBounty_;
        maxFinalizeBounty = maxFinalizeBounty_;
        maxSettleBounty = maxSettleBounty_;
    }

    /// @notice Deploy a new market on (pool, tenor). Permissionless; never deduplicates —
    ///         a second market for the same pair is a separate vault (AE11). The pool's
    ///         accumulator is created on first use, with a baseline sample taken at once.
    /// @return vault The newly deployed CoverVault. Deep parameter validation (utilization,
    ///         alpha, cap, ...) stays in the vault constructor, the single source of truth.
    function createVault(VaultParams calldata p) external returns (address vault) {
        if (p.pool == address(0) || p.pricer == address(0) || p.valuer == address(0)) {
            revert BadConfig();
        }
        if (!isAllowedTenor[p.tenor]) revert TenorNotAllowed(p.tenor);
        _checkPool(p.pool);
        _checkKeeperBounds(p);

        // One accumulator per (factory, pool), shared by every tenor and market.
        address acc = accumulatorOf[p.pool];
        if (acc == address(0)) {
            acc = AccumulatorDeployer(accumulatorDeployer).deploy(p.pool, sampleInterval);
            accumulatorOf[p.pool] = acc;
            emit AccumulatorCreated(p.pool, acc);
            // Baseline sample now (plan "Poke baseline"): the first cohort's window has a
            // predecessor sample. Loud on failure — an unobservable pool is not a market.
            IVarianceAccumulator(acc).poke();
        }

        vault = VaultDeployer(vaultDeployer)
            .deploy(
                VaultDeployer.Args({
                    pool: p.pool,
                    accumulator: acc,
                    pricer: p.pricer,
                    valuer: p.valuer,
                    positionManager: positionManager,
                    settlementToken: settlementToken,
                    tenor: p.tenor,
                    gap: gap,
                    anchor: p.anchor,
                    maxUtilizationBps: p.maxUtilizationBps,
                    maxExcessVariance: p.maxExcessVariance,
                    ewmaAlphaBps: p.ewmaAlphaBps,
                    seedVariance: p.seedVariance,
                    policyCap: p.policyCap,
                    keeperShareBps: p.keeperShareBps,
                    pokeBounty: p.pokeBounty,
                    finalizeBounty: p.finalizeBounty,
                    settleBounty: p.settleBounty
                })
            );

        isVault[vault] = true;
        _vaultsOf[p.pool][p.tenor].push(vault);
        allVaults.push(vault);
        emit VaultCreated(p.pool, p.tenor, vault, acc, gap, sampleInterval, p);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The allowed tenor set, in constructor order.
    function allowedTenors() external view returns (uint32[] memory) {
        return _allowedTenors;
    }

    /// @notice Number of vaults deployed across all pools and tenors.
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Every vault on (pool, tenor), in creation order.
    function vaultsOf(address pool, uint32 tenor) external view returns (address[] memory) {
        return _vaultsOf[pool][tenor];
    }

    /// @notice Number of vaults on (pool, tenor).
    function vaultsOfLength(address pool, uint32 tenor) external view returns (uint256) {
        return _vaultsOf[pool][tenor].length;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev The pool must be the canonical Uniswap v3 pool for its own (token0, token1,
    ///      fee) in the factory the NFPM is bound to — so positions of that NFPM can match
    ///      it — and must contain the settlement token.
    function _checkPool(address pool) internal view {
        address t0 = IUniswapV3PoolMinimal(pool).token0();
        address t1 = IUniswapV3PoolMinimal(pool).token1();
        uint24 fee = IUniswapV3PoolMinimal(pool).fee();
        address uniFactory = INonfungiblePositionManager(positionManager).factory();
        address canonical = IUniswapV3FactoryMinimal(uniFactory).getPool(t0, t1, fee);
        if (canonical != pool) revert PoolNotCanonical(pool, canonical);
        if (t0 != settlementToken && t1 != settlementToken) revert PoolLacksSettlementToken(pool);
    }

    function _checkKeeperBounds(VaultParams calldata p) internal view {
        if (p.keeperShareBps > maxKeeperShareBps) {
            revert KeeperShareTooHigh(p.keeperShareBps, maxKeeperShareBps);
        }
        if (p.pokeBounty > maxPokeBounty) revert BountyTooHigh(p.pokeBounty, maxPokeBounty);
        if (p.finalizeBounty > maxFinalizeBounty) {
            revert BountyTooHigh(p.finalizeBounty, maxFinalizeBounty);
        }
        if (p.settleBounty > maxSettleBounty) {
            revert BountyTooHigh(p.settleBounty, maxSettleBounty);
        }
    }
}
