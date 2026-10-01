// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VarianceAccumulator} from "../src/VarianceAccumulator.sol";
import {IVarianceAccumulator} from "../src/interfaces/IVarianceAccumulator.sol";
import {IUniswapV3PoolMinimal} from "../src/interfaces/IUniswapV3PoolMinimal.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// @notice Inter-sample TWAP accumulator (design §3.2). Time is driven with vm.warp and
///         the mock pool's `setTick`, so tickCumulative advances exactly like Uniswap's.
///         Under via_ir, time is read with vm.getBlockTimestamp() (never block.timestamp).
contract VarianceAccumulatorTest is Test {
    uint256 internal constant WAD = 1e18;
    int256 internal constant LN_1_0001_WAD = 99995000333308;

    uint32 internal constant INTERVAL = 1800; // 30 min

    // Exact r² values (WAD) for a Δtick, precomputed off-chain: (Δ·LN)² / 1e18.
    uint256 internal constant R2_100 = 99990000916582;
    uint256 internal constant R2_200 = 399960003666330;
    uint256 internal constant R2_60 = 35996400329969;

    MockUniswapV3Pool internal pool;
    VarianceAccumulator internal acc;

    event Poked(uint32 indexed index, uint32 timestamp, int24 avgTick, uint128 cumulativeSumSq);

    function setUp() public {
        vm.warp(1_000_000); // arbitrary non-zero start
        pool = new MockUniswapV3Pool();
        acc = new VarianceAccumulator(address(pool), INTERVAL);
    }

    // ---------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------

    /// @dev Expected r² (WAD) for a tick change of `deltaTick`, matching the contract.
    function _r2(int256 deltaTick) internal pure returns (uint256) {
        int256 r = deltaTick * LN_1_0001_WAD;
        return uint256(r * r) / WAD;
    }

    /// @dev Hold `tick` for one interval, then poke: the new sample's avgTick == tick.
    function _step(int24 tick) internal {
        pool.setTick(tick);
        skip(INTERVAL);
        acc.poke();
    }

    function _cum(uint32 i) internal view returns (uint128) {
        return acc.sampleAt(i).cumulativeSumSq;
    }

    // ---------------------------------------------------------------
    // config
    // ---------------------------------------------------------------

    function test_Constructor_BadConfig() public {
        vm.expectRevert(VarianceAccumulator.BadConfig.selector);
        new VarianceAccumulator(address(0), INTERVAL);
        vm.expectRevert(VarianceAccumulator.BadConfig.selector);
        new VarianceAccumulator(address(pool), 0);
    }

    function test_Getters() public view {
        assertEq(address(acc.pool()), address(pool));
        assertEq(acc.sampleInterval(), INTERVAL);
        assertEq(acc.lastSampleAt(), 0);
        assertEq(acc.sampleCount(), 0);
    }

    // ---------------------------------------------------------------
    // sampling semantics
    // ---------------------------------------------------------------

    function test_FirstPoke_IsBaselineOnly() public {
        pool.setTick(100);
        acc.poke();
        IVarianceAccumulator.Sample memory s = acc.sampleAt(0);
        assertEq(acc.sampleCount(), 1);
        assertEq(s.timestamp, uint32(vm.getBlockTimestamp()));
        assertEq(s.avgTick, int24(0), "baseline has no avgTick");
        assertEq(s.cumulativeSumSq, 0);
        assertEq(s.elapsed, 0);
        assertEq(acc.lastSampleAt(), uint32(vm.getBlockTimestamp()));
    }

    /// @notice First return appears at the THIRD sample (index 2).
    function test_FirstTwoPokes_NoReturn() public {
        acc.poke(); // s0: baseline (cumulative only)
        _step(100); // s1: first avgTick (100) — moved from s0's placeholder 0, still no return
        IVarianceAccumulator.Sample memory s1 = acc.sampleAt(1);
        assertEq(s1.avgTick, int24(100), "s1 avgTick = TWAP over [t0,t1]");
        assertEq(s1.cumulativeSumSq, 0, "no return at s1");
        assertEq(s1.elapsed, INTERVAL);

        _step(300); // s2: first return, +200
        assertEq(acc.sampleAt(2).avgTick, int24(300));
        assertEq(_cum(2), R2_200, "first return lands at s2");
    }

    function test_ConstantTick_ZeroVariance() public {
        pool.setTick(500);
        acc.poke();
        for (uint256 i = 0; i < 20; i++) {
            _step(500);
        }
        assertEq(acc.sampleCount(), 21);
        assertEq(_cum(20), 0, "dead pool: no variance (design 7.5)");
        assertEq(acc.sampleAt(20).avgTick, int24(500));
    }

    function test_OneStepTickChange_ExactVariance() public {
        acc.poke(); // s0
        _step(0); // s1 avg 0
        _step(100); // s2 avg 100 -> r = +100
        _step(100); // s3 no move
        assertEq(_cum(2), R2_100, "exact r^2 for +100 ticks");
        assertEq(_cum(2), _r2(100));
        assertEq(_cum(3), R2_100, "flat after the step");
    }

    /// @notice THE THESIS: up then back down accumulates BOTH legs (SSOT §2).
    function test_SymmetricRoundTrip_AccumulatesNotNets() public {
        acc.poke();
        _step(0);
        _step(100);
        _step(0);
        assertEq(_cum(3), 2 * R2_100, "variance from both legs");
    }

    function test_WindowSubtraction_GivesCoveredVariance() public {
        acc.poke(); // s0
        _step(0); // s1
        _step(100); // s2 (+100)
        _step(100); // s3 (0)
        _step(300); // s4 (+200)
        assertEq(_cum(4) - _cum(2), R2_200, "covered window (2,4] = +200 leg only");
        assertEq(_cum(4), R2_100 + R2_200);
    }

    function test_CumulativeIsMonotonic() public {
        acc.poke();
        int24[6] memory ticks =
            [int24(0), int24(30), int24(-70), int24(10), int24(-120), int24(200)];
        uint128 prev = 0;
        for (uint256 i = 0; i < ticks.length; i++) {
            _step(ticks[i]);
            uint128 c = _cum(uint32(i + 1));
            assertGe(c, prev, "monotonic (I5)");
            prev = c;
        }
    }

    // ---------------------------------------------------------------
    // rounding
    // ---------------------------------------------------------------

    /// @notice delta = −1 over 1800 s: truncation would give 0, floor gives −1.
    function test_NegativeNonDivisible_FloorsTowardNegInfinity() public {
        acc.poke();
        pool.setTick(-1);
        skip(1);
        pool.setTick(0);
        skip(INTERVAL - 1);
        acc.poke();
        assertEq(acc.sampleAt(1).avgTick, int24(-1), "floor(-1/1800) = -1");

        // -3 for 1000 s, -2 for 800 s: delta = -4600, -4600/1800 = -2.55 -> -3.
        pool.setTick(-3);
        skip(1000);
        pool.setTick(-2);
        skip(800);
        acc.poke();
        assertEq(acc.sampleAt(2).avgTick, int24(-3), "floor(-4600/1800) = -3");
        assertEq(_cum(2), _r2(-2), "return from -1 to -3");
    }

    function test_PositiveNonDivisible_Truncates() public {
        acc.poke();
        pool.setTick(3);
        skip(1000);
        pool.setTick(2);
        skip(800);
        acc.poke(); // 4600 / 1800 = 2.55 -> 2
        assertEq(acc.sampleAt(1).avgTick, int24(2));
    }

    // ---------------------------------------------------------------
    // gaps / late pokes
    // ---------------------------------------------------------------

    /// @notice A poke 5 intervals late records the gap and averages the whole span into
    ///         one TWAP, so measured variance is LOWER than the true path (underwriter bias).
    function test_LatePoke_RecordsGapAndUnderstates() public {
        acc.poke(); // s0
        _step(0); // s1 avg 0

        // True path over 5 intervals: 100, 0, 100, 0, 100 — nobody pokes.
        int24[5] memory path = [int24(100), int24(0), int24(100), int24(0), int24(100)];
        uint256 truePathVariance = 0;
        int24 prevTick = 0;
        for (uint256 i = 0; i < 5; i++) {
            pool.setTick(path[i]);
            skip(INTERVAL);
            truePathVariance += _r2(int256(path[i]) - int256(prevTick));
            prevTick = path[i];
        }
        acc.poke(); // s2, 5 intervals after s1

        IVarianceAccumulator.Sample memory s2 = acc.sampleAt(2);
        assertEq(s2.elapsed, 5 * INTERVAL, "gap recorded on the sample");
        assertEq(s2.avgTick, int24(60), "one TWAP over the span: 300*1800/9000");
        assertEq(s2.cumulativeSumSq, R2_60, "exact measured variance");
        assertEq(truePathVariance, 5 * R2_100);
        assertLt(s2.cumulativeSumSq, truePathVariance, "understated, never overstated");

        (uint32 gaps, uint32 maxGap) = acc.gapStats();
        assertEq(gaps, 1);
        assertEq(maxGap, 5 * INTERVAL);
    }

    function test_GapStats_SlightlyLateIsNotAGap() public {
        acc.poke();
        skip(INTERVAL + 30);
        acc.poke();
        skip(2 * INTERVAL - 1);
        acc.poke();
        (uint32 gaps,) = acc.gapStats();
        assertEq(gaps, 0, "< 2 intervals is not a missed interval");
        skip(2 * INTERVAL);
        acc.poke();
        (gaps,) = acc.gapStats();
        assertEq(gaps, 1);
    }

    /// @notice A huge Δt never reverts; `elapsed` saturates while gapStats keeps the exact gap.
    function test_HugeGap_SaturatesElapsed_NeverReverts() public {
        pool.setTick(10);
        acc.poke();
        skip(400 days);
        acc.poke();
        IVarianceAccumulator.Sample memory s = acc.sampleAt(1);
        assertEq(s.elapsed, type(uint16).max, "saturated");
        assertEq(s.avgTick, int24(10));
        (, uint32 maxGap) = acc.gapStats();
        assertEq(maxGap, 400 days, "exact gap in telemetry");
    }

    // ---------------------------------------------------------------
    // throttle / tryPoke
    // ---------------------------------------------------------------

    function test_Poke_RevertsBeforeInterval() public {
        acc.poke();
        uint32 next = uint32(vm.getBlockTimestamp()) + INTERVAL;
        skip(INTERVAL - 1);
        vm.expectRevert(
            abi.encodeWithSelector(VarianceAccumulator.IntervalNotElapsed.selector, next)
        );
        acc.poke();
    }

    function test_TryPoke_ReturnsFalseWhenThrottled() public {
        assertTrue(acc.tryPoke(), "first tryPoke adds baseline");
        skip(INTERVAL - 1);
        assertFalse(acc.tryPoke(), "throttled: no revert, not added");
        assertEq(acc.sampleCount(), 1);

        skip(1);
        vm.expectEmit(true, false, false, true, address(acc));
        emit Poked(1, uint32(vm.getBlockTimestamp()), 0, 0);
        assertTrue(acc.tryPoke());
        assertEq(acc.sampleCount(), 2);
    }

    function test_TryPoke_ReturnsFalseWhenPoolReverts() public {
        acc.poke();
        skip(INTERVAL);
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(IUniswapV3PoolMinimal.observe.selector), "boom"
        );
        assertFalse(acc.tryPoke(), "pool failure swallowed");
        assertEq(acc.sampleCount(), 1);

        vm.expectRevert(bytes("boom"));
        acc.poke(); // the loud path still surfaces it
    }

    function test_Poke_EmitsPoked() public {
        acc.poke();
        pool.setTick(100);
        skip(INTERVAL);
        vm.expectEmit(true, false, false, true, address(acc));
        emit Poked(1, uint32(vm.getBlockTimestamp()), 100, 0);
        acc.poke();
    }

    // ---------------------------------------------------------------
    // cardinality-1 pool
    // ---------------------------------------------------------------

    /// @notice A pool created this very second has no history: any secondsAgo > 0 would
    ///         revert "OLD". The accumulator only ever asks observe([0]).
    function test_CardinalityOne_ObserveZeroOnly() public {
        MockUniswapV3Pool fresh = new MockUniswapV3Pool();
        VarianceAccumulator a = new VarianceAccumulator(address(fresh), INTERVAL);

        uint32[] memory zero = new uint32[](1);
        vm.expectCall(address(fresh), abi.encodeCall(IUniswapV3PoolMinimal.observe, (zero)), 3);

        a.poke(); // same second as pool creation
        fresh.setTick(7);
        skip(INTERVAL);
        assertTrue(a.tryPoke());
        fresh.setTick(9);
        skip(INTERVAL);
        a.poke();
        assertEq(a.sampleAt(2).cumulativeSumSq, _r2(2));
    }

    // ---------------------------------------------------------------
    // indexAtOrBefore
    // ---------------------------------------------------------------

    function test_IndexAtOrBefore() public {
        acc.poke();
        uint64 t0 = uint64(vm.getBlockTimestamp());
        _step(10);
        uint64 t1 = uint64(vm.getBlockTimestamp());
        _step(20);
        uint64 t2 = uint64(vm.getBlockTimestamp());

        assertEq(acc.indexAtOrBefore(t0), 0);
        assertEq(acc.indexAtOrBefore(t1), 1);
        assertEq(acc.indexAtOrBefore(t2), 2);
        assertEq(acc.indexAtOrBefore(t1 + 5), 1, "between samples resolves to earlier");
        assertEq(acc.indexAtOrBefore(t2 + 100000), 2, "after last resolves to last");
    }

    function test_IndexAtOrBefore_RevertsBeforeFirst() public {
        acc.poke();
        uint64 t0 = uint64(vm.getBlockTimestamp());
        vm.expectRevert(
            abi.encodeWithSelector(VarianceAccumulator.NoSampleAtOrBefore.selector, t0 - 1)
        );
        acc.indexAtOrBefore(t0 - 1);
    }

    function test_SampleAt_OutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(VarianceAccumulator.IndexOutOfRange.selector, 0, 0));
        acc.sampleAt(0);
    }

    // ---------------------------------------------------------------
    // differential fuzz
    // ---------------------------------------------------------------

    /// @notice Random tick paths (with intra-interval tick changes and late pokes) versus
    ///         a naive reference that integrates the path itself (no pool reads).
    function testFuzz_Differential_NaiveReference(uint256 seed) public {
        uint256 steps = 3 + (seed % 20);

        // Reference state.
        int256 refTc = 0; // integrated since baseline
        int256 refPrevAvg = 0;
        uint256 refSumSq = 0;

        int24 tick = int24(int256(uint256(keccak256(abi.encode(seed, "t0"))) % 2001) - 1000);
        pool.setTick(tick);
        acc.poke();

        for (uint256 i = 1; i <= steps; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 dt = INTERVAL + (h % (3 * INTERVAL)); // on time .. ~4 intervals late
            uint256 split = (h >> 32) % dt; // tick changes once mid-interval
            int24 next = int24(int256((h >> 64) % 200_001) - 100_000);

            // Leg 1: current tick for `split` seconds; leg 2: `next` for the rest.
            int256 delta = int256(tick) * int256(split) + int256(next) * int256(dt - split);
            skip(split);
            pool.setTick(next);
            skip(dt - split);
            tick = next;
            acc.poke();

            refTc += delta;
            int256 avg = delta / int256(dt);
            if (delta < 0 && delta % int256(dt) != 0) avg -= 1;
            if (i >= 2) {
                int256 r = (avg - refPrevAvg) * LN_1_0001_WAD;
                refSumSq += uint256(r * r) / WAD;
            }
            refPrevAvg = avg;

            IVarianceAccumulator.Sample memory s = acc.sampleAt(uint32(i));
            assertEq(int256(s.avgTick), avg, "avgTick");
            assertEq(uint256(s.cumulativeSumSq), refSumSq, "cumulativeSumSq");
            assertEq(int256(s.tickCumulative) - int256(acc.sampleAt(0).tickCumulative), refTc);
            assertEq(uint256(s.elapsed), dt, "elapsed");
        }
    }
}
