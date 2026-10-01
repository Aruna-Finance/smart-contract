// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {Math} from "../src/libraries/Math.sol";
import {RealStack} from "./utils/RealStack.sol";

/// @title EdgeCasesTest
/// @notice Design §7.5 — one named test per row of the edge-case table, on the real stack
///         (factory, accumulator, vault, pricer, valuer) at sandbox scale:
///
///         | §7.5 row                              | test                                              |
///         |---------------------------------------|---------------------------------------------------|
///         | cohort with no policy                 | test_Edge75_NoPolicyCohort_FinalizesUpdatesEwma_CapitalWhole |
///         | cohort with no underwriter            | test_Edge75_NoUnderwriterCohort_SellsNothing_SettledAtEndsAt |
///         | finalize called days late             | test_Edge75_FinalizeDaysLate_WindowEndsAtEndsAt_NoExtraVariance |
///         | policy bought in the last seconds     | test_Edge75_LastSecondPurchase_RejectedByFiveIntervalRule |
///         | dead pool (no trades)                 | test_Edge75_DeadPool_LinearCumulative_ZeroVariance |
///
///         The last-seconds row changed in v2: design §7.5 relied on a small coveredSeconds
///         and minPremium; the plan ("Pengukuran") replaces that with a hard rule — a buy is
///         refused when fewer than MIN_INTERVALS_LEFT (5) sample intervals remain, which
///         also closes the free-refund option.
///
///         Spec-flow / acceptance scenarios already covered elsewhere (referenced, not
///         duplicated — plan U8):
///         - LP paid / not paid / refund on real components: Integration.t.sol
///           (test_Integration_SwingsReturningToStart_PayOut, _FlatPrice_PaysZero,
///           _NoSamplesInWindow_Refund); exact-number mock walks in
///           CoverVaultInvariantsDirected (test_Lifecycle_*).
///         - AE1 / SC-01 FUNDING withdraw: CoverVaultCalendar.test_Spec_SC01_FundingWithdrawReducesCapital_AE1;
///           I3 non-vacuity: CoverVaultInvariantsDirected.test_I3_NewForm_CatchesSC01_OnV0Harness.
///         - AE2 stale-sample jump excluded: CoverVaultPolicy.test_AE2_StaleSampleJumpBeforeBuy_Excluded,
///           test_BurnIn_JumpInsidePurchaseInterval_Excluded.
///         - AE3 roll n→n+1 in the gap: CoverVaultCalendar.test_Spec_SC04_RollToNextDuringGap_AE3;
///           AE4 late roll → n+2: test_AE4_LateSettle_RollsToNPlus2; snapshot determinism:
///           test_Snapshot_DeterministicBothOrders_IncludesPrevious.
///         - AE5 no samples (finalize never bricks): CoverVaultCalendar.test_Spec_SC03_*,
///           test_AE5_NoSamplesAtAll_FinalizeAndWithdraw; CoverVaultPolicy.test_AE5_PolicyRefund.
///         - AE6 degraded window: CoverVaultCalendar.test_AE6_GapAboveThreshold_Degraded_PayoutStillComputed.
///         - AE7 escrow + fee collect: CoverVaultPolicy.test_AE7_Escrow_OnlyOwnerCollectsToChosenRecipient,
///           test_Buy_CollectsTokensOwed_IncreaseLiquidityDoesNotMovePayout.
///         - AE8 early cancel: CoverVaultPolicy.test_AE8_CancelDay3_FreesCapacityAndSlot_PremiumStays.
///         - AE9 rejecting receiver / NFT parking: CoverVaultPolicy.test_AE9_*.
///         - AE10 keeper anti-farm: CoverVaultKeeper.test_AE10_*, test_AntiFarm_BuyMinCancelSelfSettle_Unprofitable.
///         - AE11 permissionless second market: ArunaFactory.test_AE11_SecondMarketSamePair_Succeeds.
///         - Policy cap / dust lock-out (SC-16): CoverVaultPolicy.test_PolicyCap_FillWithMinimum_EqualsCapacity_BelowMinRejected.
///         - Full gap cycle on real components (roll n+1, late roll n+2, fee collect, cancel):
///           test_Flow_F1_FullCycle_RealStack below (not covered on real components elsewhere).
contract EdgeCasesTest is RealStack {
    using Math for uint256;

    uint32 internal constant TENOR = 2 hours;
    uint32 internal constant GAP = 10 minutes;
    uint32 internal constant INTERVAL = 60;
    uint32 internal constant STEPS = TENOR / INTERVAL;
    uint64 internal constant T0 = 1_000_000;
    uint64 internal constant ANCHOR = T0 + 1 hours;
    uint128 internal constant CAPITAL = 1_000_000e6;
    uint128 internal constant LIQUIDITY = 100_000e6;
    uint64 internal constant STRIKE = uint64(WAD / 10);

    address internal uw = address(0xA1);
    address internal uw2 = address(0xA2);
    address internal lp = address(0xB1);

    CoverVault internal vault;

    function setUp() public {
        vm.warp(T0);
        uint32[] memory tenors = new uint32[](1);
        tenors[0] = TENOR;
        _deployStack(tenors, GAP, INTERVAL);
        vault = _market(TENOR, ANCHOR, 100, uint128(2 * WAD));
    }

    /// @dev Keeper samples on schedule until `until`, alternating ±swing around `base`.
    function _sampleUntil(uint256 until, int24 base, int24 swing) internal {
        bool up;
        while (true) {
            uint256 next = uint256(acc.lastSampleAt()) + INTERVAL;
            if (next < _now()) next = _now();
            if (next > until) break;
            vm.warp(next);
            acc.poke();
            up = !up;
            pool.setTick(up ? base + swing : base - swing);
        }
    }

    // =====================================================================
    // §7.5 rows
    // =====================================================================

    /// @notice §7.5 "Cohort tanpa satu polis pun": finalize still runs, the EWMA is still
    ///         updated from the window, and capital comes back whole.
    function test_Edge75_NoPolicyCohort_FinalizesUpdatesEwma_CapitalWhole() public {
        _deposit(vault, uw, 0, CAPITAL);
        vm.warp(ANCHOR - 1);
        _sampleUntil(vault.endsAt(0), 0, 300);
        vm.warp(vault.endsAt(0) + 1);

        uint128 ewmaBefore = vault.ewmaVariance();
        (bool done,) = vault.keeperFinalize(0);
        assertTrue(done, "finalized");
        assertTrue(vault.ewmaEverUpdated(), "EWMA updated by a policy-less cohort");
        assertEq(vault.lastEwmaCohortId(), 0, "by cohort 0");
        assertTrue(vault.ewmaVariance() != ewmaBefore, "EWMA moved with the window variance");
        assertEq(uint256(vault.statusOf(0)), uint256(ICoverVault.Status.SETTLED), "SETTLED");

        vm.prank(uw);
        assertEq(vault.withdraw(0), CAPITAL, "capital back whole");
        assertEq(vault.totalObligations(), 0, "nothing owed");
    }

    /// @notice §7.5 "Cohort tanpa underwriter": nothing can be sold (v2: status is derived
    ///         from the calendar, so it READS ACTIVE during the tenor but every buy reverts
    ///         ZeroCapital); it is SETTLED the moment endsAt passes, with no finalize and no
    ///         EWMA update.
    function test_Edge75_NoUnderwriterCohort_SellsNothing_SettledAtEndsAt() public {
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        vm.startPrank(lp);
        pm.approve(address(vault), id);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.ZeroCapital.selector, uint32(0)));
        vault.buyCover(0, id, STRIKE, type(uint128).max, uint64(_now()));
        vm.stopPrank();

        _sampleUntil(vault.endsAt(0), 0, 300);
        vm.warp(vault.endsAt(0));
        assertEq(uint256(vault.statusOf(0)), uint256(ICoverVault.Status.SETTLED), "SETTLED by time");
        vm.expectRevert(abi.encodeWithSelector(CoverVault.AlreadyFinalized.selector, uint32(0)));
        vault.finalize(0);
        (bool done, uint256 bounty) = vault.keeperFinalize(0);
        assertFalse(done, "nothing to finalize");
        assertEq(bounty, 0, "no bounty");
        assertFalse(vault.ewmaEverUpdated(), "EWMA untouched");
        assertEq(pm.ownerOf(id), lp, "NFT never left");
    }

    /// @notice §7.5 "finalize telat berhari-hari": endIndex stays the last sample at/before
    ///         endsAt; a violent market AFTER endsAt (sampled for 3 days) adds nothing to
    ///         the cohort's variance, its payout, or the EWMA.
    function test_Edge75_FinalizeDaysLate_WindowEndsAtEndsAt_NoExtraVariance() public {
        _deposit(vault, uw, 0, CAPITAL);
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        (uint256 pid,) = _buy(vault, lp, 0, id, STRIKE);
        uint256 lpAfterBuy = usdc.balanceOf(lp);

        _sampleUntil(vault.endsAt(0), 0, 0); // flat in the window
        uint32 lastInWindow = acc.sampleCount() - 1;
        assertEq(acc.sampleAt(lastInWindow).timestamp, vault.endsAt(0), "sample at endsAt");
        // Three days of storm after endsAt, keeper still running (every 30 min to keep
        // the test light; the accumulator accepts any spacing ≥ the interval).
        for (uint256 i = 0; i < 144; i++) {
            vm.warp(uint256(acc.lastSampleAt()) + 30 minutes);
            acc.poke();
            pool.setTick(i % 2 == 0 ? int24(4_000) : int24(-4_000));
        }
        assertGt(acc.sampleAt(acc.sampleCount() - 1).cumulativeSumSq, 0, "storm was recorded");

        uint128 ewmaBefore = vault.ewmaVariance();
        vault.finalize(0);
        ICoverVault.Cohort memory c = vault.cohort(0);
        assertEq(c.endIndex, lastInWindow, "endIndex = last sample at/before endsAt");
        assertEq(c.endIndex, acc.indexAtOrBefore(vault.endsAt(0)), "by definition");
        // Flat window → annualized variance 0 → EWMA decays by (1 − α) only.
        assertEq(vault.ewmaVariance(), uint256(ewmaBefore).mulDivDown(8_000, 10_000), "EWMA");

        vault.settlePolicy(pid);
        assertEq(
            uint256(vault.policy(pid).status), uint256(ICoverVault.PolicyStatus.Settled), "measured"
        );
        assertEq(usdc.balanceOf(lp), lpAfterBuy, "no payout from post-endsAt variance");
    }

    /// @notice §7.5 "Polis dibeli di detik-detik akhir" (v2 rule): with fewer than five
    ///         sample intervals left the buy reverts TooLateToBuy; at exactly five it is
    ///         accepted and, with an on-time keeper, measured (≥ 2 returns after baseline).
    function test_Edge75_LastSecondPurchase_RejectedByFiveIntervalRule() public {
        _deposit(vault, uw, 0, CAPITAL);
        uint64 end = vault.endsAt(0);
        uint256 lastOk = end - 5 * uint256(INTERVAL);
        vm.warp(ANCHOR);
        _sampleUntil(lastOk - 1, 0, 0);

        vm.warp(lastOk + 1);
        uint256 id = _position(lp, LIQUIDITY);
        vm.startPrank(lp);
        pm.approve(address(vault), id);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.TooLateToBuy.selector, end));
        vault.buyCover(0, id, STRIKE, type(uint128).max, uint64(_now()));
        vm.stopPrank();

        vm.warp(end - 1);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.TooLateToBuy.selector, end));
        vault.buyCover(0, id, STRIKE, type(uint128).max, uint64(_now()));

        // Exactly five intervals left: accepted (on a fresh vault clock — time only
        // moves forward, so use cohort 1 of the same market).
        _deposit(vault, uw, 1, CAPITAL);
        uint64 end1 = vault.endsAt(1);
        vm.warp(vault.startsAt(1));
        _sampleUntil(end1 - 5 * uint256(INTERVAL) - 1, 0, 0);
        vm.warp(end1 - 5 * uint256(INTERVAL));
        (uint256 pid,) = _buy(vault, lp, 1, id, STRIKE);
        assertEq(vault.policy(pid).coveredSeconds, 5 * INTERVAL, "five intervals covered");
        _sampleUntil(end1, 0, 200);
        vm.warp(end1 + 1);
        vault.settlePolicy(pid);
        assertEq(
            uint256(vault.policy(pid).status),
            uint256(ICoverVault.PolicyStatus.Settled),
            "measured, not a free refund"
        );
    }

    /// @notice §7.5 "Pool Uniswap-nya mati total": no trades, so the tick never changes;
    ///         tickCumulative keeps growing linearly (tick × Δt), every inter-sample TWAP
    ///         is the same tick, Δ avgTick = 0, variance 0 — correct, not a bug. The policy
    ///         is measured and pays 0.
    function test_Edge75_DeadPool_LinearCumulative_ZeroVariance() public {
        int24 tick = -195_000;
        pool.setTick(tick); // last trade before the vault's life; nothing after
        _deposit(vault, uw, 0, CAPITAL);
        vm.warp(ANCHOR);
        uint256 id = _position(lp, LIQUIDITY);
        (uint256 pid,) = _buy(vault, lp, 0, id, STRIKE);
        uint256 lpAfterBuy = usdc.balanceOf(lp);
        for (uint32 k = 0; k < STEPS; k++) {
            vm.warp(uint256(acc.lastSampleAt()) + INTERVAL);
            acc.poke(); // no setTick: dead pool
        }
        uint32 n = acc.sampleCount();
        for (uint32 i = 2; i < n; i++) {
            int256 dTc =
                int256(acc.sampleAt(i).tickCumulative) - int256(acc.sampleAt(i - 1).tickCumulative);
            uint256 dt = acc.sampleAt(i).timestamp - acc.sampleAt(i - 1).timestamp;
            assertEq(dTc, int256(tick) * int256(dt), "tickCumulative linear in time");
            assertEq(acc.sampleAt(i).avgTick, tick, "TWAP == the dead tick");
        }
        assertEq(acc.sampleAt(n - 1).cumulativeSumSq, 0, "zero variance");

        vm.warp(vault.endsAt(0) + 1);
        vault.settlePolicy(pid);
        assertEq(
            uint256(vault.policy(pid).status), uint256(ICoverVault.PolicyStatus.Settled), "measured"
        );
        assertEq(usdc.balanceOf(lp), lpAfterBuy, "pays 0");
    }

    // =====================================================================
    // Spec flow F1 on real components (not covered elsewhere on the real stack)
    // =====================================================================

    /// @notice F1 + F2 end to end: cohort 0 sells cover (one LP collects fees while
    ///         escrowed, one cancels early), settles in its gap; uw rolls into cohort 1
    ///         during the gap, uw2 withdraws. Cohort 1's σ̂² snapshot includes cohort 0's
    ///         result. Cohort 1 then settles only after its gap is over, so uw's late roll
    ///         lands in cohort 3 (n+2) while cohort 2 has already started.
    function test_Flow_F1_FullCycle_RealStack() public {
        _deposit(vault, uw, 0, CAPITAL);
        _deposit(vault, uw2, 0, CAPITAL);
        address lp2 = address(0xB2);
        MockFees memory f = _feeTokens();

        vm.warp(ANCHOR);
        uint256 id1 = _position(lp, LIQUIDITY);
        uint256 id2 = _position(lp2, LIQUIDITY);
        (uint256 p1,) = _buy(vault, lp, 0, id1, STRIKE);
        (uint256 p2, uint128 prem2) = _buy(vault, lp2, 0, id2, STRIKE);

        // Fees accrue while escrowed; only the policy owner collects, to any recipient.
        pm.setTokensOwed(id1, 7e15, 3e6);
        vm.prank(lp);
        vault.collectFees(p1, address(0xFEE));
        assertEq(f.t0.balanceOf(address(0xFEE)), 7e15, "fee0 to chosen recipient");
        assertEq(f.t1.balanceOf(address(0xFEE)), 3e6, "fee1 to chosen recipient");

        // lp2 cancels early: NFT back, premium stays with the cohort.
        _sampleUntil(ANCHOR + 20 minutes, 0, 400);
        vm.prank(lp2);
        vault.cancel(p2);
        assertEq(pm.ownerOf(id2), lp2, "NFT back on cancel");

        _sampleUntil(vault.endsAt(0), 0, 400);
        vm.warp(vault.endsAt(0) + 1); // gap of cohort 0
        assertEq(uint256(vault.statusOf(1)), uint256(ICoverVault.Status.FUNDING), "n+1 FUNDING");
        vault.settleBatch(0, 10);
        assertEq(uint256(vault.statusOf(0)), uint256(ICoverVault.Status.SETTLED), "settled in gap");
        assertGt(vault.cohort(0).claimsPaid, 0, "storm paid lp");
        assertEq(vault.cohort(0).cancelledPremiums, prem2, "cancelled premium kept");

        vm.prank(uw);
        vault.rollTo(0, 1);
        vm.prank(uw2);
        uint256 net2 = vault.withdraw(0);
        assertEq(vault.deposits(1, uw), vault.cohort(1).totalCapital, "rolled into n+1");
        assertGt(net2, 0, "uw2 withdrew");

        // Cohort 1 starts on schedule; its snapshot includes cohort 0's EWMA update.
        assertEq(vault.lastEwmaCohortId(), 0, "EWMA from cohort 0");
        uint128 ewmaAfter0 = vault.ewmaVariance();
        vm.warp(vault.startsAt(1));
        uint256 id3 = _position(lp, LIQUIDITY);
        (uint256 p3,) = _buy(vault, lp, 1, id3, STRIKE);
        assertEq(vault.cohort(1).varianceSnapshot, ewmaAfter0, "snapshot includes n");

        // Nobody settles cohort 1 during its gap: cohort 2 starts, the late roll goes to 3.
        _sampleUntil(vault.endsAt(1), 0, 100);
        vm.warp(vault.startsAt(2) + 1);
        assertEq(
            uint256(vault.statusOf(2)),
            uint256(ICoverVault.Status.ACTIVE),
            "cohort n+2 already started"
        );
        vault.settlePolicy(p3);
        vm.prank(uw);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(2)));
        vault.rollTo(1, 2);
        vm.prank(uw);
        vault.rollTo(1, 3);
        assertGt(vault.deposits(3, uw), 0, "late roll lands in n+2");
        assertEq(pm.ownerOf(id1), lp, "NFT 1 home");
        assertEq(pm.ownerOf(id3), lp, "NFT 3 home");
    }

    struct MockFees {
        MockERC20Like t0;
        MockERC20Like t1;
    }

    function _feeTokens() internal returns (MockFees memory f) {
        // Reuse the stack's tokens as the position's fee tokens (weth / usdc).
        pm.setFeeTokens(weth, usdc);
        f.t0 = MockERC20Like(address(weth));
        f.t1 = MockERC20Like(address(usdc));
    }
}

interface MockERC20Like {
    function balanceOf(address) external view returns (uint256);
}
