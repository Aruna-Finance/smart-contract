// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title INonfungiblePositionManager
/// @notice The slice of Uniswap v3's position NFT manager Aruna reads. `buyCover`
///         calls `ownerOf` to prove the buyer holds the position, and `positions`
///         to confirm the position belongs to the vault's pool and to feed the
///         position valuer (design §8.2 position-attached decision, invariant I8).
///         Declared locally to avoid a periphery dependency on solc 0.7.6.
interface INonfungiblePositionManager {
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice Returns the position's parameters. Aruna reads token0/token1/fee to
    ///         match the pool and liquidity/ticks for valuation; the rest is ignored.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
