// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IScriptToken} from "./base/ArunaScript.sol";
import {OpsBase, IOpsNfpm} from "./Ops.s.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {RejectingReceiver} from "../test/mocks/RejectingReceiver.sol";

/// @title Scenarios
/// @notice SINGLE-TIMESTAMP setup for the RC scenarios (plan U9). `forge script` simulates
///         everything at one block timestamp, so anything that must happen across time
///         (pokes, swaps over intervals, buy after startsAt, settle after endsAt, rolls in
///         the gap) lives in the external runner (`runner/run.sh`), never here.
///
///         `ScenarioSetup` does, in one run:
///           - deploys a `RejectingReceiver` on-chain (owner = broadcaster) for the
///             payout-parking scenario and records it in the manifest's `aux` so the
///             conformance checker (U10) accepts transactions sent to it;
///           - mints settlement tokens (testnet token) to the actor EOAs and the receiver,
///             optionally sends them gas ETH;
///           - mints small in-range LP positions: ARUNA_SC_LP_POSITIONS to the broadcaster
///             (the LP actor) and one to the receiver;
///           - has the receiver approve the vault for the settlement token and its NFT;
///           - writes token ids and addresses to ARUNA_SCENARIO_OUT for the runner.
///
///         NFT parking is NOT a scenario: on the real NFPM a hook-less `transferFrom` back
///         to the owner cannot fail, so that path is proven by unit test only (plan
///         "Pengembalian NFT", AE9 defense path).
///
///         Env: ARUNA_VAULT, ARUNA_MANIFEST (optional), ARUNA_SCENARIO_OUT (default
///         deployments/<chainId>/scenario-latest.json), ARUNA_SC_ACTORS (comma list),
///         ARUNA_SC_MINT_EACH (raw, default 1e13), ARUNA_SC_ETH_EACH (wei, default 0),
///         ARUNA_SC_LP_POSITIONS (default 2), ARUNA_POS_HALF_WIDTH (default 1000),
///         ARUNA_POS_AMOUNT0 / ARUNA_POS_AMOUNT1 (default 1e11), ARUNA_MINT (default true:
///         the pool tokens of a testnet / local stack are mintable).
contract ScenarioSetup is OpsBase {
    struct Result {
        address receiver;
        uint256[] lpTokenIds;
        uint256 receiverTokenId;
    }

    function run() external returns (Result memory r) {
        CoverVault v = _vault();
        address token = address(v.settlementToken());
        address nfpm = address(v.positionManager());
        address pool = address(v.pool());
        address[] memory actors = vm.envOr("ARUNA_SC_ACTORS", ",", new address[](0));
        uint256 mintEach = vm.envOr("ARUNA_SC_MINT_EACH", uint256(1e13));
        uint256 ethEach = vm.envOr("ARUNA_SC_ETH_EACH", uint256(0));
        uint256 nPositions = vm.envOr("ARUNA_SC_LP_POSITIONS", uint256(2));
        int24 hw = _i24(int256(vm.envOr("ARUNA_POS_HALF_WIDTH", uint256(1000))));
        uint256 a0 = vm.envOr("ARUNA_POS_AMOUNT0", uint256(1e11));
        uint256 a1 = vm.envOr("ARUNA_POS_AMOUNT1", uint256(1e11));
        bool mintTokens = vm.envOr("ARUNA_MINT", true);

        r.lpTokenIds = new uint256[](nPositions);
        vm.startBroadcast();
        r.receiver = address(new RejectingReceiver());
        for (uint256 i = 0; i < actors.length; i++) {
            IScriptToken(token).mint(actors[i], mintEach);
            if (ethEach != 0) payable(actors[i]).transfer(ethEach);
        }
        IScriptToken(token).mint(r.receiver, mintEach);
        for (uint256 i = 0; i < nPositions; i++) {
            (r.lpTokenIds[i],) = _mintPosition(nfpm, pool, msg.sender, hw, a0, a1, mintTokens);
        }
        (r.receiverTokenId,) = _mintPosition(nfpm, pool, r.receiver, hw, a0, a1, mintTokens);
        RejectingReceiver(r.receiver)
            .exec(token, abi.encodeCall(IScriptToken.approve, (address(v), type(uint256).max)));
        RejectingReceiver(r.receiver)
            .exec(nfpm, abi.encodeCall(IOpsNfpm.approve, (address(v), r.receiverTokenId)));
        vm.stopBroadcast();

        _write(r, address(v));
        console2.log("RejectingReceiver:", r.receiver);
        console2.log("receiver tokenId:", r.receiverTokenId);
        for (uint256 i = 0; i < nPositions; i++) {
            console2.log("LP tokenId:", r.lpTokenIds[i]);
        }
    }

    function _write(Result memory r, address vault) internal {
        string memory out = vm.envOr(
            "ARUNA_SCENARIO_OUT",
            string.concat(_manifestDir(block.chainid), "/scenario-latest.json")
        );
        string memory k = "aruna.scenario";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "vault", vault);
        vm.serializeAddress(k, "lp", msg.sender);
        vm.serializeAddress(k, "rejectingReceiver", r.receiver);
        vm.serializeUint(k, "receiverTokenId", r.receiverTokenId);
        vm.serializeUint(k, "blockNumber", vm.getBlockNumber());
        string memory json = vm.serializeUint(k, "lpTokenIds", r.lpTokenIds);
        if (!_persist()) {
            _logPersist("scenario", out, json);
            return;
        }
        vm.createDir(_manifestDir(block.chainid), true);
        vm.writeJson(json, out);
        console2.log("scenario written:", out);

        // The receiver is an RC transaction target: list it in the manifest's `aux`.
        string memory manifest = vm.envOr("ARUNA_MANIFEST", string(""));
        if (bytes(manifest).length == 0) return;
        string memory m = _readManifest(manifest);
        uint256 n = vm.parseJsonKeys(m, ".aux").length;
        vm.writeJson(
            string.concat('"', vm.toString(r.receiver), '"'),
            manifest,
            string.concat(".aux.rejectingReceiver_", _uintStr(n))
        );
    }
}
