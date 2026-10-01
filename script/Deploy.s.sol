// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ArunaFactory} from "../src/ArunaFactory.sol";
import {FlatVegaPricer} from "../src/FlatVegaPricer.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {VaultDeployer} from "../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../src/deployers/AccumulatorDeployer.sol";

/// @title Deploy
/// @notice Deployment tooling for the Aruna stack (build-order item 6). Two scripts,
///         split along the exact seam the factory draws in §2: chain infrastructure vs
///         per-market calibration.
///
///           - DeployFactory: deploys the VaultDeployer + AccumulatorDeployer and ONE
///             ArunaFactory wired to the chain's NFPM and settlement token, with the
///             factory-level time parameters (tenor set, gap, sample interval) and the
///             keeper-economics upper bounds, all read from the environment.
///           - DeployMarket: deploys a FlatVegaPricer + PositionValuer (both calibrated,
///             both deployed OUTSIDE the factory per §2 line 24) and then calls
///             createVault on an already-deployed factory to mint the (pool, tenor) vault.
///
///         Authority note (honored, not decided here): every numeric input below is
///         CALIBRATION (§6.4), awaiting backtest — a placeholder, never a design claim.
///         This script therefore bakes NONE of it: all of it is read from the environment
///         so the live numbers live in the dated calibration artifact, not in code the
///         design layer would have to treat as authoritative. Change a knot by changing an
///         env var and redeploying — never by editing this file.
///
///         Usage (calibration set in a .env, deployer key on the CLI as in the README):
///           forge script script/Deploy.s.sol:DeployFactory \
///             --rpc-url $RPC_URL --private-key $PK --broadcast
///           forge script script/Deploy.s.sol:DeployMarket \
///             --rpc-url $RPC_URL --private-key $PK --broadcast
///
///         Env vars — DeployFactory:
///           ARUNA_POSITION_MANAGER   address  Uniswap v3 NFPM (chain infra)
///           ARUNA_SETTLEMENT_TOKEN   address  settlement token, e.g. USDC (chain infra)
///           ARUNA_ALLOWED_TENORS     uint32[] allowed tenors (seconds), comma-separated
///           ARUNA_GAP                uint32   settlement gap seconds between cohorts
///           ARUNA_SAMPLE_INTERVAL    uint32   accumulator sample cadence (seconds)
///           ARUNA_MAX_KEEPER_SHARE_BPS uint16 upper bound on per-vault keeper share
///           ARUNA_MAX_POKE_BOUNTY    uint128  upper bound on per-vault poke bounty
///           ARUNA_MAX_FINALIZE_BOUNTY uint128 upper bound on per-vault finalize bounty
///           ARUNA_MAX_SETTLE_BOUNTY  uint128  upper bound on per-vault settle bounty
///
///         Env vars — DeployMarket (in addition to the pricer/valuer calibration below):
///           ARUNA_FACTORY            address  a factory already deployed by DeployFactory
///           ARUNA_POOL               address  Uniswap v3 pool this market covers
///           ARUNA_TENOR              uint32   cohort length, must be in the factory's set
///           ARUNA_ANCHOR             uint64   startsAt(n) = anchor + n * (tenor + gap)
///           ARUNA_MAX_UTIL_BPS       uint16   utilization cap (e.g. 8000 = 80%)
///           ARUNA_MAX_EXCESS_VARIANCE uint128 maxExcessVariance (WAD)
///           ARUNA_EWMA_ALPHA_BPS     uint16   EWMA smoothing (bps)
///           ARUNA_SEED_VARIANCE      uint128  initial ewmaVariance (WAD)
///           ARUNA_POLICY_CAP         uint32   max live policies per cohort (R24)
///           ARUNA_KEEPER_SHARE_BPS   uint16   keeper cut of premiums after endsAt (bps)
///           ARUNA_POKE_BOUNTY        uint128  keeper bounty per added sample (token units)
///           ARUNA_FINALIZE_BOUNTY    uint128  keeper bounty per cohort finalize
///           ARUNA_SETTLE_BOUNTY      uint128  keeper bounty cap per measured policy settled
///
///           ARUNA_PRICER_MIN_PREMIUM uint128  floor premium (settlement units)
///           ARUNA_PRICER_LOAD_BPS    uint16   underwriter load (bps, <= 5000)
///           ARUNA_PRICER_LAMBDA      uint128  utilization sensitivity lambda (WAD)
///           ARUNA_PRICER_M_KNOTS     uint[5]  moneyness knots (WAD), comma-separated, increasing
///           ARUNA_PRICER_G_KNOTS     uint[5]  g values (WAD), comma-separated, non-increasing, <= WAD
///
///           ARUNA_VALUER_KAPPA       uint128  variance notional per unit liquidity (WAD)
///           ARUNA_VALUER_REF_WIDTH   int24    neutral tick width (> 0)
///           ARUNA_VALUER_MIN_WIDTH_MULT uint128  width-multiplier floor (WAD), <= WAD
///           ARUNA_VALUER_MAX_WIDTH_MULT uint128  width-multiplier cap   (WAD), >= WAD

