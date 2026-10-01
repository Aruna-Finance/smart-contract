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

    /// @dev Policy lifecycle (plan "Polis dan escrow"). Active is the only non-final
    ///      status; Cancelled leaves the cohort's settle queue, Settled / Refunded are the
    ///      two settle outcomes (measured vs. fewer than 2 returns after the baseline).
    enum PolicyStatus {
        Active,
        Cancelled,
        Settled,
        Refunded
    }

    /// @dev `startsAt`, `endsAt` and `status` are filled by the `cohort()` view from the
    ///      calendar (they are not read from storage). Storage packing (slots):
    ///        0: startsAt | endsAt | totalCapital
    ///        1: reserved | premiumsCollected
    ///        2: claimsPaid | startIndex | endIndex | policyCount | settledCount
    ///        3: status | finalized | degraded | snapshotTaken | remainingPrincipal | settleCursor
    ///        4: paidOut | varianceSnapshot
    ///        5: cancelledPremiums
    ///      v2 (U5): `policyCount` counts LIVE policies — the length of the settle queue,
    ///      so a cancel decrements it and frees a slot under the per-cohort cap.
    ///      `settledCount` counts queued policies in a final settle status (Settled or
    ///      Refunded); the cohort resolves when settledCount == policyCount, whatever the
    ///      order they were settled in. `settleCursor` is only where settleBatch resumes.
    struct Cohort {
        uint64 startsAt;
        uint64 endsAt;
        uint128 totalCapital; // capital at risk; frozen once ACTIVE (share denominator)
        uint128 reserved;
        uint128 premiumsCollected; // premiums (incl. cancelled, net of refunds) + residual swept in
        uint128 claimsPaid;
        uint32 startIndex; // window bracket, locked at finalize
        uint32 endIndex; // window bracket, locked at finalize
        uint32 policyCount; // live policies (settle queue length)
        uint32 settledCount; // queued policies already Settled or Refunded
        Status status;
        bool finalized; // window locked (SC-03: finalize never reverts for lack of samples)
        bool degraded; // informational: a sample gap above the threshold in the window (AE6)
        bool snapshotTaken; // σ̂² snapshot fixed on the first touch after startsAt
        uint128 remainingPrincipal; // Σ deposits not yet withdrawn or rolled out
        uint32 settleCursor; // settleBatch resume position in the settle queue
        uint128 paidOut; // Σ nets withdrawn or rolled out after settlement
        uint128 varianceSnapshot; // σ̂² the cohort prices with (annualized WAD)
        uint128 cancelledPremiums; // Σ premiums of cancelled policies (U6 skims at finalize)
    }

    /// @dev v2 (U5): the window baseline is resolved at SETTLE, not at purchase:
    ///      `startIndex` is the first sample s whose predecessor is at/after `purchasedAt`,
    ///      and `startSumSq` its cumulativeSumSq — both 0 until the policy settles measured
    ///      (a refunded policy records startIndex only). Readers must use the settled values.
    ///      Storage: owner|maxPayout · varNotional|startSumSq · strike|coveredSeconds|
    ///      startIndex|cohortId|purchasedAt|queueIndex|status|nftParked · premium · tokenId.
    struct Policy {
        address owner; //          ┐ one slot
        uint96 maxPayout; //       ┘ derived in vault (§6.0), not an input
        uint128 varNotional; //    ┐ one slot — derived from position, not an input
        uint128 startSumSq; //     ┘ resolved at settle
        uint64 strikeAnnualized; // annualized variance (WAD), not a percent
        uint32 coveredSeconds;
        uint32 startIndex; // resolved at settle (window baseline sample)
        uint32 cohortId;
        uint32 purchasedAt; // purchase timestamp: the baseline is the first sample after it
        uint32 queueIndex; // position in the cohort's settle queue (swap-and-pop on cancel)
        PolicyStatus status;
        bool nftParked; // the NFT return failed; the owner pulls it with claimPosition
        uint128 premium; // refunded in full when the policy cannot be measured
        uint256 positionTokenId; // the Uniswap position protected and escrowed (I8)
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

    // --- v2 policy / escrow events. Each is emitted AFTER the canonical event of the same
    //     action (CoverBought, PolicySettled), so the indexer's existing log pairing —
    //     notably `Unclaimed` immediately before `PolicySettled` — is unchanged. ---
    /// @notice The position NFT entered escrow at purchase (fees owed were paid to `owner`).
    event PositionEscrowed(
        uint256 indexed policyId, uint256 indexed tokenId, address indexed owner
    );
    /// @notice The position NFT left escrow back to the policy owner.
    event PositionReturned(
        uint256 indexed policyId, uint256 indexed tokenId, address indexed owner
    );
    /// @notice The NFT return failed; the NFT stays in the vault for `claimPosition`.
    event PositionParked(uint256 indexed policyId, uint256 indexed tokenId, address indexed owner);
    /// @notice A parked NFT was pulled by its policy owner.
    event PositionClaimed(uint256 indexed policyId, uint256 indexed tokenId, address indexed owner);
    /// @notice The policy owner collected the escrowed position's fees to `recipient`.
    event FeesCollected(
        uint256 indexed policyId, address indexed recipient, uint256 amount0, uint256 amount1
    );
    /// @notice Cancelled before endsAt: the premium stays with the cohort.
    event PolicyCancelled(uint256 indexed policyId, uint32 indexed cohortId, uint128 premium);
    /// @notice Fewer than 2 returns after the baseline: the full premium goes back to the
    ///         owner (pushed, or parked in `unclaimed` — then preceded by `Unclaimed`).
    ///         Emitted after `PolicySettled(policyId, cohortId, 0)`.
    event PolicyRefunded(uint256 indexed policyId, uint32 indexed cohortId, uint128 premium);

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

    // --- policy owner ---
    /// @notice Cancel before endsAt: premium stays with the cohort, NFT returned.
    function cancel(uint256 policyId) external;
    /// @notice Collect the escrowed position's fees to `recipient` (policy owner only).
    function collectFees(uint256 policyId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);
    /// @notice Pull a parked NFT (its return failed at settle or cancel).
    function claimPosition(uint256 policyId) external;

    // --- anyone (permissionless) ---
    function finalize(uint32 cohortId) external;
    function settleBatch(uint32 cohortId, uint32 n) external;
    /// @notice Settle one policy after endsAt, in any order (finalizes lazily).
    function settlePolicy(uint256 policyId) external;

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
