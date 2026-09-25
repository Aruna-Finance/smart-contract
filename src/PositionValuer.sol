// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {Math} from "./libraries/Math.sol";

/// @title PositionValuer
/// @notice Stateless, view implementation of §8.4: derive `varNotional` (settlement
///         base units per 1 unit variance WAD, §6.0) from a Uniswap v3 position's
///         gamma exposure. The one LOCKED design decision it enforces is that
///         varNotional descends from the on-chain position — never a number the
///         caller types (§8.4 line 432). Everything numeric below (kappa, the width
///         reference and the multiplier bounds) is CALIBRATION (§6.4), set once at
///         deploy, awaiting backtest; none of it is a design claim and no admin can
///         move it mid-life.
///
///         Shape of the map, and why (design §8.4: "fungsi likuiditas dan lebar
///         range"). A v3 position in range has instantaneous dollar-gamma
///         Γ$ = L·√P / 2 — proportional to liquidity L. So absolute variance
///         exposure tracks L linearly; kappa folds √P and the §6.0 unit scaling
///         into one immutable coefficient (it cannot read price here — §3.5 keeps
///         slot0 off the settlement path). Range WIDTH enters as concentration:
///         at equal L a narrow range packs the same gamma into fewer dollars, so
///         it carries MORE variance-per-dollar. The width multiplier is therefore
///         DECREASING in tick width, neutral (WAD) at refWidth, and clamped to
///         [minWidthMult, maxWidthMult] so neither a dust-thin nor a near-full-range
///         position runs off to an unbounded or zero notional.
///
///             varNotional = kappa × liquidity/WAD × widthMult/WAD   (round DOWN)
///             widthMult   = clamp(WAD × refWidth / widthTicks, min, max)
///
///         Rounding is DOWN throughout: varNotional is a liability input (it caps
///         maxPayout), so the vault prefers the smaller figure. The exact curve is a
///         documented linear placeholder — the honest first cut of §6.4, not a fitted
///         model — and is expected to be replaced by calibrated knots after backtest.
contract PositionValuer is IPositionValuer {
    uint256 internal constant WAD = 1e18;

    error BadConfig();
    error InvalidRange(int24 tickLower, int24 tickUpper);
    error NotionalOverflow(uint256 varNotional);

    /// @notice Uniswap v3 position manager the tokenId is read from.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Settlement base units of variance notional per unit of liquidity,
    ///         with √P and the §6.0 scaling folded in (WAD). Calibration (§6.4).
    uint128 public immutable kappa;
    /// @notice Tick width at which the concentration multiplier is neutral (WAD).
    ///         Calibration (§6.4); must be > 0.
    int24 public immutable refWidth;
    /// @notice Lower clamp on the width multiplier (WAD) — the floor a very wide,
    ///         near-full-range position collapses to. Calibration (§6.4).
    uint128 public immutable minWidthMult;
    /// @notice Upper clamp on the width multiplier (WAD) — the cap a dust-thin range
    ///         is held to, so concentration cannot blow the notional up. Calibration.
    uint128 public immutable maxWidthMult;

    /// @param positionManager_ The v3 position manager to read positions from.
    /// @param kappa_           Variance notional per unit liquidity (WAD).
    /// @param refWidth_        Neutral tick width (> 0).
    /// @param minWidthMult_    Lower clamp on width multiplier (WAD), ≤ maxWidthMult_.
    /// @param maxWidthMult_    Upper clamp on width multiplier (WAD), ≥ WAD ≥ min.
    constructor(
        address positionManager_,
        uint128 kappa_,
        int24 refWidth_,
        uint128 minWidthMult_,
        uint128 maxWidthMult_
    ) {
        if (positionManager_ == address(0)) revert BadConfig();
        if (refWidth_ <= 0) revert BadConfig();
        // A sane clamp brackets the neutral point: min ≤ WAD ≤ max.
        if (!(minWidthMult_ <= WAD && WAD <= maxWidthMult_)) revert BadConfig();
        positionManager = INonfungiblePositionManager(positionManager_);
        kappa = kappa_;
        refWidth = refWidth_;
        minWidthMult = minWidthMult_;
        maxWidthMult = maxWidthMult_;
    }

    /// @inheritdoc IPositionValuer
    function varNotionalFor(uint256 positionTokenId) external view returns (uint128) {
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            positionManager.positions(positionTokenId);

        // A position with no liquidity has no gamma to hedge.
        if (liquidity == 0) return 0;
        if (tickUpper <= tickLower) revert InvalidRange(tickLower, tickUpper);

        // Width strictly positive after the guard above; widen to int256 before the
        // subtraction so the int24 range can never underflow.
        uint256 widthTicks = uint256(int256(tickUpper) - int256(tickLower));

        // widthMult = clamp(WAD × refWidth / widthTicks, min, max). Round DOWN; the
        // clamp keeps it monotone non-increasing in widthTicks and bounded.
        uint256 widthMult = Math.mulDivDown(WAD, uint256(int256(refWidth)), widthTicks);
        if (widthMult < minWidthMult) widthMult = minWidthMult;
        if (widthMult > maxWidthMult) widthMult = maxWidthMult;

        // varNotional = kappa × liquidity/WAD × widthMult/WAD, each step DOWN.
        uint256 varNotional = Math.mulDivDown(uint256(kappa), uint256(liquidity), WAD);
        varNotional = Math.mulDivDown(varNotional, widthMult, WAD);

        if (varNotional > type(uint128).max) revert NotionalOverflow(varNotional);
        return uint128(varNotional);
    }
}
