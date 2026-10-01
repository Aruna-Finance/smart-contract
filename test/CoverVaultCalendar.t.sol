// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {IPremiumPricer} from "../src/interfaces/IPremiumPricer.sol";
import {Math} from "../src/libraries/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockValuer} from "./mocks/MockValuer.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";
import {Calendar} from "./utils/Calendar.sol";

/// @notice Flat premium, or (echo mode) a premium that is a function of the σ̂² the vault
///         passes in — so a test can observe which variance a quote/buy priced with.
contract EchoPricer is IPremiumPricer {
    uint128 public premium;
    bool public echo;

    function setPremium(uint128 p) external {
        premium = p;
    }

    function setEcho(bool e) external {
        echo = e;
    }

    function quote(uint128, uint64, uint32, uint128 ewmaVariance, uint128, uint128)
        external
        view
        returns (uint128)
    {
        return echo ? ewmaVariance / 1e9 : premium;
    }
}

/// @title CoverVaultCalendarTest
/// @notice Plan U4: gap calendar, derived status, never-bricking finalize, σ̂² snapshot,
///         roll, SC-01, residual, SC-16. The three audit PoCs (SC-01, SC-03, SC-04) are
///         ported first as spec tests (`test_Spec_*`): each failed on the v0 vault.
contract CoverVaultCalendarTest is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 31_536_000;
    uint256 internal constant BPS = 10_000;

    uint32 internal constant TENOR = 7 days;
    uint32 internal constant GAP = 1 days;
    uint32 internal constant INTERVAL = 6 hours; // 28 samples per tenor
    uint64 internal constant ANCHOR = 2_000_000;
    uint16 internal constant UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS = uint128(WAD);
    uint16 internal constant ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VAR = uint128(WAD / 10);
    uint32 internal constant POLICY_CAP = 100;

    MockERC20 internal token;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    EchoPricer internal pricer;
    MockValuer internal valuer;
    MockAccumulator internal acc;
    CoverVault internal vault;

    address internal uw1 = address(0xA1);
    address internal uw2 = address(0xA2);
    address internal uw3 = address(0xA3);
    address internal lp = address(0xB1);
    uint256 internal nextTokenId = 1;

    // oracle cursor for _fillTo
    uint32 internal lastTs;
    uint128 internal cum;

    function setUp() public {
        token = new MockERC20(6);
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        pm.setPool(address(0), address(0), 3000);
        pricer = new EchoPricer();
        valuer = new MockValuer();
        acc = new MockAccumulator();
        acc.setSampleInterval(INTERVAL);

        vault = new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            TENOR,
            GAP,
            ANCHOR,
            UTIL_BPS,
            MAX_EXCESS,
            ALPHA_BPS,
            SEED_VAR,
            POLICY_CAP,
            0,
            0,
            0,
            0
        );

        address[4] memory actors = [uw1, uw2, uw3, lp];
        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
            vm.prank(actors[i]);
            pm.setApprovalForAll(address(vault), true); // buyCover escrows the NFT
        }
        vm.warp(ANCHOR - 1 days);
    }

    // =====================================================================
    // Ported audit PoCs (spec form). Each failed on the v0 vault.
    // =====================================================================

    /// @notice SC-01 / AE1: a FUNDING withdraw removes the capital, so capacity sold is
    ///         sized against what is actually there (v0 kept 10k as phantom capital).
    function test_Spec_SC01_FundingWithdrawReducesCapital_AE1() public {
        _deposit(uw1, 1, 6_000e6);
        _deposit(uw2, 1, 4_000e6);
        vm.prank(uw1);
        assertEq(vault.withdraw(1), 6_000e6, "funding withdraw returns deposit");

        ICoverVault.Cohort memory c = vault.cohort(1);
        assertEq(c.totalCapital, 4_000e6, "totalCapital 4k");
        assertEq(c.remainingPrincipal, 4_000e6, "remaining principal 4k");
        assertEq(vault.totalObligations(), 4_000e6, "obligations 4k");

        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        // capacity = 4_000 × 80% = 3_200: a 3_200.000001 cover is refused…
        valuer.setVarNotional(3_200e6 + 1);
        pricer.setPremium(1e6);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoverVault.CapacityExceeded.selector, uint128(3_200e6 + 1), uint128(3_200e6)
            )
        );
        vault.buyCover(1, id, 0, type(uint128).max, type(uint64).max);
        // …and exactly the real capacity sells.
        valuer.setVarNotional(3_200e6);
        _buy(1, 3_200e6, 1e6);
        assertEq(vault.cohort(1).reserved, 3_200e6, "reserved == real capacity");
    }

    /// @notice SC-03 / AE5 (cohort): the first sample lands after startsAt. v0 reverted
    ///         forever in finalize; v2 finalizes from the samples that exist, does not
    ///         update the EWMA (< 2 returns), flags degraded, and capital comes back.
    function test_Spec_SC03_FinalizeWithoutSampleBeforeStart_AE5() public {
        _deposit(uw1, 1, 6_000e6);
        acc.push(uint32(_s(1) + 5), 0); // first poke AFTER startsAt
        acc.push(uint32(_e(1) - 1), 0);
        vm.warp(_e(1) + 1);

        vault.finalize(1);
        ICoverVault.Cohort memory c = vault.cohort(1);
        assertTrue(c.finalized, "finalized");
        assertTrue(c.degraded, "degraded");
        assertEq(c.startIndex, 0, "start = first sample");
        assertEq(c.endIndex, 1, "end = last sample <= endsAt");
        assertEq(uint8(c.status), uint8(ICoverVault.Status.SETTLED), "settled");
        assertFalse(vault.ewmaEverUpdated(), "no EWMA update");
        assertEq(vault.ewmaVariance(), SEED_VAR, "EWMA at seed");

        vm.prank(uw1);
        assertEq(vault.withdraw(1), 6_000e6, "capital returned");
    }

    /// @notice SC-04 / AE3: cohort n settled inside its gap rolls straight into n+1
    ///         (v0: n+1 was already ACTIVE, NotFunding(n+1)).
    function test_Spec_SC04_RollToNextDuringGap_AE3() public {
        _deposit(uw1, 1, 6_000e6);
        _fillTo(_e(1));
        vm.warp(_e(1) + 1); // inside cohort 1's gap
        assertEq(uint8(vault.statusOf(2)), uint8(ICoverVault.Status.FUNDING), "n+1 FUNDING");

        vm.prank(uw1);
        vault.rollTo(1, 2); // lazily finalizes the zero-policy cohort 1
        assertEq(vault.deposits(2, uw1), 6_000e6, "rolled into n+1");
        assertEq(vault.cohort(2).totalCapital, 6_000e6, "n+1 capital");
        assertEq(vault.cohort(1).remainingPrincipal, 0, "n emptied");
    }

    // =====================================================================
    // Calendar & status
    // =====================================================================

    function test_Calendar_Formula_AndCurrentCohort() public {
        assertEq(vault.startsAt(0), ANCHOR);
        assertEq(vault.startsAt(3), Calendar.startsAt(ANCHOR, 3, TENOR, GAP));
        assertEq(vault.endsAt(3), Calendar.endsAt(ANCHOR, 3, TENOR, GAP));
        assertEq(vault.cohort(2).startsAt, _s(2), "view fills startsAt");
        assertEq(vault.cohort(2).endsAt, _e(2), "view fills endsAt");

        // Before anchor: cohort 0 is the upcoming cohort and reads FUNDING.
        assertEq(vault.currentCohortId(), 0);
        assertEq(uint8(vault.statusOf(0)), uint8(ICoverVault.Status.FUNDING));
        vm.warp(_s(1));
        assertEq(vault.currentCohortId(), 1, "at startsAt(1)");
        vm.warp(_e(1)); // gap of cohort 1 still belongs to its cycle
        assertEq(vault.currentCohortId(), 1, "in gap of 1");
        vm.warp(_s(2) - 1);
        assertEq(vault.currentCohortId(), 1, "last second of gap");
        vm.warp(_s(2));
        assertEq(vault.currentCohortId(), 2, "at startsAt(2)");
    }

    /// @notice AE4: cohort n settled only after startsAt(n+1) → n+1 is no longer
    ///         FUNDING; the late roll goes to n+2 and a plain withdraw still works.
    function test_AE4_LateSettle_RollsToNPlus2() public {
        _deposit(uw1, 1, 6_000e6);
        _deposit(uw2, 1, 4_000e6);
        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        _buy(1, 1_000e6, 50e6);
        _fillTo(_e(1));

        vm.warp(_s(2) + 1); // settle late: n+1 already ACTIVE
        vault.settleBatch(1, 10);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLED));

        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(2)));
        vault.rollTo(1, 2);

        vm.prank(uw1);
        vault.rollTo(1, 3);
        assertEq(vault.cohort(3).totalCapital, 6_030e6, "uw1 net rolled into n+2");

        vm.prank(uw2);
        assertEq(vault.withdraw(1), 4_020e6, "withdraw still works");
    }

    /// @notice Roll boundary: startsAt(n+1) − 1 is still the gap; startsAt(n+1) is not.
    function test_Roll_Boundary_AtStartOfNext() public {
        _deposit(uw1, 1, 1_000e6);
        _deposit(uw2, 1, 1_000e6);
        _fillTo(_e(1));
        vm.warp(_e(1) + 1);
        vault.finalize(1);

        vm.warp(_s(2) - 1);
        vm.prank(uw1);
        vault.rollTo(1, 2);
        assertEq(vault.deposits(2, uw1), 1_000e6, "roll at startsAt(n+1)-1");

        vm.warp(_s(2));
        vm.prank(uw2);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(2)));
        vault.rollTo(1, 2);
    }

    /// @notice R7: [endsAt, resolved) reads SETTLING, never ACTIVE; resolution → SETTLED.
    function test_Status_SettlingAfterEndsAt() public {
        _deposit(uw1, 1, 10_000e6);
        _deposit(uw1, 2, 10_000e6); // capitalized, zero policies
        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.ACTIVE));
        _buy(1, 1_000e6, 10e6);
        _fillTo(_e(1));

        vm.warp(_e(1) - 1);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.ACTIVE), "last ACTIVE second");
        vm.warp(_e(1));
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLING), "SETTLING at endsAt");
        vault.finalize(1);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLING), "policies pending");
        vault.settleBatch(1, 10);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLED), "resolved");

        // A capitalized zero-policy cohort is SETTLING until finalized.
        _fillTo(_e(2));
        vm.warp(_e(2));
        assertEq(uint8(vault.statusOf(2)), uint8(ICoverVault.Status.SETTLING), "unfinalized");
        vault.finalize(2);
        assertEq(uint8(vault.statusOf(2)), uint8(ICoverVault.Status.SETTLED), "finalized");
    }

    /// @notice A past cohort nobody touched reads its status by time (never FUNDING) and
    ///         refuses deposits and rolls.
    function test_UntouchedPastCohort_StatusByTime() public {
        _deposit(uw1, 0, 1_000e6);
        vm.warp(_s(1) + 1);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.ACTIVE), "untouched ACTIVE");
        vm.warp(_s(3) + 1);
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLED), "untouched past");
        assertEq(uint8(vault.statusOf(2)), uint8(ICoverVault.Status.SETTLED), "untouched past");
        assertEq(uint8(vault.statusOf(3)), uint8(ICoverVault.Status.ACTIVE), "current");
        assertEq(uint8(vault.statusOf(4)), uint8(ICoverVault.Status.FUNDING), "future");

        vm.prank(uw2);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(1)));
        vault.deposit(1, 1e6);

        // Cohort 0 resolves (zero policies) and the roll into a past cohort reverts.
        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(2)));
        vault.rollTo(0, 2);
    }

    /// @notice SC-16 / R6: no capital → buy reverts while ACTIVE; SETTLED at endsAt
    ///         without finalize and without touching the EWMA.
    function test_ZeroCapitalCohort() public {
        // capital that left during FUNDING counts as none (SC-01)
        _deposit(uw1, 1, 1_000e6);
        vm.prank(uw1);
        vault.withdraw(1);

        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        valuer.setVarNotional(1e6);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.ZeroCapital.selector, uint32(1)));
        vault.buyCover(1, id, 0, type(uint128).max, type(uint64).max);

        _fillTo(_e(1));
        vm.warp(_e(1));
        assertEq(uint8(vault.statusOf(1)), uint8(ICoverVault.Status.SETTLED), "SETTLED by time");
        assertFalse(vault.cohort(1).finalized, "no finalize");
        vm.expectRevert(abi.encodeWithSelector(CoverVault.AlreadyFinalized.selector, uint32(1)));
        vault.finalize(1);
        assertFalse(vault.ewmaEverUpdated(), "EWMA untouched");
    }

    // =====================================================================
    // Finalize, degraded, EWMA
    // =====================================================================

    /// @notice AE5 (cohort), extreme form: no sample at all → finalize still succeeds.
    function test_AE5_NoSamplesAtAll_FinalizeAndWithdraw() public {
        _deposit(uw1, 1, 2_000e6);
        vm.warp(_e(1) + 1);
        vault.finalize(1);
        ICoverVault.Cohort memory c = vault.cohort(1);
        assertTrue(c.finalized && c.degraded, "finalized, degraded");
        assertEq(vault.ewmaVariance(), SEED_VAR, "no EWMA update");
        vm.prank(uw1);
        assertEq(vault.withdraw(1), 2_000e6);
    }

    /// @notice AE6: a hole of 4 intervals inside the window flags degraded; the payout is
    ///         still computed from the samples that exist. A regular window is clean.
    function test_AE6_GapAboveThreshold_Degraded_PayoutStillComputed() public {
        _deposit(uw1, 1, 10_000e6);
        _deposit(uw1, 2, 10_000e6);
        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        _buy(1, 2_000e6, 10e6); // strike 0 → payout = varNotional × Σr² / WAD

        // regular samples for 2 days, then a 24h hole (> 3 × 6h), then regular again
        _fillTo(_s(1) + 2 days);
        lastTs += 24 hours;
        acc.push(lastTs, cum += 1e16);
        _fillToWith(_e(1), 1e16);

        vm.warp(_e(1) + 1);
        vault.settleBatch(1, 10); // lazy finalize
        ICoverVault.Cohort memory c = vault.cohort(1);
        assertTrue(c.degraded, "degraded");
        uint128 endSumSq = acc.sampleAt(c.endIndex).cumulativeSumSq;
        uint128 startSumSq = vault.policy(0).startSumSq;
        uint256 expected = uint256(2_000e6).mulDivDown(endSumSq - startSumSq, WAD);
        assertGt(expected, 0, "non-trivial payout");
        assertEq(c.claimsPaid, expected, "payout computed despite degraded");

        // control: cohort 2 sampled on time → not degraded
        _fillToWith(_e(2), 1e16);
        vm.warp(_e(2) + 1);
        vault.finalize(2);
        assertFalse(vault.cohort(2).degraded, "regular window clean");
    }

    /// @notice Exact EWMA update for a regular window, annualized over its span.
    function test_Finalize_EwmaUpdateExact() public {
        _deposit(uw1, 1, 1_000e6);
        _fillToWith(_s(1), 0);
        _fillToWith(_e(1), 1e15); // 28 returns of 1e15 inside the window
        vm.warp(_e(1) + 1);
        vault.finalize(1);

        uint256 sumSq = 28 * 1e15;
        uint256 annualized = sumSq.mulDivDown(YEAR, TENOR);
        uint256 expected = uint256(SEED_VAR).mulDivDown(BPS - ALPHA_BPS, BPS)
            + annualized.mulDivDown(ALPHA_BPS, BPS);
        assertEq(vault.ewmaVariance(), expected, "EWMA");
        assertEq(vault.lastEwmaCohortId(), 1);
        assertFalse(vault.cohort(1).degraded, "clean");
    }

    /// @notice Out-of-order finalize: n+1 first updates the EWMA; n afterwards does not.
    function test_Finalize_OutOfOrder_NoEwmaUpdate() public {
        _deposit(uw1, 1, 1_000e6);
        _deposit(uw1, 2, 1_000e6);
        _fillToWith(_e(2), 1e15);
        vm.warp(_e(2) + 1);

        vault.finalize(2);
        uint128 afterTwo = vault.ewmaVariance();
        assertTrue(afterTwo != SEED_VAR, "n+1 updated");
        assertEq(vault.lastEwmaCohortId(), 2);

        vault.finalize(1);
        assertTrue(vault.cohort(1).finalized, "n finalized");
        assertEq(vault.ewmaVariance(), afterTwo, "n did not update");
        assertEq(vault.lastEwmaCohortId(), 2);
    }

    /// @notice Funded → unfunded → funded: the EWMA keeps moving (it never freezes at the
    ///         seed after an empty cohort); a capitalized zero-policy cohort updates it.
    function test_Ewma_FundedUnfundedFunded_Continues() public {
        _deposit(uw1, 1, 1_000e6); // no policies
        _deposit(uw1, 3, 1_000e6); // cohort 2 left unfunded
        _fillToWith(_e(3), 1e15);

        vm.warp(_e(1) + 1);
        vault.finalize(1);
        uint128 e1 = vault.ewmaVariance();
        assertTrue(e1 != SEED_VAR, "zero-policy capitalized cohort updates");
        assertEq(vault.lastEwmaCohortId(), 1);

        vm.warp(_e(2) + 1);
        assertEq(uint8(vault.statusOf(2)), uint8(ICoverVault.Status.SETTLED), "unfunded SETTLED");
        vm.expectRevert(abi.encodeWithSelector(CoverVault.AlreadyFinalized.selector, uint32(2)));
        vault.finalize(2);

        vm.warp(_e(3) + 1);
        vault.finalize(3);
        assertTrue(vault.ewmaVariance() != e1, "third cohort updates");
        assertEq(vault.lastEwmaCohortId(), 3);
    }

    // =====================================================================
    // σ̂² snapshot
    // =====================================================================

    /// @notice After startsAt(n+1), both orders — buy in n+1 then finalize(n) is implied,
    ///         or finalize(n) then buy — give the identical snapshot, which includes n's
    ///         result; quote() before the first touch already returns that value.
    function test_Snapshot_DeterministicBothOrders_IncludesPrevious() public {
        pricer.setEcho(true);
        _deposit(uw1, 1, 10_000e6);
        _deposit(uw1, 2, 10_000e6);
        _fillToWith(_e(1), 4e15); // high variance in cohort 1
        _fillToWith(_s(2) + 1 hours, 0);
        vm.warp(_s(2) + 10);

        valuer.setVarNotional(100e6);
        uint256 idA = _newPosition(lp);
        (uint128 quoted,,,) = vault.quote(2, idA, 0);

        uint256 snap = vm.snapshotState();

        // Order A: first touch (buy) finalizes cohort 1 lazily, then snapshots.
        vm.prank(lp);
        vault.buyCover(2, idA, 0, type(uint128).max, type(uint64).max);
        ICoverVault.Cohort memory a = vault.cohort(2);
        assertTrue(vault.cohort(1).finalized, "A: n finalized lazily");
        uint128 ewmaA = vault.ewmaVariance();

        vm.revertToState(snap);

        // Order B: explicit finalize first, then buy.
        vault.finalize(1);
        vm.prank(lp);
        vault.buyCover(2, idA, 0, type(uint128).max, type(uint64).max);
        ICoverVault.Cohort memory b = vault.cohort(2);

        assertTrue(a.snapshotTaken && b.snapshotTaken, "taken");
        assertEq(a.varianceSnapshot, b.varianceSnapshot, "identical snapshot");
        assertEq(a.varianceSnapshot, ewmaA, "snapshot == EWMA after n");
        assertTrue(a.varianceSnapshot != SEED_VAR, "includes n's result");
        assertEq(a.premiumsCollected, b.premiumsCollected, "same price");
        assertEq(quoted, a.varianceSnapshot / 1e9, "quote before touch == snapshot");

        // The snapshot is fixed for the cohort: a later finalize cannot reprice it (R10).
        (uint128 again,,,) = vault.quote(2, idA, 0);
        assertEq(again, quoted, "price stable after first policy");
    }

    // =====================================================================
    // Withdraw paths
    // =====================================================================

    /// @notice Withdraw on a capitalized zero-policy cohort past endsAt finalizes lazily
    ///         and pays the right entitlement.
    function test_Withdraw_LazyFinalize_ZeroPolicyCohort() public {
        _deposit(uw1, 1, 3_000e6);
        _fillToWith(_e(1), 1e15);
        vm.warp(_e(1) + 5);
        assertFalse(vault.cohort(1).finalized);
        vm.prank(uw1);
        assertEq(vault.withdraw(1), 3_000e6, "full capital");
        assertTrue(vault.cohort(1).finalized, "lazily finalized");
        assertEq(vault.lastEwmaCohortId(), 1, "EWMA updated by the lazy finalize");
    }

    /// @notice Withdraw on a cohort with unresolved policies reverts — before finalize and
    ///         after finalize until settled.
    function test_Withdraw_RevertsWithUnresolvedPolicies() public {
        _deposit(uw1, 1, 3_000e6);
        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        _buy(1, 500e6, 5e6);
        _fillTo(_e(1));
        vm.warp(_e(1) + 1);

        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotSettled.selector, uint32(1)));
        vault.withdraw(1);

        vault.finalize(1);
        vm.prank(uw1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotSettled.selector, uint32(1)));
        vault.withdraw(1);

        vault.settleBatch(1, 10);
        vm.prank(uw1);
        assertEq(vault.withdraw(1), 3_005e6);
    }

    // =====================================================================
    // Residual
    // =====================================================================

    /// @notice Rounding dust stays cohort n's until EVERY deposit of n is out; then it is
    ///         residual, recorded until swept into the next capitalized cohort's premium
    ///         pool at its finalize.
    function test_Dust_BecomesResidualOnlyAfterAllExit_ThenSwept() public {
        _deposit(uw1, 1, 1);
        _deposit(uw2, 1, 1);
        _deposit(uw3, 1, 1);
        _deposit(uw1, 2, 1_000e6);
        _fillTo(_s(1));
        vm.warp(_s(1) + 1);
        _buy(1, 1, 1); // premium 1 over capital 3 → each premiumShare floor(1/3) = 0
        _fillTo(_e(1));
        vm.warp(_e(1) + 1);
        vault.settleBatch(1, 10);

        vm.prank(uw1);
        assertEq(vault.withdraw(1), 1);
        vm.prank(uw2);
        assertEq(vault.withdraw(1), 1);
        assertEq(vault.residual(), 0, "dust still cohort 1's while uw3 is in");

        vm.prank(uw3);
        vault.rollTo(1, 2); // the last exit may be a roll
        assertEq(vault.residual(), 1, "dust released after last exit");
        uint256 bal = token.balanceOf(address(vault));
        assertEq(vault.totalObligations() + vault.residual(), bal, "booked");

        // No capitalized cohort finalized yet: residual just stays recorded.
        _fillTo(_e(2));
        vm.warp(_e(2) + 1);
        assertEq(vault.residual(), 1);
        vault.finalize(2);
        assertEq(vault.residual(), 0, "swept");
        assertEq(vault.cohort(2).premiumsCollected, 1, "into cohort 2's premium pool");
        assertEq(vault.totalObligations(), bal, "all owed again");

        vm.prank(uw1);
        assertEq(vault.withdraw(2), 1_000e6, "uw1 share of cohort 2 (floor)");
        vm.prank(uw3);
        assertEq(vault.withdraw(2), 1, "uw3 rolled principal");
    }

    /// @notice A direct transfer is residual: no underwriter is credited until a finalize
    ///         sweeps it into a capitalized cohort's premium pool.
    function test_DirectTransfer_BecomesResidual() public {
        _deposit(uw1, 1, 1_000e6);
        token.mint(address(this), 500e6);
        token.transfer(address(vault), 500e6);

        assertEq(vault.residual(), 500e6, "residual");
        assertEq(vault.totalObligations(), 1_000e6, "obligations unchanged");
        assertEq(vault.cohort(1).premiumsCollected, 0, "no entitlement yet");

        // FUNDING withdraw returns the deposit only.
        vm.prank(uw1);
        assertEq(vault.withdraw(1), 1_000e6);
        assertEq(vault.residual(), 500e6);

        _deposit(uw2, 1, 2_000e6);
        _fillTo(_e(1));
        vm.warp(_e(1) + 1);
        vm.prank(uw2);
        assertEq(vault.withdraw(1), 2_500e6, "swept at the lazy finalize, then paid");
        assertEq(vault.residual(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _s(uint32 n) internal pure returns (uint64) {
        return Calendar.startsAt(ANCHOR, n, TENOR, GAP);
    }

    function _e(uint32 n) internal pure returns (uint64) {
        return Calendar.endsAt(ANCHOR, n, TENOR, GAP);
    }

    function _deposit(address u, uint32 n, uint128 amt) internal {
        vm.prank(u);
        vault.deposit(n, amt);
    }

    function _newPosition(address owner) internal returns (uint256 id) {
        id = nextTokenId++;
        pm.setOwner(id, owner);
        pm.setPosition(id, -600, 600, 1e18); // live liquidity (zero is refused)
    }

    function _buy(uint32 n, uint128 varNotional, uint128 premium) internal returns (uint256) {
        valuer.setVarNotional(varNotional);
        pricer.setPremium(premium);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        return vault.buyCover(n, id, 0, type(uint128).max, type(uint64).max);
    }

    /// @dev Push samples on the INTERVAL grid (from ANCHOR) up to `to`, quiet market.
    function _fillTo(uint64 to) internal {
        _fillToWith(to, 0);
    }

    /// @dev Push samples on the grid up to `to`, each adding `inc` to Σr².
    function _fillToWith(uint64 to, uint128 inc) internal {
        if (lastTs == 0) {
            lastTs = uint32(ANCHOR);
            acc.push(lastTs, cum);
        }
        while (uint64(lastTs) + INTERVAL <= to) {
            lastTs += INTERVAL;
            cum += inc;
            acc.push(lastTs, cum);
        }
    }
}
