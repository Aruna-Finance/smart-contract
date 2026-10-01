// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ArunaFactory} from "../../src/ArunaFactory.sol";
import {CoverVault} from "../../src/CoverVault.sol";
import {VarianceAccumulator} from "../../src/VarianceAccumulator.sol";
import {FlatVegaPricer} from "../../src/FlatVegaPricer.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {VaultDeployer} from "../../src/deployers/VaultDeployer.sol";
import {AccumulatorDeployer} from "../../src/deployers/AccumulatorDeployer.sol";

/// @dev The ERC-20 surface scripts use. `mint` exists only on the testnet / local mock
///      tokens (TestToken, MockERC20); scripts call it only when told to (ARUNA_MINT).
interface IScriptToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @title ArunaScript
/// @notice Shared plumbing for the v2 scripts (plan U9): checked env casts, the two
///         deployment profiles, the build's init code hashes and the deployment manifest
///         (`deployments/<chainId>/<label>.json`, format in `deployments/README.md`).
///
///         The manifest is the single source of addresses for the RC and the release
///         (R29): every script that deploys or funds something writes it, and the runner
///         and the conformance ledger (U10) read it. It is only written when the script
///         actually broadcasts (or runs inside `forge test`): a dry run never overwrites a
///         real manifest with simulated addresses.
abstract contract ArunaScript is Script {
    string internal constant PROFILE_RELEASE = "release";
    string internal constant PROFILE_SANDBOX = "sandbox";
    string internal constant MANIFEST_SCHEMA = "aruna-deployment/1";

    /// @dev Contracts whose init code hash (keccak256 of the creation code, no constructor
    ///      arguments) the manifest records. "Identical" between RC and release means
    ///      these hashes match plus recorded constructor args (plan "Arsitektur factory").
    uint256 internal constant HASHED_CONTRACTS = 7;

    error UnknownProfile(string profile);
    error ReleaseGuard(string reason);
    error InitCodeHashMismatch(string name, bytes32 build, bytes32 recorded);
    error ManifestExists(string path);
    error ManifestMissing(string path);
    error ProfileMismatch(string manifestProfile, string envProfile);
    error FactoryMismatch(address manifestFactory, address envFactory);

    // ---------------------------------------------------------------------
    // Checked env casts: revert loudly rather than silently truncate.
    // ---------------------------------------------------------------------

    function _u16(uint256 v) internal pure returns (uint16) {
        require(v <= type(uint16).max, "u16 overflow");
        return uint16(v);
    }

    function _u24(uint256 v) internal pure returns (uint24) {
        require(v <= type(uint24).max, "u24 overflow");
        return uint24(v);
    }

    function _u32(uint256 v) internal pure returns (uint32) {
        require(v <= type(uint32).max, "u32 overflow");
        return uint32(v);
    }

    function _u64(uint256 v) internal pure returns (uint64) {
        require(v <= type(uint64).max, "u64 overflow");
        return uint64(v);
    }

    function _u128(uint256 v) internal pure returns (uint128) {
        require(v <= type(uint128).max, "u128 overflow");
        return uint128(v);
    }

    function _i24(int256 v) internal pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, "i24 overflow");
        return int24(v);
    }

    function _knots5(uint256[] memory v) internal pure returns (uint128[5] memory out) {
        require(v.length == 5, "need exactly 5 knots");
        for (uint256 i = 0; i < 5; i++) {
            out[i] = _u128(v[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Profiles
    // ---------------------------------------------------------------------

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _isRelease(string memory profile) internal pure returns (bool) {
        return _eq(profile, PROFILE_RELEASE);
    }

    /// @dev Only the two plan profiles exist (R28): `release` (real time scale, all release
    ///      gates) and `sandbox` (small time scale for the RC, placeholders allowed).
    function _requireProfile(string memory profile) internal pure {
        if (!_eq(profile, PROFILE_RELEASE) && !_eq(profile, PROFILE_SANDBOX)) {
            revert UnknownProfile(profile);
        }
    }

    // ---------------------------------------------------------------------
    // Init code hashes of THIS build
    // ---------------------------------------------------------------------

    function _hashNames() internal pure returns (string[HASHED_CONTRACTS] memory n) {
        n = [
            "ArunaFactory",
            "VaultDeployer",
            "AccumulatorDeployer",
            "CoverVault",
            "VarianceAccumulator",
            "FlatVegaPricer",
            "PositionValuer"
        ];
    }

    /// @dev Same order as `_hashNames`. `bytecode_hash = "none"` + `cbor_metadata = false`
    ///      make these a function of source + compiler settings only.
    function _buildHashes() internal pure returns (bytes32[HASHED_CONTRACTS] memory h) {
        h[0] = keccak256(type(ArunaFactory).creationCode);
        h[1] = keccak256(type(VaultDeployer).creationCode);
        h[2] = keccak256(type(AccumulatorDeployer).creationCode);
        h[3] = keccak256(type(CoverVault).creationCode);
        h[4] = keccak256(type(VarianceAccumulator).creationCode);
        h[5] = keccak256(type(FlatVegaPricer).creationCode);
        h[6] = keccak256(type(PositionValuer).creationCode);
    }

    /// @dev Revert unless every hash recorded in `manifestJson` equals this build's.
    function _requireHashesMatch(string memory manifestJson) internal view {
        string[HASHED_CONTRACTS] memory names = _hashNames();
        bytes32[HASHED_CONTRACTS] memory build = _buildHashes();
        for (uint256 i = 0; i < HASHED_CONTRACTS; i++) {
            string memory key = string.concat(".initCodeHashes.", names[i]);
            if (!vm.keyExistsJson(manifestJson, key)) {
                revert InitCodeHashMismatch(names[i], build[i], bytes32(0));
            }
            bytes32 recorded = vm.parseJsonBytes32(manifestJson, key);
            if (recorded != build[i]) revert InitCodeHashMismatch(names[i], build[i], recorded);
        }
    }

    // ---------------------------------------------------------------------
    // Manifest IO
    // ---------------------------------------------------------------------

    function _manifestDir(uint256 chainId) internal pure returns (string memory) {
        return string.concat("deployments/", _uintStr(chainId));
    }

    function _manifestPath(uint256 chainId, string memory label)
        internal
        pure
        returns (string memory)
    {
        return string.concat(_manifestDir(chainId), "/", label, ".json");
    }

    /// @dev Manifest path for scripts that act on an existing deployment: ARUNA_MANIFEST,
    ///      else deployments/<chainId>/<ARUNA_DEPLOY_LABEL or PROFILE or "sandbox">.json.
    function _manifestFromEnv() internal view returns (string memory) {
        string memory explicitPath = vm.envOr("ARUNA_MANIFEST", string(""));
        if (bytes(explicitPath).length != 0) return explicitPath;
        string memory profile = vm.envOr("PROFILE", string(PROFILE_SANDBOX));
        return _manifestPath(block.chainid, vm.envOr("ARUNA_DEPLOY_LABEL", profile));
    }

    function _readManifest(string memory path) internal view returns (string memory) {
        if (!vm.exists(path)) revert ManifestMissing(path);
        return vm.readFile(path);
    }

    /// @dev Write only when the transactions are real (broadcast / resume) or inside
    ///      `forge test`. A plain `forge script` simulation logs instead.
    function _persist() internal view returns (bool) {
        return !vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
    }

    /// @dev The address that signs inside the current broadcast window.
    function _broadcaster() internal view returns (address sender) {
        (, sender,) = vm.readCallers();
    }

    /// @dev Big integers go into the manifest as decimal strings, so JavaScript readers
    ///      (indexer, frontend) never lose precision above 2^53.
    function _uintStr(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _logPersist(string memory what, string memory path, string memory json) internal view {
        if (_persist()) {
            console2.log(string.concat(what, " written: ", path));
        } else {
            console2.log(string.concat("dry run: ", what, " NOT written (", path, ")"));
            console2.log(json);
        }
    }
}
