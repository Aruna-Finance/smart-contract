// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {ArunaScript, IScriptToken} from "./base/ArunaScript.sol";
import {ArunaFactory} from "../src/ArunaFactory.sol";
import {FlatVegaPricer} from "../src/FlatVegaPricer.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {VaultDeployer} from "../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../src/deployers/AccumulatorDeployer.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";

/// @title Deploy
/// @notice Deployment tooling for Aruna v2 (plan U9; R26, R28–R31; F3). Two scripts, split
///         along the seam the factory draws in design §2: chain infrastructure + time
///         parameters vs per-market calibration.
///
///           - DeployFactory: VaultDeployer + AccumulatorDeployer + ONE ArunaFactory with the
///             factory-level time parameters (tenor set, gap, sample interval) and the
///             keeper-economics upper bounds, all from the environment. Writes the
///             manifest `deployments/<chainId>/<label>.json`: chainId, profile, label, git
///             commit, deployer, block, addresses, constructor args and the init code hash
///             of every contract of this build (factory, deployers, vault, accumulator,
///             pricer, valuer).
///           - DeployMarket: a FlatVegaPricer + PositionValuer (calibrated, deployed OUTSIDE
///             the factory per §2) then `createVault`, optionally an initial keeper-budget
///             donation; appends the market to the manifest.
///
///         Profiles (R28, revised): `sandbox` (RC; small time scale, placeholder calibration
///         allowed and recorded as such) and `release`. A release factory and its RC differ
///         ONLY in the factory constructor's time parameters; creation code is identical,
///         proven by init code hash. Release gates, all checked BEFORE any broadcast:
///           - DeployFactory: GIT_COMMIT set; ARUNA_RC_MANIFEST names a sandbox RC manifest;
///             the conformance ledger (ARUNA_LEDGER, default conformance/ledger.json) exists,
///             has `"status": "green"` and `"rcManifest"` equal to ARUNA_RC_MANIFEST; every
///             init code hash of this build equals the RC manifest's (R29, AE12).
///           - DeployMarket: ARUNA_CALIBRATION_PLACEHOLDER explicitly `false`, a calibration
///             artifact id in ARUNA_CALIBRATION_ARTIFACT (R30), an explicit anchor, and the
///             build hashes equal to the factory manifest's.
///
///         Authority note (honored, not decided here): every numeric market input is
///         CALIBRATION (§6.4), awaiting backtest. This script bakes NONE of it; change a knot
///         by changing an env var and redeploying, never by editing this file. A placeholder
///         is marked by an explicit flag, never guessed from the values.
///
///         Usage (keys from a keystore or hardware wallet, never a PRIVATE_KEY in a file;
///         see deployments/README.md):
///           GIT_COMMIT=$(git rev-parse HEAD) forge script script/Deploy.s.sol:DeployFactory \
///             --rpc-url $RPC_URL --account <keystore> --broadcast
///           forge script script/Deploy.s.sol:DeployMarket \
///             --rpc-url $RPC_URL --account <keystore> --broadcast
///
///         Env — both:
///           PROFILE                    release | sandbox (default sandbox)
///           ARUNA_DEPLOY_LABEL         manifest label (default = PROFILE)
///           ARUNA_MANIFEST             explicit manifest path (DeployMarket; overrides label)
///         Env — DeployFactory:
///           GIT_COMMIT                 commit the build came from (required in release)
///           ARUNA_RC_MANIFEST          RC manifest path (release only)
///           ARUNA_LEDGER               ledger path (default conformance/ledger.json)
///           ARUNA_MANIFEST_OVERWRITE   bool, allow replacing an existing manifest (default false)
///           ARUNA_ROUTER               optional SwapRouter02, recorded under `infra`
///           ARUNA_POSITION_MANAGER     address  Uniswap v3 NFPM (chain infra)
///           ARUNA_SETTLEMENT_TOKEN     address  settlement token (chain infra)
///           ARUNA_ALLOWED_TENORS       uint32[] allowed tenors (seconds), comma-separated
///           ARUNA_GAP                  uint32   settlement gap seconds between cohorts
///           ARUNA_SAMPLE_INTERVAL      uint32   accumulator sample cadence (seconds)
///           ARUNA_MAX_KEEPER_SHARE_BPS uint16   upper bound on per-vault keeper share
///           ARUNA_MAX_POKE_BOUNTY      uint128  upper bound on per-vault poke bounty
///           ARUNA_MAX_FINALIZE_BOUNTY  uint128  upper bound on per-vault finalize bounty
///           ARUNA_MAX_SETTLE_BOUNTY    uint128  upper bound on per-vault settle bounty
///         Env — DeployMarket:
///           ARUNA_FACTORY              optional cross-check against the manifest's factory
///           ARUNA_CALIBRATION_ARTIFACT calibration artifact path/id (required in release)
///           ARUNA_CALIBRATION_PLACEHOLDER bool (default true; must be false in release)
///           ARUNA_KEEPER_BUDGET_FUNDING initial fundKeeperBudget donation (default 0)
///           ARUNA_POOL, ARUNA_TENOR, ARUNA_ANCHOR (0 = now + ARUNA_ANCHOR_LEAD, sandbox only),
///           ARUNA_ANCHOR_LEAD (default 600), ARUNA_MAX_UTIL_BPS, ARUNA_MAX_EXCESS_VARIANCE,
///           ARUNA_EWMA_ALPHA_BPS, ARUNA_SEED_VARIANCE, ARUNA_POLICY_CAP,
///           ARUNA_KEEPER_SHARE_BPS, ARUNA_POKE_BOUNTY, ARUNA_FINALIZE_BOUNTY,
///           ARUNA_SETTLE_BOUNTY,
///           ARUNA_PRICER_MIN_PREMIUM, ARUNA_PRICER_LOAD_BPS, ARUNA_PRICER_LAMBDA,
///           ARUNA_PRICER_M_KNOTS (5, WAD, increasing), ARUNA_PRICER_G_KNOTS (5, WAD),
///           ARUNA_VALUER_KAPPA, ARUNA_VALUER_REF_WIDTH, ARUNA_VALUER_MIN_WIDTH_MULT,
///           ARUNA_VALUER_MAX_WIDTH_MULT.
///         Full annotated list with sandbox values: .env.example.

