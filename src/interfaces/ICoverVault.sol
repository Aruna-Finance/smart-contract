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
    ///      FUNDING: deposits/withdrawals open, no selling. ACTIVE: selling open,
    ///      capital locked. SETTLING: finalize() done, payouts being pushed.
    ///      SETTLED: all claims paid, underwriters may withdraw.
    enum Status {
        FUNDING,
        ACTIVE,
        SETTLING,
        SETTLED
    }

    struct Cohort {
        uint64 startsAt;
        uint64 endsAt;
        uint128 totalCapital;
        uint128 reserved;
        uint128 premiumsCollected;
        uint128 claimsPaid;
        uint32 startIndex;
        uint32 endIndex;
        uint32 policyCount;
        uint32 settledCount;
        Status status;
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
}
