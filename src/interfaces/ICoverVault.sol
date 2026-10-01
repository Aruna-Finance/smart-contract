// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICoverVault
/// @notice The one contract that holds funds (design §2). One vault per (pool, tenor)
///         — B5/A2 reconciliation, no longer "one per pool". Underwriters pool
///         capital per cohort; LPs buy position-attached cover; settlement is two
///         permissionless phases. The vault measures nothing and prices nothing: it
///         reads variance from the accumulator and premiums from the pricer.
interface ICoverVault {
    /// @dev Design §8.2 (B1: this enum is authoritative; §4.1's EXPIRED is folded away).
    ///      v2 (plan "Kalender dan status", R7): the status is DERIVED from the calendar
    ///      plus one stored "resolved" mark, so a cohort nobody ever touched still reads
    ///      the right value by time:
    ///        FUNDING  — now < startsAt: deposits/withdrawals open, no selling.
    ///        ACTIVE   — startsAt ≤ now < endsAt: selling open, capital locked.
    ///        SETTLING — now ≥ endsAt and the cohort is capitalized but not yet resolved
    ///                   (finalize pending, or policies still to settle).
    ///        SETTLED  — resolved: finalized with every policy settled, or a cohort that
    ///                   never held capital, which is SETTLED as soon as endsAt passes
    ///                   (no finalize, no EWMA update).
    enum Status {
        FUNDING,
        ACTIVE,
        SETTLING,
        SETTLED
    }

    /// @dev `startsAt`, `endsAt` and `status` are filled by the `cohort()` view from the
    ///      calendar (they are not read from storage). Storage packing (slots):
    ///        0: startsAt | endsAt | totalCapital
    ///        1: reserved | premiumsCollected
    ///        2: claimsPaid | startIndex | endIndex | policyCount | settledCount
    ///        3: status | finalized | degraded | snapshotTaken | remainingPrincipal
    ///        4: paidOut | varianceSnapshot
    struct Cohort {
        uint64 startsAt;
        uint64 endsAt;
        uint128 totalCapital; // capital at risk; frozen once ACTIVE (share denominator)
        uint128 reserved;
        uint128 premiumsCollected; // premiums + residual swept in at finalize
        uint128 claimsPaid;
        uint32 startIndex; // window bracket, locked at finalize
        uint32 endIndex; // window bracket, locked at finalize
        uint32 policyCount;
        uint32 settledCount;
        Status status;
        bool finalized; // window locked (SC-03: finalize never reverts for lack of samples)
        bool degraded; // informational: a sample gap above the threshold in the window (AE6)
        bool snapshotTaken; // σ̂² snapshot fixed on the first touch after startsAt
        uint128 remainingPrincipal; // Σ deposits not yet withdrawn or rolled out
        uint128 paidOut; // Σ nets withdrawn or rolled out after settlement
        uint128 varianceSnapshot; // σ̂² the cohort prices with (annualized WAD)
    }

    struct Policy {
        address owner; //          ┐ one slot
        uint96 maxPayout; //       ┘ derived in vault (§6.0), not an input
        uint128 varNotional; //    ┐ one slot — derived from position, not an input
        uint128 startSumSq; //     ┘
        uint64 strikeAnnualized; // annualized variance (WAD), not a percent
        uint32 coveredSeconds;
        uint32 startIndex;
        uint32 cohortId;
        bool settled;
        uint256 positionTokenId; // the Uniswap position protected (invariant I8)
    }

    event Deposited(uint32 indexed cohortId, address indexed underwriter, uint128 amount);
    event Withdrawn(uint32 indexed cohortId, address indexed underwriter, uint256 net);
    event Rolled(
        uint32 indexed fromCohort,
        uint32 indexed toCohort,
        address indexed underwriter,
        uint128 amount
    );
    event CoverBought(
        uint256 indexed policyId,
        uint32 indexed cohortId,
        address indexed owner,
        uint256 positionTokenId,
        uint128 premium,
        uint96 maxPayout
    );
    event Finalized(uint32 indexed cohortId, uint32 endIndex, uint128 finalSumSq);
    event PolicySettled(uint256 indexed policyId, uint32 indexed cohortId, uint128 payout);
    event Unclaimed(address indexed owner, uint128 amount);
    event Claimed(address indexed owner, uint256 amount);
    /// @notice Emitted after `Finalized` (canonical event kept first for the indexer).
    event WindowResolved(
        uint32 indexed cohortId,
        uint32 startIndex,
        uint32 endIndex,
        uint32 returnCount,
        bool degraded,
        bool ewmaUpdated
    );
    event VarianceSnapshot(uint32 indexed cohortId, uint128 variance);
    /// @notice Rounding dust of a fully exited cohort leaves its books and becomes residual.
    event ResidualReleased(uint32 indexed cohortId, uint256 amount);
    /// @notice Residual swept into the premium pool of a capitalized cohort at its finalize.
    event ResidualSwept(uint32 indexed cohortId, uint256 amount);

    // --- underwriter ---
    function deposit(uint32 cohortId, uint128 amount) external;
    function withdraw(uint32 cohortId) external returns (uint256 net);
    function rollTo(uint32 fromCohort, uint32 toCohort) external; // B3: two-arg

    // --- LP: quote & buyCover are position-attached; varNotional & maxPayout are outputs ---
    /// @dev maxPayout returns as uint96 per the §6.0 narrowing (event/return match the
    ///      struct's slot-packed width, rather than widening to uint128).
    function quote(uint32 cohortId, uint256 positionTokenId, uint64 strikeAnnualized)
        external
        view
        returns (uint128 premium, uint128 varNotional, uint96 maxPayout, uint32 coveredSeconds);

    function buyCover(
        uint32 cohortId,
        uint256 positionTokenId,
        uint64 strikeAnnualized,
        uint128 maxPremium,
        uint64 deadline
    ) external returns (uint256 policyId);

    // --- anyone (permissionless) ---
    function finalize(uint32 cohortId) external;
    function settleBatch(uint32 cohortId, uint32 n) external;

    // --- pull fallback for push-payout failures (B6, design §7.3) ---
    function unclaimed(address owner) external view returns (uint256 amount);
    function claimUnclaimed() external returns (uint256 amount);

    // --- calendar & status (plan "Kalender dan status") ---
    function startsAt(uint32 cohortId) external view returns (uint64);
    function endsAt(uint32 cohortId) external view returns (uint64);
    function currentCohortId() external view returns (uint32);
    function statusOf(uint32 cohortId) external view returns (Status);

    // --- accounting (plan "Akuntansi", invariant I3) ---
    function totalObligations() external view returns (uint256);
    function residual() external view returns (uint256);
}