/// @notice Shared checked env casts: revert loudly rather than silently truncate.
abstract contract DeployBase is Script {
    function _u16(uint256 v) internal pure returns (uint16) {
        require(v <= type(uint16).max, "u16 overflow");
        return uint16(v);
    }

    function _u32(uint256 v) internal pure returns (uint32) {
        require(v <= type(uint32).max, "u32 overflow");
        return uint32(v);
    }

    function _u64(uint256 v) internal pure returns (uint64) {
        require(v <= type(uint64).max, "u64 overflow");
        return uint64(v);
    }

    function _u128(uint256 v) internal pure returns (uint128) {
        require(v <= type(uint128).max, "u128 overflow");
        return uint128(v);
    }

    function _i24(int256 v) internal pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, "i24 overflow");
        return int24(v);
    }

    function _knots5(uint256[] memory v) internal pure returns (uint128[5] memory out) {
        require(v.length == 5, "need exactly 5 knots");
        for (uint256 i = 0; i < 5; i++) {
            out[i] = _u128(v[i]);
        }
    }
}

/// @notice Deploys the single ArunaFactory for a chain. Idempotent only by convention:
///         re-running deploys a second, independent factory.
contract DeployFactory is DeployBase {
    function run() external returns (ArunaFactory factory) {
        address positionManager = vm.envAddress("ARUNA_POSITION_MANAGER");
        address settlementToken = vm.envAddress("ARUNA_SETTLEMENT_TOKEN");
        uint256[] memory rawTenors = vm.envUint("ARUNA_ALLOWED_TENORS", ",");
        uint32[] memory tenors = new uint32[](rawTenors.length);
        for (uint256 i = 0; i < rawTenors.length; i++) {
            tenors[i] = _u32(rawTenors[i]);
        }
        uint32 gap = _u32(vm.envUint("ARUNA_GAP"));
        uint32 sampleInterval = _u32(vm.envUint("ARUNA_SAMPLE_INTERVAL"));
        uint16 maxKeeperShareBps = _u16(vm.envUint("ARUNA_MAX_KEEPER_SHARE_BPS"));
        uint128 maxPokeBounty = _u128(vm.envUint("ARUNA_MAX_POKE_BOUNTY"));
        uint128 maxFinalizeBounty = _u128(vm.envUint("ARUNA_MAX_FINALIZE_BOUNTY"));
        uint128 maxSettleBounty = _u128(vm.envUint("ARUNA_MAX_SETTLE_BOUNTY"));

        vm.startBroadcast();
        address vaultDeployer = address(new VaultDeployer());
        address accumulatorDeployer = address(new AccumulatorDeployer());
        factory = new ArunaFactory(
            positionManager,
            settlementToken,
            vaultDeployer,
            accumulatorDeployer,
            tenors,
            gap,
            sampleInterval,
            maxKeeperShareBps,
            maxPokeBounty,
            maxFinalizeBounty,
            maxSettleBounty
        );
        vm.stopBroadcast();

        console2.log("VaultDeployer:", vaultDeployer);
        console2.log("AccumulatorDeployer:", accumulatorDeployer);
        console2.log("ArunaFactory:", address(factory));
        console2.log("  positionManager:", positionManager);
        console2.log("  settlementToken:", settlementToken);
    }
}