/// @notice Deploys the deployers + one ArunaFactory and writes its manifest. Re-running
///         deploys a second, independent factory (and refuses to overwrite the manifest
///         unless ARUNA_MANIFEST_OVERWRITE=true).
contract DeployFactory is ArunaScript {
    struct FactoryConfig {
        string profile;
        string label;
        string gitCommit;
        string rcManifest; // release only
        string ledger; // release only
        bool allowOverwrite;
        address router; // optional, recorded as infra
        address positionManager;
        address settlementToken;
        uint32[] tenors;
        uint32 gap;
        uint32 sampleInterval;
        uint16 maxKeeperShareBps;
        uint128 maxPokeBounty;
        uint128 maxFinalizeBounty;
        uint128 maxSettleBounty;
    }

    struct Deployment {
        address vaultDeployer;
        address accumulatorDeployer;
        address factory;
        address deployer;
        string manifest;
    }

    function run() external returns (Deployment memory) {
        return deploy(configFromEnv());
    }

    function configFromEnv() public view returns (FactoryConfig memory cfg) {
        cfg.profile = vm.envOr("PROFILE", string(PROFILE_SANDBOX));
        cfg.label = vm.envOr("ARUNA_DEPLOY_LABEL", cfg.profile);
        cfg.gitCommit = vm.envOr("GIT_COMMIT", string("unknown"));
        cfg.rcManifest = vm.envOr("ARUNA_RC_MANIFEST", string(""));
        cfg.ledger = vm.envOr("ARUNA_LEDGER", string("conformance/ledger.json"));
        cfg.allowOverwrite = vm.envOr("ARUNA_MANIFEST_OVERWRITE", false);
        cfg.router = vm.envOr("ARUNA_ROUTER", address(0));
        cfg.positionManager = vm.envAddress("ARUNA_POSITION_MANAGER");
        cfg.settlementToken = vm.envAddress("ARUNA_SETTLEMENT_TOKEN");
        uint256[] memory rawTenors = vm.envUint("ARUNA_ALLOWED_TENORS", ",");
        cfg.tenors = new uint32[](rawTenors.length);
        for (uint256 i = 0; i < rawTenors.length; i++) {
            cfg.tenors[i] = _u32(rawTenors[i]);
        }
        cfg.gap = _u32(vm.envUint("ARUNA_GAP"));
        cfg.sampleInterval = _u32(vm.envUint("ARUNA_SAMPLE_INTERVAL"));
        cfg.maxKeeperShareBps = _u16(vm.envUint("ARUNA_MAX_KEEPER_SHARE_BPS"));
        cfg.maxPokeBounty = _u128(vm.envUint("ARUNA_MAX_POKE_BOUNTY"));
        cfg.maxFinalizeBounty = _u128(vm.envUint("ARUNA_MAX_FINALIZE_BOUNTY"));
        cfg.maxSettleBounty = _u128(vm.envUint("ARUNA_MAX_SETTLE_BOUNTY"));
    }

    /// @notice Every gate runs before `vm.startBroadcast`, so a refused release never
    ///         sends a transaction.
    function deploy(FactoryConfig memory cfg) public returns (Deployment memory d) {
        _requireProfile(cfg.profile);
        d.manifest = _manifestPath(block.chainid, cfg.label);
        if (_persist() && vm.exists(d.manifest) && !cfg.allowOverwrite) {
            revert ManifestExists(d.manifest);
        }
        if (_isRelease(cfg.profile)) _releaseGuard(cfg);

        vm.startBroadcast();
        d.deployer = _broadcaster();
        d.vaultDeployer = address(new VaultDeployer());
        d.accumulatorDeployer = address(new AccumulatorDeployer());
        d.factory = address(
            new ArunaFactory(
                cfg.positionManager,
                cfg.settlementToken,
                d.vaultDeployer,
                d.accumulatorDeployer,
                cfg.tenors,
                cfg.gap,
                cfg.sampleInterval,
                cfg.maxKeeperShareBps,
                cfg.maxPokeBounty,
                cfg.maxFinalizeBounty,
                cfg.maxSettleBounty
            )
        );
        vm.stopBroadcast();

        string memory json = _manifestJson(cfg, d);
        if (_persist()) {
            vm.createDir(_manifestDir(block.chainid), true);
            vm.writeJson(json, d.manifest);
        }
        _logPersist("manifest", d.manifest, json);

        console2.log("profile:", cfg.profile);
        console2.log("VaultDeployer:", d.vaultDeployer);
        console2.log("AccumulatorDeployer:", d.accumulatorDeployer);
        console2.log("ArunaFactory:", d.factory);
    }

    /// @dev R29 / AE12: the release must be byte-for-byte the creation code an RC with a
    ///      green ledger ran. The ledger contract with U10 is two top-level keys:
    ///      `status` ("green" when every row is green or n-a) and `rcManifest` (the RC
    ///      manifest path the ledger's transaction hashes belong to).
    function _releaseGuard(FactoryConfig memory cfg) internal view {
        if (bytes(cfg.gitCommit).length == 0 || _eq(cfg.gitCommit, "unknown")) {
            revert ReleaseGuard("GIT_COMMIT is required in the release profile");
        }
        if (bytes(cfg.rcManifest).length == 0) {
            revert ReleaseGuard("ARUNA_RC_MANIFEST is required in the release profile");
        }
        if (!vm.exists(cfg.ledger)) {
            revert ReleaseGuard("conformance ledger not found: release needs a green RC ledger");
        }
        string memory ledger = vm.readFile(cfg.ledger);
        if (
            !vm.keyExistsJson(ledger, ".status")
                || !_eq(vm.parseJsonString(ledger, ".status"), "green")
        ) revert ReleaseGuard("conformance ledger status is not green");
        if (
            !vm.keyExistsJson(ledger, ".rcManifest")
                || !_eq(vm.parseJsonString(ledger, ".rcManifest"), cfg.rcManifest)
        ) revert ReleaseGuard("conformance ledger is not for ARUNA_RC_MANIFEST");

        if (!vm.exists(cfg.rcManifest)) revert ManifestMissing(cfg.rcManifest);
        string memory rc = vm.readFile(cfg.rcManifest);
        if (!_eq(vm.parseJsonString(rc, ".profile"), PROFILE_SANDBOX)) {
            revert ReleaseGuard("ARUNA_RC_MANIFEST is not a sandbox (RC) manifest");
        }
        _requireHashesMatch(rc);
    }

    // ---------------------------------------------------------------------
    // Manifest
    // ---------------------------------------------------------------------

    function _manifestJson(FactoryConfig memory cfg, Deployment memory d)
        internal
        returns (string memory)
    {
        string memory root = "aruna.factory.root";
        vm.serializeString(root, "schema", MANIFEST_SCHEMA);
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "profile", cfg.profile);
        vm.serializeString(root, "label", cfg.label);
        vm.serializeString(root, "gitCommit", cfg.gitCommit);
        vm.serializeAddress(root, "deployer", d.deployer);
        vm.serializeUint(root, "blockNumber", vm.getBlockNumber());
        vm.serializeUint(root, "timestamp", vm.getBlockTimestamp());
        vm.serializeString(root, "rcManifest", cfg.rcManifest);
        vm.serializeString(root, "contracts", _contractsJson(d));
        vm.serializeString(root, "initCodeHashes", _hashesJson());
        vm.serializeString(root, "factoryArgs", _argsJson(cfg, d));
        vm.serializeString(root, "infra", _infraJson(cfg));
        vm.serializeString(root, "aux", vm.serializeJson("aruna.factory.aux", "{}"));
        return vm.serializeString(root, "markets", vm.serializeJson("aruna.factory.mk", "{}"));
    }

    function _contractsJson(Deployment memory d) internal returns (string memory) {
        string memory k = "aruna.factory.contracts";
        vm.serializeAddress(k, "VaultDeployer", d.vaultDeployer);
        vm.serializeAddress(k, "AccumulatorDeployer", d.accumulatorDeployer);
        return vm.serializeAddress(k, "ArunaFactory", d.factory);
    }

    function _hashesJson() internal returns (string memory out) {
        string memory k = "aruna.factory.hashes";
        string[HASHED_CONTRACTS] memory names = _hashNames();
        bytes32[HASHED_CONTRACTS] memory h = _buildHashes();
        for (uint256 i = 0; i < HASHED_CONTRACTS; i++) {
            out = vm.serializeBytes32(k, names[i], h[i]);
        }
    }

    /// @dev ArunaFactory constructor arguments, in constructor order.
    function _argsJson(FactoryConfig memory cfg, Deployment memory d)
        internal
        returns (string memory)
    {
        string memory k = "aruna.factory.args";
        uint256[] memory tenors = new uint256[](cfg.tenors.length);
        for (uint256 i = 0; i < tenors.length; i++) {
            tenors[i] = cfg.tenors[i];
        }
        vm.serializeAddress(k, "positionManager", cfg.positionManager);
        vm.serializeAddress(k, "settlementToken", cfg.settlementToken);
        vm.serializeAddress(k, "vaultDeployer", d.vaultDeployer);
        vm.serializeAddress(k, "accumulatorDeployer", d.accumulatorDeployer);
        vm.serializeUint(k, "allowedTenors", tenors);
        vm.serializeUint(k, "gap", cfg.gap);
        vm.serializeUint(k, "sampleInterval", cfg.sampleInterval);
        vm.serializeUint(k, "maxKeeperShareBps", cfg.maxKeeperShareBps);
        vm.serializeString(k, "maxPokeBounty", _uintStr(cfg.maxPokeBounty));
        vm.serializeString(k, "maxFinalizeBounty", _uintStr(cfg.maxFinalizeBounty));
        return vm.serializeString(k, "maxSettleBounty", _uintStr(cfg.maxSettleBounty));
    }

    function _infraJson(FactoryConfig memory cfg) internal returns (string memory) {
        string memory k = "aruna.factory.infra";
        address uniFactory;
        if (cfg.positionManager.code.length != 0) {
            // The NFPM's Uniswap factory, recorded as infra (best effort).
            try INonfungiblePositionManager(cfg.positionManager).factory() returns (address f) {
                uniFactory = f;
            } catch {}
        }
        vm.serializeAddress(k, "positionManager", cfg.positionManager);
        vm.serializeAddress(k, "settlementToken", cfg.settlementToken);
        vm.serializeAddress(k, "uniswapV3Factory", uniFactory);
        return vm.serializeAddress(k, "router", cfg.router);
    }
}

