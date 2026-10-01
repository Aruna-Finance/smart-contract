// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

/// @title PositionValuerTest
/// @notice Pins the §8.4 map: one exact arithmetic anchor at neutral width (so the
///         WAD reconciliation is a number, not a shape), the two clamp edges, the
///         width direction (narrower range → more variance-per-dollar → higher
///         notional), and monotonicity in both position inputs under fuzzing.
///         Calibration constants here are test fixtures, NOT the real §6.4 knots.
contract PositionValuerTest is Test {
    uint256 internal constant WAD = 1e18;

    // Test calibration: kappa = WAD makes varNotional == liquidity at neutral width,
    // so the anchor arithmetic is readable. refWidth 2000 ticks; clamp [0.25, 4].
    uint128 internal constant KAPPA = uint128(WAD);
    int24 internal constant REF_WIDTH = 2_000;
    uint128 internal constant MIN_MULT = uint128(WAD / 4);
    uint128 internal constant MAX_MULT = uint128(4 * WAD);

    uint256 internal constant TOKEN_ID = 1;

    MockPositionManager internal pm;
    PositionValuer internal valuer;

    function setUp() public {
        pm = new MockPositionManager();
        valuer = new PositionValuer(address(pm), KAPPA, REF_WIDTH, MIN_MULT, MAX_MULT);
    }

    function _set(int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        pm.setPosition(TOKEN_ID, tickLower, tickUpper, liquidity);
    }

    // ---------------------------------------------------------------

    /// @notice Neutral width (widthTicks == refWidth ⇒ widthMult == WAD), kappa == WAD,
    ///         so varNotional == liquidity exactly.
    function test_ExactAnchor_NeutralWidth() public {
        _set(-1_000, 1_000, 2_000_000); // width 2000 == REF_WIDTH
        assertEq(
            valuer.varNotionalFor(TOKEN_ID), 2_000_000, "neutral width => varNotional == liquidity"
        );
    }

    function test_ZeroLiquidity_ReturnsZero() public {
        _set(-1_000, 1_000, 0);
        assertEq(valuer.varNotionalFor(TOKEN_ID), 0, "no liquidity, no exposure");
    }

    function test_NarrowerRange_HigherNotional() public {
        _set(-500, 500, 1_000_000); // width 1000 == refWidth/2 => mult 2x
        assertEq(valuer.varNotionalFor(TOKEN_ID), 2_000_000, "half width => double notional");
    }

    function test_WiderRange_LowerNotional() public {
        _set(-2_000, 2_000, 1_000_000); // width 4000 == 2x refWidth => mult 0.5x
        assertEq(valuer.varNotionalFor(TOKEN_ID), 500_000, "double width => half notional");
    }

    function test_DustThinRange_CappedAtMaxMult() public {
        _set(0, 1, 1_000_000); // width 1 => raw mult 2000x, capped to 4x
        assertEq(valuer.varNotionalFor(TOKEN_ID), 4_000_000, "thin range capped at maxWidthMult");
    }

    function test_NearFullRange_FlooredAtMinMult() public {
        _set(-500_000, 500_000, 1_000_000); // width 1e6 => raw mult tiny, floored to 0.25x
        assertEq(valuer.varNotionalFor(TOKEN_ID), 250_000, "wide range floored at minWidthMult");
    }

    function test_InvalidRange_Reverts() public {
        _set(1_000, 1_000, 1_000_000); // upper == lower
        vm.expectRevert(
            abi.encodeWithSelector(PositionValuer.InvalidRange.selector, int24(1_000), int24(1_000))
        );
        valuer.varNotionalFor(TOKEN_ID);
    }

    // --- monotonicity fuzz (§8.3 spirit: pure function of the position) ---

    function testFuzz_MonotonicIn_Liquidity(uint128 a, uint128 b) public {
        a = uint128(bound(a, 1, 1e24));
        b = uint128(bound(b, 1, 1e24));
        if (a > b) (a, b) = (b, a);
        _set(-1_000, 1_000, a);
        uint128 va = valuer.varNotionalFor(TOKEN_ID);
        _set(-1_000, 1_000, b);
        uint128 vb = valuer.varNotionalFor(TOKEN_ID);
        assertLe(va, vb, "more liquidity, more (or equal) notional");
    }

    function testFuzz_NonIncreasingIn_Width(int24 wa, int24 wb) public {
        // Symmetric ranges [-w, w]; larger half-width => wider range => lower-or-equal.
        int24 la = int24(bound(int256(wa), 1, 1_000_000));
        int24 lb = int24(bound(int256(wb), 1, 1_000_000));
        if (la > lb) (la, lb) = (lb, la); // la <= lb, so range a is narrower
        _set(-la, la, 1_000_000);
        uint128 vNarrow = valuer.varNotionalFor(TOKEN_ID);
        _set(-lb, lb, 1_000_000);
        uint128 vWide = valuer.varNotionalFor(TOKEN_ID);
        assertGe(vNarrow, vWide, "narrower range is hedged at higher-or-equal notional");
    }
}
