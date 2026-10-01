// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {Math} from "../src/libraries/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {Obligations} from "./utils/Obligations.sol";

/// @title CoverVaultHandler
/// @notice Bounded actor that drives ONE CoverVault through its whole v2 lifecycle under
///         fuzzed calls (plan U8): deposit → buyCover (approve + escrow) → cancel /
///         collectFees → finalize / keeperFinalize → settlePolicy / settleBatch →
///         withdraw / rollTo (n+1 in the gap, n+2 late) → claimUnclaimed / claimPosition,
///         plus keeperPoke / fundKeeper, direct token donations (residual), third-party
///         `increaseLiquidity` on an escrowed position, an unsolicited `safeTransferFrom`
///         of an NFT, and two hostile switches: a `RejectingReceiver` actor whose incoming
///         settlement-token transfers can be made to revert, and the NFPM
///         transferFrom-fail switch (NFT parking defense). Time moves by free warps and by
///         calendar-aware warps that land on startsAt, the last buyable second, endsAt and
///         mid-gap.
///
///         Every action guards its own preconditions and returns quietly when they do not
///         hold, so `fail_on_revert = false` discards nothing meaningful. Properties that
///         can only be observed mid-action are recorded on ghost flags (a bare assert in a
///         handler would be swallowed). Money in/out is mirrored on ghosts sourced from
///         OPPOSITE sides (amounts the handler paid in vs. what recipients received), so
///         the conservation check cannot collapse into a tautology.
contract CoverVaultHandler is Test {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    /// @notice Highest cohort id deposited into / bought on. Rolls reach MAX_CID + 2.
    uint32 public constant MAX_CID = 7;

    bytes32 internal constant POLICY_SETTLED_SIG =
        keccak256("PolicySettled(uint256,uint32,uint128)");
    bytes32 internal constant REFUNDED_SIG = keccak256("PolicyRefunded(uint256,uint32,uint128)");
    bytes32 internal constant UNCLAIMED_SIG = keccak256("Unclaimed(address,uint128)");
    bytes32 internal constant PARKED_SIG = keccak256("PositionParked(uint256,uint256,address)");
    bytes32 internal constant SWEPT_SIG = keccak256("ResidualSwept(uint32,uint256)");

    CoverVault public immutable vault;
    MockERC20 public immutable token;
    MockAccumulator public immutable acc;
    MockPricer public immutable pricer;
    MockPositionManager public immutable pm;
    MockERC20 public immutable fee0;
    MockERC20 public immutable fee1;
    address public immutable rejector; // RejectingReceiver actor

    uint64 internal immutable anchor;
    uint32 internal immutable tenor;
    uint32 internal immutable gap;
    uint32 internal immutable interval;
    uint16 internal immutable maxUtilBps;

    address internal constant STRANGER = address(0x5757);

    address[] internal _actors;

    // --- ghost accounting (read by the invariant_ functions) ---
    uint256 public ghostIn; // deposits + premiums + donations + budget funding (handler side)
    uint256 public ghostOut; // nets, payouts, refunds, claims, bounties (recipient side)
    mapping(uint32 => uint256) public ghostSumMaxPayout; // Σ maxPayout ever sold per cohort
    mapping(uint32 => uint256) public ghostClaims; // Σ PolicySettled payouts per cohort
    uint256 public ghostFunded; // Σ fundKeeperBudget amounts
    uint256 public ghostBounties; // Σ bounties received by the handler
    mapping(uint256 => uint256) public ghostVarNotional; // policyId → varNotional at buy
    mapping(uint256 => uint256) public ghostMaxPayout; // policyId → maxPayout at buy
    mapping(uint32 => uint256) internal _ghostSnapshot; // cohort → first σ̂² snapshot seen
    mapping(uint32 => bool) internal _ghostSnapshotSeen;
    uint32 internal _ghostEwmaCohort;
    uint32 internal _ghostSettledPolicies;

    // --- violation flags (each pinned by an invariant_ function) ---
    bool public i2Violated; // a policy's payout exceeded its maxPayout
    bool public i4Violated; // an LP wallet was debited by anything other than its premium
    bool public monotoneViolated; // EWMA cohort went back / σ̂² snapshot moved / snapshot field moved
    bool public escrowViolated; // unsolicited NFT accepted / non-owner fee collect accepted
    bool public feeViolated; // collectFees did not deliver exactly the fees owed

    // --- NFTs ---
    uint256[] internal _tokens; // every position ever minted (ids ≥ 1)
    mapping(uint256 => address) public nftOwner; // the LP that owns the position
    mapping(uint256 => uint256) public latestPolicyPlus1; // tokenId → latest policyId + 1

    uint128 internal _cumSq;
    bool public rejecting; // RejectingReceiver currently rejects settlement-token transfers

    // --- call summary ---
    bytes32[] internal _names;
    mapping(bytes32 => uint256) public calls;
    mapping(bytes32 => uint256) public oks;

    mapping(bytes32 => bool) internal _known;

    modifier track(bytes32 name) {
        _register(name);
        calls[name]++;
        _;
        _postChecks();
    }

    function _register(bytes32 name) internal {
        if (!_known[name]) {
            _known[name] = true;
            _names.push(name);
        }
    }

    function _ok(bytes32 name) internal {
        _register(name);
        oks[name]++;
    }

    constructor(
        CoverVault vault_,
        MockAccumulator acc_,
        MockPricer pricer_,
        MockPositionManager pm_,
        MockERC20 fee0_,
        MockERC20 fee1_,
        address[] memory actors_,
        address rejector_
    ) {
        vault = vault_;
        token = MockERC20(address(vault_.settlementToken()));
        acc = acc_;
        pricer = pricer_;
        pm = pm_;
        fee0 = fee0_;
        fee1 = fee1_;
        rejector = rejector_;
        anchor = vault_.anchor();
        tenor = vault_.tenor();
        gap = vault_.gap();
        interval = vault_.sampleInterval();
        maxUtilBps = vault_.maxUtilizationBps();
        token.approve(address(vault_), type(uint256).max); // fundKeeperBudget pulls from here

        for (uint256 i = 0; i < actors_.length; i++) {
            _actors.push(actors_[i]);
            vm.prank(actors_[i]);
            token.approve(address(vault_), type(uint256).max);
            // NO setApprovalForAll: every buy approves its own tokenId, as an LP would.
        }
    }

    // ------------------------------------------------------------------
    // Views for the invariant contract
    // ------------------------------------------------------------------

    function actorsList() external view returns (address[] memory) {
        return _actors;
    }

    function tokensList() external view returns (uint256[] memory) {
        return _tokens;
    }

    /// @notice Per-action call / success counts (plan U8: show every action is reached).
    function callSummary() external view {
        console.log("-- CoverVaultHandler call summary (calls / effective) --");
        for (uint256 i = 0; i < _names.length; i++) {
            console.log(_str(_names[i]), calls[_names[i]], oks[_names[i]]);
        }
    }

    function _str(bytes32 b) internal pure returns (string memory) {
        uint256 len;
        while (len < 32 && b[len] != 0) len++;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[i];
        }
        return string(out);
    }

    function summary()
        external
        view
        returns (bytes32[] memory names, uint256[] memory called, uint256[] memory ok)
    {
        names = _names;
        called = new uint256[](_names.length);
        ok = new uint256[](_names.length);
        for (uint256 i = 0; i < _names.length; i++) {
            called[i] = calls[_names[i]];
            ok[i] = oks[_names[i]];
        }
    }

    function nameOf(bytes32 b) external pure returns (string memory) {
        return _str(b);
    }

    /// @notice Initial book (called once from setUp, not a fuzzed action): one underwriter
    ///         per cohort 0..MAX_CID, round-robin over the actors (the RejectingReceiver
    ///         included), so buys are reachable whatever cohort time lands in. Fuzzed
    ///         deposits / rolls add to it.
    function seedCapital(uint128 amount) external {
        for (uint32 cid = 0; cid <= MAX_CID; cid++) {
            address a = _actors[cid % _actors.length];
            token.mint(a, amount);
            vm.prank(a);
            vault.deposit(cid, amount);
            ghostIn += amount;
        }
    }

    // ------------------------------------------------------------------
    // Time and oracle
    // ------------------------------------------------------------------

    /// @notice Free warp. via_ir caches TIMESTAMP within a frame, so the runner (fresh
    ///         frame per call) sees the advanced value next call.
    function warp(uint256 dtSeed) external track("warp") {
        uint256 dt = bound(dtSeed, 1 hours, uint256(tenor) / 2 + 1);
        _advance(vm.getBlockTimestamp() + dt, dtSeed);
        _ok("warp");
    }

    /// @dev Move the clock to `target`. Half the time a live keeper samples on schedule
    ///      along the way (one sample per interval, Σr² growing in a quiet / moderate /
    ///      stormy regime picked from the seed, so measured policies both pay and do not);
    ///      otherwise the keeper is dead for the stretch and windows go stale / refund.
    function _advance(uint256 target, uint256 seed) internal {
        if (seed % 2 == 0) {
            uint256 regime = (seed >> 8) % 3;
            uint256 cap = regime == 1 ? 1e15 : 2e16;
            uint256 t = uint256(acc.lastSampleAt()) + interval;
            for (uint256 k = 0; t <= target; k++) {
                if (regime != 0) {
                    _cumSq += uint128(uint256(keccak256(abi.encode(seed, k))) % cap);
                }
                acc.push(uint32(t), _cumSq);
                t += interval;
            }
        }
        vm.warp(target);
    }

    /// @notice Calendar-aware warp: jump to the next of startsAt(n), the last second a buy
    ///         is still allowed (endsAt − 5 intervals), endsAt(n) (gap start) or mid-gap,
    ///         for the current cohort or the next one.
    function warpCalendar(uint256 phaseSeed) external track("warpCalendar") {
        uint256 nowTs = vm.getBlockTimestamp();
        uint32 cur = vault.currentCohortId();
        if (cur > MAX_CID + 2) return;
        uint256 phase = phaseSeed % 4;
        for (uint32 n = cur; n <= cur + 1; n++) {
            uint256 s = vault.startsAt(n);
            uint256 e = vault.endsAt(n);
            uint256 target = phase == 0
                ? s
                : phase == 1 ? e - 5 * uint256(interval) : phase == 2 ? e : e + gap / 2;
            if (target > nowTs) {
                _advance(target, phaseSeed >> 2);
                _ok("warpCalendar");
                return;
            }
        }
    }

    /// @notice Append an oracle sample at `now` with Σr² rising by `delta` (≥ 0), honoring
    ///         the interval throttle as the real accumulator does.
    function poke(uint256 deltaSeed) external track("poke") {
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 due = uint256(acc.lastSampleAt()) + interval;
        if (nowTs < due) {
            // An on-time keeper: step to the next allowed sample time (≤ one interval).
            vm.warp(due);
            nowTs = due;
        }
        uint128 delta = uint128(bound(deltaSeed, 0, 5e16));
        _cumSq += delta; // never decreases → I5
        acc.push(uint32(nowTs), _cumSq);
        _ok("poke");
    }

    // ------------------------------------------------------------------
    // Underwriter
    // ------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 cidSeed, uint256 amtSeed)
        external
        track("deposit")
    {
        address a = _actor(actorSeed);
        // Mostly the next cohort still FUNDING (what an underwriter would pick).
        uint32 cid = vault.currentCohortId();
        if (vault.statusOf(cid) != ICoverVault.Status.FUNDING) cid++;
        if (cidSeed % 4 == 0) cid = uint32(bound(cidSeed, 0, MAX_CID));
        if (cid > MAX_CID || vault.statusOf(cid) != ICoverVault.Status.FUNDING) return;
        uint128 amt = uint128(bound(amtSeed, 1e6, 1e12));
        token.mint(a, amt);
        vm.prank(a);
        try vault.deposit(cid, amt) {
            ghostIn += amt;
            _ok("deposit");
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 cidSeed) external track("withdraw") {
        address a = _actor(actorSeed);
        // A cohort this actor holds a deposit in. SETTLING is attempted too: a zero-policy
        // cohort is finalized lazily by withdraw.
        (bool found, uint32 cid) = _pickDeposit(a, cidSeed);
        if (!found || vault.statusOf(cid) == ICoverVault.Status.ACTIVE) return;
        uint256[] memory before = _snapshot();
        vm.prank(a);
        try vault.withdraw(cid) returns (uint256 net) {
            ghostOut += net;
            _ok("withdraw");
        } catch {}
        _checkNoDebit(before);
    }

    /// @notice Explicit roll of a settled position (R11): into n+1 (normally during n's
    ///         gap) or, `late`, into n+2. Tokens never move, so the ghosts are untouched.
    function rollTo(uint256 actorSeed, uint256 fromSeed, bool late) external track("rollTo") {
        address a = _actor(actorSeed);
        (bool found, uint32 from) = _pickDeposit(a, fromSeed);
        if (!found || from > MAX_CID) return;
        uint32 to = from + (late ? 2 : 1);
        if (vault.statusOf(to) != ICoverVault.Status.FUNDING) return;
        uint256[] memory before = _snapshot();
        vm.prank(a);
        try vault.rollTo(from, to) {
            _ok(late ? bytes32("rollTo_late_n+2") : bytes32("rollTo_n+1"));
            _ok("rollTo");
        } catch {}
        _checkNoDebit(before);
    }

    // ------------------------------------------------------------------
    // LP
    // ------------------------------------------------------------------

    function buyCover(
        uint256 actorSeed,
        uint256 cidSeed,
        uint256 vnSeed,
        uint256 premSeed,
        uint256 strikeSeed,
        uint256 reuseSeed
    ) external track("buyCover") {
        address a = _actor(actorSeed);
        // Only the current cohort can be ACTIVE: aim there (any other id is a no-op).
        uint32 cid = vault.currentCohortId();
        if (cidSeed % 8 == 0) cid = uint32(bound(cidSeed, 0, MAX_CID));
        if (cid > MAX_CID || vault.statusOf(cid) != ICoverVault.Status.ACTIVE) {
            _ok("~buy:notActive");
            return;
        }

        ICoverVault.Cohort memory c = vault.cohort(cid);
        if (vm.getBlockTimestamp() + 5 * uint256(interval) > c.endsAt) {
            _ok("~buy:late");
            return;
        }
        if (c.totalCapital == 0 || acc.sampleCount() == 0) {
            _ok("~buy:nocap");
            return;
        }
        if (c.policyCount >= vault.policyCap()) {
            _ok("~buy:cap");
            return;
        }

        // maxExcessVariance == WAD and the real PositionValuer at neutral width with
        // kappa == WAD give maxPayout == varNotional == liquidity.
        uint256 available = uint256(c.totalCapital).mulDivDown(maxUtilBps, BPS);
        if (available <= c.reserved) return;
        uint256 room = available - c.reserved;
        uint256 minPayout = available / vault.policyCap();
        if (minPayout == 0) minPayout = 1;
        if (room < minPayout) return;
        // Half the buys take the per-policy minimum, so the live-policy cap is reachable.
        uint128 vn = vnSeed % 2 == 0 ? uint128(minPayout) : uint128(bound(vnSeed, minPayout, room));

        // Re-use a position this LP got back (one live policy per position, R18), or mint.
        uint256 tokenId = reuseSeed % 3 == 0 ? _ownedToken(a, reuseSeed) : 0;
        if (tokenId == 0) {
            tokenId = _tokens.length + 1;
            _tokens.push(tokenId);
            pm.setOwner(tokenId, a);
            nftOwner[tokenId] = a;
        }
        pm.setPosition(tokenId, -600, 600, vn);
        vm.prank(a);
        pm.approve(address(vault), tokenId);

        uint128 premium = uint128(bound(premSeed, 0, 1e9));
        pricer.setPremium(premium);
        token.mint(a, premium);
        uint256 balBefore = token.balanceOf(a);
        uint64 strike = uint64(bound(strikeSeed, 0, 1e18));

        vm.prank(a);
        try vault.buyCover(
            cid, tokenId, strike, premium, uint64(vm.getBlockTimestamp() + 1)
        ) returns (
            uint256 pid
        ) {
            ICoverVault.Policy memory p = vault.policy(pid);
            ghostIn += premium;
            ghostSumMaxPayout[cid] += p.maxPayout;
            ghostVarNotional[pid] = p.varNotional;
            ghostMaxPayout[pid] = p.maxPayout;
            latestPolicyPlus1[tokenId] = pid + 1;
            // I4: the premium is the ONLY debit an LP ever takes.
            if (token.balanceOf(a) != balBefore - premium) i4Violated = true;
            _ok("buyCover");
        } catch {
            _ok("~buy:revert");
        }
    }

    /// @notice Cancel a live policy before endsAt (R16).
    function cancel(uint256 policySeed) external track("cancel") {
        (bool found, uint256 pid, ICoverVault.Policy memory p) = _pickPolicy(policySeed, 0);
        if (!found) return;
        if (vm.getBlockTimestamp() >= vault.endsAt(p.cohortId)) return;
        uint256[] memory before = _snapshot();
        vm.prank(p.owner);
        try vault.cancel(pid) {
            _ok("cancel");
            if (vault.policy(pid).nftParked) _ok("~outcome:nftParked");
        } catch {}
        _checkNoDebit(before);
    }

    /// @notice Fees accrue on an escrowed position; only its policy owner may collect, to a
    ///         recipient of their choice (R14/R15). A stranger's call must revert.
    function collectFees(uint256 policySeed, uint256 owedSeed, uint256 recipientSeed)
        external
        track("collectFees")
    {
        (bool found, uint256 pid, ICoverVault.Policy memory p) = _pickPolicy(policySeed, 1);
        if (!found) return;
        uint128 o0 = uint128(bound(owedSeed, 0, 1e18));
        uint128 o1 = uint128(bound(owedSeed >> 128, 1, 1e18));
        pm.setTokensOwed(p.positionTokenId, o0, o1);

        vm.prank(STRANGER);
        try vault.collectFees(pid, STRANGER) {
            escrowViolated = true;
        } catch {}

        address to = _actor(recipientSeed);
        uint256 b0 = fee0.balanceOf(to);
        uint256 b1 = fee1.balanceOf(to);
        uint256[] memory before = _snapshot();
        vm.prank(p.owner);
        try vault.collectFees(pid, to) {
            if (fee0.balanceOf(to) != b0 + o0 || fee1.balanceOf(to) != b1 + o1) {
                feeViolated = true;
            }
            _ok("collectFees");
        } catch {
            feeViolated = true; // the owner of an escrowed / parked position can always collect
        }
        _checkNoDebit(before);
    }

    /// @notice Anyone may add liquidity to any position (NFPM); the escrowed policy's
    ///         varNotional / maxPayout snapshot must not move (checked in _postChecks).
    function increaseLiquidity(uint256 policySeed, uint256 deltaSeed)
        external
        track("increaseLiquidity")
    {
        (bool found,, ICoverVault.Policy memory p) = _pickPolicy(policySeed, 0);
        if (!found) return;
        vm.prank(STRANGER);
        pm.increaseLiquidity(p.positionTokenId, uint128(bound(deltaSeed, 1, 1e12)));
        _ok("increaseLiquidity");
    }

    /// @notice A `safeTransferFrom` of a position into the vault outside a purchase must
    ///         be rejected by the receiver hook.
    function unsolicitedNft(uint256 seed) external track("unsolicitedNft") {
        if (_tokens.length == 0) return;
        uint256 id = _tokens[bound(seed, 0, _tokens.length - 1)];
        address o = pm.ownerOf(id);
        if (o == address(vault)) return;
        vm.prank(o);
        try pm.safeTransferFrom(o, address(vault), id) {
            escrowViolated = true;
        } catch {
            _ok("unsolicitedNft");
        }
    }

    function claimPosition(uint256 policySeed) external track("claimPosition") {
        uint256 n = vault.policyCount();
        if (n == 0) return;
        uint256 start = bound(policySeed, 0, n - 1);
        for (uint256 k = 0; k < n; k++) {
            uint256 pid = (start + k) % n;
            ICoverVault.Policy memory p = vault.policy(pid);
            if (!p.nftParked) continue;
            uint256[] memory before = _snapshot();
            vm.prank(p.owner);
            try vault.claimPosition(pid) {
                _ok("claimPosition");
            } catch {}
            _checkNoDebit(before);
            return;
        }
    }

    function claimUnclaimed(uint256 actorSeed) external track("claimUnclaimed") {
        address a = _actor(actorSeed);
        uint256 i0 = actorSeed % _actors.length;
        for (uint256 k = 1; k < _actors.length && vault.unclaimed(a) == 0; k++) {
            a = _actors[(i0 + k) % _actors.length];
        }
        if (vault.unclaimed(a) == 0) return;
        if (a == rejector && rejecting && actorSeed % 2 == 0) {
            rejecting = false; // the hostile receiver gets fixed and pulls what was parked
            token.setRejectTransfersTo(rejector, false);
        }
        uint256[] memory before = _snapshot();
        vm.prank(a);
        try vault.claimUnclaimed() returns (uint256 amount) {
            ghostOut += amount;
            _ok("claimUnclaimed");
        } catch {}
        _checkNoDebit(before);
    }

    // ------------------------------------------------------------------
    // Settlement and keeper
    // ------------------------------------------------------------------

    function finalize(uint256 cidSeed) external track("finalize") {
        uint32 cid = _pickSettling(cidSeed, true);
        ICoverVault.Cohort memory c = vault.cohort(cid);
        if (vm.getBlockTimestamp() < c.endsAt) return;
        if (c.finalized || c.totalCapital == 0) return; // done, or SETTLED by time
        uint256[] memory before = _snapshot();
        try vault.finalize(cid) {
            _ok("finalize");
        } catch {}
        _checkNoDebit(before);
    }

    function keeperFinalize(uint256 cidSeed) external track("keeperFinalize") {
        // Mostly a cohort that needs it; sometimes any id (the wrapper never reverts).
        uint32 cid = cidSeed % 4 == 0
            ? uint32(bound(cidSeed, 0, MAX_CID + 2))
            : _pickSettling(cidSeed, true);
        uint256[] memory before = _snapshot();
        uint256 hb = token.balanceOf(address(this));
        try vault.keeperFinalize(cid) returns (bool done, uint256) {
            if (done) _ok("keeperFinalize");
        } catch {}
        _bountySince(hb);
        _checkNoDebit(before);
    }

    function settlePolicy(uint256 policySeed) external track("settlePolicy") {
        (bool found, uint256 pid, ICoverVault.Policy memory p) = _pickPolicy(policySeed, 2);
        if (!found) return;
        if (vault.statusOf(p.cohortId) != ICoverVault.Status.SETTLING) return;
        uint256[] memory before = _snapshot();
        uint256 hb = token.balanceOf(address(this));
        vm.recordLogs();
        try vault.settlePolicy(pid) {
            _ok("settlePolicy");
        } catch {}
        _scanSettled(vm.getRecordedLogs());
        ghostOut += _received(before);
        _bountySince(hb);
        _checkNoDebit(before);
    }

    function settleBatch(uint256 cidSeed, uint256 nSeed) external track("settleBatch") {
        uint32 cid = _pickSettling(cidSeed, false);
        if (vault.statusOf(cid) != ICoverVault.Status.SETTLING) return;
        uint32 n = uint32(bound(nSeed, 1, 8));
        uint256[] memory before = _snapshot();
        uint256 hb = token.balanceOf(address(this));
        vm.recordLogs();
        try vault.settleBatch(cid, n) {
            _ok("settleBatch");
        } catch {}
        _scanSettled(vm.getRecordedLogs());
        ghostOut += _received(before); // payouts AND refunds, measured on the recipients
        _bountySince(hb);
        _checkNoDebit(before);
    }

    function keeperPoke() external track("keeperPoke") {
        uint256 hb = token.balanceOf(address(this));
        try vault.keeperPoke() returns (bool sampled, uint256) {
            if (sampled) _ok("keeperPoke");
        } catch {}
        _bountySince(hb);
    }

    function fundKeeper(uint256 amtSeed) external track("fundKeeper") {
        uint256 amt = bound(amtSeed, 1, 1e6);
        token.mint(address(this), amt);
        try vault.fundKeeperBudget(amt) {
            ghostIn += amt;
            ghostFunded += amt;
            _ok("fundKeeper");
        } catch {}
    }

    /// @notice Direct transfer to the vault: residual, never an underwriter's entitlement
    ///         until swept at a finalize (plan "Akuntansi").
    function donate(uint256 amtSeed) external track("donate") {
        uint256 amt = bound(amtSeed, 1, 1e9);
        token.mint(address(this), amt);
        token.transfer(address(vault), amt);
        ghostIn += amt;
        _ok("donate");
    }

    // ------------------------------------------------------------------
    // Hostile switches
    // ------------------------------------------------------------------

    /// @notice The RejectingReceiver actor starts / stops refusing settlement-token
    ///         transfers: its payouts and refunds park in `unclaimed` (§7.3, AE9).
    function toggleTokenRejection(uint256 seed) external track("toggleTokenRejection") {
        // Switch on one time in three, off otherwise: hostile, but not most of the run.
        rejecting = seed % 3 == 0;
        token.setRejectTransfersTo(rejector, rejecting);
        _ok("toggleTokenRejection");
    }

    /// @notice NFPM transferFrom-fail switch: NFT returns park for claimPosition (R17).
    function toggleNftTransferFail(uint256 seed) external track("toggleNftTransferFail") {
        // On one time in four (a failing NFPM also blocks every buy while it lasts).
        pm.setTransferFails(seed % 4 == 0);
        _ok("toggleNftTransferFail");
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// @dev A cohort `a` holds a deposit in, scanning from the seed.
    function _pickDeposit(address a, uint256 seed) internal view returns (bool, uint32) {
        uint32 span = MAX_CID + 3;
        uint32 start = uint32(seed % span);
        for (uint32 k = 0; k < span; k++) {
            uint32 cid = (start + k) % span;
            if (vault.deposits(cid, a) != 0) return (true, cid);
        }
        return (false, 0);
    }

    /// @dev A SETTLING cohort (if `unfinalized`, one not yet finalized), scanning from the
    ///      seed; falls back to a bounded random id.
    function _pickSettling(uint256 seed, bool unfinalized) internal view returns (uint32) {
        uint32 span = MAX_CID + 3;
        uint32 start = uint32(seed % span);
        for (uint32 k = 0; k < span; k++) {
            uint32 cid = (start + k) % span;
            if (vault.statusOf(cid) != ICoverVault.Status.SETTLING) continue;
            if (unfinalized && vault.cohort(cid).finalized) continue;
            return cid;
        }
        return start;
    }

    /// @dev mode 0: an Active policy; mode 2: an Active policy of a SETTLING cohort; mode 1: Active or NFT-parked (the vault holds the NFT).
    function _pickPolicy(uint256 seed, uint256 mode)
        internal
        view
        returns (bool found, uint256 pid, ICoverVault.Policy memory p)
    {
        uint256 n = vault.policyCount();
        if (n == 0) return (false, 0, p);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 k = 0; k < n; k++) {
            pid = (start + k) % n;
            p = vault.policy(pid);
            if (mode == 2) {
                if (
                    p.status == ICoverVault.PolicyStatus.Active
                        && vault.statusOf(p.cohortId) == ICoverVault.Status.SETTLING
                ) return (true, pid, p);
                continue;
            }
            if (p.status == ICoverVault.PolicyStatus.Active) return (true, pid, p);
            if (mode == 1 && p.nftParked) return (true, pid, p);
        }
        return (false, 0, p);
    }

    function _ownedToken(address a, uint256 seed) internal view returns (uint256) {
        uint256 n = _tokens.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = _tokens[(start + k) % n];
            if (pm.ownerOf(id) == a) return id;
        }
        return 0;
    }

    /// @dev I2 per policy from the canonical PolicySettled event: payout ≤ maxPayout.
    function _scanSettled(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(vault)) continue;
            bytes32 t0 = l.topics[0];
            if (t0 == REFUNDED_SIG) _ok("~outcome:refund");
            if (t0 == UNCLAIMED_SIG) _ok("~outcome:payoutParked");
            if (t0 == PARKED_SIG) _ok("~outcome:nftParked");
            if (t0 == SWEPT_SIG) _ok("~outcome:residualSwept");
            if (t0 != POLICY_SETTLED_SIG) continue;
            uint256 pid = uint256(l.topics[1]);
            uint32 cid = uint32(uint256(l.topics[2]));
            uint128 payout = abi.decode(l.data, (uint128));
            if (payout > ghostMaxPayout[pid]) i2Violated = true;
            _ok("~outcome:settled");
            if (payout > 0) _ok("~outcome:paid");
            ghostClaims[cid] += payout;
        }
    }

    /// @dev Monotone / frozen properties checked after every action (I5 extended): the
    ///      EWMA cohort never goes back, a cohort's σ̂² snapshot never changes once taken
    ///      (R10: price fixed after the first policy), and a policy's varNotional /
    ///      maxPayout never move (third-party increaseLiquidity cannot change a payout).
    function _postChecks() internal {
        if (vault.ewmaEverUpdated()) {
            uint32 e = vault.lastEwmaCohortId();
            if (e < _ghostEwmaCohort) monotoneViolated = true;
            _ghostEwmaCohort = e;
        }
        for (uint32 cid = 0; cid <= MAX_CID + 2; cid++) {
            ICoverVault.Cohort memory c = vault.cohort(cid);
            if (!c.snapshotTaken) continue;
            if (_ghostSnapshotSeen[cid]) {
                if (_ghostSnapshot[cid] != c.varianceSnapshot) monotoneViolated = true;
            } else {
                _ghostSnapshotSeen[cid] = true;
                _ghostSnapshot[cid] = c.varianceSnapshot;
            }
        }
        uint256 n = vault.policyCount();
        for (uint256 i = 0; i < n; i++) {
            ICoverVault.Policy memory p = vault.policy(i);
            if (p.varNotional != ghostVarNotional[i] || p.maxPayout != ghostMaxPayout[i]) {
                monotoneViolated = true;
            }
        }
    }

    /// @dev Bounty received by the handler since `before`: leaves the vault (ghostOut).
    function _bountySince(uint256 before) internal {
        uint256 b = token.balanceOf(address(this));
        if (b > before) {
            ghostBounties += b - before;
            ghostOut += b - before;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _snapshot() internal view returns (uint256[] memory bal) {
        bal = new uint256[](_actors.length);
        for (uint256 i = 0; i < _actors.length; i++) {
            bal[i] = token.balanceOf(_actors[i]);
        }
    }

    /// @dev Tokens the actors gained since `before` (settle pushes only ever credit them).
    function _received(uint256[] memory before) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < _actors.length; i++) {
            uint256 b = token.balanceOf(_actors[i]);
            if (b > before[i]) sum += b - before[i];
        }
    }

    /// @dev I4: no path but the buy itself may take tokens FROM an LP / underwriter.
    function _checkNoDebit(uint256[] memory before) internal {
        for (uint256 i = 0; i < _actors.length; i++) {
            if (token.balanceOf(_actors[i]) < before[i]) i4Violated = true;
        }
    }
}

