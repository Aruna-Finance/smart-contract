// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FlatVegaPricer} from "../src/FlatVegaPricer.sol";

/// @title FlatVegaPricerTest
/// @notice Verifies the §6.3 quote: one exact hand-derived anchor (so the WAD
///         reconciliation is pinned to a number, not just a shape), the two floors
///         (dust and dead-regime), and monotonicity in every argument — the property
///         that actually makes a stateless pricer safe to fuzz (design §8.3).
contract FlatVegaPricerTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint32 internal constant SEVEN_DAYS = 604_800;

    uint128 internal constant MIN_PREMIUM = 1e6; // $1 in 6-decimal USDC
    uint16 internal constant LOAD_BPS = 1_000; // 10%
    uint128 internal constant LAMBDA = uint128(WAD / 2); // 0.5

    FlatVegaPricer internal pricer;

    function setUp() public {
        uint128[5] memory mKnots =
            [uint128(0), uint128(WAD / 2), uint128(WAD), uint128(2 * WAD), uint128(4 * WAD)];
        // g decreasing: 1.0, 0.6, 0.35, 0.15, 0.05
        uint128[5] memory gKnots = [
            uint128(WAD),
            uint128((6 * WAD) / 10),
            uint128((35 * WAD) / 100),
            uint128((15 * WAD) / 100),
            uint128((5 * WAD) / 100)
        ];
        pricer = new FlatVegaPricer(MIN_PREMIUM, LOAD_BPS, LAMBDA, mKnots, gKnots);
    }

    function _q(
        uint128 varNotional,
        uint64 strike,
        uint32 covered,
        uint128 ewma,
        uint128 reserved,
        uint128 totalCapital
    ) internal view returns (uint128) {
        return pricer.quote(varNotional, strike, covered, ewma, reserved, totalCapital);
    }

    // ---------------------------------------------------------------

    /// @notice Exact anchor with strike 0 (g = top knot = WAD) and reserved 0
    ///         (utilMult = WAD), so only the fair-value chain and the load remain.
    ///         Derivation (all rounds UP):
    ///           f1 = ceil(2_000e6 × 0.1225e18 / WAD)      = 245_000_000
    ///           f2 = ceil(245_000_000 × WAD / WAD)        = 245_000_000
    ///           f3 = ceil(245_000_000 × 604_800 / SPY)    =   4_698_631
    ///           premium = ceil(4_698_631 × 1.1)           =   5_168_495
    function test_ExactAnchor_StrikeZero_NoUtil() public view {
        uint128 p = _q(2_000e6, 0, SEVEN_DAYS, uint128((1225 * WAD) / 10_000), 0, 10_000e6);
        assertEq(p, 5_168_495, "exact 6.3 premium");
    }

    function test_DustNotional_FloorsToMinPremium() public view {
        // Tiny notional would price well below $1; the floor holds.
        uint128 p = _q(1e6, 0, 1, uint128((1225 * WAD) / 10_000), 0, 10_000e6);
        assertEq(p, MIN_PREMIUM, "dust floored to minPremium");
    }

    function test_ZeroEwma_ReturnsFloor() public view {
        uint128 p = _q(2_000e6, 0, SEVEN_DAYS, 0, 0, 10_000e6);
        assertEq(p, MIN_PREMIUM, "no regime to price on");
    }

    function test_HigherStrike_IsCheaper() public view {
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        // strike 0 => moneyness 0 => top knot; strike = ewma => moneyness WAD => middle knot.
        uint128 pLow = _q(2_000e6, 0, SEVEN_DAYS, ewma, 0, 10_000e6);
        uint128 pHigh = _q(2_000e6, uint64(ewma), SEVEN_DAYS, ewma, 0, 10_000e6);
        assertGt(pLow, pHigh, "raising the strike lowers the premium");
    }

    function test_Utilization_RaisesPremium() public view {
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        uint128 pEmpty = _q(2_000e6, 0, SEVEN_DAYS, ewma, 0, 10_000e6);
        uint128 pBusy = _q(2_000e6, 0, SEVEN_DAYS, ewma, 8_000e6, 10_000e6);
        assertGt(pBusy, pEmpty, "scarce capacity costs more");
    }

    // --- monotonicity fuzz (§8.3): premium is a pure function of its args ---

    function testFuzz_MonotonicIn_VarNotional(uint128 a, uint128 b) public view {
        a = uint128(bound(a, 1e6, 1e15));
        b = uint128(bound(b, 1e6, 1e15));
        if (a > b) (a, b) = (b, a);
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        assertLe(_q(a, 0, SEVEN_DAYS, ewma, 0, 10_000e6), _q(b, 0, SEVEN_DAYS, ewma, 0, 10_000e6));
    }

    function testFuzz_MonotonicIn_CoveredSeconds(uint32 a, uint32 b) public view {
        a = uint32(bound(a, 1, SEVEN_DAYS * 4));
        b = uint32(bound(b, 1, SEVEN_DAYS * 4));
        if (a > b) (a, b) = (b, a);
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        assertLe(_q(2_000e6, 0, a, ewma, 0, 10_000e6), _q(2_000e6, 0, b, ewma, 0, 10_000e6));
    }

    function testFuzz_NonDecreasingIn_Ewma(uint128 a, uint128 b) public view {
        a = uint128(bound(a, 1e15, uint128(WAD)));
        b = uint128(bound(b, 1e15, uint128(WAD)));
        if (a > b) (a, b) = (b, a);
        // fixed strike > 0 so moneyness actually moves with ewma
        uint64 strike = uint64(WAD / 20);
        assertLe(_q(2_000e6, strike, SEVEN_DAYS, a, 0, 10_000e6), _q(2_000e6, strike, SEVEN_DAYS, b, 0, 10_000e6));
    }

    function testFuzz_NonIncreasingIn_Strike(uint64 a, uint64 b) public view {
        a = uint64(bound(a, 0, uint64(WAD)));
        b = uint64(bound(b, 0, uint64(WAD)));
        if (a > b) (a, b) = (b, a);
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        // higher strike (b) must be cheaper-or-equal than lower strike (a)
        assertGe(_q(2_000e6, a, SEVEN_DAYS, ewma, 0, 10_000e6), _q(2_000e6, b, SEVEN_DAYS, ewma, 0, 10_000e6));
    }

    function testFuzz_NonDecreasingIn_Reserved(uint128 a, uint128 b) public view {
        uint128 cap = 10_000e6;
        a = uint128(bound(a, 0, cap));
        b = uint128(bound(b, 0, cap));
        if (a > b) (a, b) = (b, a);
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        assertLe(_q(2_000e6, 0, SEVEN_DAYS, ewma, a, cap), _q(2_000e6, 0, SEVEN_DAYS, ewma, b, cap));
    }

    function testFuzz_NonIncreasingIn_TotalCapital(uint128 a, uint128 b) public view {
        // reserved fixed > 0 so utilization actually depends on capital
        uint128 reserved = 4_000e6;
        a = uint128(bound(a, reserved, 1e18));
        b = uint128(bound(b, reserved, 1e18));
        if (a > b) (a, b) = (b, a); // a <= b
        uint128 ewma = uint128((1225 * WAD) / 10_000);
        // larger capital (b) dilutes utilization => cheaper-or-equal
        assertGe(_q(2_000e6, 0, SEVEN_DAYS, ewma, reserved, a), _q(2_000e6, 0, SEVEN_DAYS, ewma, reserved, b));
    }
}
