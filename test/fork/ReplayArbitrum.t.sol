// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {VarianceAccumulator} from "../../src/VarianceAccumulator.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

/// @title ReplayArbitrumTest
/// @notice Plan U8 fork-replay: a REAL VarianceAccumulator measuring the real Arbitrum One
///         WETH/USDC 0.05% pool (0xC696…E8D0, verified on-chain: token0 WETH, token1
///         native USDC, fee 500). The fork is rolled forward block range by block range
///         (`vm.rollFork`, accumulator kept with `vm.makePersistent`), the accumulator is
///         poked on schedule, and its `cumulativeSumSq` is compared, sample by sample,
///         with a reference computed in the test from the very same `observe([0])` data
///         (design §3.2: avgTick = floor(Δtc/Δt), r = Δ avgTick · ln 1.0001, Σ r²/WAD).
///         It also proves `observe([0])` never reverts on a pool with its real cardinality.
///
///         Running it:
///           ARBITRUM_RPC_URL=<rpc> forge test --match-path test/fork/ReplayArbitrum.t.sol -vv
///         - No ARBITRUM_RPC_URL → the test is SKIPPED (logged), so the default suite stays
///           offline.
///         - ARBITRUM_FORK_BLOCK=<n> pins the start block (ledger runs: an archive RPC and the
///           recorded block below). Unset → "recent" mode: start = 5 600 blocks (~23 min)
///           before the RPC's latest block. The public endpoint https://arb1.arbitrum.io/rpc
///           serves only the last ~9 000 blocks of state ("historical state … is not
///           available" further back), so a pinned historical range needs an archive RPC.
///         Recorded run (2026-10-01, public RPC, recent mode): blocks 510 600 469 →
///         510 605 409 (timestamps 1 790 842 117 → 1 790 843 464), 20 samples at 60 s,
///         every sample's avgTick and cumulativeSumSq equal to the reference to the wei
///         (final Σr² = 2 079 792 019 056). Reproduce on an archive RPC with
///         ARBITRUM_FORK_BLOCK=510600469 (RECORDED_START_BLOCK).
contract ReplayArbitrumTest is Test {
    address internal constant POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice Start block of the recorded ledger run (archive-RPC reproduction only; the
    ///         default stays "recent" so the public RPC keeps working).
    uint256 internal constant RECORDED_START_BLOCK = 510_600_469;

    uint32 internal constant INTERVAL = 60; // sandbox-scale sampling (plan R28)
    uint256 internal constant STEPS = 20; // samples taken (sample 0 = baseline)
    uint256 internal constant STEP_BLOCKS = 260; // ~65 s at ~250 ms blocks
    uint256 internal constant RECENT_LOOKBACK = 5_600;

    uint256 internal constant WAD = 1e18;
    int256 internal constant LN_1_0001_WAD = 99995000333308;

    function _toUint(bytes memory b) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < b.length; i++) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    function test_Fork_ReplayWethUsdc_CumulativeSumSqMatchesReference() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console.log("SKIP: ARBITRUM_RPC_URL not set - fork replay not run");
            vm.skip(true);
            return;
        }

        uint256 start = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (start == 0) {
            // The L2 head from the RPC itself: on an Arbitrum fork `block.number` is the
            // L1 block number, so it cannot be used to pick an L2 block.
            start = _toUint(vm.rpc(rpc, "eth_blockNumber", "[]")) - RECENT_LOOKBACK;
        }
        vm.createSelectFork(rpc, start);

        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(POOL);
        assertEq(pool.token0(), WETH, "token0 WETH");
        assertEq(pool.token1(), USDC, "token1 USDC");
        assertEq(uint256(pool.fee()), 500, "0.05% pool");

        VarianceAccumulator acc = new VarianceAccumulator(POOL, INTERVAL);
        vm.makePersistent(address(acc));

        int56[] memory tc = new int56[](STEPS);
        uint256[] memory ts = new uint256[](STEPS);
        uint256[] memory blk = new uint256[](STEPS);
        uint32[] memory zero = new uint32[](1);

        uint256 b = start;
        for (uint256 i = 0; i < STEPS; i++) {
            if (i > 0) {
                b += STEP_BLOCKS;
                vm.rollFork(b);
                // Arbitrum block times vary: roll on until the throttle allows a sample.
                for (
                    uint256 k = 0;
                    k < 20 && vm.getBlockTimestamp() < uint256(ts[i - 1]) + INTERVAL;
                    k++
                ) {
                    b += STEP_BLOCKS / 4;
                    vm.rollFork(b);
                }
            }
            (int56[] memory tcs,) = pool.observe(zero); // reference read, same block
            tc[i] = tcs[0];
            ts[i] = vm.getBlockTimestamp();
            blk[i] = b;
            acc.poke(); // reverts loudly on any pool or throttle failure
        }

        assertEq(acc.sampleCount(), STEPS, "one sample per step");
        console.log("fork replay: blocks", blk[0], "->", blk[STEPS - 1]);
        console.log("             timestamps", ts[0], "->", ts[STEPS - 1]);

        int256 prevAvg;
        uint256 refCum;
        for (uint256 i = 0; i < STEPS; i++) {
            assertEq(uint256(acc.sampleAt(uint32(i)).timestamp), ts[i], "sample time");
            assertEq(acc.sampleAt(uint32(i)).tickCumulative, tc[i], "tickCumulative");
            if (i == 0) continue;
            int256 dt = int256(ts[i] - ts[i - 1]);
            int256 d = int256(tc[i]) - int256(tc[i - 1]);
            int256 avg = d / dt;
            if (d < 0 && d % dt != 0) avg--;
            assertEq(int256(acc.sampleAt(uint32(i)).avgTick), avg, "avgTick");
            if (i >= 2) {
                int256 r = (avg - prevAvg) * LN_1_0001_WAD;
                refCum += uint256(r * r) / WAD;
            }
            prevAvg = avg;
            // Wei tolerance 0: same integer arithmetic, so the match is exact.
            assertApproxEqAbs(
                uint256(acc.sampleAt(uint32(i)).cumulativeSumSq), refCum, 0, "cumulativeSumSq"
            );
        }
        console.log("             avgTick (last)", int256(acc.sampleAt(uint32(STEPS - 1)).avgTick));
        console.log("             cumulativeSumSq", refCum);
        (uint32 gaps, uint32 maxGap) = acc.gapStats();
        console.log("             gapStats", gaps, maxGap);
    }
}
