// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {ArunaScript, IScriptToken} from "./base/ArunaScript.sol";
import {INfpmSetup, ISwapRouter02} from "./Testnet.s.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {RejectingReceiver} from "../test/mocks/RejectingReceiver.sol";

/// @dev Pool / NFPM views the lifecycle scripts read (real Uniswap and the local mocks).
interface IOpsPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IOpsNfpm {
    function approve(address to, uint256 tokenId) external;
}

/// @dev The testnet token's self opt-in rejection switch (script/Testnet.s.sol TestToken).
interface IRejectSwitch {
    function setRejectIncoming(bool rejects) external;
}

/// @title OpsBase
/// @notice Helpers shared by `Ops` and `Scenarios`: env-addressed vault, optional routing
///         through an on-chain `RejectingReceiver` (`ARUNA_VIA`), and an in-range position
///         mint on the vault's pool.
abstract contract OpsBase is ArunaScript {
    function _vault() internal view returns (CoverVault) {
        return CoverVault(vm.envAddress("ARUNA_VAULT"));
    }

    function _via() internal view returns (address) {
        return vm.envOr("ARUNA_VIA", address(0));
    }

    /// @dev Call `target` as the broadcaster, or as the RejectingReceiver `via` (its owner
    ///      is the broadcaster) — so the receiver can be a policy owner on-chain.
    function _act(address via, address target, bytes memory data)
        internal
        returns (bytes memory ret)
    {
        if (via != address(0)) return RejectingReceiver(via).exec(target, data);
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev The account that acts: the receiver when routed, else the broadcaster.
    function _actor(address via) internal view returns (address) {
        return via != address(0) ? via : msg.sender;
    }

    function _tick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IOpsPool(pool).slot0();
    }

    /// @dev Mint a position of `pool` centered on the current tick, ±halfWidth rounded out
    ///      to the tick spacing (in range by construction). Must run inside a broadcast.
    function _mintPosition(
        address nfpm,
        address pool,
        address recipient,
        int24 halfWidth,
        uint256 amount0,
        uint256 amount1,
        bool mintTokens
    ) internal returns (uint256 tokenId, uint128 liquidity) {
        address t0 = IOpsPool(pool).token0();
        address t1 = IOpsPool(pool).token1();
        int24 spacing = IOpsPool(pool).tickSpacing();
        int24 tick = _tick(pool);
        int24 center = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) center -= spacing; // floor toward -inf
        int24 hw = (halfWidth + spacing - 1) / spacing * spacing;
        if (mintTokens) {
            IScriptToken(t0).mint(msg.sender, amount0);
            IScriptToken(t1).mint(msg.sender, amount1);
        }
        IScriptToken(t0).approve(nfpm, amount0);
        IScriptToken(t1).approve(nfpm, amount1);
        (tokenId, liquidity,,) = INfpmSetup(nfpm)
            .mint(
                INfpmSetup.MintParams({
                    token0: t0,
                    token1: t1,
                    fee: IOpsPool(pool).fee(),
                    tickLower: center - hw,
                    tickUpper: center + hw,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: recipient,
                    deadline: block.timestamp + 600
                })
            );
    }
}

