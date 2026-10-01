// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV3FactoryMinimal} from "../../src/interfaces/IUniswapV3FactoryMinimal.sol";

/// @title MockUniswapV3Factory
/// @notice Test double for the Uniswap v3 factory's pool registry. `setPool` registers a
///         pool for (tokenA, tokenB, fee) in both token orders, as the real factory does,
///         so `getPool` is order-insensitive. Unregistered triples return address(0).
contract MockUniswapV3Factory is IUniswapV3FactoryMinimal {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}
