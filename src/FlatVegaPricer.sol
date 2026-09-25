// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPremiumPricer} from "./interfaces/IPremiumPricer.sol";
import {Math} from "./libraries/Math.sol";

/// @title FlatVegaPricer
/// @notice Stateless premium quote implementing design §6.3. No exp/erf/sqrt on chain:
///         the statistics live in off-chain calibration; the chain does a table lookup,
///         one linear interpolation, and multiplications whose rounding direction is
///         readable on every line.
///
///         WAD reconciliation (design §6.3 line 210, deferred to implementation): the
///         doc writes `fair = varNotional × σ̂² × g(m) × coveredSeconds / SECONDS_PER_YEAR`
///         in symbols. Under the §6.0 unit convention `σ̂²` and `g(m)` are BOTH WAD, and
///         payout is `varNotional × varianceWAD / WAD`. So the honest scaling is
///
///             fair = varNotional × (σ̂²/WAD) × (g/WAD) × coveredSeconds / SECONDS_PER_YEAR
///
///         i.e. two extra `/WAD` beyond the symbolic form. Each step below carries one.
///
///         Every product on the premium path rounds UP (§9.2 favors the vault: charge
///         more), and moneyness rounds DOWN so it maps to a HIGHER g on the decreasing
///         table — also charging more. The `g(m)` knots, λ, load and minPremium are
///         immutable calibration set once at deploy (§6.4); nothing here is a design
///         decision, and no admin can move them mid-life.
contract FlatVegaPricer is IPremiumPricer {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint16 internal constant MAX_LOAD_BPS = 5_000; // 50% ceiling on underwriter load

    error BadConfig();
    error PremiumOverflow(uint256 premium);

    /// @notice Minimum premium (settlement-token units) — closes dust policies whose
    ///         settlement gas would exceed their premium (§6.3).
    uint128 public immutable minPremium;
    /// @notice Underwriter load in basis points, applied on top of fair value (§6.3).
    uint16 public immutable loadBps;
    /// @notice Utilization sensitivity λ (WAD): utilMult = WAD + λ × reserved/totalCapital.
    uint128 public immutable lambda;

    // g(m) knot table: strictly increasing moneyness m0<m1<..<m4 (WAD), each mapping to a
    // non-increasing g (WAD, ≤ WAD). Stored as scalars because Solidity has no immutable
    // arrays; five knots is enough shape for a single tenor's calibrated distribution.
    uint128 internal immutable m0;
    uint128 internal immutable m1;
    uint128 internal immutable m2;
    uint128 internal immutable m3;
    uint128 internal immutable m4;
    uint128 internal immutable g0;
    uint128 internal immutable g1;
    uint128 internal immutable g2;
    uint128 internal immutable g3;
    uint128 internal immutable g4;

    /// @param minPremium_ Floor premium in settlement-token units.
    /// @param loadBps_    Underwriter load (bps), ≤ MAX_LOAD_BPS.
    /// @param lambda_     Utilization sensitivity (WAD).
    /// @param mKnots      Moneyness knots (WAD), strictly increasing.
    /// @param gKnots      g values at each knot (WAD), non-increasing, each ≤ WAD.
    constructor(
        uint128 minPremium_,
        uint16 loadBps_,
        uint128 lambda_,
        uint128[5] memory mKnots,
        uint128[5] memory gKnots
    ) {
        if (loadBps_ > MAX_LOAD_BPS) revert BadConfig();
        // m strictly increasing.
        if (!(mKnots[0] < mKnots[1] && mKnots[1] < mKnots[2] && mKnots[2] < mKnots[3] && mKnots[3] < mKnots[4])) {
            revert BadConfig();
        }
        // g non-increasing and each a valid WAD fraction ≤ 1.
        for (uint256 i = 0; i < 5; i++) {
            if (gKnots[i] > WAD) revert BadConfig();
            if (i != 0 && gKnots[i] > gKnots[i - 1]) revert BadConfig();
        }
        minPremium = minPremium_;
        loadBps = loadBps_;
        lambda = lambda_;
        m0 = mKnots[0];
        m1 = mKnots[1];
        m2 = mKnots[2];
        m3 = mKnots[3];
        m4 = mKnots[4];
        g0 = gKnots[0];
        g1 = gKnots[1];
        g2 = gKnots[2];
        g3 = gKnots[3];
        g4 = gKnots[4];
    }

    /// @inheritdoc IPremiumPricer
    function quote(
        uint128 varNotional,
        uint64 strikeAnnualized,
        uint32 coveredSeconds,
        uint128 ewmaVariance,
        uint128 reserved,
        uint128 totalCapital
    ) external view returns (uint128) {
        // Nothing to price on: no variance regime, no notional, or no time bought.
        if (ewmaVariance == 0 || varNotional == 0 || coveredSeconds == 0) return minPremium;

        // Moneyness m = strike / σ̂² (WAD). Round DOWN → maps to a higher g on the
        // decreasing table → charges more (favors the vault).
        uint256 m = Math.mulDivDown(uint256(strikeAnnualized), WAD, uint256(ewmaVariance));
        uint256 g = _gOf(m);

        // fair = varNotional × (σ̂²/WAD) × (g/WAD) × coveredSeconds / SECONDS_PER_YEAR.
        // Round UP at each step (§9.2).
        uint256 fair = Math.mulDivUp(uint256(varNotional), uint256(ewmaVariance), WAD);
        fair = Math.mulDivUp(fair, g, WAD);
        fair = Math.mulDivUp(fair, uint256(coveredSeconds), SECONDS_PER_YEAR);

        // utilMult = WAD + λ × reserved/totalCapital. Scarce capacity costs more; this
        // is what balances the two sides without an order book (§6.3).
        uint256 utilMult = WAD;
        if (totalCapital != 0) {
            utilMult += Math.mulDivUp(uint256(lambda), uint256(reserved), uint256(totalCapital));
        }

        // loadMult = WAD + loadBps/BPS. Underwriter margin over fair value.
        uint256 loadMult = WAD + Math.mulDivUp(uint256(loadBps), WAD, BPS);

        uint256 premium = Math.mulDivUp(fair, utilMult, WAD);
        premium = Math.mulDivUp(premium, loadMult, WAD);

        if (premium < minPremium) premium = minPremium;
        if (premium > type(uint128).max) revert PremiumOverflow(premium);
        return uint128(premium);
    }

    /// @dev g(m) by linear interpolation on the immutable knot table, clamped flat
    ///      outside [m0, m4]. g is non-increasing in m, so the interpolated drop is
    ///      floored, leaving g itself rounded UP (favors the vault).
    function _gOf(uint256 m) internal view returns (uint256) {
        if (m <= m0) return g0;
        if (m >= m4) return g4;
        if (m < m1) return _interp(m, m0, m1, g0, g1);
        if (m < m2) return _interp(m, m1, m2, g1, g2);
        if (m < m3) return _interp(m, m2, m3, g2, g3);
        return _interp(m, m3, m4, g3, g4);
    }

    /// @dev Linear interpolation for a DECREASING segment (gLo ≥ gHi). The subtracted
    ///      drop is floored so the returned g rounds up.
    function _interp(uint256 m, uint256 mLo, uint256 mHi, uint256 gLo, uint256 gHi)
        internal
        pure
        returns (uint256)
    {
        uint256 drop = Math.mulDivDown(gLo - gHi, m - mLo, mHi - mLo);
        return gLo - drop;
    }
}
