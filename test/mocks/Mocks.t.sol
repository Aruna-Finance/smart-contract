// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUniswapV3Pool} from "./MockUniswapV3Pool.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {MockAccumulator} from "./MockAccumulator.sol";
import {RejectingReceiver} from "./RejectingReceiver.sol";
import {Calendar} from "../utils/Calendar.sol";

/// @title MocksTest
/// @notice Tests for the v2 test doubles themselves (plan U2), so contract tests do not
///         stand on a wrong mock.
contract MocksTest is Test {
    uint256 internal constant ID = 7;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockUniswapV3Pool internal pool;
    MockPositionManager internal pm;
    MockERC20 internal fee0;
    MockERC20 internal fee1;
    MockAccumulator internal acc;
    RejectingReceiver internal rejecter;

    function setUp() public {
        vm.warp(1_000_000);
        pool = new MockUniswapV3Pool();
        pm = new MockPositionManager();
        fee0 = new MockERC20(6);
        fee1 = new MockERC20(18);
        pm.setFeeTokens(fee0, fee1);
        pm.setOwner(ID, alice);
        acc = new MockAccumulator();
        rejecter = new RejectingReceiver();
    }

    function _observe(uint32 ago) internal view returns (int56) {
        uint32[] memory s = new uint32[](1);
        s[0] = ago;
        (int56[] memory tc,) = pool.observe(s);
        return tc[0];
    }

    function _collectAll(address recipient) internal returns (uint256, uint256) {
        return pm.collect(
            MockPositionManager.CollectParams({
                tokenId: ID,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    // --- pool -----------------------------------------------------------

    function test_Pool_CumulativeAdvancesTickTimesDt() public {
        pool.setTick(120);
        int56 c0 = _observe(0);
        skip(600);
        int56 c1 = _observe(0);
        assertEq(c1 - c0, int56(120) * 600, "k * dt");

        pool.setTick(-40); // checkpoints at now, then switches
        skip(300);
        int56 c2 = _observe(0);
        assertEq(c2 - c1, int56(-40) * 300, "new tick after checkpoint");
        // Inter-sample TWAP over [c0, c2] is the time-weighted mean.
        assertEq(c2 - c0, int56(120 * 600 - 40 * 300), "twap numerator");
    }

    function test_Pool_ObservePastMatchesHistory() public {
        pool.setTick(100);
        int56 cA = _observe(0);
        skip(1000);
        pool.setTick(-50);
        skip(500);
        // 500s ago was the switch point; 1500s ago was the setTick(100) point.
        assertEq(_observe(500), cA + int56(100) * 1000, "at switch");
        assertEq(_observe(1500), cA, "at first setTick");
        assertEq(_observe(1200), cA + int56(100) * 300, "mid first leg");
        assertEq(_observe(0), cA + int56(100) * 1000 - int56(50) * 500, "now");
    }

    function test_Pool_ObserveBeforeHistoryReverts() public {
        vm.expectRevert(MockUniswapV3Pool.OLD.selector);
        this.observeAgo(1); // pool created at this very second
    }

    function observeAgo(uint32 ago) external view returns (int56) {
        return _observe(ago);
    }

    function test_Pool_LegacyWindowMode() public {
        pool.setAvgTick(42);
        uint32[] memory s = new uint32[](2);
        s[0] = 1800;
        s[1] = 0;
        (int56[] memory tc,) = pool.observe(s);
        assertEq((tc[1] - tc[0]) / 1800, int56(42), "window twap == avgTick");
    }

    // --- position manager ---------------------------------------------

    function test_PM_SetOwnerMints() public view {
        assertEq(pm.ownerOf(ID), alice);
        assertEq(pm.balanceOf(alice), 1);
    }

    function test_PM_OwnerOfNonexistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MockPositionManager.NonexistentToken.selector, 99));
        pm.ownerOf(99);
    }

    function test_PM_CollectMovesFeesAndZeroesOwed() public {
        pm.setTokensOwed(ID, 5e6, 3e18);
        vm.prank(alice);
        (uint256 a0, uint256 a1) = _collectAll(carol);
        assertEq(a0, 5e6);
        assertEq(a1, 3e18);
        assertEq(fee0.balanceOf(carol), 5e6, "fee0 to recipient");
        assertEq(fee1.balanceOf(carol), 3e18, "fee1 to recipient");
        (,,,,,,,,,, uint128 o0, uint128 o1) = pm.positions(ID);
        assertEq(o0, 0, "owed0 zeroed");
        assertEq(o1, 0, "owed1 zeroed");
    }

    function test_PM_CollectByApprovedAndOperator() public {
        pm.setTokensOwed(ID, 1, 1);
        vm.prank(alice);
        pm.approve(bob, ID);
        vm.prank(bob);
        _collectAll(bob);

        pm.setTokensOwed(ID, 1, 1);
        vm.prank(alice);
        pm.setApprovalForAll(carol, true);
        vm.prank(carol);
        _collectAll(carol);
        assertEq(fee0.balanceOf(carol), 1);
    }

    function test_PM_NonOwnerCannotCollect() public {
        pm.setTokensOwed(ID, 1, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockPositionManager.NotAuthorized.selector, bob, ID));
        _collectAll(bob);
    }

    function test_PM_NonOwnerCannotTransfer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockPositionManager.NotAuthorized.selector, bob, ID));
        pm.transferFrom(alice, bob, ID);
    }

    function test_PM_TransferClearsApproval() public {
        vm.prank(alice);
        pm.approve(bob, ID);
        (, address op,,,,,,,,,,) = pm.positions(ID);
        assertEq(op, bob, "operator reported");
        vm.prank(bob);
        pm.transferFrom(alice, carol, ID);
        assertEq(pm.ownerOf(ID), carol);
        assertEq(pm.getApproved(ID), address(0), "approval cleared");
        assertEq(pm.balanceOf(alice), 0);
        assertEq(pm.balanceOf(carol), 1);
    }

    function test_PM_TransferToRejectingReceiverSucceeds_SafeReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockPositionManager.ReceiverRejected.selector, address(rejecter))
        );
        pm.safeTransferFrom(alice, address(rejecter), ID);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockPositionManager.ReceiverRejected.selector, address(rejecter))
        );
        pm.safeTransferFrom(alice, address(rejecter), ID, "data");

        vm.prank(alice);
        pm.transferFrom(alice, address(rejecter), ID); // no hook
        assertEq(pm.ownerOf(ID), address(rejecter));
    }

    function test_PM_SafeTransferToEoaSucceeds() public {
        vm.prank(alice);
        pm.safeTransferFrom(alice, bob, ID);
        assertEq(pm.ownerOf(ID), bob);
    }

    function test_PM_TransferFailSwitch() public {
        pm.setTransferFails(true);
        vm.prank(alice);
        vm.expectRevert(MockPositionManager.TransferDisabled.selector);
        pm.transferFrom(alice, bob, ID);

        pm.setTransferFails(false);
        vm.prank(alice);
        pm.transferFrom(alice, bob, ID);
        assertEq(pm.ownerOf(ID), bob);
    }

    function test_PM_IncreaseLiquidityOpenToAnyone() public {
        pm.setPosition(ID, -60, 60, 1000);
        vm.prank(carol);
        pm.increaseLiquidity(ID, 500);
        (,,,,,,, uint128 liq,,,,) = pm.positions(ID);
        assertEq(liq, 1500);
    }

    function test_PM_CollectToRejectedRecipientReverts() public {
        pm.setTokensOwed(ID, 1, 0);
        fee0.setRejectTransfersTo(address(rejecter), true);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockERC20.RecipientRejected.selector, address(rejecter))
        );
        _collectAll(address(rejecter));
    }

    // --- ERC20 / receiver ---------------------------------------------

    function test_ERC20_RejectFlag() public {
        fee0.mint(alice, 10);
        fee0.setRejectTransfersTo(address(rejecter), true);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MockERC20.RecipientRejected.selector, address(rejecter))
        );
        fee0.transfer(address(rejecter), 1);

        fee0.setRejectTransfersTo(address(rejecter), false);
        vm.prank(alice);
        fee0.transfer(address(rejecter), 1);
        assertEq(fee0.balanceOf(address(rejecter)), 1);
    }

    function test_RejectingReceiver_ExecOwnerOnly() public {
        pm.setOwner(8, address(rejecter));
        rejecter.exec(address(pm), abi.encodeCall(pm.transferFrom, (address(rejecter), bob, 8)));
        assertEq(pm.ownerOf(8), bob);

        vm.prank(bob);
        vm.expectRevert(RejectingReceiver.NotOwner.selector);
        rejecter.exec(address(pm), "");
    }

    // --- accumulator --------------------------------------------------

    function test_Acc_PokeThrottles() public {
        acc.setSampleInterval(1800);
        acc.setPokeIncrement(7);
        acc.poke();
        assertEq(acc.sampleCount(), 1);
        assertEq(acc.lastSampleAt(), uint32(vm.getBlockTimestamp()));

        skip(1799);
        assertFalse(acc.tryPoke(), "throttled tryPoke returns false");
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAccumulator.IntervalNotElapsed.selector, uint32(1_000_000 + 1800)
            )
        );
        acc.poke();

        skip(1);
        assertTrue(acc.tryPoke(), "elapsed tryPoke samples");
        assertEq(acc.sampleCount(), 2);
        assertEq(acc.sampleAt(1).timestamp, uint32(vm.getBlockTimestamp()));
        assertEq(acc.sampleAt(1).cumulativeSumSq, 14, "increment applied each poke");
    }

    function test_Acc_PushThenPokeHonorsThrottle() public {
        acc.setSampleInterval(60);
        acc.push(uint32(vm.getBlockTimestamp()), 100);
        assertFalse(acc.tryPoke());
        skip(60);
        assertTrue(acc.tryPoke());
        assertEq(acc.sampleAt(1).cumulativeSumSq, 100, "zero increment keeps cumSq");
    }

    // --- calendar -----------------------------------------------------

    function test_Calendar() public pure {
        assertEq(Calendar.startsAt(1000, 0, 100, 10), 1000);
        assertEq(Calendar.startsAt(1000, 3, 100, 10), 1330);
        assertEq(Calendar.endsAt(1000, 3, 100, 10), 1430);
        assertEq(Calendar.gapEnd(1000, 3, 100, 10), 1440);
    }
}