/// @title CoverVaultV0Sc01
/// @notice TEST-ONLY harness reproducing the v0 SC-01 bug on top of the v2 vault: a
///         FUNDING withdraw that returns the deposit but leaves it in `totalCapital` (and
///         the cohort's remaining principal). It keeps the vault's own obligation counter
///         consistent, exactly the situation in which a self-referential check stays green.
///         Used only to prove the new I3 form is not vacuous (plan U8 execution note).
contract CoverVaultV0Sc01 is CoverVault {
    constructor(
        address pool_,
        address acc_,
        address pricer_,
        address valuer_,
        address pm_,
        address token_
    )
        CoverVault(
            pool_,
            acc_,
            pricer_,
            valuer_,
            pm_,
            token_,
            7 days,
            1 days,
            1_000_000,
            8_000,
            uint128(1e18),
            2_000,
            uint128(1e17),
            8,
            0,
            0,
            0,
            0
        )
    {}

    /// @notice v0 `withdraw` in FUNDING: deposit zeroed and paid, cohort capital untouched.
    function withdrawV0(uint32 cohortId) external {
        uint128 dep = deposits[cohortId][msg.sender];
        deposits[cohortId][msg.sender] = 0;
        _obligations -= dep;
        _push(msg.sender, dep);
    }
}