/// @notice Deploys a calibrated pricer + valuer and mints one (pool, tenor) vault on an
///         existing factory. The accumulator is created by the factory on the pool's first
///         tenor and reused thereafter — this script never touches it directly (§2).
contract DeployMarket is DeployBase {
    function run() external returns (address vault, address pricer, address valuer) {
        ArunaFactory factory = ArunaFactory(vm.envAddress("ARUNA_FACTORY"));

        // --- pricer calibration (§6.3 / §6.4) -----------------------------------
        uint128 minPremium = _u128(vm.envUint("ARUNA_PRICER_MIN_PREMIUM"));
        uint16 loadBps = _u16(vm.envUint("ARUNA_PRICER_LOAD_BPS"));
        uint128 lambda = _u128(vm.envUint("ARUNA_PRICER_LAMBDA"));
        uint128[5] memory mKnots = _knots5(vm.envUint("ARUNA_PRICER_M_KNOTS", ","));
        uint128[5] memory gKnots = _knots5(vm.envUint("ARUNA_PRICER_G_KNOTS", ","));

        // --- valuer calibration (§8.4 / §6.4) -----------------------------------
        uint128 kappa = _u128(vm.envUint("ARUNA_VALUER_KAPPA"));
        int24 refWidth = _i24(vm.envInt("ARUNA_VALUER_REF_WIDTH"));
        uint128 minWidthMult = _u128(vm.envUint("ARUNA_VALUER_MIN_WIDTH_MULT"));
        uint128 maxWidthMult = _u128(vm.envUint("ARUNA_VALUER_MAX_WIDTH_MULT"));

        // --- market params (§4 / §8) --------------------------------------------
        ArunaFactory.VaultParams memory p = ArunaFactory.VaultParams({
            pool: vm.envAddress("ARUNA_POOL"),
            tenor: _u32(vm.envUint("ARUNA_TENOR")),
            pricer: address(0), // filled after pricer deploy
            valuer: address(0), // filled after valuer deploy
            anchor: _u64(vm.envUint("ARUNA_ANCHOR")),
            maxUtilizationBps: _u16(vm.envUint("ARUNA_MAX_UTIL_BPS")),
            maxExcessVariance: _u128(vm.envUint("ARUNA_MAX_EXCESS_VARIANCE")),
            ewmaAlphaBps: _u16(vm.envUint("ARUNA_EWMA_ALPHA_BPS")),
            seedVariance: _u128(vm.envUint("ARUNA_SEED_VARIANCE")),
            policyCap: _u32(vm.envUint("ARUNA_POLICY_CAP")),
            keeperShareBps: _u16(vm.envUint("ARUNA_KEEPER_SHARE_BPS")),
            pokeBounty: _u128(vm.envUint("ARUNA_POKE_BOUNTY")),
            finalizeBounty: _u128(vm.envUint("ARUNA_FINALIZE_BOUNTY")),
            settleBounty: _u128(vm.envUint("ARUNA_SETTLE_BOUNTY"))
        });

        vm.startBroadcast();
        pricer = address(new FlatVegaPricer(minPremium, loadBps, lambda, mKnots, gKnots));
        valuer = address(
            new PositionValuer(
                factory.positionManager(), kappa, refWidth, minWidthMult, maxWidthMult
            )
        );
        p.pricer = pricer;
        p.valuer = valuer;
        vault = factory.createVault(p);
        vm.stopBroadcast();

        console2.log("FlatVegaPricer:", pricer);
        console2.log("PositionValuer:", valuer);
        console2.log("CoverVault:", vault);
        console2.log("  pool:", p.pool);
        console2.log("  tenor:", uint256(p.tenor));
        console2.log("  accumulator:", factory.accumulatorOf(p.pool));
    }
}
