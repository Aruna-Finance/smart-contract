// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @title MockPositionManager
/// @notice Test double: settable owner per tokenId and a configurable
///         (token0, token1, fee) that the vault matches against its pool (I8).
contract MockPositionManager is INonfungiblePositionManager {
    struct Pos {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 => address) public owners;
    mapping(uint256 => Pos) public posOf;
    address public t0;
    address public t1;
    uint24 public f;

    function setPool(address token0_, address token1_, uint24 fee_) external {
        t0 = token0_;
        t1 = token1_;
        f = fee_;
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    /// @notice Set the geometry the PositionValuer reads (liquidity + range).
    function setPosition(uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        posOf[tokenId] = Pos(tickLower, tickUpper, liquidity);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos memory p = posOf[tokenId];
        return (0, address(0), t0, t1, f, p.tickLower, p.tickUpper, p.liquidity, 0, 0, 0, 0);
    }
}