/// @title InvariantBase
/// @notice Shared deployment for the invariant campaign and its directed companions.
abstract contract InvariantBase is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    uint64 internal constant ANCHOR = 1_000_000;
    uint32 internal constant TENOR = 604_800; // 7 days
    uint32 internal constant GAP = 86_400; // 1 day settlement gap
    uint32 internal constant SAMPLE_INTERVAL = 6 hours; // 28 samples per tenor (bounded scans)
    uint16 internal constant MAX_UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS_VARIANCE = uint128(WAD); // maxPayout == varNotional
    uint16 internal constant EWMA_ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VARIANCE = uint128(WAD / 10);
    uint32 internal constant POLICY_CAP = 8; // small, so the fuzzer reaches the cap
    uint16 internal constant KEEPER_BPS = 1_000; // 10% cut after endsAt (U6)
    uint128 internal constant POKE_BOUNTY = 50;
    uint128 internal constant FINALIZE_BOUNTY = 100;
    uint128 internal constant SETTLE_BOUNTY = 5;

    // Real PositionValuer at neutral width: varNotional == liquidity (positions span
    // ticks [-600, 600] = 1200 = REF_WIDTH, kappa = WAD).
    int24 internal constant REF_WIDTH = 1_200;

    CoverVault internal vault;
    MockERC20 internal token;
    MockERC20 internal fee0;
    MockERC20 internal fee1;
    MockAccumulator internal acc;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockPricer internal pricer;
    PositionValuer internal valuer;
    RejectingReceiver internal rejector;
    CoverVaultHandler internal handler;

    uint32 internal maxCid; // highest cohort id the handler can reach (rolls: MAX_CID + 2)

    function _deploy() internal {
        // Start the clock a day before the anchor: every cohort is FUNDING, so the very
        // first deposits can reach cohort 0.
        vm.warp(ANCHOR - 1 days);

        token = new MockERC20(6);
        fee0 = new MockERC20(18);
        fee1 = new MockERC20(6);
        acc = new MockAccumulator();
        acc.setSampleInterval(SAMPLE_INTERVAL); // the vault reads it at deploy
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        pm.setFeeTokens(fee0, fee1);
        pricer = new MockPricer();
        valuer = new PositionValuer(
            address(pm), uint128(WAD), REF_WIDTH, uint128(WAD / 4), uint128(4 * WAD)
        );
        rejector = new RejectingReceiver();

        // The pool reports (token0, token1, fee) = (0, 0, 3000); every position matches.
        pm.setPool(pool.token0(), pool.token1(), pool.fee());

        // One oracle sample at the anchor so finalize always finds a sample at-or-before
        // any cohort's endsAt.
        acc.push(uint32(ANCHOR - 1 days), 0);

        vault = new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            TENOR,
            GAP,
            ANCHOR,
            MAX_UTIL_BPS,
            MAX_EXCESS_VARIANCE,
            EWMA_ALPHA_BPS,
            SEED_VARIANCE,
            POLICY_CAP,
            KEEPER_BPS,
            POKE_BOUNTY,
            FINALIZE_BOUNTY,
            SETTLE_BOUNTY
        );

        address[] memory actors = new address[](4);
        actors[0] = address(uint160(0xA11CE0));
        actors[1] = address(uint160(0xA11CE1));
        actors[2] = address(uint160(0xA11CE2));
        actors[3] = address(rejector); // hostile contract LP / underwriter

        handler =
            new CoverVaultHandler(vault, acc, pricer, pm, fee0, fee1, actors, address(rejector));
        maxCid = handler.MAX_CID() + 2;
    }
}

