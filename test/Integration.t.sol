// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {Math} from "../src/libraries/Math.sol";
import {RealStack} from "./utils/RealStack.sol";

/// @title IntegrationTest
/// @notice Plan U8 integration: every Aruna component is the real contract (factory,
///         deployers, VarianceAccumulator, CoverVault, FlatVegaPricer, PositionValuer)
///         over a MockUniswapV3Pool whose tickCumulative advances with time. Three
///         outcomes of one policy, end to end:
///         (a) sharp up/down swings that END WHERE THEY STARTED pay out — the payoff is
///             path-dependent realized variance, not price change (SSOT §2);
///         (b) a flat price pays nothing, measured (not refunded);
///         (c) no sample in the window (dead keeper) refunds the premium in full.
///         Sandbox scale (plan R28): tenor 2 h, sample 60 s, gap 10 min.
contract IntegrationTest is RealStack {
    using Math for uint256;

    uint32 internal constant TENOR = 2 hours;
    uint32 internal constant GAP = 10 minutes;
    uint32 internal constant INTERVAL = 60;
    uint32 internal constant STEPS = TENOR / INTERVAL; // 120 samples across the tenor
    uint64 internal constant T0 = 1_000_000;
    uint64 internal constant ANCHOR = T0 + 1 hours;

    uint128 internal constant CAPITAL = 1_000_000e6; // 1M USDC
    uint128 internal constant LIQUIDITY = 100_000e6; // varNotional 100k USDC per unit var
    uint128 internal constant MAX_EXCESS = uint128(2 * WAD); // maxPayout = 2 × varNotional
    uint64 internal constant STRIKE = uint64(WAD / 10); // 10% annualized variance
    int24 internal constant SWING = 500; // ticks per interval (≈ 5% per minute)

    address internal uw = address(0xA1);
    address internal lp = address(0xB1);

    CoverVault internal vault;

    function setUp() public {
        vm.warp(T0);
        uint32[] memory tenors = new uint32[](1);
        tenors[0] = TENOR;
        _deployStack(tenors, GAP, INTERVAL);
        vault = _market(TENOR, ANCHOR, 100, MAX_EXCESS); // baseline sample at T0
        _deposit(vault, uw, 0, CAPITAL);
    }

    /// @notice (a) Path dependence. Ticks go 0 → +500 → +1000 → +500 → 0 → −500 → −1000 →
    ///         −500 → 0 … and the cohort ENDS AT TICK 0 again: zero net price change, yet
    ///         every one of the 119 returns in the window is a 500-tick move, so the policy
    ///         pays varNotional × (Σr² − strike) exactly as SSOT §2 / design §7.2 says.
    function test_Integration_SwingsReturningToStart_PayOut() public {
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        (uint256 pid, uint128 premium) = _buy(vault, lp, 0, id, STRIKE);
        uint256 lpAfterBuy = usdc.balanceOf(lp);

        // The buy poked at ANCHOR (sample 1). Interval k (k = 0..119) carries tick
        // cycle[(k + 1) % 8]; the last interval carries cycle[0] = 0.
        int24[8] memory cycle = [int24(0), SWING, 2 * SWING, SWING, 0, -SWING, -2 * SWING, -SWING];
        pool.setTick(cycle[1]);
        for (uint32 k = 0; k < STEPS; k++) {
            _keeperStep(cycle[(k + 2) % 8]);
        }
        assertEq(acc.sampleAt(acc.sampleCount() - 1).timestamp, vault.endsAt(0), "on schedule");
        assertEq(acc.sampleAt(acc.sampleCount() - 1).avgTick, 0, "last TWAP back at start");
        assertEq(acc.sampleAt(1).avgTick, 0, "TWAP before cover at the same price");

        // Expected window variance from the tick path alone: baseline s = 2 (first sample
        // after the purchase-time sample), end = 121 (the sample at endsAt); returns are
        // samples 3..121, every one a ±SWING move.
        uint256 expectedSumSq = 119 * _r2(SWING);
        assertEq(
            uint256(acc.sampleAt(121).cumulativeSumSq - acc.sampleAt(2).cumulativeSumSq),
            expectedSumSq,
            "accumulator window == tick-path reference"
        );
        assertEq(_refSumSq(2, 121), expectedSumSq, "avgTick reference agrees");

        // Settle in the gap, permissionless (finalizes lazily).
        vm.warp(vault.endsAt(0) + 1);
        vault.settlePolicy(pid);

        ICoverVault.Policy memory p = vault.policy(pid);
        uint256 strikeAcc = uint256(STRIKE).mulDivUp(TENOR, YEAR);
        uint256 expected = uint256(LIQUIDITY).mulDivDown(expectedSumSq - strikeAcc, WAD);
        assertGt(expected, 0, "path variance clears the strike");
        assertLt(expected, p.maxPayout, "not capped: the variance itself is paid");
        assertEq(uint256(p.status), uint256(ICoverVault.PolicyStatus.Settled), "measured");
        assertEq(p.startIndex, 2, "baseline = first sample after the purchase sample");
        assertEq(usdc.balanceOf(lp) - lpAfterBuy, expected, "LP paid the path variance");
        assertEq(uint256(vault.cohort(0).claimsPaid), expected, "claimsPaid");
        assertEq(pm.ownerOf(id), lp, "NFT returned with the payout");
        assertGt(premium, 0, "premium was charged");

        // Underwriter: capital + premium(− keeper cut) − claim, to the wei.
        uint256 skim = uint256(premium).mulDivDown(500, 10_000);
        vm.prank(uw);
        uint256 net = vault.withdraw(0);
        assertEq(net, uint256(CAPITAL) + premium - skim - expected, "underwriter net");
        assertEq(vault.totalObligations(), vault.keeperBudget(), "only the budget is owed");
    }

    /// @notice (b) A flat price — samples on schedule, tick never moves — is measured and
    ///         pays exactly 0; the underwriter keeps the premium (net of the keeper cut).
    function test_Integration_FlatPrice_PaysZero() public {
        pool.setTick(-201_000); // a realistic WETH/USDC tick, constant
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        (uint256 pid, uint128 premium) = _buy(vault, lp, 0, id, STRIKE);
        uint256 lpAfterBuy = usdc.balanceOf(lp);
        for (uint32 k = 0; k < STEPS; k++) {
            _keeperStep(-201_000);
        }
        vm.warp(vault.endsAt(0) + 1);
        vault.settleBatch(0, 1);

        ICoverVault.Policy memory p = vault.policy(pid);
        assertEq(uint256(p.status), uint256(ICoverVault.PolicyStatus.Settled), "measured");
        assertEq(usdc.balanceOf(lp), lpAfterBuy, "no payout");
        assertEq(vault.cohort(0).claimsPaid, 0, "no claims");
        assertEq(acc.sampleAt(acc.sampleCount() - 1).cumulativeSumSq, 0, "zero variance");
        assertFalse(vault.cohort(0).degraded, "on-schedule window");

        uint256 skim = uint256(premium).mulDivDown(500, 10_000);
        vm.prank(uw);
        assertEq(vault.withdraw(0), uint256(CAPITAL) + premium - skim, "underwriter keeps premium");
    }

    /// @notice (c) The keeper dies right after the purchase: no sample follows the
    ///         purchase-time sample, so the policy cannot be measured and is refunded in
    ///         full (no keeper cut); the window is flagged degraded; capital comes back whole.
    function test_Integration_NoSamplesInWindow_Refund() public {
        pool.setTick(1_234);
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        uint256 lpBefore = usdc.balanceOf(lp);
        (uint256 pid, uint128 premium) = _buy(vault, lp, 0, id, STRIKE);
        uint32 samplesAtBuy = acc.sampleCount();
        pool.setTick(-5_000); // the price moves a lot, but nobody samples it

        vm.warp(vault.endsAt(0) + 1);
        assertEq(acc.sampleCount(), samplesAtBuy, "no sample after the purchase");
        vault.settlePolicy(pid);

        ICoverVault.Policy memory p = vault.policy(pid);
        assertEq(uint256(p.status), uint256(ICoverVault.PolicyStatus.Refunded), "refunded");
        assertEq(usdc.balanceOf(lp), lpBefore + premium, "premium back in full");
        assertEq(pm.ownerOf(id), lp, "NFT back");
        assertTrue(vault.cohort(0).degraded, "window flagged degraded");

        vm.prank(uw);
        assertEq(vault.withdraw(0), CAPITAL, "capital back whole, no premium kept");
    }
}
