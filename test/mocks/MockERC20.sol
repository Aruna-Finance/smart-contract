// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title MockERC20
/// @notice Minimal bool-returning ERC20 for vault tests (6 decimals, USDC-like).
///         Recipients can be flagged so that any transfer TO them reverts — this is how
///         tests make a push payout fail and prove the `_unclaimed` parking path
///         (design §7.3, plan AE9). Minting is never blocked, so setup stays simple.
contract MockERC20 is IERC20 {
    string public name = "Mock USD";
    string public symbol = "mUSD";
    uint8 public immutable _decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    /// @notice Recipients whose incoming `transfer` / `transferFrom` revert.
    mapping(address => bool) public rejectsTransfersTo;

    error RecipientRejected(address to);

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Flag (or unflag) `to` so that transfers to it revert.
    function setRejectTransfersTo(address to, bool rejects) external {
        rejectsTransfersTo[to] = rejects;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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
        if (rejectsTransfersTo[to]) revert RecipientRejected(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
