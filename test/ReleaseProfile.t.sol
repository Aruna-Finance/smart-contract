// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {RealStack} from "./utils/RealStack.sol";

/// @title ReleaseProfileTest
/// @notice Plan U8 "suite profil rilis": the release factory parameters — tenors
///         {7, 14, 28} days, 30-minute sampling, 1-day gap — exercised through warps on the
///         real stack, measuring the gas of the three operations whose cost grows with the
///         release scale (the RC only proves the small sandbox scale):
///         1. finalize, including the degraded scan over a full 28-day sample set
///            (1 344 samples) — undegraded (full scan) and degraded at the very end;
///         2. settling a full policyCap cohort in ONE settleBatch (payout push + NFT return
///            per policy), compared with the Arbitrum per-transaction / block gas limit
///            (32M) and the gap width;
///         3. rolling n → n+1 during the gap at release scale (and late into n+2).
///         Gas is measured with gasleft() around the call after `vm.cool` on every touched
///         contract, i.e. cold-storage execution gas (L2 execution only; Arbitrum's L1 data
///         fee is extra and does not count against the 32M limit). Numbers are logged
///         (-vv) and bounded by assertions; this suite is the "profil rilis" ledger row.
contract ReleaseProfileTest is RealStack {
    uint32 internal constant D7 = 7 days;
    uint32 internal constant D14 = 14 days;
    uint32 internal constant D28 = 28 days;
    uint32 internal constant GAP = 1 days;
    uint32 internal constant INTERVAL = 30 minutes;
    uint64 internal constant T0 = 1_790_000_000;
    uint64 internal constant ANCHOR = T0 + 1 days;

    /// @notice Arbitrum One gas limit per block (and per transaction).
    uint256 internal constant ARB_BLOCK_GAS = 32_000_000;
    /// @notice Arbitrum One target block time, for the gap comparison.
    uint256 internal constant ARB_BLOCK_TIME_MS = 250;

    uint128 internal constant CAPITAL = 10_000_000e6; // 10M USDC per cohort

    address internal uw = address(0xA1);

    function setUp() public {
        vm.warp(T0);
        uint32[] memory tenors = new uint32[](3);
        tenors[0] = D7;
        tenors[1] = D14;
        tenors[2] = D28;
        _deployStack(tenors, GAP, INTERVAL);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev On-schedule keeper until `until`, ±`swing` ticks around 0 every interval.
    function _sampleUntil(uint256 until, int24 swing) internal {
        bool up;
        while (true) {
            uint256 next = uint256(acc.lastSampleAt()) + INTERVAL;
            if (next < _now()) next = _now();
            if (next > until) break;
            vm.warp(next);
            acc.poke();
            up = !up;
            pool.setTick(up ? swing : -swing);
        }
    }

    function _coolAll(CoverVault v) internal {
        vm.cool(address(v));
        vm.cool(address(acc));
        vm.cool(address(usdc));
        vm.cool(address(pm));
        vm.cool(address(pool));
        vm.cool(address(pricer));
        vm.cool(address(valuer));
    }

    function _finalizeGas(CoverVault v, uint32 cid) internal returns (uint256 used) {
        _coolAll(v);
        uint256 g = gasleft();
        v.finalize(cid);
        used = g - gasleft();
    }

    // ---------------------------------------------------------------------
    // 1. finalize incl. degraded scan, full release sample sets
    // ---------------------------------------------------------------------

    /// @notice All three release tenors on one shared accumulator, sampled on schedule
    ///         for 28 days (1 344 samples). Each vault is finalized at its own endsAt; the
    ///         28-day finalize scans the whole window (worst case: undegraded).
    function test_Profile_FinalizeGas_AllTenors_FullScan() public {
        CoverVault v7 = _market(D7, ANCHOR, 100, uint128(2 * WAD));
        CoverVault v14 = _market(D14, ANCHOR, 100, uint128(2 * WAD));
        CoverVault v28 = _market(D28, ANCHOR, 100, uint128(2 * WAD));
        _deposit(v7, uw, 0, CAPITAL);
        _deposit(v14, uw, 0, CAPITAL);
        _deposit(v28, uw, 0, CAPITAL);

        CoverVault[3] memory vs = [v7, v14, v28];
        uint256[3] memory gasUsed;
        for (uint256 i = 0; i < 3; i++) {
            _sampleUntil(vs[i].endsAt(0), 50);
            vm.warp(vs[i].endsAt(0) + 1);
            gasUsed[i] = _finalizeGas(vs[i], 0);
            ICoverVault.Cohort memory c = vs[i].cohort(0);
            assertFalse(c.degraded, "on-schedule window is not degraded (full scan ran)");
            uint256 scanned = c.endIndex - c.startIndex;
            assertEq(scanned, vs[i].tenor() / INTERVAL, "one sample per interval in the window");
            console.log("finalize tenor (days)", vs[i].tenor() / 1 days);
            console.log("  samples scanned", scanned);
            console.log("  gas", gasUsed[i]);
        }
        assertEq(acc.sampleCount() - 1, (ANCHOR + D28 - T0) / INTERVAL, "28-day sample set");
        // Bounds: linear in samples, and the 28-day worst case far inside one block.
        // Measured ≈ 4.7k gas per scanned sample (one external sampleAt per sample):
        // 7d ≈ 1.6M, 14d ≈ 3.1M, 28d ≈ 6.35M. The plain loop stays (plan "Pindai
        // degraded"): no O(1) counter needed while the worst case is < 1/4 of a block.
        assertLt(gasUsed[2], 8_000_000, "28d finalize < 8M gas");
        assertLe(gasUsed[2], ARB_BLOCK_GAS / 4, "28d finalize <= 1/4 Arbitrum block");
        assertGt(gasUsed[2], gasUsed[0], "scan grows with the window");
    }

    /// @notice Degraded scan worst case: the only gap is the LAST interval of a 28-day
    ///         window, so the scan walks every sample before it flags degraded.
    function test_Profile_FinalizeGas_28d_DegradedAtTheEnd() public {
        CoverVault v28 = _market(D28, ANCHOR, 100, uint128(2 * WAD));
        _deposit(v28, uw, 0, CAPITAL);
        uint64 end = v28.endsAt(0);
        _sampleUntil(end - 4 * uint256(INTERVAL), 50); // then the keeper misses 3 intervals
        vm.warp(end);
        acc.poke(); // one sample at endsAt, 4 intervals after the previous one
        vm.warp(end + 1);

        uint256 used = _finalizeGas(v28, 0);
        ICoverVault.Cohort memory c = v28.cohort(0);
        assertTrue(c.degraded, "gap > 3 intervals at the end -> degraded");
        console.log("finalize 28d degraded-at-end: samples", c.endIndex - c.startIndex);
        console.log("  gas", used);
        assertLt(used, 8_000_000, "degraded 28d finalize < 8M gas");
    }

    // ---------------------------------------------------------------------
    // 2. settle a full policyCap cohort in one batch
    // ---------------------------------------------------------------------

    /// @dev Fill cohort 0 of a fresh 7-day market with exactly `cap` minimum-size
    ///      policies from `cap` distinct LPs, run a stormy 7 days so EVERY policy pays
    ///      (payout push + NFT return per policy: the expensive path), then settle all of
    ///      them in one settleBatch. Returns (finalize gas, batch gas).
    function _profileSettle(uint32 cap) internal returns (uint256 gFinalize, uint256 gBatch) {
        CoverVault v = _market(D7, ANCHOR, cap, uint128(2 * WAD));
        _deposit(v, uw, 0, CAPITAL);
        vm.warp(ANCHOR);
        uint256 minPayout = (uint256(CAPITAL) * 8_000 / 10_000) / cap;
        uint128 liq = uint128((minPayout + 1) / 2); // maxPayout = 2 × varNotional ≥ min
        for (uint32 i = 0; i < cap; i++) {
            address lp = address(uint160(0x100000 + i));
            uint256 id = _position(lp, liq);
            _buy(v, lp, 0, id, uint64(WAD / 100));
        }
        assertEq(v.cohort(0).policyCount, cap, "cohort filled to the cap");

        _sampleUntil(v.endsAt(0), 300);
        vm.warp(v.endsAt(0) + 1 hours); // early in the gap
        gFinalize = _finalizeGas(v, 0);

        _coolAll(v);
        for (uint32 i = 0; i < cap; i++) {
            vm.cool(address(uint160(0x100000 + i)));
        }
        uint256 g = gasleft();
        v.settleBatch(0, cap);
        gBatch = g - gasleft();

        assertEq(uint256(v.statusOf(0)), uint256(ICoverVault.Status.SETTLED), "all settled");
        uint256 n = v.policyCount();
        for (uint256 pid = 0; pid < n; pid++) {
            ICoverVault.Policy memory p = v.policy(pid);
            assertEq(uint256(p.status), uint256(ICoverVault.PolicyStatus.Settled), "measured");
            assertEq(pm.ownerOf(p.positionTokenId), p.owner, "NFT returned");
        }
        assertGt(v.cohort(0).claimsPaid, 0, "payouts pushed");
    }

    function _report(uint32 cap, uint256 gFinalize, uint256 gBatch) internal pure {
        uint256 perPolicy = gBatch / cap;
        console.log("settle full cohort, policyCap", cap);
        console.log("  finalize gas", gFinalize);
        console.log("  settleBatch gas (one tx)", gBatch);
        console.log("  gas per policy", perPolicy);
        console.log("  policies per 32M Arbitrum block", ARB_BLOCK_GAS / perPolicy);
        console.log("  gap blocks at 250 ms", uint256(GAP) * 1000 / ARB_BLOCK_TIME_MS);
    }

    /// @notice The recommended release policyCap (100): one settleBatch settles the
    ///         whole cohort, payouts and NFT returns included, well inside one block.
    function test_Profile_SettleFullCohort_Cap100() public {
        (uint256 gF, uint256 gB) = _profileSettle(100);
        _report(100, gF, gB);
        assertLt(gB, ARB_BLOCK_GAS / 2, "cap 100 settles in < half an Arbitrum block");
        assertLt(gB / 100, 200_000, "< 200k gas per policy");
    }

    /// @notice Headroom check at twice the recommended cap.
    function test_Profile_SettleFullCohort_Cap200() public {
        (uint256 gF, uint256 gB) = _profileSettle(200);
        _report(200, gF, gB);
        assertLt(gB, ARB_BLOCK_GAS, "cap 200 still fits one Arbitrum block");
    }

    // ---------------------------------------------------------------------
    // 3. roll n -> n+1 during the gap at release scale
    // ---------------------------------------------------------------------

    /// @notice 7-day cohort with a live policy settles early in its 1-day gap and the
    ///         underwriter rolls into cohort 1 while it is still FUNDING; a second
    ///         underwriter who waits past startsAt(1) rolls late into cohort 2 (n+2).
    function test_Profile_RollDuringGap_ReleaseScale() public {
        CoverVault v = _market(D7, ANCHOR, 100, uint128(2 * WAD));
        address uw2 = address(0xA2);
        _deposit(v, uw, 0, CAPITAL);
        _deposit(v, uw2, 0, CAPITAL);
        vm.warp(ANCHOR);
        address lp = address(0xB1);
        uint256 id = _position(lp, 1_000_000e6);
        (uint256 pid,) = _buy(v, lp, 0, id, uint64(WAD / 100));
        _sampleUntil(v.endsAt(0), 300);

        vm.warp(v.endsAt(0) + 2 hours); // keeper finalizes + settles in the gap
        v.settlePolicy(pid);
        assertEq(uint256(v.statusOf(0)), uint256(ICoverVault.Status.SETTLED), "settled in gap");
        assertEq(uint256(v.statusOf(1)), uint256(ICoverVault.Status.FUNDING), "n+1 FUNDING");

        _coolAll(v);
        uint256 g = gasleft();
        vm.prank(uw);
        v.rollTo(0, 1);
        uint256 gRoll = g - gasleft();
        assertGt(v.deposits(1, uw), 0, "rolled into n+1");
        console.log("rollTo n->n+1 in gap: gas", gRoll);
        console.log("  seconds of gap left", uint256(v.startsAt(1)) - _now());
        assertLt(gRoll, 150_000, "roll < 150k gas");

        vm.warp(v.startsAt(1) + 1); // missed the gap
        vm.prank(uw2);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotFunding.selector, uint32(1)));
        v.rollTo(0, 1);
        vm.prank(uw2);
        v.rollTo(0, 2);
        assertGt(v.deposits(2, uw2), 0, "late roll lands in n+2");
    }
}