/// @title CoverVaultInvariants
/// @notice The §9.1 property suite in its v2 form (plan U8): I1–I8, the keeper bound and
///         an end-of-run liveness proof. Each invariant_ names the design property it pins.
///         Where §9.2's rounding asymmetry is what makes a property hold, the check
///         replicates the vault's own mulDivUp/mulDivDown directions.
contract CoverVaultInvariants is InvariantBase {
    using Math for uint256;

    function setUp() public {
        _deploy();
        handler.seedCapital(1e11);
        excludeSelector(_selector(CoverVaultHandler.seedCapital.selector));
        targetContract(address(handler));
    }

    function _selector(bytes4 sel) internal view returns (FuzzSelector memory fs) {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        fs = FuzzSelector({addr: address(handler), selectors: sels});
    }

    // ------------------------------------------------------------------
    // I1 — capacity: reserved never exceeds totalCapital × util on any unresolved cohort,
    //      and equals exactly Σ maxPayout of its Active policies.
    // ------------------------------------------------------------------
    function invariant_I1_reservedWithinCapacity() public view {
        uint256 n = vault.policyCount();
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            ICoverVault.Cohort memory c = vault.cohort(cid);
            uint256 cap = uint256(c.totalCapital).mulDivDown(MAX_UTIL_BPS, BPS);
            assertLe(uint256(c.reserved), cap, "I1: reserved exceeds utilization cap");
            uint256 live;
            for (uint256 i = 0; i < n; i++) {
                ICoverVault.Policy memory p = vault.policy(i);
                if (p.cohortId == cid && p.status == ICoverVault.PolicyStatus.Active) {
                    live += p.maxPayout;
                }
            }
            assertEq(uint256(c.reserved), live, "I1: reserved != sum of live maxPayout");
        }
    }

    // ------------------------------------------------------------------
    // I2 — every payout ≤ its policy's maxPayout (per policy, from PolicySettled), and a
    //      cohort's claimsPaid is exactly the sum of its payouts, ≤ the cover it sold.
    // ------------------------------------------------------------------
    function invariant_I2_payoutWithinMaxPayout() public view {
        assertFalse(handler.i2Violated(), "I2: a payout exceeded its maxPayout");
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            uint256 claims = vault.cohort(cid).claimsPaid;
            assertEq(claims, handler.ghostClaims(cid), "I2: claimsPaid != sum of payouts");
            assertLe(claims, handler.ghostSumMaxPayout(cid), "I2: claims exceed cover sold");
        }
    }

    // ------------------------------------------------------------------
    // I3 — solvency, new form (plan U8): token balance ≥ every obligation, recomputed
    //      independently from the books (capital + premiums unwithdrawn — refunds and
    //      payouts still owed included — parked payouts, keeper budget). The vault's own
    //      counter must agree to the wei, residual is exactly the excess, and the
    //      conservation form (balance == in − out, ghosts from opposite sides) still holds.
    //      test_I3_NewForm_CatchesSC01_OnV0Harness proves this form fails on SC-01.
    // ------------------------------------------------------------------
    function invariant_I3_balanceCoversObligations() public view {
        Obligations.Report memory r = Obligations.compute(vault, maxCid, handler.actorsList());
        assertFalse(r.bookUnderflow, "I3: a cohort spent more than it held");
        assertGe(r.balance, r.owed, "I3: balance below obligations");
        assertEq(r.vaultCounter, r.owed, "I3: vault obligation counter drifted");
        assertEq(vault.residual(), r.balance - r.owed, "I3: residual != excess");

        uint256 inn = handler.ghostIn();
        uint256 out = handler.ghostOut();
        assertGe(inn, out, "I3: more left than ever entered");
        assertEq(r.balance, inn - out, "I3: vault balance != in - out");
    }

    // ------------------------------------------------------------------
    // Keeper (plan U6) — bounties paid never exceed budget inflows (donations + cuts) and
    // the budget is exactly inflows − bounties. Cuts recomputed from policy/cohort state.
    // ------------------------------------------------------------------
    function invariant_Keeper_BountiesWithinInflows() public view {
        uint256 skims;
        uint256 n = vault.policyCount();
        for (uint256 i = 0; i < n; i++) {
            ICoverVault.Policy memory p = vault.policy(i);
            if (p.status == ICoverVault.PolicyStatus.Settled) {
                skims += uint256(p.premium).mulDivDown(KEEPER_BPS, BPS);
            }
        }
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            ICoverVault.Cohort memory c = vault.cohort(cid);
            if (c.finalized) skims += uint256(c.cancelledPremiums).mulDivDown(KEEPER_BPS, BPS);
        }
        uint256 inflows = handler.ghostFunded() + skims;
        assertLe(handler.ghostBounties(), inflows, "keeper: bounties exceed inflows");
        assertEq(vault.keeperBudget(), inflows - handler.ghostBounties(), "keeper: budget drift");
    }

    // ------------------------------------------------------------------
    // I4 — no LP / underwriter wallet is ever debited except by the premium at buy, and
    //      every NFT sits only with its owner, in vault escrow (live policy) or parked
    //      in the vault for its owner.
    // ------------------------------------------------------------------
    function invariant_I4_noDebitAndNftOnlyWithOwnerOrVault() public view {
        assertFalse(handler.i4Violated(), "I4: an LP / underwriter wallet was debited");
        uint256[] memory ids = handler.tokensList();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            address holder = pm.ownerOf(id);
            address lp = handler.nftOwner(id);
            uint256 lpp = handler.latestPolicyPlus1(id);
            bool inVault;
            if (lpp != 0) {
                ICoverVault.Policy memory p = vault.policy(lpp - 1);
                assertEq(p.owner, lp, "I4: policy owner is not the NFT owner");
                inVault = p.status == ICoverVault.PolicyStatus.Active || p.nftParked;
            }
            assertEq(holder, inVault ? address(vault) : lp, "I4: NFT in the wrong hands");
        }
        // Older policies on a re-used position are all final and hold nothing.
        uint256 n = vault.policyCount();
        for (uint256 pid = 0; pid < n; pid++) {
            ICoverVault.Policy memory p = vault.policy(pid);
            if (handler.latestPolicyPlus1(p.positionTokenId) == pid + 1) continue;
            assertTrue(p.status != ICoverVault.PolicyStatus.Active, "I4: two live policies");
            assertFalse(p.nftParked, "I4: superseded policy still parks an NFT");
        }
    }

    // ------------------------------------------------------------------
    // I5 — monotone: cumulativeSumSq and sample time never go back; the EWMA cohort
    //      never goes back; a cohort's σ̂² snapshot and a policy's varNotional/maxPayout
    //      never change once set (R10; third-party increaseLiquidity moves nothing).
    // ------------------------------------------------------------------
    function invariant_I5_monotone() public view {
        uint32 n = acc.sampleCount();
        for (uint32 i = 1; i < n; i++) {
            assertGe(
                uint256(acc.sampleAt(i).cumulativeSumSq),
                uint256(acc.sampleAt(i - 1).cumulativeSumSq),
                "I5: cumulativeSumSq decreased"
            );
            assertGt(acc.sampleAt(i).timestamp, acc.sampleAt(i - 1).timestamp, "I5: time");
        }
        assertFalse(handler.monotoneViolated(), "I5: a frozen / monotone value moved");
    }

    // ------------------------------------------------------------------
    // I6 — no money created, including keeper cuts and bounties: per cohort, Σ redeemable
    //      nets ≤ capital + premiums − claims − nets paid (replicating the vault's
    //      rounding); globally, everything redeemable (nets + parked + budget) ≤ balance.
    // ------------------------------------------------------------------
    function invariant_I6_noMoneyCreated() public view {
        address[] memory actors = handler.actorsList();
        uint256 redeemable;
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            ICoverVault.Cohort memory c = vault.cohort(cid);
            uint256 total = c.totalCapital;
            if (total == 0) continue;
            bool funding = vault.statusOf(cid) == ICoverVault.Status.FUNDING;
            uint256 sumNet;
            for (uint256 j = 0; j < actors.length; j++) {
                uint256 dep = vault.deposits(cid, actors[j]);
                if (dep == 0) continue;
                if (funding) {
                    sumNet += dep;
                } else {
                    uint256 premiumShare = uint256(c.premiumsCollected).mulDivDown(dep, total);
                    uint256 claimShare = uint256(c.claimsPaid).mulDivUp(dep, total);
                    uint256 credit = dep + premiumShare;
                    sumNet += credit > claimShare ? credit - claimShare : 0;
                }
            }
            uint256 rhs = total + uint256(c.premiumsCollected);
            uint256 spent = uint256(c.claimsPaid) + c.paidOut;
            rhs = rhs > spent ? rhs - spent : 0;
            assertLe(sumNet, rhs, "I6: redeemable net exceeds capital + premiums - claims");
            redeemable += sumNet;
        }
        for (uint256 j = 0; j < actors.length; j++) {
            redeemable += vault.unclaimed(actors[j]);
        }
        redeemable += vault.keeperBudget();
        assertLe(
            redeemable, token.balanceOf(address(vault)), "I6: redeemable exceeds vault balance"
        );
    }

    // ------------------------------------------------------------------
    // I7 — a resolved (SETTLED) cohort has every policy in a final status and zero
    //      capital still reserved.
    // ------------------------------------------------------------------
    function invariant_I7_resolvedImpliesAllFinal() public view {
        uint256 n = vault.policyCount();
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            if (vault.statusOf(cid) != ICoverVault.Status.SETTLED) continue;
            ICoverVault.Cohort memory c = vault.cohort(cid);
            assertEq(c.settledCount, c.policyCount, "I7: SETTLED but policies remain");
            assertEq(uint256(c.reserved), 0, "I7: SETTLED but capital still reserved");
            for (uint256 i = 0; i < n; i++) {
                ICoverVault.Policy memory p = vault.policy(i);
                if (p.cohortId != cid) continue;
                assertTrue(p.status != ICoverVault.PolicyStatus.Active, "I7: live policy");
            }
        }
    }

    // ------------------------------------------------------------------
    // I8 — every Active policy's NFT is held by the vault, and every policy is attached
    //      to a real position of this vault's pool.
    // ------------------------------------------------------------------
    function invariant_I8_activePolicyNftInVault() public view {
        uint256 n = vault.policyCount();
        for (uint256 i = 0; i < n; i++) {
            ICoverVault.Policy memory p = vault.policy(i);
            assertTrue(p.positionTokenId != 0, "I8: policy has zero position id");
            (,, address t0, address t1, uint24 f,,,,,,,) = pm.positions(p.positionTokenId);
            assertEq(t0, pool.token0(), "I8: position token0 mismatch");
            assertEq(t1, pool.token1(), "I8: position token1 mismatch");
            assertEq(uint256(f), uint256(pool.fee()), "I8: position fee mismatch");
            if (p.status == ICoverVault.PolicyStatus.Active) {
                assertEq(pm.ownerOf(p.positionTokenId), address(vault), "I8: NFT not in vault");
            }
        }
    }

    // ------------------------------------------------------------------
    // Escrow surface (R14/R15, plan "Masuknya NFT"): no unsolicited NFT accepted, no
    // stranger collects fees, the owner always receives exactly the fees owed.
    // ------------------------------------------------------------------
    function invariant_Escrow_SurfaceClosed() public view {
        assertFalse(handler.escrowViolated(), "escrow: unsolicited NFT / stranger collect");
        assertFalse(handler.feeViolated(), "escrow: fees not delivered exactly");
    }

    // ------------------------------------------------------------------
    // Liveness (plan U8 afterInvariant): whatever the run did, once time passes every
    // endsAt, every cohort can be fully resolved, every underwriter can withdraw, every
    // parked payout and NFT can be claimed — and then the vault owes exactly its keeper
    // budget.
    // ------------------------------------------------------------------
    function afterInvariant() public {
        _aggregateCallSummary();

        pm.setTransferFails(false);
        token.setRejectTransfersTo(address(rejector), false);
        uint256 end = uint256(vault.endsAt(maxCid)) + 1;
        if (vm.getBlockTimestamp() < end) vm.warp(end);

        for (uint32 cid = 0; cid <= maxCid; cid++) {
            if (vault.statusOf(cid) != ICoverVault.Status.SETTLING) continue;
            if (vault.cohort(cid).policyCount == 0) {
                vault.finalize(cid);
            } else {
                for (
                    uint256 k = 0;
                    k < 64 && vault.statusOf(cid) != ICoverVault.Status.SETTLED;
                    k++
                ) {
                    vault.settleBatch(cid, 4);
                }
            }
            assertEq(
                uint256(vault.statusOf(cid)),
                uint256(ICoverVault.Status.SETTLED),
                "liveness: cohort cannot resolve"
            );
        }

        address[] memory actors = handler.actorsList();
        for (uint32 cid = 0; cid <= maxCid; cid++) {
            for (uint256 j = 0; j < actors.length; j++) {
                if (vault.deposits(cid, actors[j]) == 0) continue;
                vm.prank(actors[j]);
                vault.withdraw(cid);
            }
        }
        for (uint256 j = 0; j < actors.length; j++) {
            if (vault.unclaimed(actors[j]) == 0) continue;
            vm.prank(actors[j]);
            vault.claimUnclaimed();
            assertEq(vault.unclaimed(actors[j]), 0, "liveness: unclaimed left");
        }
        uint256 n = vault.policyCount();
        for (uint256 pid = 0; pid < n; pid++) {
            ICoverVault.Policy memory p = vault.policy(pid);
            assertTrue(p.status != ICoverVault.PolicyStatus.Active, "liveness: live policy");
            if (!p.nftParked) continue;
            vm.prank(p.owner);
            vault.claimPosition(pid);
        }

        // Every NFT is home; nothing but the keeper budget is still owed.
        uint256[] memory ids = handler.tokensList();
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(pm.ownerOf(ids[i]), handler.nftOwner(ids[i]), "liveness: NFT not home");
        }
        Obligations.Report memory r = Obligations.compute(vault, maxCid, actors);
        assertEq(r.owed, vault.keeperBudget(), "liveness: obligations beyond keeper budget");
        assertEq(r.vaultCounter, r.owed, "liveness: counter drift");
        assertGe(r.balance, r.owed, "liveness: insolvent at the end");
    }

    /// @dev Call summary aggregated over every run of the campaign (plan U8: show each
    ///      action is reached). Each run starts from the setUp snapshot, so the running
    ///      totals ride on process environment variables (diagnostic only; nothing is
    ///      asserted on them). The last run's log (-vv) holds the campaign totals:
    ///      `name calls effective`, where effective = the action changed state.
    function _aggregateCallSummary() internal {
        (bytes32[] memory names, uint256[] memory called, uint256[] memory ok) = handler.summary();
        for (uint256 i = 0; i < names.length; i++) {
            string memory key = string.concat("ARUNA_INV_", vm.toString(names[i]));
            string memory keyC = string.concat(key, "_C");
            uint256 tc = vm.envOr(keyC, uint256(0)) + called[i];
            uint256 to = vm.envOr(key, uint256(0)) + ok[i];
            vm.setEnv(keyC, vm.toString(tc));
            vm.setEnv(key, vm.toString(to));
        }
        string memory runs = "ARUNA_INV_RUNS";
        uint256 r = vm.envOr(runs, uint256(0)) + 1;
        vm.setEnv(runs, vm.toString(r));
        console.log("-- CoverVaultHandler call summary over runs:", r, "(calls / effective) --");
        bytes32[35] memory all = [
            bytes32("warp"),
            "warpCalendar",
            "poke",
            "deposit",
            "withdraw",
            "rollTo",
            "rollTo_n+1",
            "rollTo_late_n+2",
            "buyCover",
            "cancel",
            "collectFees",
            "increaseLiquidity",
            "unsolicitedNft",
            "claimPosition",
            "claimUnclaimed",
            "finalize",
            "keeperFinalize",
            "settlePolicy",
            "settleBatch",
            "keeperPoke",
            "fundKeeper",
            "donate",
            "toggleTokenRejection",
            "toggleNftTransferFail",
            "~outcome:settled",
            "~outcome:paid",
            "~outcome:refund",
            "~outcome:payoutParked",
            "~outcome:nftParked",
            "~outcome:residualSwept",
            "~buy:notActive",
            "~buy:late",
            "~buy:nocap",
            "~buy:cap",
            "~buy:revert"
        ];
        for (uint256 i = 0; i < all.length && all[i] != bytes32(0); i++) {
            string memory key = string.concat("ARUNA_INV_", vm.toString(all[i]));
            console.log(
                handler.nameOf(all[i]),
                vm.envOr(string.concat(key, "_C"), uint256(0)),
                vm.envOr(key, uint256(0))
            );
        }
    }
}