/// @title Ops
/// @notice One entrypoint per lifecycle action (plan U9 "Ops"), each a single
///         `forge script` run that broadcasts the action, logs it and returns its result
///         (forge records the return values in the broadcast file, which `runner/` reads):
///
///           forge script script/Ops.s.sol:Ops --sig "deposit()" --rpc-url $RPC_URL \
///             --account <keystore> --broadcast
///
///         Params come from the environment:
///           ARUNA_VAULT        vault (every vault action)
///           ARUNA_COHORT       cohort id                     (deposit, buy, finalize, batch,
///                                                             withdraw, roll-from)
///           ARUNA_TO_COHORT    roll target                   (rollTo)
///           ARUNA_AMOUNT       raw settlement amount         (deposit, fundKeeperBudget)
///           ARUNA_TOKEN_ID     position NFT                  (approveAndBuy)
///           ARUNA_STRIKE       annualized strike variance, WAD (approveAndBuy)
///           ARUNA_MAX_PREMIUM  premium cap; default quote × (1 + ARUNA_SLIPPAGE_BPS, 100)
///           ARUNA_DEADLINE_SECS quote deadline from now (default 600)
///           ARUNA_POLICY_ID    policy                         (cancel, collect, settle, claim)
///           ARUNA_RECIPIENT    fee recipient (default: the acting account)
///           ARUNA_BATCH_N      settleBatch size (default 50)
///           ARUNA_VIA          act through this RejectingReceiver (buy, cancel, collect,
///                              claims, setRejectIncoming) — payout-parking scenario
///           ARUNA_MINT         mint the tokens first (testnet / local mock tokens only)
///           ARUNA_MANIFEST     fundKeeperBudget records the donation in this manifest
///           ARUNA_ROUTER, ARUNA_POOL, ARUNA_SWAP_IN, ARUNA_ZERO_FOR_ONE      (swap)
///           ARUNA_NFPM, ARUNA_POOL, ARUNA_POS_HALF_WIDTH (default 1000),
///           ARUNA_POS_AMOUNT0 / ARUNA_POS_AMOUNT1 (default 1e11), ARUNA_POS_RECIPIENT (mint)
///           ARUNA_REJECT       bool                           (setRejectIncoming)
contract Ops is OpsBase {
    // ------------------------------------------------------------------ underwriter

    function deposit() external returns (uint128 amount) {
        CoverVault v = _vault();
        uint32 cohortId = _u32(vm.envUint("ARUNA_COHORT"));
        amount = _u128(vm.envUint("ARUNA_AMOUNT"));
        address token = address(v.settlementToken());
        vm.startBroadcast();
        if (vm.envOr("ARUNA_MINT", false)) IScriptToken(token).mint(msg.sender, amount);
        IScriptToken(token).approve(address(v), amount);
        v.deposit(cohortId, amount);
        vm.stopBroadcast();
        console2.log("deposit: cohort", uint256(cohortId), "amount", uint256(amount));
    }

    function withdraw() external returns (uint256 net) {
        CoverVault v = _vault();
        uint32 cohortId = _u32(vm.envUint("ARUNA_COHORT"));
        vm.startBroadcast();
        net = v.withdraw(cohortId);
        vm.stopBroadcast();
        console2.log("withdraw: cohort", uint256(cohortId), "net", net);
    }

    function rollTo() external {
        CoverVault v = _vault();
        uint32 fromCohort = _u32(vm.envUint("ARUNA_COHORT"));
        uint32 toCohort = _u32(vm.envUint("ARUNA_TO_COHORT"));
        vm.startBroadcast();
        v.rollTo(fromCohort, toCohort);
        vm.stopBroadcast();
        console2.log("rollTo: from", uint256(fromCohort), "to", uint256(toCohort));
    }

    // ------------------------------------------------------------------ LP

    /// @notice NFT approve + premium approve + buyCover(maxPremium, deadline).
    function approveAndBuy() external returns (uint256 policyId, uint128 premium) {
        CoverVault v = _vault();
        address via = _via();
        uint32 cohortId = _u32(vm.envUint("ARUNA_COHORT"));
        uint256 tokenId = vm.envUint("ARUNA_TOKEN_ID");
        uint64 strike = _u64(vm.envUint("ARUNA_STRIKE"));
        (premium,,,) = v.quote(cohortId, tokenId, strike);
        uint256 slip = vm.envOr("ARUNA_SLIPPAGE_BPS", uint256(100));
        uint128 maxPremium =
            _u128(vm.envOr("ARUNA_MAX_PREMIUM", uint256(premium) * (10_000 + slip) / 10_000));
        uint64 deadline =
            _u64(vm.getBlockTimestamp() + vm.envOr("ARUNA_DEADLINE_SECS", uint256(600)));
        address token = address(v.settlementToken());
        address nfpm = address(v.positionManager());

        vm.startBroadcast();
        if (vm.envOr("ARUNA_MINT", false)) {
            IScriptToken(token).mint(_actor(via), maxPremium);
        }
        _act(via, nfpm, abi.encodeCall(IOpsNfpm.approve, (address(v), tokenId)));
        _act(via, token, abi.encodeCall(IScriptToken.approve, (address(v), maxPremium)));
        bytes memory ret = _act(
            via,
            address(v),
            abi.encodeCall(ICoverVault.buyCover, (cohortId, tokenId, strike, maxPremium, deadline))
        );
        vm.stopBroadcast();
        policyId = abi.decode(ret, (uint256));
        premium = v.policy(policyId).premium;
        console2.log("buyCover: policy", policyId, "premium", uint256(premium));
        console2.log("  tokenId", tokenId, "owner", _actor(via));
    }

    function cancel() external {
        CoverVault v = _vault();
        uint256 policyId = vm.envUint("ARUNA_POLICY_ID");
        vm.startBroadcast();
        _act(_via(), address(v), abi.encodeCall(ICoverVault.cancel, (policyId)));
        vm.stopBroadcast();
        console2.log("cancel: policy", policyId);
    }

    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        CoverVault v = _vault();
        address via = _via();
        uint256 policyId = vm.envUint("ARUNA_POLICY_ID");
        address recipient = vm.envOr("ARUNA_RECIPIENT", _actor(via));
        vm.startBroadcast();
        bytes memory ret =
            _act(via, address(v), abi.encodeCall(ICoverVault.collectFees, (policyId, recipient)));
        vm.stopBroadcast();
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
        console2.log("collectFees: policy", policyId, "amount0", amount0);
        console2.log("  amount1", amount1, "recipient", recipient);
    }

    function claimPosition() external {
        CoverVault v = _vault();
        uint256 policyId = vm.envUint("ARUNA_POLICY_ID");
        vm.startBroadcast();
        _act(_via(), address(v), abi.encodeCall(ICoverVault.claimPosition, (policyId)));
        vm.stopBroadcast();
        console2.log("claimPosition: policy", policyId);
    }

    function claimUnclaimed() external returns (uint256 amount) {
        CoverVault v = _vault();
        vm.startBroadcast();
        bytes memory ret = _act(_via(), address(v), abi.encodeCall(ICoverVault.claimUnclaimed, ()));
        vm.stopBroadcast();
        amount = abi.decode(ret, (uint256));
        console2.log("claimUnclaimed: amount", amount);
    }

    // ------------------------------------------------------------------ keeper / anyone

    function keeperPoke() external returns (bool sampled, uint256 bounty) {
        CoverVault v = _vault();
        vm.startBroadcast();
        (sampled, bounty) = v.keeperPoke();
        vm.stopBroadcast();
        console2.log("keeperPoke: sampled", sampled, "bounty", bounty);
    }

    function keeperFinalize() external returns (bool finalized, uint256 bounty) {
        CoverVault v = _vault();
        uint32 cohortId = _u32(vm.envUint("ARUNA_COHORT"));
        vm.startBroadcast();
        (finalized, bounty) = v.keeperFinalize(cohortId);
        vm.stopBroadcast();
        console2.log("keeperFinalize: cohort", uint256(cohortId), "finalized", finalized);
        console2.log("  bounty", bounty);
    }

    function settlePolicy() external {
        CoverVault v = _vault();
        uint256 policyId = vm.envUint("ARUNA_POLICY_ID");
        vm.startBroadcast();
        v.settlePolicy(policyId);
        vm.stopBroadcast();
        ICoverVault.Policy memory p = v.policy(policyId);
        console2.log("settlePolicy: policy", policyId, "status", uint256(p.status));
    }

    function settleBatch() external {
        CoverVault v = _vault();
        uint32 cohortId = _u32(vm.envUint("ARUNA_COHORT"));
        uint32 n = _u32(vm.envOr("ARUNA_BATCH_N", uint256(50)));
        vm.startBroadcast();
        v.settleBatch(cohortId, n);
        vm.stopBroadcast();
        console2.log("settleBatch: cohort", uint256(cohortId), "n", uint256(n));
        console2.log("  status", uint256(v.statusOf(cohortId)));
    }

    /// @notice Permissionless keeper-budget donation; recorded in ARUNA_MANIFEST (if set)
    ///         as the market's cumulative `keeperBudgetFunded`.
    function fundKeeperBudget() external returns (uint256 amount) {
        CoverVault v = _vault();
        amount = vm.envUint("ARUNA_AMOUNT");
        address token = address(v.settlementToken());
        vm.startBroadcast();
        if (vm.envOr("ARUNA_MINT", false)) IScriptToken(token).mint(msg.sender, amount);
        IScriptToken(token).approve(address(v), amount);
        v.fundKeeperBudget(amount);
        vm.stopBroadcast();
        console2.log("fundKeeperBudget: amount", amount, "budget", v.keeperBudget());
        _recordFunding(address(v), amount);
    }

    // ------------------------------------------------------------------ pool / positions

    /// @notice One SwapRouter02 exactInputSingle to move the pool's tick.
    function swap() external returns (int24 tickBefore, int24 tickAfter) {
        address router = vm.envAddress("ARUNA_ROUTER");
        address pool = vm.envOr("ARUNA_POOL", address(0));
        if (pool == address(0)) pool = address(_vault().pool());
        uint256 amountIn = vm.envUint("ARUNA_SWAP_IN");
        bool zeroForOne = vm.envOr("ARUNA_ZERO_FOR_ONE", true);
        address t0 = IOpsPool(pool).token0();
        address t1 = IOpsPool(pool).token1();
        (address tokenIn, address tokenOut) = zeroForOne ? (t0, t1) : (t1, t0);
        tickBefore = _tick(pool);

        vm.startBroadcast();
        if (vm.envOr("ARUNA_MINT", false)) IScriptToken(tokenIn).mint(msg.sender, amountIn);
        IScriptToken(tokenIn).approve(router, amountIn);
        ISwapRouter02(router)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: IOpsPool(pool).fee(),
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopBroadcast();
        tickAfter = _tick(pool);
        console2.log("swap: zeroForOne", zeroForOne, "amountIn", amountIn);
        console2.log("  tick before", int256(tickBefore));
        console2.log("  tick after", int256(tickAfter));
    }

    /// @notice NFPM mint of a small in-range position on the vault's (or ARUNA_POOL's) pool.
    function mintPosition() external returns (uint256 tokenId, uint128 liquidity) {
        address pool = vm.envOr("ARUNA_POOL", address(0));
        address nfpm = vm.envOr("ARUNA_NFPM", address(0));
        if (pool == address(0)) pool = address(_vault().pool());
        if (nfpm == address(0)) nfpm = address(_vault().positionManager());
        int24 hw = _i24(int256(vm.envOr("ARUNA_POS_HALF_WIDTH", uint256(1000))));
        uint256 a0 = vm.envOr("ARUNA_POS_AMOUNT0", uint256(1e11));
        uint256 a1 = vm.envOr("ARUNA_POS_AMOUNT1", uint256(1e11));
        address recipient = vm.envOr("ARUNA_POS_RECIPIENT", msg.sender);
        vm.startBroadcast();
        (tokenId, liquidity) =
            _mintPosition(nfpm, pool, recipient, hw, a0, a1, vm.envOr("ARUNA_MINT", false));
        vm.stopBroadcast();
        console2.log("mintPosition: tokenId", tokenId, "liquidity", uint256(liquidity));
        console2.log("  recipient", recipient);
    }

    /// @notice Payout-parking switch: the RejectingReceiver (ARUNA_VIA) opts in or out of
    ///         rejecting the testnet settlement token (TestToken.setRejectIncoming).
    function setRejectIncoming() external {
        CoverVault v = _vault();
        address via = vm.envAddress("ARUNA_VIA");
        bool rejects = vm.envBool("ARUNA_REJECT");
        vm.startBroadcast();
        _act(
            via,
            address(v.settlementToken()),
            abi.encodeCall(IRejectSwitch.setRejectIncoming, (rejects))
        );
        vm.stopBroadcast();
        console2.log("setRejectIncoming:", via, rejects);
    }

    // ------------------------------------------------------------------ manifest

    function _recordFunding(address vault, uint256 amount) internal {
        string memory path = vm.envOr("ARUNA_MANIFEST", string(""));
        if (bytes(path).length == 0 || !_persist()) return;
        string memory json = _readManifest(path);
        string[] memory keys = vm.parseJsonKeys(json, ".markets");
        for (uint256 i = 0; i < keys.length; i++) {
            string memory base = string.concat(".markets.", keys[i]);
            if (vm.parseJsonAddress(json, string.concat(base, ".vault")) != vault) continue;
            string memory key = string.concat(base, ".keeperBudgetFunded");
            uint256 prev = vm.parseUint(vm.parseJsonString(json, key));
            vm.writeJson(string.concat('"', _uintStr(prev + amount), '"'), path, key);
            console2.log("manifest keeperBudgetFunded:", prev + amount);
            return;
        }
        console2.log("manifest: vault not found, funding not recorded");
    }
}
