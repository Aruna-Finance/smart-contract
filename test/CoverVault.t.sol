// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";

/// @title CoverVaultTest
/// @notice End-to-end happy path and guard tests for the one contract that holds
///         funds. The centerpiece (test_HappyPath_ConservesFunds) proves the vault
///         pays out exactly what it took in — deposits + premium == LP payout + both
///         underwriter nets, to the base unit — which is the settlement math (§6/§7)
///         and invariants I1/I4 working together.
contract CoverVaultTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant TENOR = 604_800; // 7 days
    uint64 internal constant ANCHOR = 2_000_000;
    uint16 internal constant UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS = uint128(WAD); // maxPayout = varNotional * 1
    uint16 internal constant ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VAR = uint128(WAD / 10);

    // cohort 1 window
    uint64 internal constant C1_START = ANCHOR + TENOR; // 2_604_800
    uint64 internal constant C1_END = ANCHOR + 2 * TENOR; // 3_209_600
    uint32 internal constant COHORT = 1;
    uint256 internal constant TOKEN_ID = 42;

    MockERC20 internal token;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockPricer internal pricer;
    MockValuer internal valuer;
    MockAccumulator internal acc;
    CoverVault internal vault;

    address internal uw1 = address(0xA1);
    address internal uw2 = address(0xA2);
    address internal lp = address(0xB1);

    function setUp() public {
        token = new MockERC20(6);
        pool = new MockUniswapV3Pool(); // token0=0, token1=0, fee=3000
        pm = new MockPositionManager();
        pm.setPool(address(0), address(0), 3000); // match the pool
        pm.setOwner(TOKEN_ID, lp);
        pricer = new MockPricer();
        valuer = new MockValuer();
        acc = new MockAccumulator();

        vault = new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            TENOR,
            ANCHOR,
            UTIL_BPS,
            MAX_EXCESS,
            ALPHA_BPS,
            SEED_VAR
        );

        // Fund actors and approve the vault.
        token.mint(uw1, 100_000e6);
        token.mint(uw2, 100_000e6);
        token.mint(lp, 100_000e6);
        vm.prank(uw1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(uw2);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        token.approve(address(vault), type(uint256).max);
    }

    function test_HappyPath_ConservesFunds() public {
        // --- FUNDING: two underwriters deposit into cohort 1 ---
        vm.warp(ANCHOR + 100_000); // < C1_START
        vm.prank(uw1);
        vault.deposit(COHORT, 6_000e6);
        vm.prank(uw2);
        vault.deposit(COHORT, 4_000e6);

        ICoverVault.Cohort memory c = vault.cohort(COHORT);
        assertEq(c.totalCapital, 10_000e6, "totalCapital");
        assertEq(uint8(vault.statusOf(COHORT)), uint8(ICoverVault.Status.FUNDING), "funding");

        // A baseline variance sample exists at cohort start.
        acc.push(uint32(C1_START), 0);

        // --- ACTIVE: LP buys position-attached cover ---
        vm.warp(C1_START + 1);
        assertEq(uint8(vault.statusOf(COHORT)), uint8(ICoverVault.Status.ACTIVE), "active");

        valuer.setVarNotional(2_000e6); // maxPayout = 2_000e6 * WAD / WAD = 2_000e6
        pricer.setPremium(200e6);

        vm.prank(lp);
        uint256 policyId =
            vault.buyCover(COHORT, TOKEN_ID, uint64(0), 200e6, uint64(block.timestamp + 1));

        ICoverVault.Policy memory p = vault.policy(policyId);
        assertEq(p.owner, lp, "policy owner");
        assertEq(p.maxPayout, 2_000e6, "maxPayout derived");
        assertEq(p.startSumSq, 0, "startSumSq");

        c = vault.cohort(COHORT);
        assertEq(c.reserved, 2_000e6, "reserved");
        assertEq(c.premiumsCollected, 200e6, "premiums");
        assertEq(c.policyCount, 1, "policyCount");

        // Realized variance over the window: 0.5e18 (strike 0 => full excess).
        acc.push(uint32(C1_END), uint128(WAD / 2));

        // --- SETTLING: finalize then settle ---
        vm.warp(C1_END + 1);
        vault.finalize(COHORT);
        assertEq(uint8(vault.statusOf(COHORT)), uint8(ICoverVault.Status.SETTLING), "settling");

        uint256 lpBefore = token.balanceOf(lp);
        vault.settleBatch(COHORT, 10);
        assertEq(uint8(vault.statusOf(COHORT)), uint8(ICoverVault.Status.SETTLED), "settled");

        // payout = varNotional * excess / WAD = 2_000e6 * 0.5e18 / 1e18 = 1_000e6
        assertEq(token.balanceOf(lp) - lpBefore, 1_000e6, "lp payout");

        c = vault.cohort(COHORT);
        assertEq(c.reserved, 0, "reserved released");
        assertEq(c.claimsPaid, 1_000e6, "claimsPaid");

        // --- SETTLED: underwriters withdraw net ---
        // uw1: 6000 + 200*0.6 - ceil(1000*0.6) = 6000 + 120 - 600 = 5520
        vm.prank(uw1);
        uint256 net1 = vault.withdraw(COHORT);
        assertEq(net1, 5_520e6, "uw1 net");

        // uw2: 4000 + 200*0.4 - ceil(1000*0.4) = 4000 + 80 - 400 = 3680
        vm.prank(uw2);
        uint256 net2 = vault.withdraw(COHORT);
        assertEq(net2, 3_680e6, "uw2 net");

        // Conservation: in = deposits + premium = 10_200e6; out = payout + nets.
        assertEq(1_000e6 + net1 + net2, 10_200e6, "funds conserved");
        assertEq(token.balanceOf(address(vault)), 0, "vault drained to the base unit");
    }

    function test_BuyCover_RevertsWhenNotOwner() public {
        _fundAndActivate();
        valuer.setVarNotional(2_000e6);
        pricer.setPremium(200e6);
        vm.prank(uw1); // uw1 does not own TOKEN_ID
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PositionNotOwned.selector, TOKEN_ID));
        vault.buyCover(COHORT, TOKEN_ID, uint64(0), 200e6, uint64(block.timestamp + 1));
    }

    function test_BuyCover_RevertsOnCapacity() public {
        _fundAndActivate();
        // maxPayout = 9_000e6 > capacity (10_000e6 * 0.8 = 8_000e6)
        valuer.setVarNotional(9_000e6);
        pricer.setPremium(1e6);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoverVault.CapacityExceeded.selector, uint128(9_000e6), uint128(8_000e6)
            )
        );
        vault.buyCover(COHORT, TOKEN_ID, uint64(0), type(uint128).max, uint64(block.timestamp + 1));
    }

    function test_BuyCover_RevertsOnPremiumTooHigh() public {
        _fundAndActivate();
        valuer.setVarNotional(2_000e6);
        pricer.setPremium(300e6);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoverVault.PremiumTooHigh.selector, uint128(300e6), uint128(200e6)
            )
        );
        vault.buyCover(COHORT, TOKEN_ID, uint64(0), 200e6, uint64(block.timestamp + 1));
    }

    function test_Deposit_RevertsAfterFunding() public {
        _fundAndActivate(); // now ACTIVE
        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, COHORT));
        vault.deposit(COHORT, 1e6);
    }

    function test_Finalize_RevertsBeforeExpiry() public {
        _fundAndActivate();
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotExpiredYet.selector, COHORT));
        vault.finalize(COHORT);
    }

    function test_Finalize_NoPolicies_GoesStraightToSettled() public {
        vm.warp(ANCHOR + 100_000);
        vm.prank(uw1);
        vault.deposit(COHORT, 5_000e6);
        acc.push(uint32(C1_START), 0);
        acc.push(uint32(C1_END), uint128(WAD / 4));

        vm.warp(C1_END + 1);
        vault.finalize(COHORT);
        assertEq(
            uint8(vault.statusOf(COHORT)), uint8(ICoverVault.Status.SETTLED), "no-policy => settled"
        );

        vm.prank(uw1);
        uint256 net = vault.withdraw(COHORT);
        assertEq(net, 5_000e6, "capital returns whole");
    }

    function test_Withdraw_InFunding_ReturnsDeposit() public {
        vm.warp(ANCHOR + 100_000);
        vm.prank(uw1);
        vault.deposit(COHORT, 5_000e6);
        vm.prank(uw1);
        uint256 net = vault.withdraw(COHORT);
        assertEq(net, 5_000e6, "funding withdraw = deposit");
    }

    // --- helpers ---

    function _fundAndActivate() internal {
        vm.warp(ANCHOR + 100_000);
        vm.prank(uw1);
        vault.deposit(COHORT, 6_000e6);
        vm.prank(uw2);
        vault.deposit(COHORT, 4_000e6);
        acc.push(uint32(C1_START), 0);
        vm.warp(C1_START + 1);
    }
}
