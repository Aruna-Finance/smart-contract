// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TestToken, INfpmSetup, ISwapRouter02} from "./Testnet.s.sol";
import {MockUniswapV3Pool} from "../test/mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../test/mocks/MockUniswapV3Factory.sol";
import {MockPositionManager} from "../test/mocks/MockPositionManager.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title Local
/// @notice LOCAL ANVIL ONLY (chainId 31337). Uniswap v3 is not deployable on a bare anvil,
///         so this stands up the test mocks behind the SAME call surfaces the Aruna scripts
///         use on a real chain: an NFPM with `mint(MintParams)`, a SwapRouter02 with
///         `exactInputSingle`, a pool with `slot0`/`tickSpacing`/`observe`. Every Aruna
///         contract on top (factory, deployers, accumulator, vault, pricer, valuer) is the
///         real one, so `runner/` can drive a full sandbox cycle end to end with
///         `--anvil` time acceleration before anything touches a testnet.
///
///         Never use these contracts outside anvil: anyone can move the pool's tick.

/// @notice MockUniswapV3Pool plus the two pool views the scripts read.
contract LocalPool is MockUniswapV3Pool {
    function tickSpacing() external view returns (int24) {
        uint24 f = fee;
        if (f == 100) return 1;
        if (f == 500) return 10;
        if (f == 10_000) return 200;
        return 60;
    }
}

/// @notice MockPositionManager plus Uniswap's `mint(MintParams)`: pulls both desired
///         amounts and books liquidity = min(amount0, amount1) over the given range.
contract LocalPositionManager is MockPositionManager {
    uint256 public nextTokenId = 1;

    error PoolMismatch();

    function mint(INfpmSetup.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (p.token0 != t0 || p.token1 != t1 || p.fee != f) revert PoolMismatch();
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        uint256 l = amount0 < amount1 ? amount0 : amount1;
        require(l > 0 && l <= type(uint128).max, "liquidity");
        liquidity = uint128(l);
        TestToken(p.token0).transferFrom(msg.sender, address(this), amount0);
        TestToken(p.token1).transferFrom(msg.sender, address(this), amount1);
        tokenId = nextTokenId++;
        this.setOwner(tokenId, p.recipient);
        this.setPosition(tokenId, p.tickLower, p.tickUpper, liquidity);
    }
}

/// @notice SwapRouter02 `exactInputSingle` over a LocalPool: pulls amountIn, moves the
///         tick by amountIn / amountPerTick (zeroForOne lowers it, as on Uniswap) and mints
///         the same raw amount of tokenOut to the recipient.
contract LocalSwapRouter is ISwapRouter02 {
    LocalPool public immutable pool;
    uint256 public immutable amountPerTick;
    int256 internal constant MAX_MOVE = 50_000;
    int256 internal constant MAX_TICK = 887_272;

    error UnknownPair();

    constructor(LocalPool pool_, uint256 amountPerTick_) {
        pool = pool_;
        amountPerTick = amountPerTick_;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        address t0 = pool.token0();
        address t1 = pool.token1();
        bool zeroForOne = p.tokenIn == t0 && p.tokenOut == t1;
        if (!zeroForOne && !(p.tokenIn == t1 && p.tokenOut == t0)) revert UnknownPair();
        if (p.fee != pool.fee()) revert UnknownPair();
        TestToken(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);

        int256 move = int256(p.amountIn / amountPerTick);
        if (move > MAX_MOVE) move = MAX_MOVE;
        int256 next = int256(pool.currentTick()) + (zeroForOne ? -move : move);
        if (next > MAX_TICK) next = MAX_TICK;
        if (next < -MAX_TICK) next = -MAX_TICK;
        pool.setTick(int24(next));

        amountOut = p.amountIn;
        require(amountOut >= p.amountOutMinimum, "slippage");
        TestToken(p.tokenOut).mint(p.recipient, amountOut);
    }
}

/// @notice Deploys the local Uniswap stand-ins + two TestTokens and writes
///         `deployments/31337/local-infra.json` for `runner/anvil-e2e.sh`.
///
///         Env (all optional): ARUNA_TN_FEE (default 500), ARUNA_LOCAL_AMOUNT_PER_TICK
///         (raw amountIn per tick moved, default 1e9), ARUNA_LOCAL_INFRA_OUT.
contract LocalSetup is Script {
    function run() external {
        require(block.chainid == 31_337, "LocalSetup is anvil-only");
        uint24 fee = uint24(vm.envOr("ARUNA_TN_FEE", uint256(500)));
        uint256 perTick = vm.envOr("ARUNA_LOCAL_AMOUNT_PER_TICK", uint256(1e9));
        string memory out =
            vm.envOr("ARUNA_LOCAL_INFRA_OUT", string("deployments/31337/local-infra.json"));

        vm.startBroadcast();
        TestToken weth = new TestToken("Mock Wrapped Ether", "mWETH", 18);
        TestToken usdc = new TestToken("Mock USD Coin", "mUSDC", 6);
        (address token0, address token1) = address(weth) < address(usdc)
            ? (address(weth), address(usdc))
            : (address(usdc), address(weth));

        LocalPool pool = new LocalPool();
        pool.setTokens(token0, token1, fee);
        MockUniswapV3Factory uniFactory = new MockUniswapV3Factory();
        uniFactory.setPool(token0, token1, fee, address(pool));
        LocalPositionManager nfpm = new LocalPositionManager();
        nfpm.setFactory(address(uniFactory));
        nfpm.setPool(token0, token1, fee);
        // Fees owed are paid in the pool's own tokens (TestToken has MockERC20's mint).
        nfpm.setFeeTokens(MockERC20(token0), MockERC20(token1));
        LocalSwapRouter router = new LocalSwapRouter(pool, perTick);
        vm.stopBroadcast();

        string memory k = "local.infra";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "weth", address(weth));
        vm.serializeAddress(k, "usdc", address(usdc));
        vm.serializeAddress(k, "token0", token0);
        vm.serializeAddress(k, "token1", token1);
        vm.serializeUint(k, "fee", fee);
        vm.serializeAddress(k, "pool", address(pool));
        vm.serializeAddress(k, "uniswapV3Factory", address(uniFactory));
        vm.serializeAddress(k, "positionManager", address(nfpm));
        string memory json = vm.serializeAddress(k, "router", address(router));
        vm.createDir("deployments/31337", true);
        vm.writeJson(json, out);

        console2.log("LocalSetup written:", out);
        console2.log("  ARUNA_POSITION_MANAGER =", address(nfpm));
        console2.log("  ARUNA_SETTLEMENT_TOKEN =", address(usdc));
        console2.log("  ARUNA_POOL             =", address(pool));
        console2.log("  ARUNA_ROUTER           =", address(router));
    }
}
