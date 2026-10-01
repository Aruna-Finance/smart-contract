// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RejectingReceiver
/// @notice A contract recipient that refuses everything it can refuse:
///         - ERC721: `onERC721Received` always reverts, so any `safeTransferFrom` to it
///           fails, while a plain `transferFrom` (no hook) still lands.
///         - ERC20: plain ERC20 has no receive hook, so rejection is configured on the
///           token side (e.g. `MockERC20.setRejectTransfersTo(receiver, true)`).
///         Used to prove the NFT-return and payout parking paths (plan AE9, design §7.3).
///         `exec` lets its deployer drive it as a policy owner (buy, cancel, claim) when
///         it is deployed on-chain as a hostile LP.
contract RejectingReceiver {
    address public immutable owner;

    error Rejected();
    error NotOwner();
    error CallFailed(bytes reason);

    constructor() {
        owner = msg.sender;
    }

    /// @notice ERC721 receive hook: always rejects.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Rejected();
    }

    /// @notice Forward an arbitrary call as this contract (owner only).
    function exec(address target, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner) revert NotOwner();
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) revert CallFailed(result);
    }
}
