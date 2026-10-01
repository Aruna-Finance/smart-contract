// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {Math} from "../src/libraries/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";
import {Calendar} from "./utils/Calendar.sol";

/// @title CoverVaultKeeperTest
/// @notice Plan U6: keeper budget and bounties — the cut taken after endsAt (measured at
///         settle, cancelled once at finalize, never on refunds), permissionless funding,
///         and wrappers that pay min(bounty, budget) only when state changed (AE10, SC-10).
contract CoverVaultKeeperTest is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    uint32 internal constant TENOR = 7 days;
    uint32 internal constant GAP = 1 days;
    uint32 internal constant INTERVAL = 6 hours;
    uint64 internal constant ANCHOR = 2_000_000;
    uint16 internal constant UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS = uint128(WAD); // maxPayout == varNotional
    uint16 internal constant ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VAR = uint128(WAD / 10);
    uint32 internal constant POLICY_CAP = 10; // capacity 8_000e6 → min maxPayout 800e6

    uint16 internal constant KEEPER_BPS = 1_000; // 10%
    uint128 internal constant POKE_BOUNTY = 1e6;
    uint128 internal constant FINALIZE_BOUNTY = 2e6;
    uint128 internal constant SETTLE_BOUNTY = 3e6;

    uint32 internal constant C = 1;
    uint128 internal constant CAPITAL = 10_000e6;
    uint128 internal constant VN = 800e6; // the minimum policy
    uint128 internal constant PREMIUM = 100e6; // cut = 10e6 > SETTLE_BOUNTY
    uint128 internal constant SKIM = 10e6;

    MockERC20 internal token;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockPricer internal pricer;
    MockValuer internal valuer;
    MockAccumulator internal acc;
    CoverVault internal vault;

    address internal uw = address(0xA1);
    address internal lp = address(0xB1);
    address internal keeper = address(0x4EE9);
    address internal donor = address(0xD0);
    uint256 internal nextTokenId = 1;

    uint32 internal lastTs;
    uint128 internal cum;

    function setUp() public {
        token = new MockERC20(6);
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        pm.setPool(address(0), address(0), 3000);
        pricer = new MockPricer();
        pricer.setPremium(PREMIUM);
        valuer = new MockValuer();
        valuer.setVarNotional(VN);
        acc = new MockAccumulator();
        acc.setSampleInterval(INTERVAL);
        vault = _newVault(TENOR);
        _fundAndApprove(uw, vault);
        _fundAndApprove(lp, vault);
        _fundAndApprove(donor, vault);
        vm.warp(ANCHOR - 1 days);
    }

    // =====================================================================
    // AE10 — no state change, no bounty
    // =====================================================================

    /// @notice AE10: a poke before the interval elapsed adds no sample and pays nothing.
    function test_AE10_PokeBeforeInterval_NoBounty() public {
        _fund(100e6);
        vm.prank(keeper);
        (bool sampled, uint256 bounty) = vault.keeperPoke();
        assertTrue(sampled);
        assertEq(bounty, POKE_BOUNTY);

        vm.warp(vm.getBlockTimestamp() + INTERVAL - 1);
        uint256 budget = vault.keeperBudget();
        vm.prank(keeper);
        (sampled, bounty) = vault.keeperPoke();
        assertFalse(sampled, "throttled");
        assertEq(bounty, 0, "no bounty");
        assertEq(vault.keeperBudget(), budget, "budget untouched");
        assertEq(token.balanceOf(keeper), POKE_BOUNTY, "paid only once");
    }

    /// @notice AE10: finalize pays once per cohort; a re-finalize, a finalize after the
    ///         explicit/lazy path, or one before endsAt is a no-op without a bounty.
    function test_AE10_Refinalize_NoBounty() public {
        _fund(100e6);
        _depositTo(C, CAPITAL);
        _fillTo(_e(C));

        vm.warp(_e(C) - 1);
        vm.prank(keeper);
        (bool fin, uint256 bounty) = vault.keeperFinalize(C);
        assertFalse(fin, "before endsAt: no-op");
        assertEq(bounty, 0);

        vm.warp(_e(C));
        vm.prank(keeper);
        (fin, bounty) = vault.keeperFinalize(C);
        assertTrue(fin);
        assertEq(bounty, FINALIZE_BOUNTY);

        vm.prank(keeper);
        (fin, bounty) = vault.keeperFinalize(C);
        assertFalse(fin, "already final");
        assertEq(bounty, 0);
        assertEq(token.balanceOf(keeper), FINALIZE_BOUNTY, "one finalize bounty");
        assertEq(vault.keeperBudget(), 100e6 - FINALIZE_BOUNTY);

        // Finalized by the plain entry point first → the wrapper pays nothing.
        _depositTo(C + 1, CAPITAL);
        _fillTo(_e(C + 1));
        vm.warp(_e(C + 1));
        vault.finalize(C + 1);
        vm.prank(keeper);
        (fin, bounty) = vault.keeperFinalize(C + 1);
        assertFalse(fin);
        assertEq(bounty, 0);

        // A cohort that never held capital has nothing to finalize.
        vm.prank(keeper);
        (fin,) = vault.keeperFinalize(0);
        assertFalse(fin);
    }

    // =====================================================================
    // Poke bounty
    // =====================================================================

    function test_Poke_AfterInterval_PaysAndBudgetDecreases() public {
        _fund(10e6);
        vm.prank(keeper);
        vault.keeperPoke();
        vm.warp(vm.getBlockTimestamp() + INTERVAL);

        uint32 n = acc.sampleCount();
        vm.prank(keeper);
        (bool sampled, uint256 bounty) = vault.keeperPoke();
        assertTrue(sampled);
        assertEq(acc.sampleCount(), n + 1, "sample added");
        assertEq(bounty, POKE_BOUNTY);
        assertEq(vault.keeperBudget(), 10e6 - 2 * POKE_BOUNTY, "budget decreased");
        assertEq(token.balanceOf(keeper), 2 * POKE_BOUNTY);
        assertEq(vault.totalObligations(), vault.keeperBudget(), "budget is the obligation");
    }

    function test_Poke_PartialBudget_PaysRemainder() public {
        _fund(POKE_BOUNTY * 4 / 10);
        vm.prank(keeper);
        (, uint256 bounty) = vault.keeperPoke();
        assertEq(bounty, POKE_BOUNTY * 4 / 10, "remainder paid");
        assertEq(vault.keeperBudget(), 0);
    }

    function test_ZeroBudget_ActionsStillSucceed() public {
        vm.prank(keeper);
        (bool sampled, uint256 bounty) = vault.keeperPoke();
        assertTrue(sampled, "poke still samples");
        assertEq(bounty, 0);

        _depositTo(C, CAPITAL);
        vm.warp(_e(C));
        vm.prank(keeper);
        (bool fin, uint256 b2) = vault.keeperFinalize(C);
        assertTrue(fin, "finalize still happens");
        assertEq(b2, 0);
        assertEq(token.balanceOf(keeper), 0);
    }

    /// @notice Two tenors share one accumulator: in one interval only the first wrapper
    ///         call adds a sample, so only one poke bounty is paid.
    function test_SharedAccumulator_OnlyOnePokeBountyPerInterval() public {
        CoverVault vault14 = _newVault(14 days);
        _fundAndApprove(donor, vault14);
        _fund(10e6);
        vm.prank(donor);
        vault14.fundKeeperBudget(10e6);

        vm.prank(keeper);
        (bool s1, uint256 b1) = vault.keeperPoke();
        vm.prank(keeper);
        (bool s2, uint256 b2) = vault14.keeperPoke();
        assertTrue(s1);
        assertFalse(s2, "same interval: throttled");
        assertEq(b1 + b2, POKE_BOUNTY, "one bounty");
        assertEq(vault14.keeperBudget(), 10e6, "second vault paid nothing");
    }

    /// @notice A poke triggered by buyCover (poke-on-touch) pays nobody.
    function test_PokeOnTouch_PaysNothing() public {
        _fund(10e6);
        _depositTo(C, CAPITAL);
        _fillTo(_s(C) - INTERVAL); // last sample one interval before the buy → buy pokes
        vm.warp(_s(C));
        uint32 n = acc.sampleCount();
        _buy(lp);
        assertEq(acc.sampleCount(), n + 1, "buy poked");
        assertEq(vault.keeperBudget(), 10e6, "no bounty from a touch poke");
    }

    /// @notice Permissionless funding: a fresh vault's very first poke is paid; the
    ///         donor gets no claim (the amount is a pure obligation of the budget).
    function test_PermissionlessFunding_FirstPokePaid() public {
        uint256 donorBefore = token.balanceOf(donor);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ICoverVault.KeeperBudgetFunded(donor, 5e6);
        _fund(5e6);
        assertEq(token.balanceOf(donor), donorBefore - 5e6);
        assertEq(vault.keeperBudget(), 5e6);
        assertEq(vault.totalObligations(), 5e6);
        assertEq(vault.residual(), 0);

        vm.prank(keeper);
        (bool sampled, uint256 bounty) = vault.keeperPoke();
        assertTrue(sampled);
        assertEq(bounty, POKE_BOUNTY, "first poke of the vault paid");

        vm.expectRevert(CoverVault.BadConfig.selector);
        vault.fundKeeperBudget(0);
    }

    /// @notice A bounty push that fails keeps the amount in the budget; the action holds.
    function test_BountyTransferFails_KeptInBudget() public {
        _fund(10e6);
        token.setRejectTransfersTo(keeper, true);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ICoverVault.KeeperBountyFailed(keeper, ICoverVault.BountyKind.Poke, POKE_BOUNTY);
        vm.prank(keeper);
        (bool sampled, uint256 bounty) = vault.keeperPoke();
        assertTrue(sampled, "poke still happened");
        assertEq(bounty, 0);
        assertEq(vault.keeperBudget(), 10e6, "kept in budget");
        assertEq(vault.totalObligations(), 10e6);
    }

    // =====================================================================
    // Skim + settle bounty
    // =====================================================================

    /// @notice All-refund cohort: no cut is taken, no settle bounty is paid even with a
    ///         funded budget, LPs get premiums back and the underwriter exactly capital.
    function test_AllRefundCohort_NoSkim_UnderwriterGetsCapital() public {
        _fund(50e6);
        _depositTo(C, CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        _buy(lp);
        _buy(lp);
        // no further samples → fewer than 2 returns after the baseline → refund
        vm.warp(_e(C) + 1);
        uint256 lpBefore = token.balanceOf(lp);
        vm.prank(keeper);
        vault.settleBatch(C, 10);
        assertEq(token.balanceOf(lp), lpBefore + 2 * PREMIUM, "full refunds");
        assertEq(token.balanceOf(keeper), 0, "no settle bounty for refunds");
        assertEq(vault.keeperBudget(), 50e6, "no skim");

        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL, "underwriter gets exactly capital");
    }

    /// @notice A 10-policy batch pays the settle bounty per policy resolved.
    function test_Batch10_PaysPerPolicy() public {
        _measuredCohort(10);
        vm.prank(keeper);
        vault.settleBatch(C, 10);
        assertEq(token.balanceOf(keeper), 10 * SETTLE_BOUNTY, "per policy, not per call");
        assertEq(vault.keeperBudget(), 10 * (SKIM - SETTLE_BOUNTY));
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));
    }

    /// @notice The settle bounty is capped by the policy's own cut (and paid via
    ///         settlePolicy as well).
    function test_SettleBounty_CappedByOwnSkim() public {
        pricer.setPremium(10e6); // cut = 1e6 < SETTLE_BOUNTY
        _measuredCohort(1);
        _fund(100e6);
        vm.prank(keeper);
        vault.settlePolicy(0);
        assertEq(token.balanceOf(keeper), 1e6, "min(bounty, own cut)");
    }

    /// @notice I6 with the cut: the underwriter's premium share drops by exactly the cut
    ///         (rounded DOWN, so the underwriter keeps the fractional unit).
    function test_Skim_ReducesUnderwriterPremiumShareExactly() public {
        uint128 premium = 123_456_789;
        uint128 skim = uint128(uint256(premium).mulDivDown(KEEPER_BPS, BPS)); // 12_345_678
        assertEq(skim, 12_345_678);
        pricer.setPremium(premium);
        _measuredCohort(1);
        vault.settleBatch(C, 1); // msg.sender = this test: gets the settle bounty

        ICoverVault.Cohort memory c = vault.cohort(C);
        assertEq(c.premiumsCollected, premium - skim, "pool net of cut");
        assertEq(c.claimsPaid, 0);
        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL + premium - skim, "UW share reduced by cut");
        assertEq(vault.keeperBudget(), skim - SETTLE_BOUNTY);
        assertEq(token.balanceOf(address(vault)), vault.keeperBudget(), "only budget left");
        assertEq(vault.totalObligations(), vault.keeperBudget());
    }

    /// @notice A cancelled premium's cut enters the budget once at finalize — not lost,
    ///         not counted twice by a later settle or re-finalize.
    function test_CancelledPremium_SkimmedOnceAtFinalize() public {
        _depositTo(C, CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 p0 = _buy(lp);
        _buy(lp);
        vm.prank(lp);
        vault.cancel(p0);
        _fillToWith(_e(C), 0);
        vm.warp(_e(C) + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ICoverVault.CancelledPremiumsSkimmed(C, SKIM);
        vm.prank(keeper);
        vault.keeperFinalize(C);
        assertEq(vault.keeperBudget(), SKIM - FINALIZE_BOUNTY, "cancelled cut in budget");
        assertEq(vault.cohort(C).premiumsCollected, 2 * PREMIUM - SKIM);

        vm.prank(keeper);
        vault.settleBatch(C, 10); // settles the live one: its own cut only
        assertEq(vault.cohort(C).premiumsCollected, 2 * PREMIUM - 2 * SKIM, "once");
        vm.prank(keeper);
        (bool fin,) = vault.keeperFinalize(C);
        assertFalse(fin);

        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL + 2 * PREMIUM - 2 * SKIM);
        assertEq(vault.keeperBudget(), 2 * SKIM - FINALIZE_BOUNTY - SETTLE_BOUNTY);
        assertEq(token.balanceOf(address(vault)), vault.keeperBudget());
    }

    /// @notice Anti-farm: buy minimum cover, cancel, then act as the keeper on your own
    ///         cohort. The bounties collected never exceed the premium forfeited.
    function test_AntiFarm_BuyMinCancelSelfSettle_Unprofitable() public {
        _depositTo(C, CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 start = token.balanceOf(lp);
        uint256 p0 = _buy(lp);
        uint256 p1 = _buy(lp);
        vm.prank(lp);
        vault.cancel(p0);
        _fillToWith(_e(C), 0);
        vm.warp(_e(C) + 1);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PolicyNotActive.selector, p0));
        vault.settlePolicy(p0); // a cancelled policy yields no settle bounty

        uint256 beforeKeeping = token.balanceOf(lp);
        vm.startPrank(lp);
        vault.keeperFinalize(C);
        vault.settlePolicy(p1);
        vm.stopPrank();
        uint256 bounties = token.balanceOf(lp) - beforeKeeping;
        assertGt(bounties, 0);
        assertLe(bounties, PREMIUM, "bounty <= forfeited premium");
        assertLt(token.balanceOf(lp), start, "farming loses money");
    }

    function test_SettleBatch_ZeroN_Reverts() public {
        _measuredCohort(1);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NothingToSettle.selector, C));
        vault.settleBatch(C, 0);
    }

    function test_Constructor_KeeperBpsAboveBps_Reverts() public {
        vm.expectRevert(CoverVault.BadConfig.selector);
        new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            TENOR,
            GAP,
            ANCHOR,
            UTIL_BPS,
            MAX_EXCESS,
            ALPHA_BPS,
            SEED_VAR,
            POLICY_CAP,
            uint16(BPS + 1),
            POKE_BOUNTY,
            FINALIZE_BOUNTY,
            SETTLE_BOUNTY
        );
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _newVault(uint32 tenor) internal returns (CoverVault) {
        return new CoverVault(
            address(pool),
            address(acc),
            address(pricer),
            address(valuer),
            address(pm),
            address(token),
            tenor,
            GAP,
            ANCHOR,
            UTIL_BPS,
            MAX_EXCESS,
            ALPHA_BPS,
            SEED_VAR,
            POLICY_CAP,
            KEEPER_BPS,
            POKE_BOUNTY,
            FINALIZE_BOUNTY,
            SETTLE_BOUNTY
        );
    }

    function _fundAndApprove(address a, CoverVault v) internal {
        token.mint(a, 1_000_000e6);
        vm.prank(a);
        token.approve(address(v), type(uint256).max);
        vm.prank(a);
        pm.setApprovalForAll(address(v), true);
    }

    function _fund(uint256 amt) internal {
        vm.prank(donor);
        vault.fundKeeperBudget(amt);
    }

    function _s(uint32 n) internal pure returns (uint64) {
        return Calendar.startsAt(ANCHOR, n, TENOR, GAP);
    }

    function _e(uint32 n) internal pure returns (uint64) {
        return Calendar.endsAt(ANCHOR, n, TENOR, GAP);
    }

    function _depositTo(uint32 n, uint128 amt) internal {
        vm.prank(uw);
        vault.deposit(n, amt);
    }

    function _buy(address owner) internal returns (uint256) {
        uint256 id = nextTokenId++;
        pm.setOwner(id, owner);
        pm.setPosition(id, -600, 600, 1e18);
        vm.prank(owner);
        return vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
    }

    /// @dev Cohort C with `k` measured (quiet, zero-payout) policies, past endsAt.
    function _measuredCohort(uint256 k) internal {
        _depositTo(C, CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        for (uint256 i = 0; i < k; i++) {
            _buy(lp);
        }
        _fillToWith(_e(C), 0);
        vm.warp(_e(C) + 1);
    }

    function _fillTo(uint64 to) internal {
        _fillToWith(to, 0);
    }

    function _fillToWith(uint64 to, uint128 inc) internal {
        if (lastTs == 0) {
            lastTs = uint32(ANCHOR);
            acc.push(lastTs, cum);
        }
        while (uint64(lastTs) + INTERVAL <= to) {
            lastTs += INTERVAL;
            cum += inc;
            acc.push(lastTs, cum);
        }
    }
}
