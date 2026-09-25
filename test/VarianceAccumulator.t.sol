// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VarianceAccumulator} from "../src/VarianceAccumulator.sol";
import {IVarianceAccumulator} from "../src/interfaces/IVarianceAccumulator.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

contract VarianceAccumulatorTest is Test {
    uint256 internal constant WAD = 1e18;
    int256 internal constant LN_1_0001_WAD = 99995000333308;

    uint32 internal constant INTERVAL = 1800; // 30 min
    uint32 internal constant WINDOW = 1800;

    MockUniswapV3Pool internal pool;
    VarianceAccumulator internal acc;

    function setUp() public {
        pool = new MockUniswapV3Pool();
        acc = new VarianceAccumulator(address(pool), INTERVAL, WINDOW);
        vm.warp(1_000_000); // arbitrary non-zero start
    }

    /// @dev Expected r² (WAD) for a tick change of `deltaTick`, matching the contract.
    function _expectedRSquared(int256 deltaTick) internal pure returns (uint256) {
        int256 r = deltaTick * LN_1_0001_WAD;
        return uint256(r * r) / WAD;
    }

    function _poke(int24 avgTick) internal {
        pool.setAvgTick(avgTick);
        acc.poke();
    }

    // ---------------------------------------------------------------

    function test_FirstPoke_EstablishesBaseline_NoVariance() public {
        _poke(100);
        assertEq(acc.sampleCount(), 1, "one sample");
        IVarianceAccumulator.Sample memory s = acc.sampleAt(0);
        assertEq(s.cumulativeSumSq, 0, "baseline carries no variance");
        assertEq(s.avgTick, int24(100), "baseline tick recorded");
    }

    function test_Throttle_RevertsBeforeInterval() public {
        _poke(0);
        pool.setAvgTick(50);
        vm.expectRevert(); // IntervalNotElapsed
        acc.poke();
    }

    function test_SingleMove_AccumulatesExactVariance() public {
        _poke(0); // baseline at tick 0
        skip(INTERVAL);
        _poke(100); // +100 ticks

        IVarianceAccumulator.Sample memory s = acc.sampleAt(1);
        assertEq(s.cumulativeSumSq, uint128(_expectedRSquared(100)), "r^2 for +100 ticks");
    }

    /// @notice THE THESIS: price up then back down by the same amount ends near the
    ///         same tick, yet variance accumulates BOTH legs — it measures how wildly
    ///         price moved, not where it ended (SSOT §2).
    function test_SymmetricRoundTrip_AccumulatesNotNets() public {
        _poke(0); // baseline tick 0
        skip(INTERVAL);
        _poke(100); // up +100
        skip(INTERVAL);
        _poke(0); // back down -100, ends at the start

        IVarianceAccumulator.Sample memory s = acc.sampleAt(2);
        // Both a +100 and a -100 leg, each contributing the same r².
        uint256 expected = _expectedRSquared(100) + _expectedRSquared(-100);
        assertEq(s.cumulativeSumSq, uint128(expected), "variance from both legs");
        assertGt(s.cumulativeSumSq, 0, "round trip is NOT zero variance");
    }

    function test_DeadPool_ZeroVariance() public {
        _poke(500); // baseline
        skip(INTERVAL);
        _poke(500); // no movement — §7.5 dead-pool case
        IVarianceAccumulator.Sample memory s = acc.sampleAt(1);
        assertEq(s.cumulativeSumSq, 0, "no move, no variance");
    }

    function test_CumulativeIsMonotonic() public {
        _poke(0);
        uint128 prev = 0;
        int24[5] memory ticks = [int24(30), int24(-70), int24(10), int24(-120), int24(200)];
        for (uint256 i = 0; i < ticks.length; i++) {
            skip(INTERVAL);
            _poke(ticks[i]);
            IVarianceAccumulator.Sample memory s = acc.sampleAt(uint32(i + 1));
            assertGe(s.cumulativeSumSq, prev, "monotonic non-decreasing (I5)");
            prev = s.cumulativeSumSq;
        }
    }

    function test_WindowSubtraction_GivesCoveredVariance() public {
        // A policy bought at sample 1 and settled at sample 3 pays only for the
        // variance BETWEEN them (design §6.2: one subtraction).
        _poke(0); // s0 baseline
        skip(INTERVAL);
        _poke(100); // s1  (+100 leg lands here)
        skip(INTERVAL);
        _poke(100); // s2  (no move)
        skip(INTERVAL);
        _poke(300); // s3  (+200 leg lands here)

        uint128 start = acc.sampleAt(1).cumulativeSumSq;
        uint128 end = acc.sampleAt(3).cumulativeSumSq;
        uint256 covered = end - start;
        // Between s1 and s3: a 0-move then a +200 move.
        assertEq(covered, _expectedRSquared(200), "covered window = +200 leg only");
    }

    function test_IndexAtOrBefore() public {
        // NOTE: capture times via the cheatcode, not `block.timestamp`. Under via_ir
        // the TIMESTAMP opcode is cached as constant within this function frame (a real
        // chain can't change it mid-tx), so plain `block.timestamp` reads would all
        // collapse to the first value despite vm.warp. vm.getBlockTimestamp() is an
        // external call and reflects each warp.
        _poke(0); // s0 @ t0
        uint64 t0 = uint64(vm.getBlockTimestamp());
        skip(INTERVAL);
        _poke(10); // s1
        uint64 t1 = uint64(vm.getBlockTimestamp());
        skip(INTERVAL);
        _poke(20); // s2
        uint64 t2 = uint64(vm.getBlockTimestamp());

        assertEq(acc.indexAtOrBefore(t0), 0);
        assertEq(acc.indexAtOrBefore(t1), 1);
        assertEq(acc.indexAtOrBefore(t2), 2);
        assertEq(acc.indexAtOrBefore(t1 + 5), 1, "between samples resolves to earlier");
        assertEq(acc.indexAtOrBefore(t2 + 100000), 2, "after last resolves to last");
    }

    function test_IndexAtOrBefore_RevertsBeforeFirst() public {
        _poke(0);
        uint64 t0 = uint64(block.timestamp);
        vm.expectRevert();
        acc.indexAtOrBefore(t0 - 1);
    }

    function test_GapStats_RecordsLatePokes() public {
        _poke(0);
        skip(INTERVAL);
        _poke(10); // on time
        (uint32 gaps0,) = acc.gapStats();
        assertEq(gaps0, 0, "on-time poke is not a gap");

        skip(INTERVAL * 3); // very late
        _poke(20);
        (uint32 gaps1, uint32 maxGap) = acc.gapStats();
        assertEq(gaps1, 1, "late poke recorded");
        assertEq(maxGap, INTERVAL * 3, "max gap tracked");
    }
}
