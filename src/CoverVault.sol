// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICoverVault} from "./interfaces/ICoverVault.sol";
import {IVarianceAccumulator} from "./interfaces/IVarianceAccumulator.sol";
import {IPremiumPricer} from "./interfaces/IPremiumPricer.sol";
import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3PoolMinimal} from "./interfaces/IUniswapV3PoolMinimal.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {Math} from "./libraries/Math.sol";

/// @title CoverVault
/// @notice The only Aruna contract that holds funds (design §2). One vault per
///         (pool, tenor). It measures nothing and prices nothing — variance comes
///         from the accumulator, premiums from the pricer, notional from the position
///         valuer. All it does is custody capital, sell position-attached cover, and
///         settle in two permissionless phases.
///
///         Capital is locked for a cohort's life (§4.2), so ownership ratios never
///         move mid-cycle: `share_u = deposit[u] / totalCapital`, computed only at
///         withdraw. There is no share token and no `balanceOf`-derived ratio, which
///         removes the entire donation / first-depositor inflation class (§5.1).
///
///         Every money-path rounding favors the vault (§9.2): payout DOWN, premium
///         UP, strike threshold UP, premium-share DOWN, claim-share UP. All products
///         go through Math.mulDiv{Up,Down} so the direction is readable per line.
///
///         v2 calendar (plan "Kalender dan status", R8–R11): cohorts are separated by a
///         settlement gap, `startsAt(n) = anchor + n·(tenor + gap)`, `endsAt(n) =
///         startsAt(n) + tenor`, and cohort n's gap is `[endsAt(n), startsAt(n+1))`. A
///         cohort's status is derived from that calendar plus one stored "resolved" mark,
///         finalize never reverts for lack of samples (SC-03), and underwriter capital can
///         roll into cohort n+1 during n's gap (SC-04). The vault tracks every obligation
///         it owes, so `residual = balance − obligations` is explicit and testable (R5, I3).
contract CoverVault is ICoverVault {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant BPS = 10_000;

    /// @dev Gas stipend for the payout push. A griefing recipient that burns more
    ///      than this reverts only its own transfer; the batch continues and the
    ///      payout lands in `unclaimed` (design §7.3).
    uint256 internal constant PUSH_GAS = 100_000;

    /// @notice A cohort window is flagged `degraded` (AE6, informational only) when two
    ///         consecutive samples in it — or a window edge and its nearest sample — are
    ///         more than DEGRADED_GAP_MULTIPLE × sampleInterval apart, i.e. at least two
    ///         whole sampling intervals were missed. One late keeper tick is not degraded.
    uint256 public constant DEGRADED_GAP_MULTIPLE = 3;

    /// @notice Hard bound on the samples finalize scans for the degraded flag. The
    ///         constructor rejects any (tenor, sampleInterval) whose undegraded window
    ///         could hold more, so the scan is bounded by configuration, never by input.
    uint256 public constant MAX_SCAN_SAMPLES = 2_048;

    // --- immutables (set at deploy, never change: no admin can reprice a live market) ---
    IUniswapV3PoolMinimal public immutable pool;
    IVarianceAccumulator public immutable accumulator;
    IPremiumPricer public immutable pricer;
    IPositionValuer public immutable valuer;
    INonfungiblePositionManager public immutable positionManager;
    IERC20 public immutable settlementToken;

    address internal immutable poolToken0;
    address internal immutable poolToken1;
    uint24 internal immutable poolFee;

    uint32 public immutable tenor; // seconds; cohort selling + coverage length
    uint32 public immutable gap; // seconds; settlement gap between endsAt(n) and startsAt(n+1)
    uint64 public immutable anchor; // startsAt(n) = anchor + n * (tenor + gap)
    /// @notice Read once from the accumulator at deploy (the factory forwards one interval
    ///         to the accumulator; the vault never takes a second copy that could disagree).
    uint32 public immutable sampleInterval;
    uint16 public immutable maxUtilizationBps; // I1 lever; 8000 recommended, not 10000
    uint128 public immutable maxExcessVariance; // caps maxPayout = varNotional * this / WAD
    uint16 public immutable ewmaAlphaBps; // EWMA weight on the newest cohort

    /// @dev Max samples between the window's bracketing indices when NOT degraded:
    ///      tenor/interval + DEGRADED_GAP_MULTIPLE + 1 (see _scanDegraded).
    uint256 internal immutable _maxScan;

    // --- state ---
    /// @dev EWMA of annualized realized variance (WAD), updated only by finalize so it
    ///      can never be nudged mid-cycle. Seeded at deploy. Packs with the two fields
    ///      below into one slot.
    uint128 public ewmaVariance;
    /// @notice The last cohort whose finalize updated the EWMA (valid once
    ///         `ewmaEverUpdated`). Updates are monotone in cohort id and may skip.
    uint32 public lastEwmaCohortId;
    bool public ewmaEverUpdated;

    mapping(uint32 => Cohort) internal _cohorts;
    mapping(uint32 => mapping(address => uint128)) public deposits; // cohortId => underwriter => amount
    mapping(uint32 => uint256[]) internal _cohortPolicies; // cohortId => policyIds (settle cursor order)
    mapping(address => uint256) internal _unclaimed; // push-payout fallback (B6)

    Policy[] internal _policies; // global; policyId == index

    /// @dev Every token amount the vault owes (plan "Akuntansi"): open cohort books
    ///      (capital + premiums − claims − nets paid out) plus parked payouts. Anything
    ///      the vault holds above this is residual (`residual()`).
    uint256 internal _obligations;

    uint256 internal _locked = 1; // reentrancy guard (1 = free, 2 = entered)

    error Reentrancy();
    error BadConfig();
    error NotFunding(uint32 cohortId);
    error NotActive(uint32 cohortId);
    error NotSettling(uint32 cohortId);
    error NotSettled(uint32 cohortId);
    error NotExpiredYet(uint32 cohortId);
    error AlreadyFinalized(uint32 cohortId);
    error ZeroCapital(uint32 cohortId);
    error NoSamples();
    error PositionNotOwned(uint256 tokenId);
    error PositionWrongPool(uint256 tokenId);
    error CapacityExceeded(uint128 wouldReserve, uint128 available);
    error PremiumTooHigh(uint128 premium, uint128 maxPremium);
    error QuoteExpired(uint64 deadline);
    error MaxPayoutOverflow(uint256 value);
    error NothingToWithdraw();
    error TransferFailed();

    /// @dev The variance window a finalize locks: the samples bracketing
    ///      [startsAt, endsAt] that actually exist (SC-03).
    struct Window {
        bool hasSamples; // some sample at-or-before endsAt exists
        uint32 startIndex;
        uint32 endIndex;
        uint32 returnCount; // log returns in (startIndex, endIndex] (accumulator semantics)
        uint32 startTs;
        uint32 endTs;
        uint128 startSumSq;
        uint128 endSumSq;
    }

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @param gap_ Settlement gap in seconds (R8): forwarded by the factory, > 0 so a
    ///        settled cohort can roll into the next one before it starts.
    /// @dev `sampleInterval` is read from the accumulator, which must already be
    ///      configured; the scan bound is validated against it here.
    constructor(
        address pool_,
        address accumulator_,
        address pricer_,
        address valuer_,
        address positionManager_,
        address settlementToken_,
        uint32 tenor_,
        uint32 gap_,
        uint64 anchor_,
        uint16 maxUtilizationBps_,
        uint128 maxExcessVariance_,
        uint16 ewmaAlphaBps_,
        uint128 seedVariance_
    ) {
        if (
            pool_ == address(0) || accumulator_ == address(0) || pricer_ == address(0)
                || valuer_ == address(0) || positionManager_ == address(0)
                || settlementToken_ == address(0) || tenor_ == 0 || gap_ == 0
                || maxUtilizationBps_ == 0 || maxUtilizationBps_ > BPS || maxExcessVariance_ == 0
                || ewmaAlphaBps_ > BPS
        ) revert BadConfig();

        uint32 interval = IVarianceAccumulator(accumulator_).sampleInterval();
        if (interval == 0) revert BadConfig();
        uint256 maxScan = uint256(tenor_) / interval + DEGRADED_GAP_MULTIPLE + 1;
        if (maxScan > MAX_SCAN_SAMPLES) revert BadConfig();

        pool = IUniswapV3PoolMinimal(pool_);
        accumulator = IVarianceAccumulator(accumulator_);
        pricer = IPremiumPricer(pricer_);
        valuer = IPositionValuer(valuer_);
        positionManager = INonfungiblePositionManager(positionManager_);
        settlementToken = IERC20(settlementToken_);

        poolToken0 = IUniswapV3PoolMinimal(pool_).token0();
        poolToken1 = IUniswapV3PoolMinimal(pool_).token1();
        poolFee = IUniswapV3PoolMinimal(pool_).fee();

        tenor = tenor_;
        gap = gap_;
        anchor = anchor_;
        sampleInterval = interval;
        _maxScan = maxScan;
        maxUtilizationBps = maxUtilizationBps_;
        maxExcessVariance = maxExcessVariance_;
        ewmaAlphaBps = ewmaAlphaBps_;
        ewmaVariance = seedVariance_;
    }

    // ---------------------------------------------------------------------
    // Underwriter
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoverVault
    function deposit(uint32 cohortId, uint128 amount) external nonReentrant {
        if (amount == 0) revert BadConfig();
        Cohort storage c = _cohorts[cohortId];
        // Deposits only while the cohort has not started — capital is locked once
        // it goes ACTIVE (§4.2), which is what makes settlement O(1) per underwriter.
        // A past cohort never reads FUNDING, touched or not.
        if (_status(cohortId, c) != Status.FUNDING) revert NotFunding(cohortId);

        _pull(msg.sender, amount);
        deposits[cohortId][msg.sender] += amount;
        c.totalCapital += amount;
        c.remainingPrincipal += amount;
        _obligations += amount;
        emit Deposited(cohortId, msg.sender, amount);
    }

    /// @inheritdoc ICoverVault
    /// @dev FUNDING: returns the deposit and REMOVES it from the cohort's capital (SC-01,
    ///      AE1), so capacity is never sold against money that left. SETTLED: pays the
    ///      net (§7.4). A capitalized cohort with no policies past endsAt is finalized
    ///      lazily here; one with unresolved policies still reverts NotSettled.
    ///      A deposit wiped to a zero net is still cleared (no transfer), so the cohort's
    ///      remaining principal can reach zero and its dust can become residual.
    function withdraw(uint32 cohortId) external nonReentrant returns (uint256 net) {
        Cohort storage c = _cohorts[cohortId];
        Status s = _resolveForExit(cohortId, c);
        // Withdrawals are legal only before capital is ever at risk (FUNDING) or
        // after every obligation is paid (SETTLED). §5.4.
        if (s != Status.FUNDING && s != Status.SETTLED) revert NotSettled(cohortId);

        uint128 dep = deposits[cohortId][msg.sender];
        if (dep == 0) revert NothingToWithdraw();
        deposits[cohortId][msg.sender] = 0;

        if (s == Status.FUNDING) {
            net = dep; // capital never went at risk
            c.totalCapital -= dep;
            c.remainingPrincipal -= dep;
        } else {
            net = _settledNet(dep, c);
            _exitSettled(cohortId, c, dep, net);
        }
        _obligations -= net;

        if (net > 0) _push(msg.sender, net); // accounted obligation; not gas-limited
        emit Withdrawn(cohortId, msg.sender, net);
    }

    /// @inheritdoc ICoverVault
    /// @dev Moves an underwriter's settled net straight into a FUNDING cohort of this
    ///      vault with no token round-trip (§5.4, R11). Always explicit, never a default.
    ///      With the gap, cohort n settled during [endsAt(n), startsAt(n+1)) can roll into
    ///      n+1; a later roll targets n+2 (AE3/AE4).
    function rollTo(uint32 fromCohort, uint32 toCohort) external nonReentrant {
        Cohort storage from = _cohorts[fromCohort];
        if (_resolveForExit(fromCohort, from) != Status.SETTLED) revert NotSettled(fromCohort);

        Cohort storage to = _cohorts[toCohort];
        if (_status(toCohort, to) != Status.FUNDING) revert NotFunding(toCohort);

        uint128 dep = deposits[fromCohort][msg.sender];
        uint256 net = _settledNet(dep, from);
        if (net == 0) revert NothingToWithdraw();

        deposits[fromCohort][msg.sender] = 0;
        _exitSettled(fromCohort, from, dep, net);

        // Obligations unchanged: the same tokens move from one cohort's books to another.
        uint128 amount = uint128(net); // net ≤ totalCapital + premiums, well within uint128
        deposits[toCohort][msg.sender] += amount;
        to.totalCapital += amount;
        to.remainingPrincipal += amount;
        emit Rolled(fromCohort, toCohort, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // LP — position-attached quote & buyCover
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoverVault
    /// @dev Prices with the cohort's σ̂² snapshot. Before the snapshot is taken (no touch
    ///      after startsAt yet) it returns what the snapshot WOULD be if taken now: the
    ///      EWMA after finalizing the previous cohort when that is still pending. During
    ///      FUNDING, before the previous cohort ends, this is the current EWMA and is
    ///      indicative only.
    function quote(uint32 cohortId, uint256 positionTokenId, uint64 strikeAnnualized)
        external
        view
        returns (uint128 premium, uint128 varNotional, uint96 maxPayout, uint32 coveredSeconds)
    {
        Cohort storage c = _cohorts[cohortId];
        _requirePositionMatchesPool(positionTokenId); // ownership NOT required to quote

        varNotional = valuer.varNotionalFor(positionTokenId);
        coveredSeconds = _coveredSeconds(cohortId);
        maxPayout = _deriveMaxPayout(varNotional);
        premium = pricer.quote(
            varNotional,
            strikeAnnualized,
            coveredSeconds,
            _pricingVariance(cohortId, c),
            c.reserved,
            c.totalCapital
        );
    }

    /// @inheritdoc ICoverVault
    /// @dev TODO(U5): poke-on-touch (tryPoke), ≥5-interval remaining-time gate, min maxPayout
    ///      and live-policy cap, NFT escrow (transferFrom into the vault, collect
    ///      tokensOwed, snapshot varNotional), purchase timestamp instead of the
    ///      startIndex/startSumSq recorded below (baseline resolved at settle).
    function buyCover(
        uint32 cohortId,
        uint256 positionTokenId,
        uint64 strikeAnnualized,
        uint128 maxPremium,
        uint64 deadline
    ) external nonReentrant returns (uint256 policyId) {
        if (block.timestamp > deadline) revert QuoteExpired(deadline);

        Cohort storage c = _cohorts[cohortId];
        if (_status(cohortId, c) != Status.ACTIVE) revert NotActive(cohortId);
        // SC-16: a cohort without capital sells nothing (and is SETTLED at endsAt).
        if (c.totalCapital == 0) revert ZeroCapital(cohortId);

        // Position-attached: prove ownership NOW and that the position is this pool's.
        // A speculator with no position cannot buy; an LP cannot cover someone else's
        // position (design §8.2, invariant I8). Ownership is a precondition at buy,
        // not a standing invariant — the NFT may be sold afterward.
        if (positionManager.ownerOf(positionTokenId) != msg.sender) {
            revert PositionNotOwned(positionTokenId);
        }
        _requirePositionMatchesPool(positionTokenId);

        // First touch after startsAt: finalize the previous cohort if pending, then fix
        // this cohort's σ̂². Every later policy of the cohort prices with it (R10).
        uint128 sigma2 = _touchSnapshot(cohortId, c);

        uint32 sampleCount = accumulator.sampleCount();
        if (sampleCount == 0) revert NoSamples();

        // varNotional falls out of the position's gamma exposure — never a caller input.
        uint128 varNotional = valuer.varNotionalFor(positionTokenId);
        uint96 maxPayout = _deriveMaxPayout(varNotional);
        uint32 coveredSeconds = _coveredSeconds(cohortId);

        // Capacity: reserved + maxPayout ≤ totalCapital * util / 10_000 (invariant I1).
        // Premiums never add capacity (§5.2): selling cover with the buyer's own money
        // is exactly what this line forbids.
        uint128 available = uint128(uint256(c.totalCapital).mulDivDown(maxUtilizationBps, BPS));
        uint128 wouldReserve = c.reserved + maxPayout;
        if (wouldReserve > available) revert CapacityExceeded(wouldReserve, available);

        uint128 premium = pricer.quote(
            varNotional, strikeAnnualized, coveredSeconds, sigma2, c.reserved, c.totalCapital
        );
        if (premium > maxPremium) revert PremiumTooHigh(premium, maxPremium);

        // Per-policy window (§6.2): record the cumulative sum-of-squares at purchase;
        // settlement subtracts it once.
        uint32 startIndex = sampleCount - 1;
        uint128 startSumSq = accumulator.sampleAt(startIndex).cumulativeSumSq;

        // Effects before interaction (CEI): reserve, record premium, store policy.
        // TODO(U6): the keeper skim is taken after endsAt (at settle / finalize), never here.
        c.reserved = wouldReserve;
        c.premiumsCollected += premium;
        c.policyCount += 1;
        _obligations += premium;

        policyId = _policies.length;
        _policies.push(
            Policy({
                owner: msg.sender,
                maxPayout: maxPayout,
                varNotional: varNotional,
                startSumSq: startSumSq,
                strikeAnnualized: strikeAnnualized,
                coveredSeconds: coveredSeconds,
                startIndex: startIndex,
                cohortId: cohortId,
                settled: false,
                positionTokenId: positionTokenId
            })
        );
        _cohortPolicies[cohortId].push(policyId);

        _pull(msg.sender, premium);
        emit CoverBought(policyId, cohortId, msg.sender, positionTokenId, premium, maxPayout);
    }

    // ---------------------------------------------------------------------
    // Settlement (permissionless, two phases)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoverVault
    /// @dev Locks the cohort's variance window from whatever samples exist and NEVER
    ///      reverts for lack of them (SC-03, AE5). Explicit entry point for keepers; the
    ///      same path runs lazily from settleBatch, withdraw/rollTo (zero-policy cohorts)
    ///      and the first touch of the next cohort. A cohort that never held capital is
    ///      SETTLED by time and has nothing to finalize.
    function finalize(uint32 cohortId) external nonReentrant {
        Cohort storage c = _cohorts[cohortId];
        if (block.timestamp < _endsAt(cohortId)) revert NotExpiredYet(cohortId);
        if (c.finalized || c.totalCapital == 0) revert AlreadyFinalized(cohortId);
        _finalize(cohortId, c);
    }

    /// @inheritdoc ICoverVault
    /// @dev O(n). Finalizes lazily if needed, then pushes payout to each LP; a reverting
    ///      recipient is parked in `unclaimed` so it cannot block the batch (§7.3).
    ///      `reserved` is released per policy so I1 holds mid-batch.
    ///      TODO(U5): per-policy settle (anyone), policy status enum (skip final ones,
    ///      resolved = finalCount == policyCount), baseline window + refund when fewer
    ///      than 2 returns follow the baseline, NFT return / parking.
    ///      TODO(U6): keeper skim per measured policy and the settle bounty.
    function settleBatch(uint32 cohortId, uint32 n) external nonReentrant {
        Cohort storage c = _cohorts[cohortId];
        if (_status(cohortId, c) != Status.SETTLING) revert NotSettling(cohortId);
        if (!c.finalized) _finalize(cohortId, c);

        uint32 cursor = c.settledCount;
        uint32 end = cursor + n;
        if (end > c.policyCount) end = c.policyCount;

        if (cursor < end) {
            uint256[] storage ids = _cohortPolicies[cohortId];
            uint128 endSumSq = accumulator.sampleAt(c.endIndex).cumulativeSumSq;

            for (uint32 i = cursor; i < end; i++) {
                uint256 policyId = ids[i];
                Policy storage p = _policies[policyId];
                uint128 payout = _computePayout(p, endSumSq);

                p.settled = true;
                c.reserved -= p.maxPayout; // release exactly maxPayout, whatever the outcome
                if (payout > 0) {
                    c.claimsPaid += payout;
                    // A parked payout stays an obligation until claimUnclaimed.
                    if (_pushPayout(p.owner, payout)) _obligations -= payout;
                }
                emit PolicySettled(policyId, cohortId, payout);
            }
        }

        c.settledCount = end;
        if (end == c.policyCount) c.status = Status.SETTLED;
    }

    // ---------------------------------------------------------------------
    // Pull fallback (B6, §7.3)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoverVault
    function unclaimed(address owner) external view returns (uint256 amount) {
        return _unclaimed[owner];
    }

    /// @inheritdoc ICoverVault
    function claimUnclaimed() external nonReentrant returns (uint256 amount) {
        amount = _unclaimed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _unclaimed[msg.sender] = 0;
        _obligations -= amount;
        _push(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Cohort record with `startsAt`, `endsAt` and `status` filled from the
    ///         calendar, so an untouched cohort still reads correctly.
    function cohort(uint32 cohortId) external view returns (Cohort memory c) {
        c = _cohorts[cohortId];
        c.startsAt = startsAt(cohortId);
        c.endsAt = endsAt(cohortId);
        c.status = _status(cohortId, _cohorts[cohortId]);
    }

    function policy(uint256 policyId) external view returns (Policy memory) {
        return _policies[policyId];
    }

    function policyCount() external view returns (uint256) {
        return _policies.length;
    }

    /// @inheritdoc ICoverVault
    function startsAt(uint32 cohortId) public view returns (uint64) {
        return uint64(_startsAt(cohortId));
    }

    /// @inheritdoc ICoverVault
    function endsAt(uint32 cohortId) public view returns (uint64) {
        return uint64(_endsAt(cohortId));
    }

    /// @notice The cohort whose cycle `[startsAt, startsAt + tenor + gap)` contains now:
    ///         FUNDING never (a cycle begins at startsAt), ACTIVE during its tenor, then
    ///         its gap. Before `anchor` this returns 0 — cohort 0 is the upcoming cohort
    ///         and reads FUNDING.
    function currentCohortId() external view returns (uint32) {
        if (block.timestamp < anchor) return 0;
        return uint32((block.timestamp - anchor) / (uint256(tenor) + gap));
    }

    /// @notice Status derived from the calendar plus the stored resolved mark (R7).
    function statusOf(uint32 cohortId) external view returns (Status) {
        return _status(cohortId, _cohorts[cohortId]);
    }

    /// @inheritdoc ICoverVault
    function totalObligations() external view returns (uint256) {
        return _obligations;
    }

    /// @inheritdoc ICoverVault
    /// @dev Token balance above tracked obligations: direct transfers, and the rounding
    ///      dust of cohorts whose deposits have all exited. Swept into the premium pool
    ///      of the next capitalized cohort at its finalize (R5). Saturates at zero.
    function residual() external view returns (uint256) {
        return _residual();
    }

    // ---------------------------------------------------------------------
    // Internal — accounting
    // ---------------------------------------------------------------------

    /// @dev Underwriter net for a SETTLED cohort (§7.4). O(1), no iteration over policies.
    ///      Premium share rounds DOWN, claim share rounds UP (§9.2); the difference is
    ///      dust that stays with the cohort until every deposit has exited.
    function _settledNet(uint128 dep, Cohort storage c) internal view returns (uint256) {
        if (dep == 0) return 0;
        uint256 total = c.totalCapital;
        uint256 premiumShare = uint256(c.premiumsCollected).mulDivDown(dep, total);
        uint256 claimShare = uint256(c.claimsPaid).mulDivUp(dep, total);
        uint256 credit = uint256(dep) + premiumShare;
        // Saturating: a cohort where claims exceed a share's capital+premium wipes that
        // share to zero, never below (the loss is bounded by the deposit — I4/§4.1).
        return credit > claimShare ? credit - claimShare : 0;
    }

    /// @dev Book a settled exit (withdraw or roll). When the last deposit leaves, the
    ///      cohort's leftover rounding dust stops being its liability and becomes
    ///      residual (plan "Akuntansi": never before every deposit is out).
    function _exitSettled(uint32 cohortId, Cohort storage c, uint128 dep, uint256 net) internal {
        c.remainingPrincipal -= dep;
        c.paidOut += uint128(net);
        if (c.remainingPrincipal == 0) {
            uint256 assets = uint256(c.totalCapital) + c.premiumsCollected;
            uint256 spent = uint256(c.claimsPaid) + c.paidOut;
            uint256 dust = assets > spent ? assets - spent : 0;
            if (dust > 0) {
                _obligations -= dust;
                emit ResidualReleased(cohortId, dust);
            }
        }
    }

    function _residual() internal view returns (uint256) {
        uint256 bal = settlementToken.balanceOf(address(this));
        return bal > _obligations ? bal - _obligations : 0;
    }

    /// @dev Per-policy payout (§7.2). No annualization: strike is scaled to the
    ///      covered window, payout is over accumulated variance. `min` with maxPayout
    ///      comes AFTER the multiply, and everything rounds toward less payout.
    function _computePayout(Policy storage p, uint128 endSumSq) internal view returns (uint128) {
        // sumSqCovered = cumulativeSumSq[endIndex] − policy.startSumSq (§6.2).
        uint128 sumSqCovered = endSumSq >= p.startSumSq ? endSumSq - p.startSumSq : 0;

        // strikeAccumulated = strikeAnnualized × coveredSeconds / SECONDS_PER_YEAR,
        // rounded UP so the threshold is a touch harder to cross (§9.2).
        uint256 strikeAccumulated =
            uint256(p.strikeAnnualized).mulDivUp(p.coveredSeconds, SECONDS_PER_YEAR);

        if (sumSqCovered <= strikeAccumulated) return 0;
        uint256 excess = sumSqCovered - strikeAccumulated;

        // payout = min(maxPayout, varNotional × excess / WAD) — §6.0 unit convention.
        uint256 raw = uint256(p.varNotional).mulDivDown(excess, WAD);
        return uint128(Math.min(p.maxPayout, raw));
    }

    /// @dev maxPayout = varNotional × maxExcessVariance / WAD (§6.0), narrowed to
    ///      uint96 with a checked cast at the write point.
    function _deriveMaxPayout(uint128 varNotional) internal view returns (uint96) {
        uint256 mp = uint256(varNotional).mulDivDown(maxExcessVariance, WAD);
        if (mp > type(uint96).max) revert MaxPayoutOverflow(mp);
        return uint96(mp);
    }

    // ---------------------------------------------------------------------
    // Internal — finalize, EWMA, σ̂² snapshot
    // ---------------------------------------------------------------------

    /// @dev Lock the window, flag degraded, update the EWMA under the monotone rule,
    ///      sweep residual into this (capitalized) cohort's premium pool, and resolve the
    ///      cohort if it has nothing left to settle. Caller guarantees: endsAt passed,
    ///      not finalized, totalCapital > 0.
    function _finalize(uint32 cohortId, Cohort storage c) internal {
        Window memory w = _window(cohortId);
        (bool ewmaUpdated, uint128 newEwma) = _ewmaAfter(cohortId, w);
        bool degraded = _scanDegraded(cohortId, w);

        c.startIndex = w.startIndex;
        c.endIndex = w.endIndex;
        c.finalized = true;
        c.degraded = degraded;
        if (ewmaUpdated) {
            ewmaVariance = newEwma;
            lastEwmaCohortId = cohortId;
            ewmaEverUpdated = true;
        }

        // TODO(U6): skim the keeper cut of cancelled premiums into the keeper budget here
        //           (cancelled policies have left the settle queue).

        // Residual (direct transfers, dust of fully exited cohorts) joins this cohort's
        // premium pool, so its underwriters own it from now on (R5).
        uint256 swept = _residual();
        if (swept > 0) {
            uint256 room = type(uint128).max - c.premiumsCollected;
            if (swept > room) swept = room;
            c.premiumsCollected += uint128(swept);
            _obligations += swept;
        }

        if (c.settledCount == c.policyCount) c.status = Status.SETTLED; // no policies: done

        emit Finalized(cohortId, w.endIndex, w.endSumSq);
        emit WindowResolved(
            cohortId, w.startIndex, w.endIndex, w.returnCount, degraded, ewmaUpdated
        );
        if (swept > 0) emit ResidualSwept(cohortId, swept);
    }

    /// @dev The samples bracketing [startsAt, endsAt] that exist. endIndex is the last
    ///      sample at/before endsAt (a late finalize adds no variance, §7.5); startIndex
    ///      the last at/before startsAt, or — when the first sample came after startsAt
    ///      (SC-03) — sample 0. No sample at/before endsAt ⇒ no window (hasSamples false).
    function _window(uint32 cohortId) internal view returns (Window memory w) {
        if (accumulator.sampleCount() == 0) return w;
        uint256 s = _startsAt(cohortId);
        uint256 e = s + tenor;
        IVarianceAccumulator.Sample memory first = accumulator.sampleAt(0);
        if (first.timestamp > e) return w;

        w.hasSamples = true;
        w.endIndex = accumulator.indexAtOrBefore(uint64(e));
        w.startIndex = first.timestamp > s ? 0 : accumulator.indexAtOrBefore(uint64(s));

        IVarianceAccumulator.Sample memory a = accumulator.sampleAt(w.startIndex);
        IVarianceAccumulator.Sample memory b = accumulator.sampleAt(w.endIndex);
        w.startTs = a.timestamp;
        w.endTs = b.timestamp;
        w.startSumSq = a.cumulativeSumSq;
        w.endSumSq = b.cumulativeSumSq;

        // Returns live at indices ≥ 2 (sample 0 is a baseline, sample 1 the first TWAP).
        uint32 lo = w.startIndex < 1 ? 1 : w.startIndex;
        w.returnCount = w.endIndex > lo ? w.endIndex - lo : 0;
    }

    /// @dev EWMA rule (plan "Aturan pembaruan EWMA"): update only for a cohort id above
    ///      the last one that updated (monotone, may skip) and only when the window holds
    ///      ≥ 2 returns. Annualized over the window's actual span `endTs − startTs` (the
    ///      time the summed returns cover) — annualization lives ONLY here, never on the
    ///      settlement money path (§6.1). `new = old·(1−α) + annualized·α`.
    function _ewmaAfter(uint32 cohortId, Window memory w)
        internal
        view
        returns (bool updated, uint128 value)
    {
        value = ewmaVariance;
        if (!w.hasSamples || w.returnCount < 2 || w.endTs <= w.startTs) return (false, value);
        if (ewmaEverUpdated && cohortId <= lastEwmaCohortId) return (false, value);

        uint256 sumSq = w.endSumSq - w.startSumSq; // monotonic ⇒ never underflows (I5)
        uint256 annualized = sumSq.mulDivDown(SECONDS_PER_YEAR, w.endTs - w.startTs);
        uint256 alpha = ewmaAlphaBps;
        uint256 blended =
            uint256(value).mulDivDown(BPS - alpha, BPS) + annualized.mulDivDown(alpha, BPS);
        if (blended > type(uint128).max) blended = type(uint128).max;
        return (true, uint128(blended));
    }

    /// @dev Degraded (AE6, informational): fewer than 2 returns, a window edge more than
    ///      the threshold from its nearest sample, or two consecutive samples more than the
    ///      threshold apart. Bounded: an undegraded window spans at most `_maxScan` sample
    ///      steps (its head sample is within the threshold before startsAt and samples are
    ///      ≥ sampleInterval apart), so a longer span is degraded without scanning.
    function _scanDegraded(uint32 cohortId, Window memory w) internal view returns (bool) {
        if (!w.hasSamples || w.returnCount < 2) return true;
        uint256 thr = DEGRADED_GAP_MULTIPLE * sampleInterval;
        uint256 s = _startsAt(cohortId);
        if (w.startTs > s + thr || w.startTs + thr < s) return true; // head uncovered
        if (s + tenor > w.endTs + thr) return true; // tail uncovered
        if (w.endIndex - w.startIndex > _maxScan) return true;

        uint256 prevTs = w.startTs;
        for (uint32 i = w.startIndex + 1; i <= w.endIndex; i++) {
            uint256 ts = accumulator.sampleAt(i).timestamp;
            if (ts > prevTs + thr) return true;
            prevTs = ts;
        }
        return false;
    }

    /// @dev First touch of `cohortId` after its startsAt: lazily finalize cohortId − 1
    ///      (its endsAt has passed by then) and snapshot the EWMA into the cohort, so the
    ///      snapshot always includes the previous cohort's result whatever the transaction
    ///      order (R10, AE3). Later touches return the stored snapshot.
    function _touchSnapshot(uint32 cohortId, Cohort storage c) internal returns (uint128 v) {
        if (c.snapshotTaken) return c.varianceSnapshot;
        if (cohortId > 0) {
            Cohort storage prev = _cohorts[cohortId - 1];
            if (!prev.finalized && prev.totalCapital > 0) _finalize(cohortId - 1, prev);
        }
        v = ewmaVariance;
        c.snapshotTaken = true;
        c.varianceSnapshot = v;
        emit VarianceSnapshot(cohortId, v);
    }

    /// @dev View twin of _touchSnapshot for quote(): the stored snapshot, else what it
    ///      would be if taken now.
    function _pricingVariance(uint32 cohortId, Cohort storage c) internal view returns (uint128) {
        if (c.snapshotTaken) return c.varianceSnapshot;
        if (cohortId > 0) {
            uint32 prevId = cohortId - 1;
            Cohort storage prev = _cohorts[prevId];
            if (!prev.finalized && prev.totalCapital > 0 && block.timestamp >= _endsAt(prevId)) {
                (, uint128 v) = _ewmaAfter(prevId, _window(prevId));
                return v;
            }
        }
        return ewmaVariance;
    }

    // ---------------------------------------------------------------------
    // Internal — cohort calendar & status
    // ---------------------------------------------------------------------

    function _startsAt(uint32 cohortId) internal view returns (uint256) {
        return uint256(anchor) + uint256(cohortId) * (uint256(tenor) + gap);
    }

    function _endsAt(uint32 cohortId) internal view returns (uint256) {
        return _startsAt(cohortId) + tenor;
    }

    /// @dev Pure function of the calendar plus the stored SETTLED mark (R7):
    ///      FUNDING < startsAt ≤ ACTIVE < endsAt ≤ SETTLING, then SETTLED once resolved.
    ///      A cohort with no capital after endsAt is SETTLED without finalize (capital
    ///      can only change during FUNDING, so it held none while ACTIVE either).
    function _status(uint32 cohortId, Cohort storage c) internal view returns (Status) {
        if (c.status == Status.SETTLED) return Status.SETTLED;
        uint256 s = _startsAt(cohortId);
        if (block.timestamp < s) return Status.FUNDING;
        if (block.timestamp < s + tenor) return Status.ACTIVE;
        if (c.totalCapital == 0) return Status.SETTLED;
        return Status.SETTLING;
    }

    /// @dev Status for an underwriter exit: a capitalized cohort with no policies past
    ///      endsAt is finalized lazily and becomes SETTLED. One with policies is left
    ///      as is (withdraw/roll then revert until settlement resolves it).
    function _resolveForExit(uint32 cohortId, Cohort storage c) internal returns (Status s) {
        s = _status(cohortId, c);
        if (s == Status.SETTLING && !c.finalized && c.policyCount == 0) {
            _finalize(cohortId, c);
            s = Status.SETTLED;
        }
    }

    function _coveredSeconds(uint32 cohortId) internal view returns (uint32) {
        uint256 s = _startsAt(cohortId);
        uint256 e = s + tenor;
        uint256 from = block.timestamp < s ? s : block.timestamp;
        if (from >= e) return 0;
        return uint32(e - from);
    }

    function _requirePositionMatchesPool(uint256 positionTokenId) internal view {
        (,, address t0, address t1, uint24 f,,,,,,,) = positionManager.positions(positionTokenId);
        if (t0 != poolToken0 || t1 != poolToken1 || f != poolFee) {
            revert PositionWrongPool(positionTokenId);
        }
    }

    // ---------------------------------------------------------------------
    // Internal — token movement
    // ---------------------------------------------------------------------

    /// @dev Pull `amount` from `from` into the vault (deposits, premiums). Handles
    ///      tokens that return no data (USDT-style) as well as bool-returning ones.
    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory data) = address(settlementToken)
            .call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Push `amount` to `to` for obligations we already accounted (underwriter
    ///      withdraw, unclaimed pull). Full gas: these are trusted, non-batch paths.
    function _push(address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(settlementToken)
            .call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Gas-limited payout push inside settleBatch. A recipient that reverts or
    ///      burns gas is parked in `unclaimed` and the batch continues (§7.3).
    ///      Returns whether the tokens actually left the vault.
    function _pushPayout(address to, uint128 amount) internal returns (bool sent) {
        (bool ok, bytes memory data) = address(settlementToken).call{gas: PUSH_GAS}(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        sent = ok && (data.length == 0 || abi.decode(data, (bool)));
        if (!sent) {
            _unclaimed[to] += amount;
            emit Unclaimed(to, amount);
        }
    }
}
