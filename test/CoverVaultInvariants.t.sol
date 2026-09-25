// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {Math} from "../src/libraries/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";

/// @title CoverVaultHandler
/// @notice Bounded actor that drives ONE CoverVault through its whole cohort lifecycle
///         under fuzzed calls: deposit (FUNDING) → buyCover (ACTIVE) → finalize →
///         settleBatch (SETTLING) → withdraw (FUNDING/SETTLED), plus poke/warp to march
///         the oracle and the calendar. Every action guards its own preconditions and
///         returns quietly when they do not hold, so `fail_on_revert = false` discards
///         nothing meaningful. Money that enters and leaves is mirrored on ghost totals
///         (ghostIn/ghostOut) sourced from OPPOSITE sides — amounts the handler passes IN
///         vs. amounts the vault reports paying OUT — so I3's conservation check cannot
///         collapse into a tautology.
contract CoverVaultHandler is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    CoverVault public immutable vault;
    MockERC20 public immutable token;
    MockAccumulator public immutable acc;
    MockPricer public immutable pricer;
    MockValuer public immutable valuer;
    MockPositionManager public immutable pm;

    uint64 internal immutable anchor;
    uint32 internal immutable tenor;
    uint16 internal immutable maxUtilBps;

    address[] internal _actors;
    uint32[] internal _cohorts; // touched (deposited-into or bought-on) cohort ids
    mapping(uint32 => bool) internal _seen;

    // --- ghost accounting (read by the invariant_ functions) ---
    uint256 public ghostIn; // deposits + premiums pulled IN (amounts the handler paid)
    uint256 public ghostOut; // withdraw net + claims paid + claimUnclaimed (vault-reported)
    mapping(uint32 => uint256) public ghostSumMaxPayout; // Σ policy.maxPayout per cohort (I2)
    bool public i4Violated; // set if any LP balance ever DROPPED across a settlement action

    uint256 internal _tokenCounter; // Uniswap position ids, always >= 1 (I8)
    uint128 internal _cumSq; // last cumulativeSumSq pushed to the oracle

    constructor(
        CoverVault vault_,
        MockERC20 token_,
        MockAccumulator acc_,
        MockPricer pricer_,
        MockValuer valuer_,
        MockPositionManager pm_,
        address[] memory actors_,
        uint64 anchor_,
        uint32 tenor_,
        uint16 maxUtilBps_,
        uint128 seededCumSq_
    ) {
        vault = vault_;
        token = token_;
        acc = acc_;
        pricer = pricer_;
        valuer = valuer_;
        pm = pm_;
        anchor = anchor_;
        tenor = tenor_;
        maxUtilBps = maxUtilBps_;
        _cumSq = seededCumSq_;

        for (uint256 i = 0; i < actors_.length; i++) {
            _actors.push(actors_[i]);
            vm.prank(actors_[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------
    // Views for the invariant contract
    // ------------------------------------------------------------------

    function actorsList() external view returns (address[] memory) {
        return _actors;
    }

    function cohortsList() external view returns (uint32[] memory) {
        return _cohorts;
    }

    // ------------------------------------------------------------------
    // Handler actions
    // ------------------------------------------------------------------

    /// @notice March wall-clock forward. via_ir caches TIMESTAMP within a frame, so the
    ///         invariant runner (fresh frame per call) sees the advanced value next call.
    function warp(uint256 dtSeed) external {
        uint256 dt = bound(dtSeed, 1 hours, uint256(tenor) / 2 + 1);
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    /// @notice Append a monotonic oracle sample at `now` (delta >= 0). This is the only
    ///         thing that makes realized variance — and therefore payouts — non-trivial.
    function poke(uint256 deltaSeed) external {
        uint128 delta = uint128(bound(deltaSeed, 0, 1e15));
        _cumSq += delta; // never decreases -> MockAccumulator accepts it (I5)
        acc.push(uint32(vm.getBlockTimestamp()), _cumSq);
    }

    function deposit(uint256 actorSeed, uint256 cidSeed, uint256 amtSeed) external {
        address a = _actor(actorSeed);
        uint32 cid = uint32(bound(cidSeed, 0, 5));
        if (vault.statusOf(cid) != ICoverVault.Status.FUNDING) return;

        uint128 amt = uint128(bound(amtSeed, 1e6, 1e12));
        token.mint(a, amt);
        vm.prank(a);
        try vault.deposit(cid, amt) {
            ghostIn += amt;
            _touch(cid);
        } catch {}
    }

    function buyCover(
        uint256 actorSeed,
        uint256 cidSeed,
        uint256 vnSeed,
        uint256 premSeed,
        uint256 strikeSeed
    ) external {
        address a = _actor(actorSeed);
        uint32 cid = uint32(bound(cidSeed, 0, 5));
        if (vault.statusOf(cid) != ICoverVault.Status.ACTIVE) return;

        ICoverVault.Cohort memory c = vault.cohort(cid);
        if (vm.getBlockTimestamp() >= c.endsAt) return;
        if (c.totalCapital == 0 || acc.sampleCount() == 0) return;

        // Room under the utilization cap. maxExcessVariance == WAD in this suite, so
        // maxPayout == varNotional; picking varNotional <= room guarantees capacity.
        uint256 available = uint256(c.totalCapital).mulDivDown(maxUtilBps, BPS);
        if (available <= c.reserved) return;
        uint256 room = available - c.reserved;

        uint128 vn = uint128(bound(vnSeed, 1, room));
        valuer.setVarNotional(vn);

        uint128 premium = uint128(bound(premSeed, 0, 1e9));
        pricer.setPremium(premium);
        token.mint(a, premium);

        uint64 strike = uint64(bound(strikeSeed, 0, uint64(WAD / 2)));
        uint256 tokenId = ++_tokenCounter; // >= 1 always (I8)
        pm.setOwner(tokenId, a);

        vm.prank(a);
        try vault.buyCover(cid, tokenId, strike, premium, uint64(vm.getBlockTimestamp() + 1)) returns (
            uint256 pid
        ) {
            ghostIn += premium;
            ghostSumMaxPayout[cid] += vault.policy(pid).maxPayout;
            _touch(cid);
        } catch {}
    }

    function finalize(uint256 cidSeed) external {
        uint32 cid = uint32(bound(cidSeed, 0, 5));
        ICoverVault.Cohort memory c = vault.cohort(cid);
        if (c.endsAt == 0 || vm.getBlockTimestamp() < c.endsAt) return;
        if (c.status != ICoverVault.Status.FUNDING) return; // already finalized

        uint256[] memory before = _snapshot();
        try vault.finalize(cid) {} catch {}
        _checkNoDebit(before);
    }

    function settleBatch(uint256 cidSeed, uint256 nSeed) external {
        uint32 cid = uint32(bound(cidSeed, 0, 5));
        if (vault.cohort(cid).status != ICoverVault.Status.SETTLING) return;

        uint32 n = uint32(bound(nSeed, 1, 8));
        uint128 paidBefore = vault.cohort(cid).claimsPaid;
        uint256[] memory before = _snapshot();
        try vault.settleBatch(cid, n) {
            uint128 paidAfter = vault.cohort(cid).claimsPaid;
            ghostOut += (paidAfter - paidBefore); // tokens pushed to LP owners
        } catch {}
        _checkNoDebit(before);
    }

    function withdraw(uint256 actorSeed, uint256 cidSeed) external {
        address a = _actor(actorSeed);
        uint32 cid = uint32(bound(cidSeed, 0, 5));
        ICoverVault.Status s = vault.statusOf(cid);
        if (s != ICoverVault.Status.FUNDING && s != ICoverVault.Status.SETTLED) return;
        if (vault.deposits(cid, a) == 0) return;

        uint256[] memory before = _snapshot();
        vm.prank(a);
        try vault.withdraw(cid) returns (uint256 net) {
            ghostOut += net;
        } catch {}
        _checkNoDebit(before); // a withdrawer is only ever credited, never debited
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _touch(uint32 cid) internal {
        if (!_seen[cid]) {
            _seen[cid] = true;
            _cohorts.push(cid);
        }
    }

    function _snapshot() internal view returns (uint256[] memory bal) {
        bal = new uint256[](_actors.length);
        for (uint256 i = 0; i < _actors.length; i++) {
            bal[i] = token.balanceOf(_actors[i]);
        }
    }

    /// @dev I4: no settlement/withdraw path may ever take tokens FROM an LP. Recorded on
    ///      a ghost flag rather than asserted here, because a bare assert inside a
    ///      handler call would be swallowed by fail_on_revert = false.
    function _checkNoDebit(uint256[] memory before) internal {
        for (uint256 i = 0; i < _actors.length; i++) {
            if (token.balanceOf(_actors[i]) < before[i]) i4Violated = true;
        }
    }
}

/// @title CoverVaultInvariants
/// @notice The §9.1 property suite (I1–I8). Each invariant_ function names the exact
///         design property it pins; none tests an invented one. Where §9.2's rounding
///         asymmetry is what makes a property hold, the check replicates the vault's
///         own mulDivUp/mulDivDown directions (I6) rather than re-deriving them.
contract CoverVaultInvariants is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    uint64 internal constant ANCHOR = 1_000_000;
    uint32 internal constant TENOR = 604_800; // 7 days
    uint16 internal constant MAX_UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS_VARIANCE = uint128(WAD); // maxPayout == varNotional
    uint16 internal constant EWMA_ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VARIANCE = uint128(WAD / 10);
    uint128 internal constant SEED_CUMSQ = 0;

    CoverVault internal vault;
    MockERC20 internal token;
    MockAccumulator internal acc;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockPricer internal pricer;
    MockValuer internal valuer;
    CoverVaultHandler internal handler;

    function setUp() public {
        // Start the clock at the anchor: cohort 0 is exactly ACTIVE, cohorts >=1 FUNDING.
        vm.warp(ANCHOR);

        token = new MockERC20(6);
        acc = new MockAccumulator();
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        pricer = new MockPricer();
        valuer = new MockValuer();

        // The pool reports (token0, token1, fee) = (0, 0, 3000); make every position match
        // so _requirePositionMatchesPool never gates the fuzzer artificially (I8).
        pm.setPool(pool.token0(), pool.token1(), pool.fee());

        // Seed one oracle sample at the anchor so finalize() always finds a sample
        // at-or-before any cohort's endsAt.
        acc.push(uint32(ANCHOR), SEED_CUMSQ);

        vault = new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            TENOR,
            ANCHOR,
            MAX_UTIL_BPS,
            MAX_EXCESS_VARIANCE,
            EWMA_ALPHA_BPS,
            SEED_VARIANCE
        );

        address[] memory actors = new address[](3);
        actors[0] = address(uint160(0xA11CE0));
        actors[1] = address(uint160(0xA11CE1));
        actors[2] = address(uint160(0xA11CE2));

        handler = new CoverVaultHandler(
            vault, token, acc, pricer, valuer, pm, actors, ANCHOR, TENOR, MAX_UTIL_BPS, SEED_CUMSQ
        );

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // I1 — reserved never exceeds the utilization cap on an ACTIVE cohort.
    //      (§9.1: capital at risk is bounded by maxUtilizationBps of the pool.)
    // ------------------------------------------------------------------
    function invariant_I1_reservedWithinUtilization() public view {
        uint32[] memory cs = handler.cohortsList();
        for (uint256 i = 0; i < cs.length; i++) {
            uint32 cid = cs[i];
            if (vault.statusOf(cid) != ICoverVault.Status.ACTIVE) continue;
            ICoverVault.Cohort memory c = vault.cohort(cid);
            uint256 cap = uint256(c.totalCapital).mulDivDown(MAX_UTIL_BPS, BPS);
            assertLe(uint256(c.reserved), cap, "I1: reserved exceeds utilization cap");
        }
    }

    // ------------------------------------------------------------------
    // I2 — a cohort can never pay out more in claims than the sum of the maxPayouts
    //      it sold. (§9.1: claims bounded by written cover.)
    // ------------------------------------------------------------------
    function invariant_I2_claimsPaidWithinMaxPayout() public view {
        uint32[] memory cs = handler.cohortsList();
        for (uint256 i = 0; i < cs.length; i++) {
            uint32 cid = cs[i];
            assertLe(
                uint256(vault.cohort(cid).claimsPaid),
                handler.ghostSumMaxPayout(cid),
                "I2: claimsPaid exceeds sum of maxPayout sold"
            );
        }
    }

    // ------------------------------------------------------------------
    // I3 — solvency. §9.1 states balance >= obligations; this pins the stronger exact
    //      form: the vault's token balance equals everything paid in minus everything
    //      paid out. Rounding dust (premiumShare DOWN vs claimShare UP) is never
    //      withdrawn, so it simply remains inside balanceOf — captured by equality, not
    //      leaked. ghostIn is what the handler paid; ghostOut is what the vault reported
    //      paying — independent sources, so this is not self-referential.
    // ------------------------------------------------------------------
    function invariant_I3_solvencyConservation() public view {
        uint256 inn = handler.ghostIn();
        uint256 out = handler.ghostOut();
        assertGe(inn, out, "I3: more left than ever entered");
        assertEq(token.balanceOf(address(vault)), inn - out, "I3: vault balance != in - out");
    }

    // ------------------------------------------------------------------
    // I4 — once cover is bought, no settlement or withdrawal ever debits an LP's wallet.
    //      (§9.1: underwriters bear loss only up to deposited capital; buyers are never
    //      clawed back.) Recorded on a ghost flag inside the handler.
    // ------------------------------------------------------------------
    function invariant_I4_noClawbackFromLPs() public view {
        assertFalse(handler.i4Violated(), "I4: a settlement path debited an LP wallet");
    }

    // ------------------------------------------------------------------
    // I5 — cumulativeSumSq is monotonically non-decreasing. The payout math relies on
    //      endSumSq >= startSumSq; re-scan every sample rather than trust the mock.
    // ------------------------------------------------------------------
    function invariant_I5_cumulativeSumSqMonotonic() public view {
        uint32 n = acc.sampleCount();
        for (uint32 i = 1; i < n; i++) {
            assertGe(
                uint256(acc.sampleAt(i).cumulativeSumSq),
                uint256(acc.sampleAt(i - 1).cumulativeSumSq),
                "I5: cumulativeSumSq decreased"
            );
        }
    }

    // ------------------------------------------------------------------
    // I6 — no money creation. The sum of every underwriter's redeemable net across a
    //      cohort never exceeds that cohort's capital plus premiums minus claims paid.
    //      Replicates _accountFor EXACTLY (premiumShare DOWN, claimShare UP) so the
    //      §9.2 rounding asymmetry that makes this hold is honored, not re-invented.
    // ------------------------------------------------------------------
    function invariant_I6_noMoneyCreated() public view {
        address[] memory actors = handler.actorsList();
        uint32[] memory cs = handler.cohortsList();
        for (uint256 i = 0; i < cs.length; i++) {
            uint32 cid = cs[i];
            ICoverVault.Cohort memory c = vault.cohort(cid);
            uint256 total = c.totalCapital;
            if (total == 0) continue;

            ICoverVault.Status s = vault.statusOf(cid);
            uint256 sumNet;
            for (uint256 j = 0; j < actors.length; j++) {
                uint256 dep = vault.deposits(cid, actors[j]);
                if (dep == 0) continue;
                if (s == ICoverVault.Status.FUNDING) {
                    sumNet += dep;
                } else {
                    uint256 premiumShare = uint256(c.premiumsCollected).mulDivDown(dep, total);
                    uint256 claimShare = uint256(c.claimsPaid).mulDivUp(dep, total);
                    uint256 credit = dep + premiumShare;
                    sumNet += credit > claimShare ? credit - claimShare : 0;
                }
            }

            uint256 rhs = total + uint256(c.premiumsCollected);
            uint256 claims = c.claimsPaid;
            rhs = rhs > claims ? rhs - claims : 0;
            assertLe(sumNet, rhs, "I6: redeemable net exceeds capital + premiums - claims");
        }
    }

    // ------------------------------------------------------------------
    // I7 — a SETTLED cohort has every policy settled and zero capital still reserved.
    //      Uses the STORED status (the terminal flag), not the time-derived one.
    // ------------------------------------------------------------------
    function invariant_I7_settledImpliesFullyPaidAndUnreserved() public view {
        uint32[] memory cs = handler.cohortsList();
        for (uint256 i = 0; i < cs.length; i++) {
            ICoverVault.Cohort memory c = vault.cohort(cs[i]);
            if (c.status != ICoverVault.Status.SETTLED) continue;
            assertEq(c.settledCount, c.policyCount, "I7: SETTLED but policies remain");
            assertEq(uint256(c.reserved), 0, "I7: SETTLED but capital still reserved");
        }
    }

    // ------------------------------------------------------------------
    // I8 — every policy is attached to a real position whose (token0, token1, fee)
    //      matches this vault's pool, and carries a non-zero token id. Ownership is a
    //      buy-time precondition (checked in buyCover), NOT a standing invariant, so it
    //      is deliberately not asserted here.
    // ------------------------------------------------------------------
    function invariant_I8_everyPolicyAttachedToPool() public view {
        uint256 n = vault.policyCount();
        for (uint256 i = 0; i < n; i++) {
            ICoverVault.Policy memory p = vault.policy(i);
            assertTrue(p.positionTokenId != 0, "I8: policy has zero position id");
            (,, address t0, address t1, uint24 f,,,,,,,) = pm.positions(p.positionTokenId);
            assertEq(t0, pool.token0(), "I8: position token0 mismatch");
            assertEq(t1, pool.token1(), "I8: position token1 mismatch");
            assertEq(uint256(f), uint256(pool.fee()), "I8: position fee mismatch");
        }
    }

    // ==================================================================
    // Directed lifecycle tests — proof the fuzzed suite is not vacuous.
    // They walk the whole path deterministically (deposit -> buyCover ->
    // finalize -> settleBatch -> withdraw) and assert exact settlement
    // numbers, so a regression that quietly stopped reaching ACTIVE/
    // SETTLING would fail here even while the invariants stayed green.
    // ==================================================================

    address internal constant UNDERWRITER = address(0xBEEF);
    address internal constant BUYER = address(0xCAFE);

    /// @notice Variance crosses a zero strike -> a real payout is pushed to the buyer,
    ///         and the lone underwriter redeems capital + premium - claim, to the wei.
    function test_Lifecycle_PayoutHappens() public {
        uint32 cid = 1;
        uint64 startsAt = ANCHOR + uint64(cid) * TENOR; // 1_604_800
        uint64 endsAt = startsAt + TENOR; //               2_209_600

        // Underwriter funds the cohort while it is FUNDING.
        uint128 capital = 10_000;
        token.mint(UNDERWRITER, capital);
        vm.prank(UNDERWRITER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(UNDERWRITER);
        vault.deposit(cid, capital);

        // Move to ACTIVE and sell cover: varNotional 1000 -> maxPayout 1000, strike 0.
        vm.warp(startsAt);
        valuer.setVarNotional(1_000);
        pricer.setPremium(100);
        pm.setOwner(1, BUYER);
        token.mint(BUYER, 100);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        vault.buyCover(cid, 1, uint64(0), 100, uint64(startsAt + 1));
        assertEq(uint256(vault.cohort(cid).reserved), 1_000, "reserved == maxPayout at buy");

        // Accumulate realized variance to 5e17 at a timestamp <= endsAt.
        vm.warp(2_000_000);
        acc.push(uint32(2_000_000), uint128(5e17));

        // Expire, finalize (-> SETTLING), settle the single policy.
        vm.warp(endsAt);
        vault.finalize(cid);
        assertEq(uint256(vault.statusOf(cid)), uint256(ICoverVault.Status.SETTLING), "SETTLING after finalize");
        vault.settleBatch(cid, 1);

        // payout = varNotional * (5e17 - 0) / WAD = 1000 * 5e17 / 1e18 = 500.
        assertEq(token.balanceOf(BUYER), 500, "buyer received 500 payout");
        assertEq(uint256(vault.cohort(cid).claimsPaid), 500, "claimsPaid == 500");
        assertEq(uint256(vault.statusOf(cid)), uint256(ICoverVault.Status.SETTLED), "SETTLED after last batch");
        assertEq(uint256(vault.cohort(cid).reserved), 0, "reserved released to 0");

        // Underwriter net = 10000 + premiumShare(100) - claimShare(500) = 9600.
        vm.prank(UNDERWRITER);
        uint256 net = vault.withdraw(cid);
        assertEq(net, 9_600, "underwriter net == 9600");

        // In (10000 + 100) == out (500 + 9600): no dust in this clean case.
        assertEq(token.balanceOf(address(vault)), 0, "vault emptied exactly");
    }

    /// @notice Quiet market: cumulativeSumSq never rises, so no policy pays and the
    ///         underwriter keeps capital plus the full premium.
    function test_Lifecycle_NoVariance_NoPayout() public {
        uint32 cid = 1;
        uint64 startsAt = ANCHOR + uint64(cid) * TENOR;
        uint64 endsAt = startsAt + TENOR;

        uint128 capital = 10_000;
        token.mint(UNDERWRITER, capital);
        vm.prank(UNDERWRITER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(UNDERWRITER);
        vault.deposit(cid, capital);

        vm.warp(startsAt);
        valuer.setVarNotional(1_000);
        pricer.setPremium(100);
        pm.setOwner(1, BUYER);
        token.mint(BUYER, 100);
        vm.prank(BUYER);
        token.approve(address(vault), type(uint256).max);
        vm.prank(BUYER);
        vault.buyCover(cid, 1, uint64(0), 100, uint64(startsAt + 1));

        // No new oracle samples -> sumSqCovered stays 0 -> payout 0.
        vm.warp(endsAt);
        vault.finalize(cid);
        vault.settleBatch(cid, 1);

        assertEq(token.balanceOf(BUYER), 0, "no variance => no payout");
        assertEq(uint256(vault.cohort(cid).claimsPaid), 0, "claimsPaid == 0");
        assertEq(uint256(vault.statusOf(cid)), uint256(ICoverVault.Status.SETTLED), "SETTLED");

        vm.prank(UNDERWRITER);
        uint256 net = vault.withdraw(cid);
        assertEq(net, 10_100, "underwriter keeps capital + full premium");
        assertEq(token.balanceOf(address(vault)), 0, "vault emptied exactly");
    }
}
