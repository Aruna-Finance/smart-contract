// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployFactory, DeployMarket} from "../../script/Deploy.s.sol";
import {ArunaScript} from "../../script/base/ArunaScript.sol";
import {ArunaFactory} from "../../src/ArunaFactory.sol";
import {CoverVault} from "../../src/CoverVault.sol";
import {VarianceAccumulator} from "../../src/VarianceAccumulator.sol";
import {FlatVegaPricer} from "../../src/FlatVegaPricer.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {VaultDeployer} from "../../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../../src/deployers/AccumulatorDeployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @title DeployScriptTest
/// @notice Plan U9 test scenarios for the deploy tooling, run in-process over the test
///         mocks (chain infra only; every Aruna contract is real):
///         - DeployFactory (sandbox) writes a manifest whose init code hashes equal
///           keccak256(type(X).creationCode) of THIS build, with addresses and args;
///         - DeployMarket appends the market (vault, accumulator, params, calibration
///           marker, keeper funding) to that manifest;
///         - release gates refuse BEFORE broadcast: placeholder calibration (R30), RC hashes
///           that differ from the build (R29 / AE12), a missing or non-green ledger.
///         The scripts' `deploy(config)` entrypoints are called directly (no env), so the
///         tests are hermetic and safe to run in parallel. Every test uses its own manifest
///         label under deployments/31337/ (gitignored) and removes its files.
contract DeployScriptTest is Test {
    uint256 internal constant WAD = 1e18;
    uint24 internal constant FEE = 500;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;

    DeployFactory internal factoryScript;
    DeployMarket internal marketScript;

    string[] internal _cleanup;

    function setUp() public {
        usdc = new MockERC20(6);
        weth = new MockERC20(18);
        MockUniswapV3Factory uniFactory = new MockUniswapV3Factory();
        pm = new MockPositionManager();
        pm.setFactory(address(uniFactory));
        pool = new MockUniswapV3Pool();
        pool.setTokens(address(weth), address(usdc), FEE);
        uniFactory.setPool(address(weth), address(usdc), FEE, address(pool));
        pm.setPool(address(weth), address(usdc), FEE);
        factoryScript = new DeployFactory();
        marketScript = new DeployMarket();
    }

    function tearDown() internal {
        for (uint256 i = 0; i < _cleanup.length; i++) {
            if (vm.exists(_cleanup[i])) vm.removeFile(_cleanup[i]);
        }
    }

    // ------------------------------------------------------------------ fixtures

    function _path(string memory label) internal returns (string memory p) {
        p = string.concat("deployments/31337/", label, ".json");
        _cleanup.push(p);
    }

    function _factoryCfg(string memory profile, string memory label)
        internal
        returns (DeployFactory.FactoryConfig memory cfg)
    {
        _path(label);
        cfg.profile = profile;
        cfg.label = label;
        cfg.gitCommit = "0123456789abcdef0123456789abcdef01234567";
        cfg.ledger = "conformance/ledger.json";
        cfg.positionManager = address(pm);
        cfg.settlementToken = address(usdc);
        cfg.tenors = new uint32[](2);
        cfg.tenors[0] = 3600;
        cfg.tenors[1] = 7200;
        cfg.gap = 600;
        cfg.sampleInterval = 60;
        cfg.maxKeeperShareBps = 1_000;
        cfg.maxPokeBounty = 1e6;
        cfg.maxFinalizeBounty = 5e6;
        cfg.maxSettleBounty = 2e6;
    }

    function _marketCfg(string memory manifest)
        internal
        view
        returns (DeployMarket.MarketConfig memory cfg)
    {
        cfg.manifest = manifest;
        cfg.calibrationArtifact = "sandbox-placeholder";
        cfg.calibrationPlaceholder = true;
        cfg.anchorLead = 600;
        cfg.pricerArgs = DeployMarket.PricerArgs({
            minPremium: 1e6,
            loadBps: 1_000,
            lambda: uint128(WAD / 2),
            mKnots: [
                uint128(0), uint128(WAD / 2), uint128(WAD), uint128(2 * WAD), uint128(4 * WAD)
            ],
            gKnots: [
                uint128(WAD),
                uint128((6 * WAD) / 10),
                uint128((35 * WAD) / 100),
                uint128((15 * WAD) / 100),
                uint128((5 * WAD) / 100)
            ]
        });
        cfg.valuerArgs = DeployMarket.ValuerArgs({
            kappa: uint128(WAD),
            refWidth: 2_000,
            minWidthMult: uint128(WAD / 4),
            maxWidthMult: uint128(4 * WAD)
        });
        cfg.params = ArunaFactory.VaultParams({
            pool: address(pool),
            tenor: 3600,
            pricer: address(0),
            valuer: address(0),
            anchor: 0,
            maxUtilizationBps: 8_000,
            maxExcessVariance: uint128(2 * WAD),
            ewmaAlphaBps: 2_000,
            seedVariance: uint128(WAD / 2),
            policyCap: 20,
            keeperShareBps: 500,
            pokeBounty: 1e4,
            finalizeBounty: 5e4,
            settleBounty: 2e4
        });
    }

    function _buildHash(uint256 i) internal pure returns (bytes32) {
        if (i == 0) return keccak256(type(ArunaFactory).creationCode);
        if (i == 1) return keccak256(type(VaultDeployer).creationCode);
        if (i == 2) return keccak256(type(AccumulatorDeployer).creationCode);
        if (i == 3) return keccak256(type(CoverVault).creationCode);
        if (i == 4) return keccak256(type(VarianceAccumulator).creationCode);
        if (i == 5) return keccak256(type(FlatVegaPricer).creationCode);
        return keccak256(type(PositionValuer).creationCode);
    }

    function _names() internal pure returns (string[7] memory) {
        return [
            "ArunaFactory",
            "VaultDeployer",
            "AccumulatorDeployer",
            "CoverVault",
            "VarianceAccumulator",
            "FlatVegaPricer",
            "PositionValuer"
        ];
    }

    /// @dev A sandbox RC manifest + a ledger file pointing at it with the given status.
    function _rcWithLedger(string memory tag, string memory status)
        internal
        returns (string memory rcPath, string memory ledgerPath)
    {
        DeployFactory.Deployment memory rc =
            factoryScript.deploy(_factoryCfg("sandbox", string.concat(tag, "-rc")));
        rcPath = rc.manifest;
        ledgerPath = _path(string.concat(tag, "-ledger"));
        vm.writeJson(
            string.concat('{"status":"', status, '","rcManifest":"', rcPath, '"}'), ledgerPath
        );
    }

    function _releaseCfg(string memory tag, string memory rcPath, string memory ledgerPath)
        internal
        returns (DeployFactory.FactoryConfig memory cfg)
    {
        cfg = _factoryCfg("release", string.concat(tag, "-release"));
        cfg.rcManifest = rcPath;
        cfg.ledger = ledgerPath;
    }

    // ------------------------------------------------------------------ DeployFactory

    /// @notice Integration (U9): the manifest carries this build's init code hashes, the
    ///         deployed addresses and the constructor args, and the addresses are live.
    function test_DeployFactory_Sandbox_WritesManifestWithBuildHashes() public {
        DeployFactory.Deployment memory d =
            factoryScript.deploy(_factoryCfg("sandbox", "t-factory-sandbox"));
        string memory json = vm.readFile(d.manifest);

        string[7] memory names = _names();
        for (uint256 i = 0; i < 7; i++) {
            assertEq(
                vm.parseJsonBytes32(json, string.concat(".initCodeHashes.", names[i])),
                _buildHash(i),
                names[i]
            );
        }
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "chainId");
        assertEq(vm.parseJsonString(json, ".profile"), "sandbox", "profile");
        assertEq(vm.parseJsonString(json, ".label"), "t-factory-sandbox", "label");
        assertEq(
            vm.parseJsonString(json, ".gitCommit"),
            "0123456789abcdef0123456789abcdef01234567",
            "commit"
        );
        assertEq(vm.parseJsonAddress(json, ".deployer"), DEFAULT_SENDER, "deployer");
        assertEq(vm.parseJsonAddress(json, ".contracts.ArunaFactory"), d.factory, "factory");
        assertEq(vm.parseJsonAddress(json, ".contracts.VaultDeployer"), d.vaultDeployer, "vd");
        assertEq(
            vm.parseJsonAddress(json, ".contracts.AccumulatorDeployer"), d.accumulatorDeployer, "ad"
        );
        assertEq(vm.parseJsonKeys(json, ".markets").length, 0, "no markets yet");

        // Constructor args recorded == what the live factory holds.
        ArunaFactory f = ArunaFactory(d.factory);
        assertEq(vm.parseJsonAddress(json, ".factoryArgs.positionManager"), f.positionManager());
        assertEq(vm.parseJsonAddress(json, ".factoryArgs.settlementToken"), f.settlementToken());
        assertEq(vm.parseJsonAddress(json, ".factoryArgs.vaultDeployer"), f.vaultDeployer());
        assertEq(vm.parseJsonUint(json, ".factoryArgs.gap"), f.gap());
        assertEq(vm.parseJsonUint(json, ".factoryArgs.sampleInterval"), f.sampleInterval());
        uint256[] memory tenors = vm.parseJsonUintArray(json, ".factoryArgs.allowedTenors");
        assertEq(tenors.length, 2);
        assertEq(tenors[1], 7200);
        assertEq(
            vm.parseUint(vm.parseJsonString(json, ".factoryArgs.maxFinalizeBounty")),
            f.maxFinalizeBounty()
        );
        assertEq(vm.parseJsonAddress(json, ".infra.uniswapV3Factory"), pm.factory(), "infra");
        tearDown();
    }

    /// @notice A second run never clobbers an existing manifest unless told to.
    function test_DeployFactory_RefusesToOverwriteManifest() public {
        DeployFactory.FactoryConfig memory cfg = _factoryCfg("sandbox", "t-factory-overwrite");
        DeployFactory.Deployment memory first = factoryScript.deploy(cfg);
        vm.expectRevert(abi.encodeWithSelector(ArunaScript.ManifestExists.selector, first.manifest));
        factoryScript.deploy(cfg);

        cfg.allowOverwrite = true;
        DeployFactory.Deployment memory second = factoryScript.deploy(cfg);
        assertEq(
            vm.parseJsonAddress(vm.readFile(second.manifest), ".contracts.ArunaFactory"),
            second.factory
        );
        assertTrue(second.factory != first.factory, "a fresh factory");
        tearDown();
    }

    function test_DeployFactory_UnknownProfile_Reverts() public {
        DeployFactory.FactoryConfig memory cfg = _factoryCfg("staging", "t-factory-staging");
        vm.expectRevert(abi.encodeWithSelector(ArunaScript.UnknownProfile.selector, "staging"));
        factoryScript.deploy(cfg);
        tearDown();
    }

    /// @notice Release with a green ledger whose RC hashes equal the build: deploys, and
    ///         records the RC manifest it was gated on.
    function test_DeployFactory_Release_GreenMatchingRc_Deploys() public {
        (string memory rcPath, string memory ledgerPath) = _rcWithLedger("t-rel-ok", "green");
        DeployFactory.Deployment memory d =
            factoryScript.deploy(_releaseCfg("t-rel-ok", rcPath, ledgerPath));
        string memory json = vm.readFile(d.manifest);
        assertEq(vm.parseJsonString(json, ".profile"), "release");
        assertEq(vm.parseJsonString(json, ".rcManifest"), rcPath);
        assertEq(
            vm.parseJsonBytes32(json, ".initCodeHashes.CoverVault"),
            vm.parseJsonBytes32(vm.readFile(rcPath), ".initCodeHashes.CoverVault"),
            "release == RC creation code"
        );
        tearDown();
    }

    /// @notice Error path (U9 / AE12): the build differs from the green RC → refused before
    ///         any broadcast (the deployer's nonce does not move).
    function test_DeployFactory_Release_MismatchedRcHashes_Reverts() public {
        (string memory rcPath, string memory ledgerPath) = _rcWithLedger("t-rel-mismatch", "green");
        bytes32 tampered = keccak256("an older CoverVault");
        vm.writeJson(vm.toString(tampered), rcPath, ".initCodeHashes.CoverVault");
        DeployFactory.FactoryConfig memory cfg = _releaseCfg("t-rel-mismatch", rcPath, ledgerPath);

        uint64 nonceBefore = vm.getNonce(DEFAULT_SENDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.InitCodeHashMismatch.selector,
                "CoverVault",
                keccak256(type(CoverVault).creationCode),
                tampered
            )
        );
        factoryScript.deploy(cfg);
        assertEq(vm.getNonce(DEFAULT_SENDER), nonceBefore, "nothing broadcast");
        assertFalse(vm.exists(string.concat("deployments/31337/", cfg.label, ".json")));
        tearDown();
    }

    function test_DeployFactory_Release_MissingLedger_Reverts() public {
        (string memory rcPath,) = _rcWithLedger("t-rel-noledger", "green");
        DeployFactory.FactoryConfig memory cfg =
            _releaseCfg("t-rel-noledger", rcPath, "deployments/31337/does-not-exist.json");
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector,
                "conformance ledger not found: release needs a green RC ledger"
            )
        );
        factoryScript.deploy(cfg);
        tearDown();
    }

    function test_DeployFactory_Release_LedgerNotGreen_Reverts() public {
        (string memory rcPath, string memory ledgerPath) = _rcWithLedger("t-rel-red", "red");
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector, "conformance ledger status is not green"
            )
        );
        factoryScript.deploy(_releaseCfg("t-rel-red", rcPath, ledgerPath));
        tearDown();
    }

    function test_DeployFactory_Release_LedgerForAnotherRc_Reverts() public {
        (, string memory ledgerPath) = _rcWithLedger("t-rel-other", "green");
        DeployFactory.Deployment memory otherRc =
            factoryScript.deploy(_factoryCfg("sandbox", "t-rel-other-rc2"));
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector, "conformance ledger is not for ARUNA_RC_MANIFEST"
            )
        );
        factoryScript.deploy(_releaseCfg("t-rel-other", otherRc.manifest, ledgerPath));
        tearDown();
    }

    function test_DeployFactory_Release_WithoutCommit_Reverts() public {
        (string memory rcPath, string memory ledgerPath) = _rcWithLedger("t-rel-commit", "green");
        DeployFactory.FactoryConfig memory cfg = _releaseCfg("t-rel-commit", rcPath, ledgerPath);
        cfg.gitCommit = "unknown";
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector, "GIT_COMMIT is required in the release profile"
            )
        );
        factoryScript.deploy(cfg);
        tearDown();
    }

    // ------------------------------------------------------------------ DeployMarket

    /// @notice Integration (U9): the market lands in the manifest with the vault the
    ///         factory registered, its accumulator, params, calibration marker and the
    ///         initial keeper-budget donation.
    function test_DeployMarket_Sandbox_AppendsMarket() public {
        DeployFactory.Deployment memory d =
            factoryScript.deploy(_factoryCfg("sandbox", "t-market-sandbox"));
        DeployMarket.MarketConfig memory cfg = _marketCfg(d.manifest);
        cfg.keeperFunding = 3e6;
        usdc.mint(DEFAULT_SENDER, 3e6);

        DeployMarket.Market memory m = marketScript.deploy(cfg);
        DeployMarket.Market memory m2 = marketScript.deploy(_marketCfg(d.manifest));

        ArunaFactory f = ArunaFactory(d.factory);
        assertEq(f.allVaults(0), m.vault, "registered vault");
        assertEq(CoverVault(m.vault).keeperBudget(), 3e6, "budget funded");
        assertEq(m.anchor, vm.getBlockTimestamp() + 600, "anchor = now + lead");

        string memory json = vm.readFile(d.manifest);
        assertEq(vm.parseJsonKeys(json, ".markets").length, 2, "two markets appended");
        assertEq(vm.parseJsonAddress(json, ".markets.0.vault"), m.vault);
        assertEq(vm.parseJsonAddress(json, ".markets.1.vault"), m2.vault);
        assertEq(
            vm.parseJsonAddress(json, ".markets.0.accumulator"), f.accumulatorOf(address(pool))
        );
        assertEq(vm.parseJsonAddress(json, ".markets.0.accumulator"), m2.accumulator, "shared");
        assertEq(vm.parseJsonAddress(json, ".markets.0.params.pricer"), m.pricer);
        assertEq(vm.parseJsonUint(json, ".markets.0.params.policyCap"), 20);
        assertEq(vm.parseJsonString(json, ".markets.0.keeperBudgetFunded"), "3000000");
        assertTrue(
            vm.parseJsonBool(json, ".markets.0.calibration.placeholder"), "marked placeholder"
        );
        assertEq(vm.parseJsonString(json, ".markets.0.calibration.artifact"), "sandbox-placeholder");
        assertEq(vm.parseJsonString(json, ".markets.0.valuerArgs.kappa"), vm.toString(WAD));
        // The factory section is untouched by the append.
        assertEq(vm.parseJsonAddress(json, ".contracts.ArunaFactory"), d.factory);
        assertEq(
            vm.parseJsonBytes32(json, ".initCodeHashes.ArunaFactory"),
            keccak256(type(ArunaFactory).creationCode)
        );
        tearDown();
    }

    /// @notice Error path (R30): a release market on placeholder calibration is refused
    ///         before broadcast; so is one without a calibration artifact or anchor; with an
    ///         explicit non-placeholder marker it deploys and records the marker.
    function test_DeployMarket_Release_PlaceholderCalibration_Reverts() public {
        (string memory rcPath, string memory ledgerPath) = _rcWithLedger("t-mkt-rel", "green");
        DeployFactory.Deployment memory d =
            factoryScript.deploy(_releaseCfg("t-mkt-rel", rcPath, ledgerPath));
        DeployMarket.MarketConfig memory cfg = _marketCfg(d.manifest);
        cfg.params.anchor = uint64(vm.getBlockTimestamp() + 1 days);
        uint64 nonceBefore = vm.getNonce(DEFAULT_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector, "placeholder calibration in the release profile"
            )
        );
        marketScript.deploy(cfg);
        assertEq(vm.getNonce(DEFAULT_SENDER), nonceBefore, "nothing broadcast");

        cfg.calibrationPlaceholder = false;
        cfg.calibrationArtifact = "";
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector,
                "ARUNA_CALIBRATION_ARTIFACT is required in release"
            )
        );
        marketScript.deploy(cfg);

        cfg.calibrationArtifact = "calibration/2026-10-01-weth-usdc-7d.json";
        cfg.params.anchor = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaScript.ReleaseGuard.selector, "an explicit ARUNA_ANCHOR is required in release"
            )
        );
        marketScript.deploy(cfg);

        cfg.params.anchor = uint64(vm.getBlockTimestamp() + 1 days);
        DeployMarket.Market memory m = marketScript.deploy(cfg);
        string memory json = vm.readFile(d.manifest);
        assertEq(vm.parseJsonAddress(json, ".markets.0.vault"), m.vault);
        assertFalse(vm.parseJsonBool(json, ".markets.0.calibration.placeholder"));
        assertEq(
            vm.parseJsonString(json, ".markets.0.calibration.artifact"),
            "calibration/2026-10-01-weth-usdc-7d.json"
        );
        tearDown();
    }

    /// @notice The manifest's profile is authoritative: a conflicting PROFILE is refused.
    function test_DeployMarket_ProfileMismatch_Reverts() public {
        DeployFactory.Deployment memory d =
            factoryScript.deploy(_factoryCfg("sandbox", "t-market-mismatch"));
        DeployMarket.MarketConfig memory cfg = _marketCfg(d.manifest);
        cfg.envProfile = "release";
        vm.expectRevert(
            abi.encodeWithSelector(ArunaScript.ProfileMismatch.selector, "sandbox", "release")
        );
        marketScript.deploy(cfg);

        cfg.envProfile = "";
        cfg.envFactory = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(ArunaScript.FactoryMismatch.selector, d.factory, address(0xBEEF))
        );
        marketScript.deploy(cfg);
        tearDown();
    }
}
