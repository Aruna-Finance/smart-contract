// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {MockERC20} from "./MockERC20.sol";

interface IERC721ReceiverMock {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title MockPositionManager
/// @notice Test double for Uniswap v3's NonfungiblePositionManager (NFPM). A real-enough
///         ERC721 (ownerOf/balanceOf/approve/setApprovalForAll/transferFrom/
///         safeTransferFrom with the receiver hook; the per-token approval is cleared
///         on transfer, as in NFPM) plus the position surface Aruna v2 touches:
///         - `positions`: (token0, token1, fee) from `setPool`, geometry from
///           `setPosition`, fees owed from `setTokensOwed`; `operator` = getApproved.
///         - `collect`: NFPM signature, owner/approved/operator only; pays the owed
///           amounts (capped by amount{0,1}Max) in two configured MockERC20 fee tokens
///           and zeroes what it paid.
///         - `increaseLiquidity`: open to anyone (as on NFPM, which lets anyone add).
///         - `decreaseLiquidity`: owner/approved/operator only (as on NFPM).
///         - `setTransferFails`: makes every transfer revert, to prove the vault's
///           NFT-parking defense (plan "Pengembalian NFT"), unreachable on real NFPM.
contract MockPositionManager is INonfungiblePositionManager {
    // CollectParams comes from INonfungiblePositionManager (mirrors Uniswap v3 periphery).

    struct Pos {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    // --- ERC721 state ---
    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // --- position state ---
    mapping(uint256 => Pos) public posOf;
    address public t0;
    address public t1;
    uint24 public f;
    MockERC20 public feeToken0;
    MockERC20 public feeToken1;
    bool public transferFails;
    /// @notice The Uniswap v3 factory this NFPM reports (`setFactory`).
    address public factory;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    error NonexistentToken(uint256 tokenId);
    error NotAuthorized(address caller, uint256 tokenId);
    error WrongFrom(address from, uint256 tokenId);
    error ZeroAddress();
    error TransferDisabled();
    error ReceiverRejected(address to);
    error NothingToCollect();

    // ---------------------------------------------------------------------
    // Test setters
    // ---------------------------------------------------------------------

    function setPool(address token0_, address token1_, uint24 fee_) external {
        t0 = token0_;
        t1 = token1_;
        f = fee_;
    }

    /// @notice Mint `tokenId` to `owner`, or force-reassign it if it exists (approval
    ///         cleared). `owner == address(0)` burns it.
    function setOwner(uint256 tokenId, address owner) external {
        address prev = _owners[tokenId];
        if (prev == owner) return;
        if (prev != address(0)) balanceOf[prev] -= 1;
        if (owner != address(0)) balanceOf[owner] += 1;
        _owners[tokenId] = owner;
        delete _tokenApprovals[tokenId];
        emit Transfer(prev, owner, tokenId);
    }

    /// @notice Set the geometry the PositionValuer reads (liquidity + range).
    function setPosition(uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
    {
        Pos storage p = posOf[tokenId];
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
    }

    function setTokensOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        posOf[tokenId].tokensOwed0 = owed0;
        posOf[tokenId].tokensOwed1 = owed1;
    }

    function setFeeTokens(MockERC20 token0_, MockERC20 token1_) external {
        feeToken0 = token0_;
        feeToken1 = token1_;
    }

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setTransferFails(bool fails) external {
        transferFails = fails;
    }

    // ---------------------------------------------------------------------
    // ERC721
    // ---------------------------------------------------------------------

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert NonexistentToken(tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        ownerOf(tokenId);
        return _tokenApprovals[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) {
            revert NotAuthorized(msg.sender, tokenId);
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        _transfer(from, to, tokenId);
        if (to.code.length != 0) {
            try IERC721ReceiverMock(to).onERC721Received(msg.sender, from, tokenId, data) returns (
                bytes4 ret
            ) {
                if (ret != IERC721ReceiverMock.onERC721Received.selector) {
                    revert ReceiverRejected(to);
                }
            } catch {
                revert ReceiverRejected(to);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Position surface
    // ---------------------------------------------------------------------

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Pos memory p = posOf[tokenId];
        return (
            0,
            _tokenApprovals[tokenId],
            t0,
            t1,
            f,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            0,
            0,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }

    /// @notice NFPM `collect`: pays owed fees (capped by the max amounts) to `recipient`.
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        if (params.amount0Max == 0 && params.amount1Max == 0) revert NothingToCollect();
        if (!_isApprovedOrOwner(msg.sender, params.tokenId)) {
            revert NotAuthorized(msg.sender, params.tokenId);
        }
        Pos storage p = posOf[params.tokenId];
        uint128 c0 = p.tokensOwed0 < params.amount0Max ? p.tokensOwed0 : params.amount0Max;
        uint128 c1 = p.tokensOwed1 < params.amount1Max ? p.tokensOwed1 : params.amount1Max;
        p.tokensOwed0 -= c0;
        p.tokensOwed1 -= c1;
        if (c0 != 0) _pay(feeToken0, params.recipient, c0);
        if (c1 != 0) _pay(feeToken1, params.recipient, c1);
        emit Collect(params.tokenId, params.recipient, c0, c1);
        return (c0, c1);
    }

    /// @notice NFPM `decreaseLiquidity` shape (owner/approved/operator only, as on NFPM):
    ///         lowers liquidity and books the withdrawn amount as owed (1:1 into owed0).
    ///         Lets tests prove an escrowed position cannot be drained by its LP (AE7).
    function decreaseLiquidity(uint256 tokenId, uint128 liquidityDelta) external {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotAuthorized(msg.sender, tokenId);
        posOf[tokenId].liquidity -= liquidityDelta;
        posOf[tokenId].tokensOwed0 += liquidityDelta;
    }

    /// @notice Open to anyone, like NFPM: bumps liquidity (no tokens pulled).
    function increaseLiquidity(uint256 tokenId, uint128 liquidityDelta) external {
        ownerOf(tokenId);
        posOf[tokenId].liquidity += liquidityDelta;
    }

    // ---------------------------------------------------------------------

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return
            spender == owner || _tokenApprovals[tokenId] == spender
                || isApprovedForAll[owner][spender];
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (transferFails) revert TransferDisabled();
        if (ownerOf(tokenId) != from) revert WrongFrom(from, tokenId);
        if (to == address(0)) revert ZeroAddress();
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotAuthorized(msg.sender, tokenId);
        delete _tokenApprovals[tokenId]; // NFPM clears the operator on transfer
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    /// @dev Fees are minted to the mock and then transferred, so a recipient flagged
    ///      on the MockERC20 makes `collect` revert (as a real pool transfer would).
    function _pay(MockERC20 token, address to, uint128 amount) internal {
        token.mint(address(this), amount);
        token.transfer(to, amount);
    }
}
