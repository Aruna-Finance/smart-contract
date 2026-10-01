// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CoverVault} from "../src/CoverVault.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {Math} from "../src/libraries/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockPricer} from "./mocks/MockPricer.sol";
import {MockValuer} from "./mocks/MockValuer.sol";
import {MockAccumulator} from "./mocks/MockAccumulator.sol";
import {RejectingReceiver} from "./mocks/RejectingReceiver.sol";
import {Calendar} from "./utils/Calendar.sol";

/// @title CoverVaultPolicyTest
/// @notice Plan U5: the policy lifecycle — poke-on-touch, the per-index window baseline
///         (SC-02, burn-in), the ≥5-interval buy gate, minimum maxPayout + live-policy cap,
///         NFT escrow (AE7), cancel (AE8), refund (AE5), payout/NFT parking (AE9), and
///         per-policy settle out of order.
contract CoverVaultPolicyTest is Test {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;

    uint32 internal constant TENOR = 7 days;
    uint32 internal constant GAP = 1 days;
    uint32 internal constant INTERVAL = 6 hours; // 28 samples per tenor
    uint64 internal constant ANCHOR = 2_000_000;
    uint16 internal constant UTIL_BPS = 8_000;
    uint128 internal constant MAX_EXCESS = uint128(WAD); // maxPayout == varNotional
    uint16 internal constant ALPHA_BPS = 2_000;
    uint128 internal constant SEED_VAR = uint128(WAD / 10);
    uint32 internal constant POLICY_CAP = 4;

    uint32 internal constant C = 1; // the cohort under test
    uint128 internal constant CAPITAL = 10_000e6; // capacity 8_000e6 → min maxPayout 2_000e6
    uint128 internal constant VN = 2_000e6; // the minimum policy
    uint128 internal constant PREMIUM = 100e6;
    uint128 internal constant JUMP = 9_085e12; // ≈ ln(1.1)² — a 10% move, WAD
    uint128 internal constant SMALL = 1e14; // a quiet return, WAD

    MockERC20 internal token;
    MockERC20 internal fee0;
    MockERC20 internal fee1;
    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockPricer internal pricer;
    MockValuer internal valuer;
    MockAccumulator internal acc;
    CoverVault internal vault;

    address internal uw = address(0xA1);
    address internal lp = address(0xB1);
    address internal lp2 = address(0xB2);
    address internal carol = address(0xC1);
    address internal stranger = address(0xD1);
    uint256 internal nextTokenId = 1;

    // oracle cursor for the grid helpers
    uint32 internal lastTs;
    uint128 internal cum;

    function setUp() public {
        token = new MockERC20(6);
        fee0 = new MockERC20(18);
        fee1 = new MockERC20(6);
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        pm.setPool(address(0), address(0), 3000);
        pm.setFeeTokens(fee0, fee1);
        pricer = new MockPricer();
        pricer.setPremium(PREMIUM);
        valuer = new MockValuer();
        valuer.setVarNotional(VN);
        acc = new MockAccumulator();
        acc.setSampleInterval(INTERVAL);
        vault = _newVault();

        address[3] memory actors = [uw, lp, lp2];
        for (uint256 i = 0; i < actors.length; i++) {
            _fundAndApprove(actors[i], vault);
        }
        vm.warp(ANCHOR - 1 days);
    }

    // =====================================================================
    // Window baseline (plan "Pengukuran")
    // =====================================================================

    /// @notice AE2 / SC-02: the last sample is 10h stale and the price jumped 10% before
    ///         the buy. The buy's poke records that move in the sample AT the purchase;
    ///         the baseline is the sample after it, so neither the jump nor the
    ///         half-stale return after it is paid — only the returns that follow.
    function test_AE2_StaleSampleJumpBeforeBuy_Excluded() public {
        _deposit(CAPITAL);
        _fillTo(_s(C) + 12 hours);
        uint64 buyAt = _s(C) + 22 hours; // 10h after the last sample
        vm.warp(buyAt);

        acc.setPokeIncrement(JUMP); // the 10% move lands in the buy's own poke
        uint256 pid = _buyFresh(lp);
        acc.setPokeIncrement(0);
        assertEq(acc.lastSampleAt(), buyAt, "buy poked (throttle elapsed)");

        _sync();
        _fillToWith(_e(C), SMALL); // on-time samples every 6h after the buy
        uint256 after_ = (uint256(_e(C)) - buyAt) / INTERVAL; // samples after the buy
        uint256 returns_ = after_ - 1; // the first one is the baseline

        vm.warp(_e(C) + 1);
        vault.settlePolicy(pid);
        uint256 expected = uint256(VN).mulDivDown(returns_ * SMALL, WAD);
        assertEq(vault.cohort(C).claimsPaid, expected, "only post-baseline returns paid");
        assertLt(expected, uint256(VN).mulDivDown(JUMP, WAD), "jump would dominate");
        ICoverVault.Policy memory p = vault.policy(pid);
        assertEq(acc.sampleAt(p.startIndex - 1).timestamp, buyAt, "baseline predecessor");
        assertEq(uint8(p.status), uint8(ICoverVault.PolicyStatus.Settled));
    }

    /// @notice Burn-in: the price jumps inside the interval of the purchase (throttled,
    ///         no sample at the buy). The next sample's TWAP holds the jump, and the one
    ///         after still half of it — both are before/at the baseline, so not paid.
    function test_BurnIn_JumpInsidePurchaseInterval_Excluded() public {
        _deposit(CAPITAL);
        _fillTo(_s(C) + 12 hours);
        uint32 last = lastTs;
        vm.warp(last + 1 hours);
        uint256 pid = _buyFresh(lp);
        assertEq(acc.lastSampleAt(), last, "throttled: no sample at the buy");

        acc.push(lastTs += INTERVAL, cum += JUMP); // j: TWAP over the jump
        acc.push(lastTs += INTERVAL, cum += JUMP / 2); // s: half-jumped TWAP vs j
        uint32 baselineTs = lastTs;
        _fillToWith(_e(C), SMALL);
        uint256 returns_ = (uint256(_e(C)) - baselineTs) / INTERVAL;

        vm.warp(_e(C) + 1);
        vault.settleBatch(C, 10);
        assertEq(
            vault.cohort(C).claimsPaid,
            uint256(VN).mulDivDown(returns_ * SMALL, WAD),
            "jump in the purchase interval not paid"
        );
        assertEq(acc.sampleAt(vault.policy(pid).startIndex).timestamp, baselineTs, "baseline");
    }

    // =====================================================================
    // Buy gates
    // =====================================================================

    /// @notice Fewer than 5 sample intervals before endsAt → revert; exactly 5 → allowed.
    function test_Buy_RevertsWithLessThanFiveIntervalsLeft() public {
        _deposit(CAPITAL);
        _fillTo(_e(C) - 5 * INTERVAL);
        vm.warp(_e(C) - 5 * INTERVAL + 1);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.TooLateToBuy.selector, _e(C)));
        vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
    }

    /// @notice Buy exactly at the 5-interval threshold while the poke is throttled (last
    ///         sample 1s before), then on-time pokes → measured (≥2 returns), not refund.
    function test_Buy_AtFiveIntervalThreshold_Throttled_ThenOnTime_Measured() public {
        _deposit(CAPITAL);
        _fillTo(_e(C) - 6 * INTERVAL);
        uint64 buyAt = _e(C) - 5 * INTERVAL;
        acc.push(uint32(buyAt - 1), cum); // a poke 1s before the buy: next is throttled
        vm.warp(buyAt);
        uint256 pid = _buyFresh(lp);
        assertEq(acc.lastSampleAt(), buyAt - 1, "throttled");

        // On-time keeper: one sample every interval from the last one, up to endsAt.
        lastTs = uint32(buyAt - 1);
        _fillToWith(_e(C), SMALL); // j, s, then 3 returns
        vm.warp(_e(C));
        vault.settlePolicy(pid);
        ICoverVault.Policy memory p = vault.policy(pid);
        assertEq(uint8(p.status), uint8(ICoverVault.PolicyStatus.Settled), "measured");
        assertEq(vault.cohort(C).claimsPaid, uint256(VN).mulDivDown(3 * SMALL, WAD), "3 returns");
    }

    /// @notice R24 / SC-16: filling the live-policy cap with minimum policies costs the
    ///         whole capacity; below the minimum is refused, as is a slot over the cap.
    function test_PolicyCap_FillWithMinimum_EqualsCapacity_BelowMinRejected() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);

        uint128 capacity = uint128(uint256(CAPITAL).mulDivDown(UTIL_BPS, 10_000));
        uint128 minPayout = capacity / POLICY_CAP;
        assertEq(minPayout, VN, "min = capacity / cap");

        valuer.setVarNotional(minPayout - 1);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoverVault.BelowMinPayout.selector, uint96(minPayout - 1), minPayout
            )
        );
        vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);

        valuer.setVarNotional(minPayout);
        for (uint256 i = 0; i < POLICY_CAP; i++) {
            _buyFresh(lp);
        }
        ICoverVault.Cohort memory c = vault.cohort(C);
        assertEq(c.reserved, capacity, "cap x minimum == full capacity");
        assertEq(c.policyCount, POLICY_CAP, "cap filled");

        id = _newPosition(lp2);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PolicyCapReached.selector, POLICY_CAP));
        vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
    }

    function test_Buy_Reverts_ZeroLiquidity_WrongPool_ZeroCapital() public {
        // zero capital (SC-16)
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.ZeroCapital.selector, C));
        vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);

        // capitalized cohort 2 for the position checks
        vm.warp(_e(C));
        _depositTo(2, CAPITAL);
        _fillTo(_s(2));
        vm.warp(_s(2) + 1);

        pm.setPosition(id, -600, 600, 0);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.ZeroLiquidity.selector, id));
        vault.buyCover(2, id, 0, type(uint128).max, type(uint64).max);

        pm.setPosition(id, -600, 600, 1e18);
        pm.setPool(address(0), address(0), 500); // the position is now another pool's
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PositionWrongPool.selector, id));
        vault.buyCover(2, id, 0, type(uint128).max, type(uint64).max);
    }

    // =====================================================================
    // Escrow (AE7)
    // =====================================================================

    /// @notice AE7: the vault holds the NFT; the LP cannot pull liquidity or fees directly;
    ///         only the policy owner can make the vault collect, to any recipient.
    function test_AE7_Escrow_OnlyOwnerCollectsToChosenRecipient() public {
        uint256 pid = _activeWithPolicy();
        uint256 id = vault.policy(pid).positionTokenId;
        assertEq(pm.ownerOf(id), address(vault), "escrowed");

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MockPositionManager.NotAuthorized.selector, lp, id));
        pm.decreaseLiquidity(id, 1);

        pm.setTokensOwed(id, 7e18, 3e6);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MockPositionManager.NotAuthorized.selector, lp, id));
        pm.collect(_collectParams(id, lp));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotPolicyOwner.selector, pid));
        vault.collectFees(pid, stranger);

        vm.prank(lp);
        vm.expectRevert(CoverVault.ZeroRecipient.selector);
        vault.collectFees(pid, address(0));

        vm.prank(lp);
        (uint256 a0, uint256 a1) = vault.collectFees(pid, carol);
        assertEq(a0, 7e18);
        assertEq(a1, 3e6);
        assertEq(fee0.balanceOf(carol), 7e18, "fees to the chosen recipient");
        assertEq(fee1.balanceOf(carol), 3e6);
        assertEq(pm.ownerOf(id), address(vault), "still escrowed");
    }

    /// @notice Fees owed before the buy go to the owner at the buy; a third party's
    ///         increaseLiquidity after the buy moves neither varNotional nor the payout.
    function test_Buy_CollectsTokensOwed_IncreaseLiquidityDoesNotMovePayout() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 id = _newPosition(lp);
        pm.setTokensOwed(id, 5e18, 2e6);

        vm.prank(lp);
        uint256 pid = vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
        assertEq(fee0.balanceOf(lp), 5e18, "owed0 to owner at buy");
        assertEq(fee1.balanceOf(lp), 2e6, "owed1 to owner at buy");
        (,,,,,,,,,, uint128 o0, uint128 o1) = pm.positions(id);
        assertEq(o0 + o1, 0, "nothing left owed");

        vm.prank(stranger);
        pm.increaseLiquidity(id, 1e30);
        valuer.setVarNotional(VN * 10); // what a fresh valuation would now say
        assertEq(vault.policy(pid).varNotional, VN, "snapshot unchanged");

        _fillToWith(_e(C), SMALL);
        vm.warp(_e(C) + 1);
        vault.settlePolicy(pid);
        assertEq(
            vault.cohort(C).claimsPaid, uint256(VN).mulDivDown(26 * SMALL, WAD), "snapshot payout"
        );
    }

    /// @notice While escrowed the NFT cannot back a policy in another vault (the buyer no
    ///         longer owns it); right after cancel it can.
    function test_Escrow_NftNotReusableElsewhere_UntilCancel() public {
        CoverVault vault2 = _newVault();
        _fundAndApprove(uw, vault2);
        _fundAndApprove(lp, vault2);
        vm.prank(uw);
        vault2.deposit(C, CAPITAL);

        uint256 pid = _activeWithPolicy();
        uint256 id = vault.policy(pid).positionTokenId;

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PositionNotOwned.selector, id));
        vault2.buyCover(C, id, 0, type(uint128).max, type(uint64).max);

        vm.prank(lp);
        vault.cancel(pid);
        vm.prank(lp);
        uint256 pid2 = vault2.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
        assertEq(pm.ownerOf(id), address(vault2), "escrowed in the second vault");
        assertEq(vault2.policy(pid2).owner, lp);
    }

    /// @notice An unsolicited safeTransferFrom into the vault is refused by the hook.
    function test_SafeTransferToVault_WithoutBuy_Rejected() public {
        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(MockPositionManager.ReceiverRejected.selector, address(vault))
        );
        pm.safeTransferFrom(lp, address(vault), id);
        assertEq(pm.ownerOf(id), lp);

        // Direct calls are refused too, even "from" the manager with the vault as operator
        // outside a vault action.
        vm.prank(address(pm));
        vm.expectRevert(abi.encodeWithSelector(CoverVault.UnsolicitedPosition.selector, id));
        vault.onERC721Received(address(vault), lp, id, "");
    }

    // =====================================================================
    // Cancel (AE8)
    // =====================================================================

    /// @notice AE8: cancel on day 3 → NFT back, premium stays with the cohort, reserved
    ///         and the live slot freed; another LP buys that capacity with the freed slot.
    ///         Filling the cap, cancelling and rebuying never grows the settle queue.
    function test_AE8_CancelDay3_FreesCapacityAndSlot_PremiumStays() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256[] memory pids = new uint256[](POLICY_CAP);
        for (uint256 i = 0; i < POLICY_CAP; i++) {
            pids[i] = _buyFresh(lp);
        }
        _fillTo(_s(C) + 3 days);
        vm.warp(_s(C) + 3 days);

        uint256 victim = pids[1];
        uint256 id = vault.policy(victim).positionTokenId;
        ICoverVault.Cohort memory before = vault.cohort(C);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotPolicyOwner.selector, victim));
        vault.cancel(victim);

        vm.prank(lp);
        vault.cancel(victim);

        ICoverVault.Cohort memory c = vault.cohort(C);
        assertEq(pm.ownerOf(id), lp, "NFT back");
        assertEq(c.premiumsCollected, before.premiumsCollected, "premium stays");
        assertEq(c.cancelledPremiums, PREMIUM, "tracked for the keeper skim");
        assertEq(c.reserved, before.reserved - VN, "reserved released");
        assertEq(c.policyCount, POLICY_CAP - 1, "slot freed");
        assertEq(uint8(vault.policy(victim).status), uint8(ICoverVault.PolicyStatus.Cancelled));

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PolicyNotActive.selector, victim));
        vault.cancel(victim);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PositionNotHeld.selector, victim));
        vault.collectFees(victim, lp);

        // Another LP takes the freed capacity and slot.
        uint256 rebuy = _buyFresh(lp2);
        c = vault.cohort(C);
        assertEq(c.policyCount, POLICY_CAP, "queue length bounded by the cap");
        assertEq(c.reserved, before.reserved, "capacity reused");
        // The queue is a permutation of the live policies: every index < cap, distinct.
        uint256 seen;
        uint256[4] memory live = [pids[0], pids[2], pids[3], rebuy];
        for (uint256 i = 0; i < live.length; i++) {
            uint32 q = vault.policy(live[i]).queueIndex;
            assertLt(q, POLICY_CAP, "queue index in range");
            seen |= 1 << q;
        }
        assertEq(seen, 15, "distinct queue slots");

        // After endsAt: cancel is closed; settle resolves the 4 live policies only and the
        // underwriter keeps the cancelled premium.
        _fillTo(_e(C));
        vm.warp(_e(C));
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotActive.selector, C));
        vault.cancel(pids[0]);
        vault.settleBatch(C, 10);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));
        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL + 5 * PREMIUM, "5 premiums kept, quiet market");
    }

    // =====================================================================
    // Refund (AE5, policy)
    // =====================================================================

    /// @notice AE5 (policy): fewer than 2 returns after the baseline → the full premium
    ///         goes back to the LP, the NFT returns, reserved is released.
    function test_AE5_PolicyRefund() public {
        uint256 pid = _activeWithPolicy(); // bought at _s+1, last sample at _s
        uint256 id = vault.policy(pid).positionTokenId;
        // the keeper dies: only j and s ever arrive
        acc.push(lastTs += INTERVAL, cum += JUMP);
        acc.push(lastTs += INTERVAL, cum += JUMP);

        vm.warp(_e(C) + 1);
        uint256 lpBefore = token.balanceOf(lp);
        vm.recordLogs();
        vault.settlePolicy(pid);
        _assertNextLog(ICoverVault.PolicySettled.selector, ICoverVault.PolicyRefunded.selector);

        ICoverVault.Policy memory p = vault.policy(pid);
        assertEq(uint8(p.status), uint8(ICoverVault.PolicyStatus.Refunded), "refunded");
        assertEq(token.balanceOf(lp) - lpBefore, PREMIUM, "full premium back");
        assertEq(pm.ownerOf(id), lp, "NFT back");
        ICoverVault.Cohort memory c = vault.cohort(C);
        assertEq(c.reserved, 0, "reserved released");
        assertEq(c.premiumsCollected, 0, "premium left the cohort");
        assertEq(c.claimsPaid, 0);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));

        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL, "capital back exactly");
        assertEq(token.balanceOf(address(vault)), 0, "vault empty");
    }

    // =====================================================================
    // Parking (AE9)
    // =====================================================================

    /// @notice AE9: the policy owner is a contract that rejects the settlement token. The
    ///         batch still settles the other policy; the payout parks (Unclaimed right
    ///         before PolicySettled) and is claimable later; the NFT is delivered anyway
    ///         (transferFrom has no hook).
    function test_AE9_RejectingReceiver_PayoutParked_NftDelivered() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);

        RejectingReceiver rr = new RejectingReceiver();
        token.mint(address(rr), 1_000e6);
        rr.exec(address(token), abi.encodeCall(token.approve, (address(vault), type(uint256).max)));
        rr.exec(address(pm), abi.encodeCall(pm.setApprovalForAll, (address(vault), true)));
        uint256 rrId = _newPosition(address(rr));
        bytes memory ret = rr.exec(
            address(vault),
            abi.encodeCall(vault.buyCover, (C, rrId, 0, type(uint128).max, type(uint64).max))
        );
        uint256 rrPid = abi.decode(ret, (uint256));
        uint256 lpPid = _buyFresh(lp);

        _fillToWith(_e(C), SMALL);
        token.setRejectTransfersTo(address(rr), true);
        vm.warp(_e(C) + 1);
        uint256 payout = uint256(VN).mulDivDown(26 * SMALL, WAD);
        uint256 lpBefore = token.balanceOf(lp);

        vm.recordLogs();
        vault.settleBatch(C, 10);
        _assertNextLog(ICoverVault.Unclaimed.selector, ICoverVault.PolicySettled.selector);

        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED), "batch completed");
        assertEq(token.balanceOf(lp) - lpBefore, payout, "other policy paid");
        assertEq(vault.unclaimed(address(rr)), payout, "rejected payout parked");
        assertEq(pm.ownerOf(rrId), address(rr), "NFT delivered despite the hook");
        assertFalse(vault.policy(rrPid).nftParked);
        assertEq(uint8(vault.policy(lpPid).status), uint8(ICoverVault.PolicyStatus.Settled));

        token.setRejectTransfersTo(address(rr), false);
        uint256 rrBefore = token.balanceOf(address(rr));
        rr.exec(address(vault), abi.encodeCall(vault.claimUnclaimed, ()));
        assertEq(token.balanceOf(address(rr)) - rrBefore, payout, "claimed later");
        assertEq(vault.unclaimed(address(rr)), 0);
    }

    /// @notice AE9 defense path: the manager's transferFrom fails → both NFTs park, the
    ///         batch carries on, and each owner pulls theirs later with claimPosition.
    function test_AE9_Defense_TransferFails_NftParked_ClaimPosition() public {
        uint256 pidA = _activeWithPolicy();
        uint256 pidB = _buyFresh(lp2);
        uint256 idA = vault.policy(pidA).positionTokenId;
        uint256 idB = vault.policy(pidB).positionTokenId;
        _fillToWith(_e(C), SMALL);
        vm.warp(_e(C) + 1);

        pm.setTransferFails(true);
        vault.settleBatch(C, 10);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED), "batch continued");
        assertTrue(vault.policy(pidA).nftParked && vault.policy(pidB).nftParked, "parked");
        assertEq(pm.ownerOf(idA), address(vault));
        assertGt(vault.cohort(C).claimsPaid, 0, "payouts still pushed");

        // A parked NFT is still the owner's to collect fees from.
        pm.setTokensOwed(idA, 1e18, 0);
        vm.prank(lp);
        vault.collectFees(pidA, lp);
        assertEq(fee0.balanceOf(lp), 1e18);

        pm.setTransferFails(false);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotPolicyOwner.selector, pidA));
        vault.claimPosition(pidA);

        vm.prank(lp);
        vault.claimPosition(pidA);
        assertEq(pm.ownerOf(idA), lp, "claimed");
        assertFalse(vault.policy(pidA).nftParked);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotParked.selector, pidA));
        vault.claimPosition(pidA);

        vm.prank(lp2);
        vault.claimPosition(pidB);
        assertEq(pm.ownerOf(idB), lp2);
    }

    /// @notice AE9 + AE5: a REFUND to a policy owner that rejects the settlement token.
    ///         Fewer than 2 returns after the baseline → Refunded; the premium push fails,
    ///         so the premium parks in `unclaimed` (canonical order: PolicySettled(…, 0),
    ///         Unclaimed, PolicyRefunded), stays an obligation, the NFT is still delivered,
    ///         and the owner pulls exactly the premium later.
    function test_AE9_RejectingReceiver_RefundParked_NftDelivered() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);

        RejectingReceiver rr = new RejectingReceiver();
        token.mint(address(rr), 1_000e6);
        rr.exec(address(token), abi.encodeCall(token.approve, (address(vault), type(uint256).max)));
        rr.exec(address(pm), abi.encodeCall(pm.setApprovalForAll, (address(vault), true)));
        uint256 rrId = _newPosition(address(rr));
        bytes memory ret = rr.exec(
            address(vault),
            abi.encodeCall(vault.buyCover, (C, rrId, 0, type(uint128).max, type(uint64).max))
        );
        uint256 rrPid = abi.decode(ret, (uint256));

        // the keeper dies: only j and s ever arrive → < 2 returns after the baseline
        acc.push(lastTs += INTERVAL, cum += JUMP);
        acc.push(lastTs += INTERVAL, cum += JUMP);

        token.setRejectTransfersTo(address(rr), true);
        vm.warp(_e(C) + 1);
        uint256 rrBefore = token.balanceOf(address(rr));
        uint256 obligationsBefore = vault.totalObligations();

        vm.recordLogs();
        vault.settlePolicy(rrPid);
        _assertLogSequence(
            ICoverVault.PolicySettled.selector,
            ICoverVault.Unclaimed.selector,
            ICoverVault.PolicyRefunded.selector
        );

        ICoverVault.Policy memory p = vault.policy(rrPid);
        assertEq(uint8(p.status), uint8(ICoverVault.PolicyStatus.Refunded), "refunded");
        assertEq(token.balanceOf(address(rr)), rrBefore, "push failed: nothing received");
        assertEq(vault.unclaimed(address(rr)), PREMIUM, "premium parked");
        assertEq(vault.totalObligations(), obligationsBefore, "parked premium still owed");
        assertEq(pm.ownerOf(rrId), address(rr), "NFT delivered despite the hook");
        assertFalse(p.nftParked);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));

        token.setRejectTransfersTo(address(rr), false);
        rr.exec(address(vault), abi.encodeCall(vault.claimUnclaimed, ()));
        assertEq(token.balanceOf(address(rr)) - rrBefore, PREMIUM, "claimed exactly the premium");
        assertEq(vault.unclaimed(address(rr)), 0);
        assertEq(vault.totalObligations(), obligationsBefore - PREMIUM, "obligation released");
    }

    // =====================================================================
    // Quote deadline
    // =====================================================================

    /// @notice buyCover's deadline is inclusive: now − 1 reverts QuoteExpired(deadline),
    ///         deadline == now still buys.
    function test_BuyCover_DeadlineBoundary() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint64 nowTs = uint64(vm.getBlockTimestamp());

        uint256 id = _newPosition(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.QuoteExpired.selector, nowTs - 1));
        vault.buyCover(C, id, 0, type(uint128).max, nowTs - 1);

        vm.prank(lp);
        uint256 pid = vault.buyCover(C, id, 0, type(uint128).max, nowTs);
        assertEq(vault.policy(pid).owner, lp, "bought at deadline == now");
    }

    // =====================================================================
    // NothingToWithdraw guards
    // =====================================================================

    /// @notice FUNDING: a second withdraw after the deposit was returned reverts.
    function test_Withdraw_TwiceInFunding_Reverts() public {
        _deposit(CAPITAL);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.FUNDING));
        vm.prank(uw);
        assertEq(vault.withdraw(C), CAPITAL);
        vm.prank(uw);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.withdraw(C);
        vm.prank(stranger);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.withdraw(C);
    }

    /// @notice SETTLED: a second withdraw after the net was paid reverts.
    function test_Withdraw_TwiceAfterSettled_Reverts() public {
        _activeWithPolicy();
        _fillToWith(_e(C), SMALL);
        vm.warp(_e(C) + 1);
        vault.settleBatch(C, 10);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));

        vm.prank(uw);
        assertGt(vault.withdraw(C), 0);
        vm.prank(uw);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.withdraw(C);
    }

    /// @notice rollTo from a SETTLED cohort reverts for a caller with no deposit there, and
    ///         for one who already exited (by withdraw or by a previous roll).
    function test_RollTo_NoDepositOrAlreadyExited_Reverts() public {
        _deposit(CAPITAL / 2);
        vm.prank(lp2);
        vault.deposit(C, CAPITAL / 2);
        _fillTo(_s(C));
        vm.warp(_e(C) + 1); // no policies: finalized lazily on exit
        assertEq(uint8(vault.statusOf(C + 1)), uint8(ICoverVault.Status.FUNDING));

        vm.prank(stranger);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.rollTo(C, C + 1);

        vm.prank(uw);
        vault.withdraw(C);
        vm.prank(uw);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.rollTo(C, C + 1);

        vm.prank(lp2);
        vault.rollTo(C, C + 1);
        assertEq(vault.deposits(C + 1, lp2), CAPITAL / 2, "rolled");
        vm.prank(lp2);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.rollTo(C, C + 1);
    }

    /// @notice claimUnclaimed with nothing parked reverts.
    function test_ClaimUnclaimed_NothingOwed_Reverts() public {
        assertEq(vault.unclaimed(stranger), 0);
        vm.prank(stranger);
        vm.expectRevert(CoverVault.NothingToWithdraw.selector);
        vault.claimUnclaimed();
    }

    // =====================================================================
    // Settle order
    // =====================================================================

    /// @notice Per-policy settle out of order, then batch: final policies are skipped, the
    ///         cohort is SETTLED exactly when every live policy is final (not by cursor),
    ///         and the result equals a pure-batch settlement.
    function test_SettlePolicy_OutOfOrder_ThenBatchSkips_SettledWhenAllFinal() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 p0 = _buyFresh(lp);
        uint256 p1 = _buyFresh(lp2);
        uint256 p2 = _buyFresh(lp);
        _fillToWith(_e(C), SMALL);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotSettling.selector, C));
        vault.settlePolicy(p2); // before endsAt

        vm.warp(_e(C) + 1);
        uint256 snap = vm.snapshotState();

        // Reference: pure batch.
        vault.settleBatch(C, 10);
        uint256 lpRef = token.balanceOf(lp);
        uint256 lp2Ref = token.balanceOf(lp2);
        uint128 claimsRef = vault.cohort(C).claimsPaid;
        vm.revertToState(snap);

        // LP settles its last policy itself (finalizes lazily), out of order.
        vm.prank(lp);
        vault.settlePolicy(p2);
        assertTrue(vault.cohort(C).finalized, "lazy finalize");
        assertEq(uint8(vault.policy(p2).status), uint8(ICoverVault.PolicyStatus.Settled));
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLING));
        vm.expectRevert(abi.encodeWithSelector(CoverVault.PolicyNotActive.selector, p2));
        vault.settlePolicy(p2);

        vault.settleBatch(C, 1); // p0
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLING), "p1 open");
        assertEq(vault.cohort(C).settledCount, 2);

        vault.settlePolicy(p1); // the last open one, cursor still at 1
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED), "all final");
        assertEq(vault.cohort(C).settleCursor, 1, "resolved independent of the cursor");
        vm.expectRevert(abi.encodeWithSelector(CoverVault.NotSettling.selector, C));
        vault.settleBatch(C, 10);

        assertEq(token.balanceOf(lp), lpRef, "same as batch (lp)");
        assertEq(token.balanceOf(lp2), lp2Ref, "same as batch (lp2)");
        assertEq(vault.cohort(C).claimsPaid, claimsRef, "no double processing");
        assertEq(vault.cohort(C).reserved, 0);
        assertEq(uint8(vault.policy(p0).status), uint8(ICoverVault.PolicyStatus.Settled));
    }

    /// @notice A batch that only meets already-final policies still advances its cursor
    ///         and settles what follows.
    function test_SettleBatch_SkipsFinal_ThenResolves() public {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        uint256 p0 = _buyFresh(lp);
        _buyFresh(lp2);
        _fillToWith(_e(C), SMALL);
        vm.warp(_e(C) + 1);

        vault.settlePolicy(p0);
        uint256 lpBal = token.balanceOf(lp);
        vault.settleBatch(C, 1); // only p0: skipped
        assertEq(token.balanceOf(lp), lpBal, "not paid twice");
        assertEq(vault.cohort(C).settleCursor, 1);
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLING));
        vault.settleBatch(C, type(uint32).max); // no overflow on a huge n
        assertEq(uint8(vault.statusOf(C)), uint8(ICoverVault.Status.SETTLED));
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _newVault() internal returns (CoverVault) {
        return new CoverVault(
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
            0,
            0,
            0,
            0
        );
    }

    function _fundAndApprove(address a, CoverVault v) internal {
        token.mint(a, 1_000_000e6);
        vm.prank(a);
        token.approve(address(v), type(uint256).max);
        vm.prank(a);
        pm.setApprovalForAll(address(v), true);
    }

    function _s(uint32 n) internal pure returns (uint64) {
        return Calendar.startsAt(ANCHOR, n, TENOR, GAP);
    }

    function _e(uint32 n) internal pure returns (uint64) {
        return Calendar.endsAt(ANCHOR, n, TENOR, GAP);
    }

    function _deposit(uint128 amt) internal {
        _depositTo(C, amt);
    }

    function _depositTo(uint32 n, uint128 amt) internal {
        vm.prank(uw);
        vault.deposit(n, amt);
    }

    function _newPosition(address owner) internal returns (uint256 id) {
        id = nextTokenId++;
        pm.setOwner(id, owner);
        pm.setPosition(id, -600, 600, 1e18);
    }

    function _buyFresh(address owner) internal returns (uint256) {
        uint256 id = _newPosition(owner);
        vm.prank(owner);
        return vault.buyCover(C, id, 0, type(uint128).max, type(uint64).max);
    }

    /// @dev Capitalized cohort C, ACTIVE at startsAt + 1, one minimum policy by `lp`.
    function _activeWithPolicy() internal returns (uint256) {
        _deposit(CAPITAL);
        _fillTo(_s(C));
        vm.warp(_s(C) + 1);
        return _buyFresh(lp);
    }

    function _collectParams(uint256 id, address to)
        internal
        pure
        returns (INonfungiblePositionManager.CollectParams memory)
    {
        return INonfungiblePositionManager.CollectParams({
            tokenId: id, recipient: to, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
    }

    /// @dev Among the vault's own logs, every `first` is immediately followed by `second`
    ///      (the indexer pairs adjacent vault events; token/NFT logs are other emitters).
    function _assertNextLog(bytes32 first, bytes32 second) internal {
        Vm.Log[] memory all = vm.getRecordedLogs();
        bytes32[] memory topics = new bytes32[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].emitter == address(vault)) topics[n++] = all[i].topics[0];
        }
        bool found;
        for (uint256 i = 0; i + 1 < n; i++) {
            if (topics[i] == first) {
                assertEq(topics[i + 1], second, "log order");
                found = true;
            }
        }
        assertTrue(found, "first log not emitted");
    }

    /// @dev Among the vault's own logs, `a`, `b`, `c` appear consecutively in this order
    ///      (exactly once as a run).
    function _assertLogSequence(bytes32 a, bytes32 b, bytes32 c) internal {
        Vm.Log[] memory all = vm.getRecordedLogs();
        bytes32[] memory topics = new bytes32[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].emitter == address(vault)) topics[n++] = all[i].topics[0];
        }
        uint256 runs;
        for (uint256 i = 0; i + 2 < n; i++) {
            if (topics[i] == a && topics[i + 1] == b && topics[i + 2] == c) runs++;
        }
        assertEq(runs, 1, "log sequence");
    }

    /// @dev Resync the grid cursor to the accumulator's latest sample.
    function _sync() internal {
        uint32 last = acc.sampleCount() - 1;
        lastTs = acc.sampleAt(last).timestamp;
        cum = acc.sampleAt(last).cumulativeSumSq;
    }

    function _fillTo(uint64 to) internal {
        _fillToWith(to, 0);
    }

    /// @dev Push samples every INTERVAL from the cursor (ANCHOR initially) up to `to`.
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
