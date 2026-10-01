// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IUniswapV3FactoryMinimal
/// @notice The slice of the Uniswap v3 factory Aruna reads. `ArunaFactory.createVault`
///         resolves the canonical pool for (token0, token1, fee) through the factory the
///         NFPM itself is bound to, so a market can never point at a look-alike contract
///         that merely reports the same tokens and fee (plan "Arsitektur factory").
///         Declared locally to avoid a v3-core dependency on solc 0.7.6.
interface IUniswapV3FactoryMinimal {
    /// @notice The pool for the pair and fee, or address(0) if none. Order-insensitive.
    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);
}