/// @title CoverVaultInvariantsDirected
/// @notice Deterministic companions of the campaign: the I3 non-vacuity proof (SC-01) and
///         full lifecycle walks with exact numbers, so a regression that quietly stopped
///         reaching ACTIVE / SETTLING would fail here even while the invariants stayed green.
contract CoverVaultInvariantsDirected is InvariantBase {
    using Math for uint256;

    function setUp() public {
        _deploy();
    }

    // ==================================================================
    // Non-vacuity of I3 (plan U8 execution note): the new form is run against a vault
    // that carries the v0 SC-01 bug and must FAIL there, while the old conservation form
    // (balance == in − out) stays green on the very same state.
    // ==================================================================

    function test_I3_NewForm_CatchesSC01_OnV0Harness() public {
        CoverVaultV0Sc01 bug = new CoverVaultV0Sc01(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token)
        );
        (uint256 inn, uint256 out) = _sc01Sequence(CoverVault(address(bug)), true);

        address[] memory holders = _sc01Holders();
        Obligations.Report memory r = Obligations.compute(CoverVault(address(bug)), 3, holders);
        // Old I3: conservation holds — it never looked at the books.
        assertEq(r.balance, inn - out, "old I3 form (conservation) is green on SC-01");
        // The vault's own counter is self-consistent too...
        assertGe(r.balance, r.vaultCounter, "self-referential counter is green on SC-01");
        // ...but the books still carry the 5_000 that left: the new I3 form fails.
        assertEq(vault.cohort(1).totalCapital, 0, "fresh vault untouched");
        assertEq(CoverVault(address(bug)).cohort(1).totalCapital, 15_000e6, "phantom capital");
        assertEq(r.balance, 10_000e6, "only 10k really held");
        assertEq(r.owed, 15_000e6, "books say 15k owed");
        assertFalse(Obligations.solvent(r), "new I3 form must fail on the SC-01 bug");
    }

    function test_I3_NewForm_HoldsOnV2_SameSequence() public {
        (uint256 inn, uint256 out) = _sc01Sequence(vault, false);
        Obligations.Report memory r = Obligations.compute(vault, 3, _sc01Holders());
        assertEq(r.balance, inn - out, "conservation");
        assertEq(r.owed, 10_000e6, "books: only the 10k still deposited");
        assertEq(r.vaultCounter, r.owed, "counter agrees");
        assertTrue(Obligations.solvent(r), "v2 is solvent on the SC-01 sequence");
    }

    function _sc01Holders() internal pure returns (address[] memory h) {
        h = new address[](2);
        h[0] = address(0xD1);
        h[1] = address(0xD2);
    }

    /// @dev uw1 deposits 10k and uw2 5k into FUNDING cohort 1; uw2 withdraws in FUNDING.
    function _sc01Sequence(CoverVault v, bool v0) internal returns (uint256 inn, uint256 out) {
        address uw1 = address(0xD1);
        address uw2 = address(0xD2);
        token.mint(uw1, 10_000e6);
        token.mint(uw2, 5_000e6);
        vm.prank(uw1);
        token.approve(address(v), type(uint256).max);
        vm.prank(uw2);
        token.approve(address(v), type(uint256).max);
        vm.prank(uw1);
        v.deposit(1, 10_000e6);
        vm.prank(uw2);
        v.deposit(1, 5_000e6);
        inn = 15_000e6;
        vm.prank(uw2);
        if (v0) CoverVaultV0Sc01(address(v)).withdrawV0(1);
        else v.withdraw(1);
        out = token.balanceOf(uw2);
    }

    // ==================================================================
    // Directed lifecycle tests — proof the fuzzed suite is not vacuous.
    // ==================================================================

    address internal constant UNDERWRITER = address(0xBEEF);
    address internal constant BUYER = address(0xCAFE);

    /// @notice Variance crosses a zero strike -> a real payout is pushed to the buyer,
    ///         and the lone underwriter redeems capital + premium - claim, to the wei.
    function test_Lifecycle_PayoutHappens() public {
        uint32 cid = 1;
        uint64 startsAt = ANCHOR + uint64(cid) * (TENOR + GAP); // 1_691_200
        uint64 endsAt = startsAt + TENOR; //                      2_296_000

        uint128 capital = 10_000;
        token.mint(UNDERWRITER, capital);
        vm.prank(UNDERWRITER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(UNDERWRITER);
        vault.deposit(cid, capital);

        // Move to ACTIVE and sell cover: varNotional 1000 -> maxPayout 1000, strike 0.
        vm.warp(startsAt);
        _buyAsBuyer(cid, startsAt);
        assertEq(uint256(vault.cohort(cid).reserved), 1_000, "reserved == maxPayout at buy");

        // The buy's poke sampled at startsAt (j); +1800 is the baseline s. Realized
        // variance after s reaches 5e17 at a timestamp <= endsAt, over 2 returns.
        acc.push(uint32(startsAt + 1_800), 0);
        acc.push(uint32(startsAt + 3_600), uint128(25e16));
        vm.warp(2_000_000);
        acc.push(uint32(2_000_000), uint128(5e17));

        vm.warp(endsAt);
        vault.finalize(cid);
        assertEq(
            uint256(vault.statusOf(cid)),
            uint256(ICoverVault.Status.SETTLING),
            "SETTLING after finalize"
        );
        vault.settleBatch(cid, 1);

        // payout = varNotional * (5e17 - 0) / WAD = 1000 * 5e17 / 1e18 = 500.
        assertEq(token.balanceOf(BUYER), 500, "buyer received 500 payout");
        assertEq(uint256(vault.cohort(cid).claimsPaid), 500, "claimsPaid == 500");
        assertEq(
            uint256(vault.statusOf(cid)),
            uint256(ICoverVault.Status.SETTLED),
            "SETTLED after last batch"
        );
        assertEq(uint256(vault.cohort(cid).reserved), 0, "reserved released to 0");

        // Keeper cut (U6): 100 × 10% = 10 leaves the premium pool; the settle bounty
        // min(5, 10) went to this caller, 5 stays in the budget.
        // Underwriter net = 10000 + premiumShare(90) - claimShare(500) = 9590.
        vm.prank(UNDERWRITER);
        uint256 net = vault.withdraw(cid);
        assertEq(net, 9_590, "underwriter net == 9590");

        assertEq(token.balanceOf(address(this)), 5, "settle bounty to caller");
        assertEq(vault.keeperBudget(), 5, "budget keeps the rest of the cut");
        assertEq(token.balanceOf(address(vault)), 5, "only the keeper budget remains");
    }

    /// @notice Quiet market: cumulativeSumSq never rises, so no policy pays and the
    ///         underwriter keeps capital plus the full premium.
    function test_Lifecycle_NoVariance_NoPayout() public {
        uint32 cid = 1;
        uint64 startsAt = ANCHOR + uint64(cid) * (TENOR + GAP);
        uint64 endsAt = startsAt + TENOR;

        uint128 capital = 10_000;
        token.mint(UNDERWRITER, capital);
        vm.prank(UNDERWRITER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(UNDERWRITER);
        vault.deposit(cid, capital);

        vm.warp(startsAt);
        _buyAsBuyer(cid, startsAt);

        acc.push(uint32(startsAt + 1_800), 0);
        acc.push(uint32(startsAt + 3_600), 0);
        acc.push(uint32(startsAt + 5_400), 0);
        vm.warp(endsAt);
        vault.finalize(cid);
        vault.settleBatch(cid, 1);

        assertEq(token.balanceOf(BUYER), 0, "no variance => no payout");
        assertEq(uint256(vault.cohort(cid).claimsPaid), 0, "claimsPaid == 0");
        assertEq(uint256(vault.statusOf(cid)), uint256(ICoverVault.Status.SETTLED), "SETTLED");

        vm.prank(UNDERWRITER);
        uint256 net = vault.withdraw(cid);
        assertEq(net, 10_090, "underwriter keeps capital + premium net of the keeper cut");
        assertEq(token.balanceOf(address(vault)), vault.keeperBudget(), "only budget remains");
    }

    function _buyAsBuyer(uint32 cid, uint64 startsAt) internal {
        pricer.setPremium(100);
        pm.setOwner(1, BUYER);
        pm.setPosition(1, -600, 600, 1_000); // real valuer: varNotional == 1000
        token.mint(BUYER, 100);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        pm.approve(address(vault), 1);
        vm.prank(BUYER);
        vault.buyCover(cid, 1, uint64(0), 100, uint64(startsAt + 1));
    }
}
