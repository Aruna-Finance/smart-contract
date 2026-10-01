// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArunaFactory} from "../src/ArunaFactory.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";

/// @title ArunaFactoryTest
/// @notice Verifies the registry contract of §2: one accumulator per pool (reused
///         across tenors), one vault per (pool, tenor), duplicates rejected, and the
///         deployed vault wired to exactly the addresses the factory recorded.
contract ArunaFactoryTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant TENOR_7D = 604_800;
    uint32 internal constant TENOR_14D = 1_209_600;
    uint64 internal constant ANCHOR = 2_000_000;

    ArunaFactory internal factory;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockERC20 internal token;
    MockPricer internal pricer;
    MockValuer internal valuer;

    function setUp() public {
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        token = new MockERC20(6);
        pricer = new MockPricer();
        valuer = new MockValuer();
        factory = new ArunaFactory(address(pm), address(token));
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
            sampleInterval: 1_800,
            twapWindow: 1_800
        });
    }

    // ---------------------------------------------------------------

    function test_CreateVault_DeploysAccumulatorAndVault() public {
        address vault = factory.createVault(_params(TENOR_7D));

        assertTrue(vault != address(0), "vault deployed");
        assertEq(factory.vaultOf(address(pool), TENOR_7D), vault, "registry: vault by (pool,tenor)");
        assertTrue(
            factory.accumulatorOf(address(pool)) != address(0), "registry: accumulator by pool"
        );
        assertEq(factory.allVaultsLength(), 1, "one vault total");

        // Wired to exactly what the factory holds/recorded.
        CoverVault cv = CoverVault(vault);
        assertEq(
            address(cv.accumulator()),
            factory.accumulatorOf(address(pool)),
            "vault uses pool accumulator"
        );
        assertEq(address(cv.pricer()), address(pricer), "vault pricer");
        assertEq(address(cv.valuer()), address(valuer), "vault valuer");
        assertEq(address(cv.positionManager()), address(pm), "vault position manager");
        assertEq(address(cv.settlementToken()), address(token), "vault settlement token");
        assertEq(cv.tenor(), TENOR_7D, "vault tenor");
    }

    function test_SecondTenor_ReusesAccumulator() public {
        address v7 = factory.createVault(_params(TENOR_7D));
        address acc = factory.accumulatorOf(address(pool));

        address v14 = factory.createVault(_params(TENOR_14D));

        assertTrue(v14 != v7, "distinct vaults per tenor");
        assertEq(factory.accumulatorOf(address(pool)), acc, "same pool => same accumulator");
        assertEq(address(CoverVault(v14).accumulator()), acc, "14d vault shares the 7d accumulator");
        assertEq(factory.allVaultsLength(), 2, "two vaults total");
    }

    function test_DuplicatePair_Reverts() public {
        address v7 = factory.createVault(_params(TENOR_7D));
        vm.expectRevert(
            abi.encodeWithSelector(ArunaFactory.VaultExists.selector, address(pool), TENOR_7D, v7)
        );
        factory.createVault(_params(TENOR_7D));
    }

    function test_DifferentPool_GetsOwnAccumulator() public {
        factory.createVault(_params(TENOR_7D));
        address acc1 = factory.accumulatorOf(address(pool));

        MockUniswapV3Pool pool2 = new MockUniswapV3Pool();
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pool = address(pool2);
        factory.createVault(p);

        address acc2 = factory.accumulatorOf(address(pool2));
        assertTrue(acc2 != address(0) && acc2 != acc1, "second pool gets its own accumulator");
        assertEq(factory.allVaultsLength(), 2, "two vaults total");
    }

    function test_ZeroPricer_Reverts() public {
        ArunaFactory.VaultParams memory p = _params(TENOR_7D);
        p.pricer = address(0);
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        factory.createVault(p);
    }

    function test_ZeroTenor_Reverts() public {
        ArunaFactory.VaultParams memory p = _params(0);
        vm.expectRevert(ArunaFactory.BadConfig.selector);
        factory.createVault(p);
    }
}
