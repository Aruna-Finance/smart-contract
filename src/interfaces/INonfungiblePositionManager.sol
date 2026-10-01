// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title INonfungiblePositionManager
/// @notice The slice of Uniswap v3's position NFT manager Aruna touches. `buyCover`
///         calls `ownerOf` to prove the buyer holds the position and `positions` to
///         confirm it belongs to the vault's pool and to feed the position valuer
///         (design §8.2 position-attached decision, invariant I8). v2 escrows the NFT
///         (plan "Polis dan escrow"): `transferFrom` pulls it in at purchase and returns
///         it (no receiver hook, so a contract owner cannot block the return), and
///         `collect` pays fees out — at purchase to the owner, later only on the policy
///         owner's request. No liquidity-moving function is declared, on purpose: the
///         vault can never call `decreaseLiquidity` (R14, R15).
///         Declared locally to avoid a periphery dependency on solc 0.7.6.
interface INonfungiblePositionManager {
    /// @dev Mirrors INonfungiblePositionManager.CollectParams in Uniswap v3 periphery.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice The Uniswap v3 factory this NFPM is bound to. ArunaFactory resolves the
    ///         canonical pool through it (plan "Arsitektur factory").
    function factory() external view returns (address);

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

    /// @notice ERC721 transfer without the receiver hook (escrow in and out).
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Collects up to the max amounts of owed fees to `recipient`.
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}
