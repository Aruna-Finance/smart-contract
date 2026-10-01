// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ArunaFactory} from "../src/ArunaFactory.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {VarianceAccumulator} from "../src/VarianceAccumulator.sol";
import {VaultDeployer} from "../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../src/deployers/AccumulatorDeployer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "./mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";

/// @title ArunaFactoryTest
/// @notice ArunaFactory v2 (plan U7): permissionless, no canonical slot (AE11), time
///         parameters as factory immutables (R28), one accumulator per (factory, pool)
///         with a baseline sample, canonical-pool + settlement-token validation, keeper
///         bounds, and a VaultCreated log that fully describes the market (R22, R25).
contract ArunaFactoryTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant HOUR = 3_600;
    uint32 internal constant TENOR_7D = 7 days;
    uint32 internal constant TENOR_10D = 10 days;
    uint32 internal constant TENOR_14D = 14 days;
    uint32 internal constant TENOR_28D = 28 days;
    uint32 internal constant GAP = 1 days;
    uint32 internal constant SAMPLE = 30 minutes;
    uint64 internal constant ANCHOR = 2_000_000;
    uint24 internal constant FEE = 3000;

    uint16 internal constant MAX_KEEPER_BPS = 1_000;
    uint128 internal constant MAX_POKE = 1e6;
    uint128 internal constant MAX_FINALIZE = 5e6;
    uint128 internal constant MAX_SETTLE = 2e6;

    ArunaFactory internal factory; // release: {7d, 14d, 28d}
    MockUniswapV3Factory internal uniFactory;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockERC20 internal token; // settlement
    MockERC20 internal weth;
    MockPricer internal pricer;
    MockValuer internal valuer;
    address internal vaultDeployer;
    address internal accDeployer;

    function setUp() public {
        vm.warp(1_000_000);
        token = new MockERC20(6);
        weth = new MockERC20(18);
        uniFactory = new MockUniswapV3Factory();
        pm = new MockPositionManager();
        pm.setFactory(address(uniFactory));
        pool = _canonicalPool(address(weth), address(token), FEE);
        pricer = new MockPricer();
        valuer = new MockValuer();
        vaultDeployer = address(new VaultDeployer());
        accDeployer = address(new AccumulatorDeployer());
        factory = _factory(_releaseTenors(), GAP, SAMPLE);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    function _releaseTenors() internal pure returns (uint32[] memory t) {
        t = new uint32[](3);
        t[0] = TENOR_7D;
        t[1] = TENOR_14D;
        t[2] = TENOR_28D;
    }

    function _one(uint32 tenor) internal pure returns (uint32[] memory t) {
        t = new uint32[](1);
        t[0] = tenor;
    }

    function _factory(uint32[] memory tenors, uint32 gap, uint32 sample)
        internal
        returns (ArunaFactory)
    {
        return new ArunaFactory(
            address(pm),
            address(token),
            vaultDeployer,
            accDeployer,
            tenors,
            gap,
            sample,
            MAX_KEEPER_BPS,
            MAX_POKE,
            MAX_FINALIZE,
            MAX_SETTLE
        );
    }

    function _canonicalPool(address a, address b, uint24 fee)
        internal
        returns (MockUniswapV3Pool p)
    {
        p = new MockUniswapV3Pool();
        p.setTokens(a, b, fee);
        uniFactory.setPool(a, b, fee, address(p));
    }

    function _params(uint32 tenor) internal view returns (ArunaFactory.VaultParams memory) {
        return ArunaFactory.VaultParams({
            pool: address(pool),
            tenor: tenor,
            pricer: address(pricer),
            valuer: address(valuer),
            anchor: ANCHOR,
            maxUtilizationBps: 8_000,
            maxExcessVariance: uint128(WAD),
            ewmaAlphaBps: 2_000,
            seedVariance: uint128(WAD / 10),
            policyCap: 100,
            keeperShareBps: 500,
            pokeBounty: 1e5,
            finalizeBounty: 1e6,
            settleBounty: 5e5
        });
    }

    // ---------------------------------------------------------------
    // constructor
    // ---------------------------------------------------------------

    function test_Constructor_ExposesConfig() public view {
        assertEq(factory.positionManager(), address(pm));
        assertEq(factory.settlementToken(), address(token));
        assertEq(factory.vaultDeployer(), vaultDeployer);
        assertEq(factory.accumulatorDeployer(), accDeployer);
        assertEq(factory.gap(), GAP);
        assertEq(factory.sampleInterval(), SAMPLE);
        assertEq(factory.maxKeeperShareBps(), MAX_KEEPER_BPS);
        assertEq(factory.maxPokeBounty(), MAX_POKE);
        assertEq(factory.maxFinalizeBounty(), MAX_FINALIZE);
        assertEq(factory.maxSettleBounty(), MAX_SETTLE);
        uint32[] memory t = factory.allowedTenors();
        assertEq(t.length, 3);
        assertEq(t[0], TENOR_7D);
        assertEq(t[1], TENOR_14D);
        assertEq(t[2], TENOR_28D);
        assertTrue(factory.isAllowedTenor(TENOR_14D));
        assertFalse(factory.isAllowedTenor(TENOR_10D));
    }

    function test_Constructor_RejectsBadTenorSets() public {
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        _factory(new uint32[](0), GAP, SAMPLE); // empty

        uint32[] memory zero = new uint32[](2);
        zero[0] = TENOR_7D; // zero[1] == 0
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        _factory(zero, GAP, SAMPLE);

        uint32[] memory dup = new uint32[](2);
        dup[0] = TENOR_7D;
        dup[1] = TENOR_7D;
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        _factory(dup, GAP, SAMPLE);
    }

    function test_Constructor_RejectsZeroAndOutOfRange() public {
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        _factory(_releaseTenors(), 0, SAMPLE); // zero gap
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        _factory(_releaseTenors(), GAP, 0); // zero sample interval

        uint32[] memory t = _releaseTenors();
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        new ArunaFactory(
            address(0), address(token), vaultDeployer, accDeployer, t, GAP, SAMPLE, 0, 0, 0, 0
        );
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        new ArunaFactory(
            address(pm), address(0), vaultDeployer, accDeployer, t, GAP, SAMPLE, 0, 0, 0, 0
        );
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        new ArunaFactory(
            address(pm), address(token), address(0), accDeployer, t, GAP, SAMPLE, 0, 0, 0, 0
        );
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        new ArunaFactory(
            address(pm), address(token), vaultDeployer, address(0), t, GAP, SAMPLE, 0, 0, 0, 0
        );
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        new ArunaFactory(
            address(pm), address(token), vaultDeployer, accDeployer, t, GAP, SAMPLE, 10_001, 0, 0, 0
        );
    }

    // ---------------------------------------------------------------
    // happy paths
    // ---------------------------------------------------------------

    function test_CreateVault_DeploysAndWires() public {
        address vault = factory.createVault(_params(TENOR_7D));
        address acc = factory.accumulatorOf(address(pool));

        assertTrue(vault != address(0) && acc != address(0));
        assertTrue(factory.isVault(vault), "registered");
        assertEq(factory.allVaultsLength(), 1);
        assertEq(factory.allVaults(0), vault);
        assertEq(factory.vaultsOfLength(address(pool), TENOR_7D), 1);
        assertEq(factory.vaultsOf(address(pool), TENOR_7D)[0], vault);

        CoverVault cv = CoverVault(vault);
        assertEq(address(cv.accumulator()), acc);
        assertEq(address(cv.positionManager()), address(pm));
        assertEq(address(cv.settlementToken()), address(token));
        assertEq(cv.gap(), GAP, "factory gap forwarded");
        assertEq(cv.sampleInterval(), SAMPLE, "factory interval via accumulator");
        assertEq(VarianceAccumulator(acc).sampleInterval(), SAMPLE);
    }

    /// AE11: a second market on the same (pool, tenor) is a separate vault sharing the
    /// accumulator; the first is untouched.
    function test_AE11_SecondMarketSamePair_Succeeds() public {
        address v1 = factory.createVault(_params(TENOR_7D));
        address acc = factory.accumulatorOf(address(pool));
        uint32 samplesBefore = VarianceAccumulator(acc).sampleCount();

        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.maxUtilizationBps = 5_000;
        p.policyCap = 7;
        address v2 = factory.createVault(p);

        assertTrue(v2 != v1, "separate vault");
        assertEq(address(CoverVault(v2).accumulator()), acc, "shares accumulator");
        assertEq(factory.accumulatorOf(address(pool)), acc);
        assertEq(VarianceAccumulator(acc).sampleCount(), samplesBefore, "no re-baseline");
        assertEq(factory.vaultsOfLength(address(pool), TENOR_7D), 2);
        assertEq(factory.vaultsOf(address(pool), TENOR_7D)[0], v1);
        assertEq(factory.vaultsOf(address(pool), TENOR_7D)[1], v2);

        // First market unchanged.
        assertEq(CoverVault(v1).maxUtilizationBps(), 8_000);
        assertEq(CoverVault(v1).policyCap(), 100);
        assertEq(CoverVault(v2).maxUtilizationBps(), 5_000);
        assertEq(CoverVault(v2).policyCap(), 7);
    }

    /// AE11 / R28: the release set rejects 10 days.
    function test_ReleaseFactory_Rejects10DayTenor() public {
        vm.expectRevert(abi.encodeWithSelector(ArunaFactory.TenorNotAllowed.selector, TENOR_10D));
        factory.createVault(_params(TENOR_10D));
        vm.expectRevert(abi.encodeWithSelector(ArunaFactory.TenorNotAllowed.selector, uint32(0)));
        factory.createVault(_params(0));
    }

    /// R28: a sandbox factory {1h} with 1-minute samples accepts 1h and rejects 7d.
    function test_SandboxFactory_Accepts1h_Rejects7d() public {
        ArunaFactory sandbox = _factory(_one(HOUR), 10 minutes, 1 minutes);
        address v = sandbox.createVault(_params(HOUR));
        assertEq(CoverVault(v).tenor(), HOUR);
        assertEq(CoverVault(v).gap(), 10 minutes);
        assertEq(CoverVault(v).sampleInterval(), 1 minutes);

        vm.expectRevert(abi.encodeWithSelector(ArunaFactory.TenorNotAllowed.selector, TENOR_7D));
        sandbox.createVault(_params(TENOR_7D));
    }

    function test_TenorsSharePoolAccumulator_OtherFactoryGetsOwn() public {
        address v7 = factory.createVault(_params(TENOR_7D));
        address v14 = factory.createVault(_params(TENOR_14D));
        address acc = factory.accumulatorOf(address(pool));
        assertEq(address(CoverVault(v7).accumulator()), acc);
        assertEq(address(CoverVault(v14).accumulator()), acc, "7d and 14d share");

        ArunaFactory other = _factory(_releaseTenors(), GAP, SAMPLE);
        address vo = other.createVault(_params(TENOR_7D));
        address accOther = other.accumulatorOf(address(pool));
        assertTrue(accOther != address(0) && accOther != acc, "other factory: own accumulator");
        assertEq(address(CoverVault(vo).accumulator()), accOther);
    }

    function test_NewAccumulator_HasBaselineSample() public {
        vm.recordLogs();
        factory.createVault(_params(TENOR_7D));
        VarianceAccumulator acc = VarianceAccumulator(factory.accumulatorOf(address(pool)));
        assertEq(acc.sampleCount(), 1, "baseline sample taken at creation");
        assertEq(acc.sampleAt(0).timestamp, uint64(vm.getBlockTimestamp()));

        bool sawAcc;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ArunaFactory.AccumulatorCreated.selector) {
                sawAcc = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(pool)))));
                assertEq(abi.decode(logs[i].data, (address)), address(acc));
            }
        }
        assertTrue(sawAcc, "AccumulatorCreated emitted");
    }

    // ---------------------------------------------------------------
    // validation
    // ---------------------------------------------------------------

    function test_InvalidParams_BadConfig() public {
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pricer = address(0);
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.valuer = address(0);
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.pool = address(0);
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        factory.createVault(p);

        // Deep validation stays in the vault constructor (same BadConfig() selector).
        p = _params(TENOR_7D);
        p.maxUtilizationBps = 0;
        vm.expectRevert(CoverVault.BadConfig.selector);
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.policyCap = 0;
        vm.expectRevert(CoverVault.BadConfig.selector);
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.maxExcessVariance = 0;
        vm.expectRevert(CoverVault.BadConfig.selector);
        factory.createVault(p);
    }

    /// A look-alike with the same token0/token1/fee that the Uniswap factory does not list.
    function test_FakePool_Reverts() public {
        MockUniswapV3Pool fake = new MockUniswapV3Pool();
        fake.setTokens(address(weth), address(token), FEE);
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pool = address(fake);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaFactory.PoolNotCanonical.selector, address(fake), address(pool)
            )
        );
        factory.createVault(p);
        assertEq(factory.accumulatorOf(address(fake)), address(0), "no accumulator for fake");
    }

    function test_UnlistedPair_Reverts() public {
        MockUniswapV3Pool lone = new MockUniswapV3Pool();
        lone.setTokens(address(weth), address(token), 500);
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pool = address(lone);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaFactory.PoolNotCanonical.selector, address(lone), address(0)
            )
        );
        factory.createVault(p);
    }

    function test_PoolWithoutSettlementToken_Reverts() public {
        MockERC20 other = new MockERC20(18);
        MockUniswapV3Pool p2 = _canonicalPool(address(weth), address(other), FEE);
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pool = address(p2);
        vm.expectRevert(
            abi.encodeWithSelector(ArunaFactory.PoolLacksSettlementToken.selector, address(p2))
        );
        factory.createVault(p);
    }

    function test_SettlementAsToken0_Accepted() public {
        MockUniswapV3Pool p2 = _canonicalPool(address(token), address(weth), 500);
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pool = address(p2);
        address v = factory.createVault(p);
        assertTrue(factory.isVault(v));
    }

    function test_KeeperBpsAboveBound_Reverts() public {
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.keeperShareBps = MAX_KEEPER_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaFactory.KeeperShareTooHigh.selector, MAX_KEEPER_BPS + 1, MAX_KEEPER_BPS
            )
        );
        factory.createVault(p);

        p.keeperShareBps = MAX_KEEPER_BPS; // at the bound is fine
        factory.createVault(p);
    }

    function test_BountiesAboveBound_Revert() public {
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pokeBounty = MAX_POKE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ArunaFactory.BountyTooHigh.selector, MAX_POKE + 1, MAX_POKE)
        );
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.finalizeBounty = MAX_FINALIZE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ArunaFactory.BountyTooHigh.selector, MAX_FINALIZE + 1, MAX_FINALIZE
            )
        );
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.settleBounty = MAX_SETTLE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ArunaFactory.BountyTooHigh.selector, MAX_SETTLE + 1, MAX_SETTLE)
        );
        factory.createVault(p);

        p = _params(TENOR_7D);
        p.pokeBounty = MAX_POKE;
        p.finalizeBounty = MAX_FINALIZE;
        p.settleBounty = MAX_SETTLE;
        factory.createVault(p); // exactly at bounds is fine
    }

    // ---------------------------------------------------------------
    // event = curator verification source
    // ---------------------------------------------------------------

    function test_VaultCreated_ParamsMatchVaultGetters() public {
        ArunaFactory.VaultParams memory p = _params(TENOR_14D);
        vm.recordLogs();
        address vault = factory.createVault(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256(
            "VaultCreated(address,uint32,address,address,uint32,uint32,(address,uint32,address,address,uint64,uint16,uint128,uint16,uint128,uint32,uint16,uint128,uint128,uint128))"
        );
        assertEq(ArunaFactory.VaultCreated.selector, sig, "event signature");

        Vm.Log memory l;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                l = logs[i];
                found = true;
            }
        }
        assertTrue(found, "VaultCreated emitted");
        assertEq(l.emitter, address(factory));
        assertEq(address(uint160(uint256(l.topics[1]))), address(pool));
        assertEq(uint32(uint256(l.topics[2])), TENOR_14D);
        assertEq(address(uint160(uint256(l.topics[3]))), vault);

        (address acc, uint32 gap, uint32 sample, ArunaFactory.VaultParams memory e) =
            abi.decode(l.data, (address, uint32, uint32, ArunaFactory.VaultParams));

        CoverVault cv = CoverVault(vault);
        assertEq(acc, address(cv.accumulator()), "accumulator");
        assertEq(gap, cv.gap(), "gap");
        assertEq(sample, cv.sampleInterval(), "sampleInterval");
        assertEq(e.pool, address(cv.pool()), "pool");
        assertEq(e.tenor, cv.tenor(), "tenor");
        assertEq(e.pricer, address(cv.pricer()), "pricer");
        assertEq(e.valuer, address(cv.valuer()), "valuer");
        assertEq(e.anchor, cv.anchor(), "anchor");
        assertEq(e.maxUtilizationBps, cv.maxUtilizationBps(), "maxUtilizationBps");
        assertEq(e.maxExcessVariance, cv.maxExcessVariance(), "maxExcessVariance");
        assertEq(e.ewmaAlphaBps, cv.ewmaAlphaBps(), "ewmaAlphaBps");
        assertEq(e.seedVariance, cv.ewmaVariance(), "seed = initial ewmaVariance");
        assertEq(e.policyCap, cv.policyCap(), "policyCap");
        assertEq(e.keeperShareBps, cv.keeperShareBps(), "keeperShareBps");
        assertEq(e.pokeBounty, cv.pokeBounty(), "pokeBounty");
        assertEq(e.finalizeBounty, cv.finalizeBounty(), "finalizeBounty");
        assertEq(e.settleBounty, cv.settleBounty(), "settleBounty");
    }

    // ---------------------------------------------------------------
    // deployers
    // ---------------------------------------------------------------

    /// Deployers are open, but what they deploy directly is not a registered market.
    function test_Deployers_PermissionlessButUnregistered() public {
        address acc = AccumulatorDeployer(accDeployer).deploy(address(pool), SAMPLE);
        assertEq(VarianceAccumulator(acc).sampleInterval(), SAMPLE);
        assertEq(factory.accumulatorOf(address(pool)), address(0));

        address v = VaultDeployer(vaultDeployer)
            .deploy(
                VaultDeployer.Args({
                    pool: address(pool),
                    accumulator: acc,
                    pricer: address(pricer),
                    valuer: address(valuer),
                    positionManager: address(pm),
                    settlementToken: address(token),
                    tenor: TENOR_7D,
                    gap: GAP,
                    anchor: ANCHOR,
                    maxUtilizationBps: 8_000,
                    maxExcessVariance: uint128(WAD),
                    ewmaAlphaBps: 2_000,
                    seedVariance: uint128(WAD / 10),
                    policyCap: 100,
                    keeperShareBps: 10_000, // no bound outside the factory
                    pokeBounty: type(uint128).max,
                    finalizeBounty: 0,
                    settleBounty: 0
                })
            );
        assertTrue(v.code.length > 0);
        assertFalse(factory.isVault(v), "not a market");
        assertEq(factory.allVaultsLength(), 0);
    }
}
