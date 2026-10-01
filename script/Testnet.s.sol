// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title Testnet
/// @notice Stands up a REAL Uniswap v3 environment on Arbitrum Sepolia so the Aruna
///         stack can be deployed against genuine `observe()` data (integration G5,
///         "Uniswap v3 asli"). Mock ERC-20s are used only so we can mint balances and
///         provision liquidity freely — the pool, position manager, and router are the
///         chain's real Uniswap contracts. This script does NOT deploy Aruna: after it
///         runs, feed its printed addresses into .env and run DeployFactory +
///         DeployMarket (the audited path) unchanged.
///
///         Two scripts here:
///           - SetupTestnet: deploy 2 mock tokens, create+initialize the v3 pool,
///             bump observation cardinality, and mint one full-range LP position.
///           - SeedSwaps: push one swap through the pool to move price. Run REPEATEDLY
///             over time (each run is its own block/timestamp) to build a variance
///             signal, then poke() the accumulator between runs.
///
///         Arbitrum Sepolia (chainId 421614) Uniswap v3 infra — verified against
///         developers.uniswap.org deployments (2026-09):
///           NonfungiblePositionManager 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65
///           SwapRouter02               0x101F443B4d1b059569D643917553c771E1b9663E
///           UniswapV3Factory           0x248AB79Bbb9bC29bB72f7Cd42F17e054Fc40188e
///
///         Env (SetupTestnet), all optional with testnet defaults:
///           ARUNA_NFPM            address  NFPM (default = Arbitrum Sepolia NFPM above)
///           ARUNA_TN_FEE          uint24   fee tier: 500/3000/10000 (default 3000)
///           ARUNA_TN_WETH_DEC     uint8    mock WETH decimals (default 18)
///           ARUNA_TN_USDC_DEC     uint8    mock USDC decimals (default 6)
///           ARUNA_TN_CARDINALITY  uint16   observation slots to grow to (default 200)
///           ARUNA_TN_MINT         uint256  raw units of EACH token to mint to deployer
///                                          (default 1e30) and add as liquidity
///
///         Env (SeedSwaps):
///           ARUNA_ROUTER          address  SwapRouter02 (default = Arb Sepolia router)
///           ARUNA_TN_WETH         address  mock WETH from SetupTestnet
///           ARUNA_TN_USDC         address  mock USDC from SetupTestnet
///           ARUNA_TN_FEE          uint24   same fee tier used at setup (default 3000)
///           ARUNA_TN_SWAP_IN      uint256  raw amountIn for the swap (default 1e21)
///           ARUNA_TN_ZERO_FOR_ONE bool     swap token0->token1 if true (default true)

