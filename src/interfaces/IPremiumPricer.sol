// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPremiumPricer
/// @notice Stateless premium quote (design §8.3). No vault storage access, so it can
///         be fuzzed as a pure function: monotonicity in each argument is directly
///         testable. The vault passes in everything the formula needs; the pricer
///         holds only immutable calibration (g(m) knots, λ, load, minPremium).
///
///         All variance quantities are WAD; `varNotional` follows the §6.0 unit
///         convention (settlement-token base units per 1 unit of variance), so the
///         pricer divides by WAD wherever a product touches variance.
interface IPremiumPricer {
    /// @param varNotional        Payout per 1 unit variance (WAD), derived from position.
    /// @param strikeAnnualized   Strike as annualized variance (WAD), e.g. 0.1225e18 = 35% vol.
    /// @param coveredSeconds     Seconds of protection actually purchased.
    /// @param ewmaVariance       Vault's EWMA annualized realized variance (WAD).
    /// @param reserved           Currently reserved capacity (settlement-token units).
    /// @param totalCapital       Cohort total capital (settlement-token units).
    /// @return premium           Premium in settlement-token units, rounded UP (§9.2).
    function quote(
        uint128 varNotional,
        uint64 strikeAnnualized,
        uint32 coveredSeconds,
        uint128 ewmaVariance,
        uint128 reserved,
        uint128 totalCapital
    ) external view returns (uint128 premium);
}
