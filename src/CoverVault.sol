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
contract CoverVault is ICoverVault {
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant BPS = 10_000;

    /// @dev Gas stipend for the payout push. A griefing recipient that burns more
    ///      than this reverts only its own transfer; the batch continues and the
    ///      payout lands in `unclaimed` (design §7.3).
    uint256 internal constant PUSH_GAS = 100_000;

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

    uint32 public immutable tenor; // seconds; cohort length
    uint64 public immutable anchor; // startsAt(n) = anchor + n * tenor
    uint16 public immutable maxUtilizationBps; // I1 lever; 8000 recommended, not 10000
    uint128 public immutable maxExcessVariance; // caps maxPayout = varNotional * this / WAD
    uint16 public immutable ewmaAlphaBps; // EWMA weight on the newest cohort

    // --- state ---
    /// @dev EWMA of annualized realized variance (WAD), updated only in finalize()
    ///      so it can never be nudged mid-cycle. Seeded at deploy.
    uint128 public ewmaVariance;

    mapping(uint32 => Cohort) internal _cohorts;
    mapping(uint32 => mapping(address => uint128)) public deposits; // cohortId => underwriter => amount
    mapping(uint32 => uint256[]) internal _cohortPolicies; // cohortId => policyIds (settle cursor order)
    mapping(address => uint256) internal _unclaimed; // push-payout fallback (B6)

    Policy[] internal _policies; // global; policyId == index

    uint256 internal _locked = 1; // reentrancy guard (1 = free, 2 = entered)

    error Reentrancy();
    error BadConfig();
    error NotFunding(uint32 cohortId);
    error NotActive(uint32 cohortId);
    error NotSettling(uint32 cohortId);
    error NotSettled(uint32 cohortId);
    error NotExpiredYet(uint32 cohortId);
    error AlreadyFinalized(uint32 cohortId);
    error NoSamples();
    error PositionNotOwned(uint256 tokenId);
    error PositionWrongPool(uint256 tokenId);
    error CapacityExceeded(uint128 wouldReserve, uint128 available);
    error PremiumTooHigh(uint128 premium, uint128 maxPremium);
    error QuoteExpired(uint64 deadline);
    error MaxPayoutOverflow(uint256 value);
    error NothingToWithdraw();
    error TransferFailed();

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address pool_,
        address accumulator_,
        address pricer_,
        address valuer_,
        address positionManager_,
        address settlementToken_,
        uint32 tenor_,
        uint64 anchor_,
        uint16 maxUtilizationBps_,
        uint128 maxExcessVariance_,
        uint16 ewmaAlphaBps_,
        uint128 seedVariance_
    ) {
        if (
            pool_ == address(0) || accumulator_ == address(0) || pricer_ == address(0)
                || valuer_ == address(0) || positionManager_ == address(0)
                || settlementToken_ == address(0) || tenor_ == 0 || maxUtilizationBps_ == 0
                || maxUtilizationBps_ > BPS || maxExcessVariance_ == 0 || ewmaAlphaBps_ > BPS
        ) revert BadConfig();

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
        anchor = anchor_;
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
        Cohort storage c = _ensureCohort(cohortId);
        // Deposits only while the cohort has not started — capital is locked once
        // it goes ACTIVE (§4.2), which is what makes settlement O(1) per underwriter.
        if (_effectiveStatus(c) != Status.FUNDING) revert NotFunding(cohortId);

        _pull(msg.sender, amount);
        deposits[cohortId][msg.sender] += amount;
        c.totalCapital += amount;
        emit Deposited(cohortId, msg.sender, amount);
    }

    /// @inheritdoc ICoverVault
    function withdraw(uint32 cohortId) external nonReentrant returns (uint256 net) {
        Cohort storage c = _cohorts[cohortId];
        Status s = _effectiveStatus(c);
        // Withdrawals are legal only before capital is ever at risk (FUNDING) or
        // after every obligation is paid (SETTLED). §5.4.
        if (s != Status.FUNDING && s != Status.SETTLED) revert NotSettled(cohortId);

        net = _accountFor(cohortId, msg.sender, c, s);
        if (net == 0) revert NothingToWithdraw();

        deposits[cohortId][msg.sender] = 0;
        _push(msg.sender, net); // owed to an underwriter we already accounted; not gas-limited
        emit Withdrawn(cohortId, msg.sender, net);
    }

    /// @inheritdoc ICoverVault
    /// @dev Moves an underwriter's settled net straight into a FUNDING cohort with no
    ///      token round-trip (§5.4). Always explicit, never a default.
    function rollTo(uint32 fromCohort, uint32 toCohort) external nonReentrant {
        Cohort storage from = _cohorts[fromCohort];
        Status sf = _effectiveStatus(from);
        if (sf != Status.SETTLED) revert NotSettled(fromCohort);

        uint256 net = _accountFor(fromCohort, msg.sender, from, sf);
        if (net == 0) revert NothingToWithdraw();
        deposits[fromCohort][msg.sender] = 0;

        Cohort storage to = _ensureCohort(toCohort);
        if (_effectiveStatus(to) != Status.FUNDING) revert NotFunding(toCohort);

        uint128 amount = uint128(net); // net ≤ totalCapital + premiums, well within uint128
        deposits[toCohort][msg.sender] += amount;
        to.totalCapital += amount;
        emit Rolled(fromCohort, toCohort, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // LP — position-attached quote & buyCover
    // ---------------------------------------------------------------------

    /// @inheritdoc ICoverVault
    function quote(uint32 cohortId, uint256 positionTokenId, uint64 strikeAnnualized)
        external
        view
        returns (uint128 premium, uint128 varNotional, uint96 maxPayout, uint32 coveredSeconds)
    {
        Cohort storage c = _cohorts[cohortId];
        _requirePositionMatchesPool(positionTokenId); // ownership NOT required to quote

        varNotional = valuer.varNotionalFor(positionTokenId);
        coveredSeconds = _coveredSeconds(c);
        maxPayout = _deriveMaxPayout(varNotional);
        premium = pricer.quote(
            varNotional, strikeAnnualized, coveredSeconds, ewmaVariance, c.reserved, c.totalCapital
        );
    }

    /// @inheritdoc ICoverVault
    function buyCover(
        uint32 cohortId,
        uint256 positionTokenId,
        uint64 strikeAnnualized,
        uint128 maxPremium,
        uint64 deadline
    ) external nonReentrant returns (uint256 policyId) {
        if (block.timestamp > deadline) revert QuoteExpired(deadline);

        Cohort storage c = _cohorts[cohortId];
        if (_effectiveStatus(c) != Status.ACTIVE || block.timestamp >= c.endsAt) {
            revert NotActive(cohortId);
        }

        // Position-attached: prove ownership NOW and that the position is this pool's.
        // A speculator with no position cannot buy; an LP cannot cover someone else's
        // position (design §8.2, invariant I8). Ownership is a precondition at buy,
        // not a standing invariant — the NFT may be sold afterward.
        if (positionManager.ownerOf(positionTokenId) != msg.sender) {
            revert PositionNotOwned(positionTokenId);
        }
        _requirePositionMatchesPool(positionTokenId);

        uint32 sampleCount = accumulator.sampleCount();
        if (sampleCount == 0) revert NoSamples();

        // varNotional falls out of the position's gamma exposure — never a caller input.
        uint128 varNotional = valuer.varNotionalFor(positionTokenId);
        uint96 maxPayout = _deriveMaxPayout(varNotional);
        uint32 coveredSeconds = _coveredSeconds(c);

        // Capacity: reserved + maxPayout ≤ totalCapital * util / 10_000 (invariant I1).
        // Premiums never add capacity (§5.2): selling cover with the buyer's own money
        // is exactly what this line forbids.
        uint128 available = uint128(uint256(c.totalCapital).mulDivDown(maxUtilizationBps, BPS));
        uint128 wouldReserve = c.reserved + maxPayout;
        if (wouldReserve > available) revert CapacityExceeded(wouldReserve, available);

        uint128 premium = pricer.quote(
            varNotional, strikeAnnualized, coveredSeconds, ewmaVariance, c.reserved, c.totalCapital
        );
        if (premium > maxPremium) revert PremiumTooHigh(premium, maxPremium);

        // Per-policy window is exact (§6.2): record the cumulative sum-of-squares at
        // purchase; settlement subtracts it once. Volatility before this instant is
        // never billed or paid.
        uint32 startIndex = sampleCount - 1;
        uint128 startSumSq = accumulator.sampleAt(startIndex).cumulativeSumSq;

        // Effects before interaction (CEI): reserve, record premium, store policy.
        c.reserved = wouldReserve;
        c.premiumsCollected += premium;
        c.policyCount += 1;

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
    /// @dev O(1). Locks the cohort's end index, updates the EWMA for the NEXT cohort's
    ///      pricing, and moves to SETTLING. A cohort with no policies goes straight to
    ///      SETTLED with capital intact (§7.5).
    function finalize(uint32 cohortId) external {
        Cohort storage c = _cohorts[cohortId];
        if (block.timestamp < c.endsAt || c.endsAt == 0) revert NotExpiredYet(cohortId);
        if (c.status == Status.SETTLING || c.status == Status.SETTLED) {
            revert AlreadyFinalized(cohortId);
        }

        // endIndex is the last sample at/before endsAt; a late finalize adds no
        // variance (§7.5). startIndex brackets the cohort window for the EWMA update.
        uint32 endIndex = accumulator.indexAtOrBefore(c.endsAt);
        uint32 startIndex = accumulator.indexAtOrBefore(c.startsAt);
        c.endIndex = endIndex;
        c.startIndex = startIndex;

        uint128 endSumSq = accumulator.sampleAt(endIndex).cumulativeSumSq;
        uint128 startSumSq = accumulator.sampleAt(startIndex).cumulativeSumSq;
        uint128 cohortSumSq = endSumSq - startSumSq; // monotonic ⇒ never underflows (I5)

        _updateEwma(cohortSumSq);

        if (c.policyCount == 0) {
            c.status = Status.SETTLED; // nothing to settle; capital returns whole
        } else {
            c.status = Status.SETTLING;
        }
        emit Finalized(cohortId, endIndex, endSumSq);
    }

    /// @inheritdoc ICoverVault
    /// @dev O(n). Pushes payout to each LP; a reverting recipient is parked in
    ///      `unclaimed` so it cannot block the batch (§7.3). `reserved` is released
    ///      per policy so I1 holds mid-batch.
    function settleBatch(uint32 cohortId, uint32 n) external nonReentrant {
        Cohort storage c = _cohorts[cohortId];
        if (c.status != Status.SETTLING) revert NotSettling(cohortId);

        uint256[] storage ids = _cohortPolicies[cohortId];
        uint32 cursor = c.settledCount;
        uint32 end = cursor + n;
        if (end > c.policyCount) end = c.policyCount;

        uint128 endSumSq = accumulator.sampleAt(c.endIndex).cumulativeSumSq;

        for (uint32 i = cursor; i < end; i++) {
            uint256 policyId = ids[i];
            Policy storage p = _policies[policyId];
            uint128 payout = _computePayout(p, endSumSq);

            p.settled = true;
            c.reserved -= p.maxPayout; // release exactly maxPayout, whatever the outcome
            if (payout > 0) {
                c.claimsPaid += payout;
                _pushPayout(p.owner, payout);
            }
            emit PolicySettled(policyId, cohortId, payout);
        }

        c.settledCount = end;
        if (c.settledCount == c.policyCount) c.status = Status.SETTLED;
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
        _push(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function cohort(uint32 cohortId) external view returns (Cohort memory) {
        return _cohorts[cohortId];
    }

    function policy(uint256 policyId) external view returns (Policy memory) {
        return _policies[policyId];
    }

    function policyCount() external view returns (uint256) {
        return _policies.length;
    }

    /// @notice The cohort id currently in its ACTIVE window (selling open).
    function currentCohortId() public view returns (uint32) {
        if (block.timestamp < anchor) return 0;
        return uint32((block.timestamp - anchor) / tenor);
    }

    /// @notice Effective status of a cohort, deriving the time-driven transitions
    ///         (FUNDING→ACTIVE) and reading the stored flag for the settlement phases.
    function statusOf(uint32 cohortId) external view returns (Status) {
        return _effectiveStatus(_cohorts[cohortId]);
    }

    // ---------------------------------------------------------------------
    // Internal — accounting
    // ---------------------------------------------------------------------

    /// @dev Underwriter net for a cohort (§7.4). O(1), no iteration over policies.
    ///      Premium share rounds DOWN, claim share rounds UP (§9.2); the difference
    ///      is dust that stays in the vault as residual, never negative net.
    function _accountFor(uint32 cohortId, address u, Cohort storage c, Status s)
        internal
        view
        returns (uint256)
    {
        uint128 dep = deposits[cohortId][u];
        if (dep == 0) return 0;
        if (s == Status.FUNDING) return dep; // capital never went at risk

        uint256 total = c.totalCapital;
        uint256 premiumShare = uint256(c.premiumsCollected).mulDivDown(dep, total);
        uint256 claimShare = uint256(c.claimsPaid).mulDivUp(dep, total);
        uint256 credit = uint256(dep) + premiumShare;
        // Saturating: a cohort where claims exceed a share's capital+premium wipes that
        // share to zero, never below (the loss is bounded by the deposit — I4/§4.1).
        return credit > claimShare ? credit - claimShare : 0;
    }

    /// @dev EWMA update on the cohort's annualized realized variance. Annualization
    ///      lives ONLY here, for regime tracking — NEVER on the settlement money path
    ///      (§6.1). `new = old·(1-α) + annualized·α`.
    function _updateEwma(uint128 cohortSumSq) internal {
        uint256 annualized = uint256(cohortSumSq).mulDivDown(SECONDS_PER_YEAR, tenor);
        uint256 alpha = ewmaAlphaBps;
        uint256 blended =
            uint256(ewmaVariance).mulDivDown(BPS - alpha, BPS) + annualized.mulDivDown(alpha, BPS);
        ewmaVariance = uint128(blended);
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
    // Internal — cohort calendar & status
    // ---------------------------------------------------------------------

    function _ensureCohort(uint32 cohortId) internal returns (Cohort storage c) {
        c = _cohorts[cohortId];
        if (c.endsAt == 0) {
            uint64 startsAt = anchor + uint64(cohortId) * uint64(tenor);
            c.startsAt = startsAt;
            c.endsAt = startsAt + uint64(tenor);
            // status defaults to FUNDING (0); start/end indices locked at finalize.
        }
    }

    function _effectiveStatus(Cohort storage c) internal view returns (Status) {
        if (c.status == Status.SETTLED) return Status.SETTLED;
        if (c.status == Status.SETTLING) return Status.SETTLING;
        // Not yet finalized: derive from time. An expired-but-unfinalized cohort reads
        // as ACTIVE (its selling window is gated separately by `block.timestamp < endsAt`
        // in buyCover), which keeps the enum to the four §8.2 values (B1).
        if (c.endsAt == 0 || block.timestamp < c.startsAt) return Status.FUNDING;
        return Status.ACTIVE;
    }

    function _coveredSeconds(Cohort storage c) internal view returns (uint32) {
        if (c.endsAt == 0) return tenor; // uninitialized cohort quotes the full tenor
        uint256 start = block.timestamp < c.startsAt ? c.startsAt : block.timestamp;
        if (start >= c.endsAt) return 0;
        return uint32(c.endsAt - start);
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
    function _pushPayout(address to, uint128 amount) internal {
        (bool ok, bytes memory data) = address(settlementToken).call{gas: PUSH_GAS}(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            _unclaimed[to] += amount;
            emit Unclaimed(to, amount);
        }
    }
}