/// @notice Deploys a calibrated pricer + valuer and mints one (pool, tenor) vault on the
///         manifest's factory, then appends the market to the manifest. The accumulator is
///         created by the factory on the pool's first market (with its baseline sample) and
///         reused thereafter — this script never touches it directly (§2).
contract DeployMarket is ArunaScript {
    struct PricerArgs {
        uint128 minPremium;
        uint16 loadBps;
        uint128 lambda;
        uint128[5] mKnots;
        uint128[5] gKnots;
    }

    struct ValuerArgs {
        uint128 kappa;
        int24 refWidth;
        uint128 minWidthMult;
        uint128 maxWidthMult;
    }

    struct MarketConfig {
        string manifest;
        string envProfile; // optional cross-check; the manifest's profile is authoritative
        address envFactory; // optional cross-check
        string calibrationArtifact;
        bool calibrationPlaceholder;
        uint256 keeperFunding;
        uint64 anchorLead; // anchor = now + lead when params.anchor == 0 (sandbox only)
        ArunaFactory.VaultParams params; // pricer / valuer filled after their deploy
        PricerArgs pricerArgs;
        ValuerArgs valuerArgs;
    }

    struct Market {
        uint256 index;
        address vault;
        address accumulator;
        address pricer;
        address valuer;
        address deployer;
        uint64 anchor;
    }

    function run() external returns (Market memory) {
        return deploy(configFromEnv());
    }

    function configFromEnv() public view returns (MarketConfig memory cfg) {
        cfg.manifest = _manifestFromEnv();
        cfg.envProfile = vm.envOr("PROFILE", string(""));
        cfg.envFactory = vm.envOr("ARUNA_FACTORY", address(0));
        cfg.calibrationArtifact = vm.envOr("ARUNA_CALIBRATION_ARTIFACT", string(""));
        cfg.calibrationPlaceholder = vm.envOr("ARUNA_CALIBRATION_PLACEHOLDER", true);
        cfg.keeperFunding = vm.envOr("ARUNA_KEEPER_BUDGET_FUNDING", uint256(0));
        cfg.anchorLead = _u64(vm.envOr("ARUNA_ANCHOR_LEAD", uint256(600)));

        // --- pricer calibration (§6.3 / §6.4) ---
        cfg.pricerArgs.minPremium = _u128(vm.envUint("ARUNA_PRICER_MIN_PREMIUM"));
        cfg.pricerArgs.loadBps = _u16(vm.envUint("ARUNA_PRICER_LOAD_BPS"));
        cfg.pricerArgs.lambda = _u128(vm.envUint("ARUNA_PRICER_LAMBDA"));
        cfg.pricerArgs.mKnots = _knots5(vm.envUint("ARUNA_PRICER_M_KNOTS", ","));
        cfg.pricerArgs.gKnots = _knots5(vm.envUint("ARUNA_PRICER_G_KNOTS", ","));

        // --- valuer calibration (§8.4 / §6.4) ---
        cfg.valuerArgs.kappa = _u128(vm.envUint("ARUNA_VALUER_KAPPA"));
        cfg.valuerArgs.refWidth = _i24(vm.envInt("ARUNA_VALUER_REF_WIDTH"));
        cfg.valuerArgs.minWidthMult = _u128(vm.envUint("ARUNA_VALUER_MIN_WIDTH_MULT"));
        cfg.valuerArgs.maxWidthMult = _u128(vm.envUint("ARUNA_VALUER_MAX_WIDTH_MULT"));

        // --- market params (§4 / §8) ---
        cfg.params = ArunaFactory.VaultParams({
            pool: vm.envAddress("ARUNA_POOL"),
            tenor: _u32(vm.envUint("ARUNA_TENOR")),
            pricer: address(0),
            valuer: address(0),
            anchor: _u64(vm.envOr("ARUNA_ANCHOR", uint256(0))),
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
    }

    function deploy(MarketConfig memory cfg) public returns (Market memory m) {
        string memory json = _readManifest(cfg.manifest);
        string memory profile = vm.parseJsonString(json, ".profile");
        _requireProfile(profile);
        if (bytes(cfg.envProfile).length != 0 && !_eq(cfg.envProfile, profile)) {
            revert ProfileMismatch(profile, cfg.envProfile);
        }
        ArunaFactory factory = ArunaFactory(vm.parseJsonAddress(json, ".contracts.ArunaFactory"));
        if (cfg.envFactory != address(0) && cfg.envFactory != address(factory)) {
            revert FactoryMismatch(address(factory), cfg.envFactory);
        }

        if (_isRelease(profile)) {
            // R30: no release market on placeholder calibration. The marker is explicit.
            if (cfg.calibrationPlaceholder) {
                revert ReleaseGuard("placeholder calibration in the release profile");
            }
            if (bytes(cfg.calibrationArtifact).length == 0) {
                revert ReleaseGuard("ARUNA_CALIBRATION_ARTIFACT is required in release");
            }
            if (cfg.params.anchor == 0) {
                revert ReleaseGuard("an explicit ARUNA_ANCHOR is required in release");
            }
            _requireHashesMatch(json); // same build as the factory manifest
        }
        if (cfg.params.anchor == 0) {
            cfg.params.anchor = _u64(vm.getBlockTimestamp() + cfg.anchorLead);
        }
        m.anchor = cfg.params.anchor;
        m.index = vm.parseJsonKeys(json, ".markets").length;

        vm.startBroadcast();
        m.deployer = _broadcaster();
        m.pricer = address(
            new FlatVegaPricer(
                cfg.pricerArgs.minPremium,
                cfg.pricerArgs.loadBps,
                cfg.pricerArgs.lambda,
                cfg.pricerArgs.mKnots,
                cfg.pricerArgs.gKnots
            )
        );
        m.valuer = address(
            new PositionValuer(
                factory.positionManager(),
                cfg.valuerArgs.kappa,
                cfg.valuerArgs.refWidth,
                cfg.valuerArgs.minWidthMult,
                cfg.valuerArgs.maxWidthMult
            )
        );
        cfg.params.pricer = m.pricer;
        cfg.params.valuer = m.valuer;
        m.vault = factory.createVault(cfg.params);
        if (cfg.keeperFunding != 0) {
            IScriptToken(factory.settlementToken()).approve(m.vault, cfg.keeperFunding);
            ICoverVault(m.vault).fundKeeperBudget(cfg.keeperFunding);
        }
        vm.stopBroadcast();
        m.accumulator = factory.accumulatorOf(cfg.params.pool);

        string memory entry = _marketJson(cfg, m, address(factory));
        if (_persist()) {
            vm.writeJson(entry, cfg.manifest, string.concat(".markets.", _uintStr(m.index)));
        }
        _logPersist(string.concat("market ", _uintStr(m.index)), cfg.manifest, entry);

        console2.log("FlatVegaPricer:", m.pricer);
        console2.log("PositionValuer:", m.valuer);
        console2.log("CoverVault:", m.vault);
        console2.log("  accumulator:", m.accumulator);
        console2.log("  anchor:", uint256(m.anchor));
        console2.log("  calibration placeholder:", cfg.calibrationPlaceholder);
    }

    // ---------------------------------------------------------------------
    // Manifest entry
    // ---------------------------------------------------------------------

    function _marketJson(MarketConfig memory cfg, Market memory m, address factory)
        internal
        returns (string memory)
    {
        string memory k = "aruna.market.root";
        vm.serializeAddress(k, "vault", m.vault);
        vm.serializeAddress(k, "accumulator", m.accumulator);
        vm.serializeAddress(k, "pool", cfg.params.pool);
        vm.serializeAddress(k, "pricer", m.pricer);
        vm.serializeAddress(k, "valuer", m.valuer);
        vm.serializeAddress(k, "factory", factory);
        vm.serializeAddress(k, "deployer", m.deployer);
        vm.serializeUint(k, "tenor", cfg.params.tenor);
        vm.serializeUint(k, "anchor", m.anchor);
        vm.serializeUint(k, "blockNumber", vm.getBlockNumber());
        vm.serializeUint(k, "timestamp", vm.getBlockTimestamp());
        vm.serializeString(k, "keeperBudgetFunded", _uintStr(cfg.keeperFunding));
        vm.serializeString(k, "calibration", _calibrationJson(cfg));
        vm.serializeString(k, "params", _paramsJson(cfg.params));
        vm.serializeString(k, "pricerArgs", _pricerJson(cfg.pricerArgs));
        return vm.serializeString(k, "valuerArgs", _valuerJson(cfg.valuerArgs, factory));
    }

    function _calibrationJson(MarketConfig memory cfg) internal returns (string memory) {
        string memory k = "aruna.market.calibration";
        vm.serializeString(k, "artifact", cfg.calibrationArtifact);
        return vm.serializeBool(k, "placeholder", cfg.calibrationPlaceholder);
    }

    /// @dev ArunaFactory.VaultParams exactly as passed to createVault (and as emitted in
    ///      VaultCreated), so a curator can diff the manifest against the log.
    function _paramsJson(ArunaFactory.VaultParams memory p) internal returns (string memory) {
        string memory k = "aruna.market.params";
        vm.serializeAddress(k, "pool", p.pool);
        vm.serializeUint(k, "tenor", p.tenor);
        vm.serializeAddress(k, "pricer", p.pricer);
        vm.serializeAddress(k, "valuer", p.valuer);
        vm.serializeUint(k, "anchor", p.anchor);
        vm.serializeUint(k, "maxUtilizationBps", p.maxUtilizationBps);
        vm.serializeString(k, "maxExcessVariance", _uintStr(p.maxExcessVariance));
        vm.serializeUint(k, "ewmaAlphaBps", p.ewmaAlphaBps);
        vm.serializeString(k, "seedVariance", _uintStr(p.seedVariance));
        vm.serializeUint(k, "policyCap", p.policyCap);
        vm.serializeUint(k, "keeperShareBps", p.keeperShareBps);
        vm.serializeString(k, "pokeBounty", _uintStr(p.pokeBounty));
        vm.serializeString(k, "finalizeBounty", _uintStr(p.finalizeBounty));
        return vm.serializeString(k, "settleBounty", _uintStr(p.settleBounty));
    }

    function _pricerJson(PricerArgs memory a) internal returns (string memory) {
        string memory k = "aruna.market.pricer";
        string[] memory mk = new string[](5);
        string[] memory gk = new string[](5);
        for (uint256 i = 0; i < 5; i++) {
            mk[i] = _uintStr(a.mKnots[i]);
            gk[i] = _uintStr(a.gKnots[i]);
        }
        vm.serializeString(k, "minPremium", _uintStr(a.minPremium));
        vm.serializeUint(k, "loadBps", a.loadBps);
        vm.serializeString(k, "lambda", _uintStr(a.lambda));
        vm.serializeString(k, "mKnots", mk);
        return vm.serializeString(k, "gKnots", gk);
    }

    function _valuerJson(ValuerArgs memory a, address factory) internal returns (string memory) {
        string memory k = "aruna.market.valuer";
        vm.serializeAddress(k, "positionManager", ArunaFactory(factory).positionManager());
        vm.serializeString(k, "kappa", _uintStr(a.kappa));
        vm.serializeInt(k, "refWidth", a.refWidth);
        vm.serializeString(k, "minWidthMult", _uintStr(a.minWidthMult));
        return vm.serializeString(k, "maxWidthMult", _uintStr(a.maxWidthMult));
    }
}