/// @notice Unrestricted-mint ERC-20 for TESTNET ONLY. Anyone can mint; never use on
///         a network where the balance means anything.
contract TestToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev The slices of Uniswap v3 periphery/core this script calls. Declared locally to
///      avoid pulling the full periphery (which pins solc 0.7.6).
interface INfpmSetup {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IUniV3PoolSetup {
    function tickSpacing() external view returns (int24);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Deploy tokens + real v3 pool + liquidity. Prints the addresses .env needs.
contract SetupTestnet is Script {
    // 1:1 raw price => tick 0, so a symmetric full range is always in range.
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96
    int24 internal constant MAX_TICK = 887272;
    address internal constant DEFAULT_NFPM = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65; // Arb Sepolia

    function run() external {
        address nfpm = vm.envOr("ARUNA_NFPM", DEFAULT_NFPM);
        uint24 fee = uint24(vm.envOr("ARUNA_TN_FEE", uint256(3000)));
        uint8 wethDec = uint8(vm.envOr("ARUNA_TN_WETH_DEC", uint256(18)));
        uint8 usdcDec = uint8(vm.envOr("ARUNA_TN_USDC_DEC", uint256(6)));
        uint16 cardinality = uint16(vm.envOr("ARUNA_TN_CARDINALITY", uint256(200)));
        uint256 mintAmt = vm.envOr("ARUNA_TN_MINT", uint256(1e30));

        address deployer = msg.sender;

        vm.startBroadcast();

        // 1) Mock tokens. USDC is the Aruna settlement token; WETH is only the pool's
        //    other side (Aruna never calls it as ERC-20, only reads its address).
        TestToken weth = new TestToken("Mock Wrapped Ether", "mWETH", wethDec);
        TestToken usdc = new TestToken("Mock USD Coin", "mUSDC", usdcDec);
        weth.mint(deployer, mintAmt);
        usdc.mint(deployer, mintAmt);

        // 2) Real v3 pool. Uniswap requires token0 < token1; sort before initializing.
        (address token0, address token1) = address(weth) < address(usdc)
            ? (address(weth), address(usdc))
            : (address(usdc), address(weth));
        address pool = INfpmSetup(nfpm)
            .createAndInitializePoolIfNecessary(token0, token1, fee, SQRT_PRICE_1_1);

        // 3) Grow observation ring so the accumulator's TWAP window has history to read.
        IUniV3PoolSetup(pool).increaseObservationCardinalityNext(cardinality);

        // 4) Full-range LP position (owned by deployer) — the position a buyer protects,
        //    and the depth swaps move against to create variance.
        int24 spacing = IUniV3PoolSetup(pool).tickSpacing();
        int24 maxUsable = (MAX_TICK / spacing) * spacing;
        TestToken(token0).approve(nfpm, type(uint256).max);
        TestToken(token1).approve(nfpm, type(uint256).max);
        (uint256 tokenId, uint128 liquidity,,) = INfpmSetup(nfpm)
            .mint(
                INfpmSetup.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: fee,
                    tickLower: -maxUsable,
                    tickUpper: maxUsable,
                    amount0Desired: mintAmt / 2,
                    amount1Desired: mintAmt / 2,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: deployer,
                    deadline: block.timestamp + 3600
                })
            );

        vm.stopBroadcast();

        console2.log("== SetupTestnet done ==");
        console2.log("mock WETH (mWETH):", address(weth));
        console2.log("mock USDC (mUSDC):", address(usdc));
        console2.log("pool:", pool);
        console2.log("  token0:", token0);
        console2.log("  token1:", token1);
        console2.log("  fee:", uint256(fee));
        console2.log("LP tokenId (protect this):", tokenId);
        console2.log("LP liquidity:", uint256(liquidity));
        console2.log("");
        console2.log("Next: set in .env then run DeployFactory + DeployMarket:");
        console2.log("  ARUNA_POSITION_MANAGER =", nfpm);
        console2.log("  ARUNA_SETTLEMENT_TOKEN =", address(usdc));
        console2.log("  ARUNA_POOL             =", pool);
    }
}

/// @notice One swap to move price. Run repeatedly over time (each run advances the
///         block timestamp), poking the accumulator between runs, to build variance.
contract SeedSwaps is Script {
    address internal constant DEFAULT_ROUTER = 0x101F443B4d1b059569D643917553c771E1b9663E; // Arb Sepolia

    function run() external {
        address router = vm.envOr("ARUNA_ROUTER", DEFAULT_ROUTER);
        address weth = vm.envAddress("ARUNA_TN_WETH");
        address usdc = vm.envAddress("ARUNA_TN_USDC");
        uint24 fee = uint24(vm.envOr("ARUNA_TN_FEE", uint256(3000)));
        uint256 amountIn = vm.envOr("ARUNA_TN_SWAP_IN", uint256(1e21));
        bool zeroForOne = vm.envOr("ARUNA_TN_ZERO_FOR_ONE", true);

        (address token0, address token1) = weth < usdc ? (weth, usdc) : (usdc, weth);
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);

        vm.startBroadcast();
        TestToken(tokenIn).mint(msg.sender, amountIn); // testnet mint so we always have input
        TestToken(tokenIn).approve(router, amountIn);
        uint256 out = ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopBroadcast();

        console2.log("swapped in:", amountIn);
        console2.log("received out:", out);
        console2.log("Now poke the accumulator, wait, and run again in the other direction.");
    }
}
