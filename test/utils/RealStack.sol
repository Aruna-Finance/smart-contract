// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArunaFactory} from "../../src/ArunaFactory.sol";
import {CoverVault} from "../../src/CoverVault.sol";
import {VarianceAccumulator} from "../../src/VarianceAccumulator.sol";
import {FlatVegaPricer} from "../../src/FlatVegaPricer.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {VaultDeployer} from "../../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../../src/deployers/AccumulatorDeployer.sol";
import {IVarianceAccumulator} from "../../src/interfaces/IVarianceAccumulator.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @title RealStack
/// @notice Shared fixture for the integration-style suites (plan U8): the REAL
///         ArunaFactory + VaultDeployer + AccumulatorDeployer + VarianceAccumulator +
///         CoverVault + FlatVegaPricer + PositionValuer, over a MockUniswapV3Pool whose
///         tickCumulative advances with block time like Uniswap's oracle. Only the chain
///         infrastructure (tokens, pool, NFPM, Uniswap factory) is mocked.
///
///         Calibration below is a TEST fixture, not the §6.4 release calibration:
///         - PositionValuer kappa = WAD at a neutral width of 2000 ticks, so a position
///           over [-1000, 1000] has varNotional == liquidity (settlement base units).
///         - FlatVegaPricer: minPremium 1 USDC, 10% load, λ = 0.5, g(m) knots as in
///           FlatVegaPricerTest.
abstract contract RealStack is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 31_536_000;
    int256 internal constant LN_1_0001_WAD = 99995000333308;
    int24 internal constant REF_WIDTH = 2_000;
    uint24 internal constant FEE = 500;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockUniswapV3Factory internal uniFactory;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    FlatVegaPricer internal pricer;
    PositionValuer internal valuer;
    ArunaFactory internal factory;
    VarianceAccumulator internal acc;

    uint256 internal nextTokenId = 1;

    function _deployStack(uint32[] memory tenors, uint32 gap, uint32 interval) internal {
        usdc = new MockERC20(6);
        weth = new MockERC20(18);
        uniFactory = new MockUniswapV3Factory();
        pm = new MockPositionManager();
        pm.setFactory(address(uniFactory));
        pool = new MockUniswapV3Pool();
        pool.setTokens(address(weth), address(usdc), FEE);
        uniFactory.setPool(address(weth), address(usdc), FEE, address(pool));
        pm.setPool(address(weth), address(usdc), FEE);

        uint128[5] memory mKnots =
            [uint128(0), uint128(WAD / 2), uint128(WAD), uint128(2 * WAD), uint128(4 * WAD)];
        uint128[5] memory gKnots = [
            uint128(WAD),
            uint128((6 * WAD) / 10),
            uint128((35 * WAD) / 100),
            uint128((15 * WAD) / 100),
            uint128((5 * WAD) / 100)
        ];
        pricer = new FlatVegaPricer(1e6, 1_000, uint128(WAD / 2), mKnots, gKnots);
        valuer = new PositionValuer(
            address(pm), uint128(WAD), REF_WIDTH, uint128(WAD / 4), uint128(4 * WAD)
        );
        factory = new ArunaFactory(
            address(pm),
            address(usdc),
            address(new VaultDeployer()),
            address(new AccumulatorDeployer()),
            tenors,
            gap,
            interval,
            1_000, // max keeper bps
            1e6, // max poke bounty
            5e6, // max finalize bounty
            2e6 // max settle bounty
        );
    }

    /// @dev A market through the real factory. The pool's accumulator (and its baseline
    ///      sample) is created on the first market.
    function _market(uint32 tenor, uint64 anchor, uint32 policyCap, uint128 maxExcess)
        internal
        returns (CoverVault v)
    {
        v = CoverVault(
            factory.createVault(
                ArunaFactory.VaultParams({
                    pool: address(pool),
                    tenor: tenor,
                    pricer: address(pricer),
                    valuer: address(valuer),
                    anchor: anchor,
                    maxUtilizationBps: 8_000,
                    maxExcessVariance: maxExcess,
                    ewmaAlphaBps: 2_000,
                    seedVariance: uint128(WAD / 2),
                    policyCap: policyCap,
                    keeperShareBps: 500,
                    pokeBounty: 0,
                    finalizeBounty: 0,
                    settleBounty: 0
                })
            )
        );
        acc = VarianceAccumulator(factory.accumulatorOf(address(pool)));
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _deposit(CoverVault v, address uw, uint32 cid, uint128 amount) internal {
        usdc.mint(uw, amount);
        vm.startPrank(uw);
        usdc.approve(address(v), type(uint256).max);
        v.deposit(cid, amount);
        vm.stopPrank();
    }

    /// @dev A position of this pool over [-1000, 1000] (neutral width): varNotional ==
    ///      liquidity.
    function _position(address owner, uint128 liquidity) internal returns (uint256 id) {
        id = nextTokenId++;
        pm.setOwner(id, owner);
        pm.setPosition(id, -1_000, 1_000, liquidity);
    }

    /// @dev Approve the NFT + premium and buy at the live quote.
    function _buy(CoverVault v, address lp, uint32 cid, uint256 tokenId, uint64 strike)
        internal
        returns (uint256 pid, uint128 premium)
    {
        (premium,,,) = v.quote(cid, tokenId, strike);
        usdc.mint(lp, premium);
        vm.startPrank(lp);
        usdc.approve(address(v), type(uint256).max);
        pm.approve(address(v), tokenId);
        pid = v.buyCover(cid, tokenId, strike, premium, uint64(_now()));
        vm.stopPrank();
    }

    /// @dev One on-schedule keeper step: move to the next allowed sample time, poke, then
    ///      set the tick that will be in force during the NEXT interval (so the next
    ///      sample's inter-sample TWAP is exactly `nextTick`).
    function _keeperStep(int24 nextTick) internal {
        vm.warp(uint256(acc.lastSampleAt()) + acc.sampleInterval());
        acc.poke();
        pool.setTick(nextTick);
    }

    /// @dev Reference Σr² over samples (from, to] recomputed from the stored avgTicks,
    ///      independent of cumulativeSumSq (sample ≥ 2 carries a return).
    function _refSumSq(uint32 from, uint32 to) internal view returns (uint256 sum) {
        for (uint32 i = from + 1; i <= to; i++) {
            if (i < 2) continue;
            IVarianceAccumulator.Sample memory a = acc.sampleAt(i - 1);
            IVarianceAccumulator.Sample memory b = acc.sampleAt(i);
            int256 r = (int256(b.avgTick) - int256(a.avgTick)) * LN_1_0001_WAD;
            sum += uint256(r * r) / WAD;
        }
    }

    /// @dev r² (WAD, floored) of a move of `dTick` ticks between consecutive TWAPs.
    function _r2(int256 dTick) internal pure returns (uint256) {
        int256 r = dTick * LN_1_0001_WAD;
        return uint256(r * r) / WAD;
    }
}
