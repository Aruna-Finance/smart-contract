#!/usr/bin/env bash
# Aruna v2 RC scenario runner (plan U9, "Runner skenario eksternal").
#
# forge script simulates a whole script at ONE timestamp, so every cross-time sequence of
# the RC lives here: a loop with real delays that calls one `script/Ops.s.sol` entrypoint
# per step (keeper pokes per interval through the vault wrapper, price-driving swaps,
# buy / collect / cancel at the right times, finalize + settle after endsAt, roll in the
# gap, late roll to n+2). Each step's transactions go to
# runner/results/<scenario>-<timestamp>.json (scenario, step, tx hash, block, address),
# which the conformance ledger (U10) reads. RPC transport errors are retried.
#
# Usage:
#   runner/run.sh --scenario pay|nopay|refund [--manifest PATH] [--market N] [--anvil]
#   runner/run.sh --keeper-only [--manifest PATH] [--market N] [--until UNIX_TS] [--max-pokes N]
#
# Scenarios (one cohort n each, n = first cohort starting >= LEAD_SECS from now):
#   pay     large alternating swings every interval. Covers: deposit (3 underwriters),
#           keeper-budget donation, 3 buys (LP x2 + RejectingReceiver), collectFees,
#           cancel, keeper pokes, keeperFinalize, settlePolicy (payout PARKED: receiver
#           rejects the token), settleBatch, claimUnclaimed, withdraw, rollTo n+1 in the
#           gap, late rollTo n+2 after startsAt(n+1).
#   nopay   no swaps: one buy, pokes, finalize, settleBatch (measured, pays 0), withdraw.
#   refund  the keeper stops right after the buy: settlePolicy refunds the premium.
#   --keeper-only  act as the temporary keeper (Fase 2) for the market: poke every
#           interval, keeperFinalize and settleBatch every cohort that needs it.
#
# Environment (all optional unless stated):
#   RPC_URL           RPC endpoint (required live; --anvil default http://127.0.0.1:8545).
#                     Use a dedicated RPC; never commit a URL that embeds a key.
#   SIGNER_LP, SIGNER_UW, SIGNER_UW2, SIGNER_KEEPER
#                     forge/cast wallet args per actor, e.g. "--account rc-lp" (keystore) or
#                     "--ledger". REQUIRED live. --anvil defaults to anvil dev keys 0/1/2
#                     (keeper = LP). Never put a private key in a committed file.
#   MANIFEST          deployment manifest (default deployments/<chainId>/sandbox.json)
#   MARKET            market index in the manifest (default 0)
#   ROUTER            SwapRouter02 (default: manifest infra.router)
#   RESULTS_DIR       default runner/results (--anvil: runner/results/local, gitignored)
#   MINT              true: tokens are testnet/local mocks, mint as needed (default true)
#   STRIKE            annualized strike variance, WAD (default 1e17 = 10%)
#   CAP_UW, CAP_UW2, CAP_LP   deposits, raw units (default 5e11, 3e11, 2e11)
#   KEEPER_FUND       keeper-budget donation, raw (default 1e8)
#   SWAP_IN           raw amountIn per price-driving swap (default 5e11 = 500 ticks on the
#                     local mock router; calibrate on a real pool so a swap moves the tick)
#   POS_AMOUNT0/1, POS_HALF_WIDTH   LP position size / half range (default 1e11, 1e11, 1000)
#   LEAD_SECS         min seconds between now and the chosen cohort's startsAt (default 180)
#   POLL_SECS         live-mode polling period (default 5)
#   ANVIL_STEP_DELAY  --anvil: real seconds to sleep after each time jump (default 0)
#   RETRIES, RETRY_BACKOFF   RPC retry count / base backoff seconds (default 4 / 3)
#   RECEIPT_WAIT      seconds to wait for a receipt before deciding whether a failed send
#                     landed (default 60)
#   KEEPER_MAX_FAILS  --keeper-only: consecutive failed ticks before giving up (default 5)
#   KEEPER_BACKOFF, KEEPER_BACKOFF_MAX   --keeper-only: base / max seconds of the
#                     exponential backoff after a failed tick (default RETRY_BACKOFF / 300)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=runner/lib.sh
. "$ROOT/runner/lib.sh"

# ---------------------------------------------------------------- args
ANVIL=0 KEEPER_ONLY=0 SCENARIO="" UNTIL=0 MAX_POKES=0
MANIFEST="${MANIFEST:-}" MARKET="${MARKET:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --anvil) ANVIL=1 ;;
    --keeper-only) KEEPER_ONLY=1 ;;
    --scenario) SCENARIO="$2"; shift ;;
    --manifest) MANIFEST="$2"; shift ;;
    --market) MARKET="$2"; shift ;;
    --rpc-url) RPC_URL="$2"; shift ;;
    --until) UNTIL="$2"; shift ;;
    --max-pokes) MAX_POKES="$2"; shift ;;
    --results-dir) RESULTS_DIR="$2"; shift ;;
    -h | --help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$KEEPER_ONLY" = 1 ] && SCENARIO="keeper"
case "$SCENARIO" in pay | nopay | refund | keeper) ;; *) echo "--scenario pay|nopay|refund or --keeper-only" >&2; exit 2 ;; esac

# ---------------------------------------------------------------- config
RETRIES="${RETRIES:-4}" RETRY_BACKOFF="${RETRY_BACKOFF:-3}" POLL_SECS="${POLL_SECS:-5}"
MINT="${MINT:-true}" STRIKE="${STRIKE:-100000000000000000}"
CAP_UW="${CAP_UW:-500000000000}" CAP_UW2="${CAP_UW2:-300000000000}" CAP_LP="${CAP_LP:-200000000000}"
KEEPER_FUND="${KEEPER_FUND:-100000000}" SWAP_IN="${SWAP_IN:-500000000000}"
POS_AMOUNT0="${POS_AMOUNT0:-100000000000}" POS_AMOUNT1="${POS_AMOUNT1:-100000000000}" POS_HALF_WIDTH="${POS_HALF_WIDTH:-1000}"
LEAD_SECS="${LEAD_SECS:-180}"

if [ "$ANVIL" = 1 ]; then
  RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
  # Public anvil dev keys (well known, worthless; only ever valid on a local anvil).
  SIGNER_LP="${SIGNER_LP:---private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
  SIGNER_UW="${SIGNER_UW:---private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
  SIGNER_UW2="${SIGNER_UW2:---private-key 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
  FORGE_FLAGS="${FORGE_FLAGS:-}"
  RESULTS_DIR="${RESULTS_DIR:-$ROOT/runner/results/local}"
else
  : "${RPC_URL:?RPC_URL is required}"
  : "${SIGNER_LP:?SIGNER_LP is required (e.g. --account rc-lp)}"
  if [ "$SCENARIO" = pay ]; then
    : "${SIGNER_UW:?SIGNER_UW is required}"
    : "${SIGNER_UW2:?SIGNER_UW2 is required}"
  fi
  # --slow: wait for each receipt before the next tx (approve -> buy ordering).
  FORGE_FLAGS="${FORGE_FLAGS:---slow}"
  RESULTS_DIR="${RESULTS_DIR:-$ROOT/runner/results}"
fi
SIGNER_UW="${SIGNER_UW:-$SIGNER_LP}" SIGNER_UW2="${SIGNER_UW2:-$SIGNER_UW}"
SIGNER_KEEPER="${SIGNER_KEEPER:-$SIGNER_LP}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$ANVIL" = 1 ] && [ "$CHAIN_ID" != 31337 ]; then echo "--anvil but chainId $CHAIN_ID" >&2; exit 2; fi
MANIFEST="${MANIFEST:-deployments/$CHAIN_ID/sandbox.json}"
case "$MANIFEST" in /*) MANIFEST_ABS="$MANIFEST" ;; *) MANIFEST_ABS="$ROOT/$MANIFEST" ;; esac
[ -f "$MANIFEST_ABS" ] || { echo "manifest not found: $MANIFEST" >&2; exit 2; }
[ "$(jq -r .chainId "$MANIFEST_ABS")" = "$CHAIN_ID" ] || { echo "manifest chainId != RPC chainId" >&2; exit 2; }

M=".markets.\"$MARKET\""
VAULT=$(jq -r "$M.vault" "$MANIFEST_ABS")
ACC=$(jq -r "$M.accumulator" "$MANIFEST_ABS")
POOL=$(jq -r "$M.pool" "$MANIFEST_ABS")
NFPM=$(jq -r .infra.positionManager "$MANIFEST_ABS")
TOKEN=$(jq -r .infra.settlementToken "$MANIFEST_ABS")
ROUTER="${ROUTER:-$(jq -r '.infra.router // empty' "$MANIFEST_ABS")}"
[ "$VAULT" != null ] || { echo "market $MARKET not in manifest" >&2; exit 2; }
INTERVAL=$(cast_call "$ACC" "sampleInterval()(uint32)" | first)
TENOR=$(cast_call "$VAULT" "tenor()(uint32)" | first)

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aruna-runner.XXXXXX")"
STEP_NO=1
# Every Ops call gets these explicitly: forge auto-loads ./.env, whose ARUNA_* values (an
# old pool, factory...) must never leak into a run (dotenv never overrides set vars).
BASE_ENV=(ARUNA_VAULT="$VAULT" ARUNA_POOL="$POOL" ARUNA_NFPM="$NFPM" ARUNA_ROUTER="${ROUTER:-0x0000000000000000000000000000000000000000}"
  ARUNA_MANIFEST="$MANIFEST" ARUNA_MINT="$MINT" ARUNA_STRIKE="$STRIKE"
  ARUNA_POS_AMOUNT0="$POS_AMOUNT0" ARUNA_POS_AMOUNT1="$POS_AMOUNT1" ARUNA_POS_HALF_WIDTH="$POS_HALF_WIDTH")
unset ARUNA_VIA ARUNA_RECIPIENT ARUNA_MAX_PREMIUM ARUNA_POS_RECIPIENT ARUNA_COHORT ARUNA_TO_COHORT \
  ARUNA_POLICY_ID ARUNA_TOKEN_ID ARUNA_AMOUNT ARUNA_BATCH_N ARUNA_REJECT ARUNA_SWAP_IN ARUNA_ZERO_FOR_ONE 2>/dev/null || true

log "chain $CHAIN_ID vault $VAULT tenor ${TENOR}s interval ${INTERVAL}s mode $([ "$ANVIL" = 1 ] && echo anvil || echo live)"

# ---------------------------------------------------------------- vault views
starts_at() { cast_call "$VAULT" "startsAt(uint32)(uint64)" "$1" | first; }
ends_at() { cast_call "$VAULT" "endsAt(uint32)(uint64)" "$1" | first; }
status_of() { cast_call "$VAULT" "statusOf(uint32)(uint8)" "$1" | first; }
unclaimed_of() { cast_call "$VAULT" "unclaimed(address)(uint256)" "$1" | first; }
# Fails (no output) on an empty read instead of scheduling at 0 + INTERVAL.
next_poke_at() {
  local last
  last=$(cast_call "$ACC" "lastSampleAt()(uint32)" | first) || last=""
  is_uint "$last" || { log "  WARN: lastSampleAt() read returned '${last}'"; return 1; }
  echo $((last + INTERVAL))
}

pick_cohort() {
  local now n
  now=$(chain_now)
  n=$(cast_call "$VAULT" "currentCohortId()(uint32)" | first)
  while [ "$(starts_at "$n")" -lt $((now + LEAD_SECS)) ]; do n=$((n + 1)); done
  echo "$n"
}

# ---------------------------------------------------------------- keeper + price driver
DRIVE=0 SWING_DIR=0 POKES=0
on_poke() { :; } # scenario hook, called with the poke number inside the drive window

poke_now() {
  ops "keeper-poke" "$SIGNER_KEEPER" "keeperPoke()" || return 1
  POKES=$((POKES + 1))
  if [ "$DRIVE" = 1 ]; then
    # Pay scenario: a large swing every interval, alternating direction, so every return
    # in the window is a large move even though the price keeps coming back.
    local z=true
    [ "$SWING_DIR" = 0 ] && z=false
    SWING_DIR=$((1 - SWING_DIR))
    ops "swap" "$SIGNER_LP" "swap()" ARUNA_SWAP_IN="$SWAP_IN" ARUNA_ZERO_FOR_ONE="$z" || return 1
  fi
}

# Keeper loop until chain time `target`: poke whenever due (KEEP_POKING=1), then land at
# target. `hook_every` runs on_poke after each poke.
advance_to() {
  local target="$1" due k=0
  if [ "${KEEP_POKING:-1}" = 1 ]; then
    while :; do
      due=$(next_poke_at) || die "cannot schedule the next poke (empty chain read)"
      [ "$due" -lt "$target" ] || break
      wait_until "$due"
      poke_now
      k=$((k + 1))
      on_poke "$k"
    done
  fi
  wait_until "$target"
}

# ---------------------------------------------------------------- scenarios
read_scenario_setup() {
  RECEIVER=$(jq -r .rejectingReceiver "$1")
  POS_A=$(jq -r '.lpTokenIds[0]' "$1")
  POS_B=$(jq -r '.lpTokenIds[1]' "$1")
  POS_R=$(jq -r .receiverTokenId "$1")
}

buy() { # buy <step> <signer> <tokenId> [VIA]  -> BUY_PID
  if [ -n "${4:-}" ]; then
    ops "$1" "$2" "approveAndBuy()" ARUNA_COHORT="$N" ARUNA_TOKEN_ID="$3" ARUNA_VIA="$4"
  else
    ops "$1" "$2" "approveAndBuy()" ARUNA_COHORT="$N" ARUNA_TOKEN_ID="$3"
  fi
  BUY_PID=$(ret policyId)
}

# Policy.status (ICoverVault.PolicyStatus: 0 Active, 1 Cancelled, 2 Settled, 3 Refunded).
# The Policy struct is all static types, so `policy()` returns 14 words; status is word 10.
policy_status() {
  local hex
  hex=$(cast_call "$VAULT" "policy(uint256)" "$1")
  hex="${hex#0x}"
  echo $((16#${hex:$((10 * 64 + 48)):16}))
}

scenario_pay() {
  local uw uw2 setup_out
  uw=$(cast wallet address $SIGNER_UW)
  uw2=$(cast wallet address $SIGNER_UW2)
  [ "$uw" != "$uw2" ] || die "pay needs two distinct underwriters (SIGNER_UW, SIGNER_UW2) for roll + late roll"
  N=$(pick_cohort)
  S=$(starts_at "$N") E=$(ends_at "$N") S1=$(starts_at $((N + 1)))
  log "pay: cohort $N startsAt $S endsAt $E next startsAt $S1"

  # --- FUNDING: single-timestamp setup, then deposits before startsAt
  setup_out="$ROOT/deployments/$CHAIN_ID/scenario-$(date -u +%Y%m%dT%H%M%SZ).json"
  (cd "$ROOT" && env "${BASE_ENV[@]}" ARUNA_SCENARIO_OUT="${setup_out#"$ROOT"/}" ARUNA_SC_ACTORS="$uw,$uw2" \
    ARUNA_SC_LP_POSITIONS=2 forge script script/Scenarios.s.sol:ScenarioSetup \
    --rpc-url "$RPC_URL" --broadcast $FORGE_FLAGS $SIGNER_LP) >"$WORK_DIR/scenario-setup.log" 2>&1 \
    || { tail -30 "$WORK_DIR/scenario-setup.log" >&2; die "scenario setup failed"; }
  record_broadcast "scenario-setup" "" "$ROOT/broadcast/Scenarios.s.sol/$CHAIN_ID/run-latest.json"
  read_scenario_setup "$setup_out"
  log "  receiver $RECEIVER positions A=$POS_A B=$POS_B R=$POS_R"

  ops "deposit-uw" "$SIGNER_UW" "deposit()" ARUNA_COHORT="$N" ARUNA_AMOUNT="$CAP_UW"
  ops "deposit-uw2" "$SIGNER_UW2" "deposit()" ARUNA_COHORT="$N" ARUNA_AMOUNT="$CAP_UW2"
  ops "deposit-lp" "$SIGNER_LP" "deposit()" ARUNA_COHORT="$N" ARUNA_AMOUNT="$CAP_LP"
  ops "fund-keeper-budget" "$SIGNER_LP" "fundKeeperBudget()" ARUNA_AMOUNT="$KEEPER_FUND"
  [ "$(chain_now)" -lt "$S" ] || die "deposits landed after startsAt; raise LEAD_SECS"

  # --- ACTIVE: buy right after startsAt (>= 5 intervals left by construction)
  advance_to "$S"
  buy "buy-lp-a" "$SIGNER_LP" "$POS_A"
  PID_A=$BUY_PID
  buy "buy-lp-b" "$SIGNER_LP" "$POS_B"
  PID_B=$BUY_PID
  buy "buy-receiver" "$SIGNER_LP" "$POS_R" "$RECEIVER"
  PID_R=$BUY_PID
  ops "receiver-reject-on" "$SIGNER_LP" "setRejectIncoming()" ARUNA_VIA="$RECEIVER" ARUNA_REJECT=true
  log "  policies A=$PID_A B=$PID_B R=$PID_R"
  if [ "$ANVIL" = 1 ]; then
    # Local mock NFPM only: book some fees on position A so collectFees moves tokens.
    cast send --rpc-url "$RPC_URL" $SIGNER_LP "$NFPM" "setTokensOwed(uint256,uint128,uint128)" \
      "$POS_A" 1000000000 1000000 >/dev/null
  fi

  on_poke() {
    case "$1" in
      2) ops "collect-fees" "$SIGNER_LP" "collectFees()" ARUNA_POLICY_ID="$PID_A" ;;
      3) ops "cancel" "$SIGNER_LP" "cancel()" ARUNA_POLICY_ID="$PID_B" ;;
    esac
  }
  DRIVE=1
  advance_to "$E"
  DRIVE=0
  on_poke() { :; }

  # --- after endsAt (gap): finalize, settle, claims, exits
  ops "keeper-finalize" "$SIGNER_KEEPER" "keeperFinalize()" ARUNA_COHORT="$N"
  ops "settle-policy-receiver" "$SIGNER_KEEPER" "settlePolicy()" ARUNA_POLICY_ID="$PID_R"
  local parked
  parked=$(unclaimed_of "$RECEIVER")
  [ "$parked" != 0 ] || die "receiver payout was not parked (unclaimed = 0)"
  log "  parked payout for receiver: $parked"
  ops "settle-batch" "$SIGNER_KEEPER" "settleBatch()" ARUNA_COHORT="$N"
  [ "$(policy_status "$PID_A")" = 2 ] || die "policy A not settled"
  [ "$(policy_status "$PID_B")" = 1 ] || die "policy B not cancelled"
  [ "$(status_of "$N")" = 3 ] || die "cohort $N not SETTLED after settleBatch"
  ops "receiver-reject-off" "$SIGNER_LP" "setRejectIncoming()" ARUNA_VIA="$RECEIVER" ARUNA_REJECT=false
  ops "claim-unclaimed" "$SIGNER_LP" "claimUnclaimed()" ARUNA_VIA="$RECEIVER"
  ops "withdraw-lp" "$SIGNER_LP" "withdraw()" ARUNA_COHORT="$N"
  [ "$(chain_now)" -lt "$S1" ] || die "gap already over before roll; cannot roll into n+1"
  ops "roll-n+1" "$SIGNER_UW" "rollTo()" ARUNA_COHORT="$N" ARUNA_TO_COHORT=$((N + 1))

  # --- late roll: once n+1 is ACTIVE, roll n's remaining deposit into n+2
  advance_to $((S1 + 1))
  ops "late-roll-n+2" "$SIGNER_UW2" "rollTo()" ARUNA_COHORT="$N" ARUNA_TO_COHORT=$((N + 2))
}

scenario_simple() { # nopay | refund
  N=$(pick_cohort)
  S=$(starts_at "$N") E=$(ends_at "$N")
  log "$SCENARIO: cohort $N startsAt $S endsAt $E"
  ops "mint-position" "$SIGNER_LP" "mintPosition()"
  POS_A=$(ret tokenId)
  ops "deposit-uw" "$SIGNER_UW" "deposit()" ARUNA_COHORT="$N" ARUNA_AMOUNT="$CAP_UW"
  advance_to "$S"
  buy "buy-lp" "$SIGNER_LP" "$POS_A"
  PID_A=$BUY_PID
  if [ "$SCENARIO" = refund ]; then
    # The keeper "dies" after the purchase: no sample follows it, the window cannot be
    # measured and settle refunds the premium in full (lazy finalize inside settle).
    KEEP_POKING=0 advance_to "$E"
    ops "settle-policy" "$SIGNER_LP" "settlePolicy()" ARUNA_POLICY_ID="$PID_A"
    [ "$(policy_status "$PID_A")" = 3 ] || die "policy $PID_A was not refunded"
  else
    advance_to "$E"
    ops "keeper-finalize" "$SIGNER_KEEPER" "keeperFinalize()" ARUNA_COHORT="$N"
    ops "settle-batch" "$SIGNER_KEEPER" "settleBatch()" ARUNA_COHORT="$N"
    [ "$(policy_status "$PID_A")" = 2 ] || die "policy $PID_A was not settled measured"
  fi
  ops "withdraw-uw" "$SIGNER_UW" "withdraw()" ARUNA_COHORT="$N"
}

# Temporary keeper (Fase 2): poke on schedule; finalize and settle whatever is due.
# A tick's poke / finalize / settle failure is logged and the loop carries on; an empty
# scheduling read skips the tick with a warning. Consecutive failed ticks back off
# exponentially (KEEPER_BACKOFF doubling, capped at KEEPER_BACKOFF_MAX) and the keeper
# gives up after KEEPER_MAX_FAILS of them. Insufficient funds stops it at once.
KEEPER_MAX_FAILS="${KEEPER_MAX_FAILS:-5}" KEEPER_BACKOFF="${KEEPER_BACKOFF:-$RETRY_BACKOFF}"
KEEPER_BACKOFF_MAX="${KEEPER_BACKOFF_MAX:-300}"

# Note a failed keeper action; insufficient funds is fatal, the rest only fail the tick.
keeper_action_failed() { # keeper_action_failed <what>
  case "$OPS_ERR" in
    funds) die "keeper $1: insufficient funds for gas; top up the keeper signer" ;;
    nonce) log "  WARN: keeper $1: nonce conflict (a previous tx may still be pending); retrying next tick" ;;
    price) log "  WARN: keeper $1: underpriced; fees are re-estimated next tick" ;;
    *) log "  WARN: keeper $1 failed (${OPS_ERR:-unknown}); continuing" ;;
  esac
}

# One keeper tick. Returns 1 if any action failed or a scheduling read came back empty.
keeper_tick() { # keeper_tick <keeper-address>
  local keeper="$1" due cur c st fin out ok=0
  due=$(next_poke_at) || { log "  WARN: skipping tick: cannot schedule the next poke"; return 1; }
  wait_until "$due" || { log "  WARN: skipping tick: cannot reach poke time $due"; return 1; }
  poke_now || { keeper_action_failed poke; ok=1; }
  cur=$(cast_call "$VAULT" "currentCohortId()(uint32)" | first) || cur=""
  is_uint "$cur" || { log "  WARN: skipping finalize/settle: currentCohortId() read returned '${cur}'"; return 1; }
  c=$((cur > 2 ? cur - 2 : 0))
  while [ "$c" -le "$cur" ]; do
    st=$(status_of "$c") || st=""
    is_uint "$st" || { log "  WARN: skipping rest of tick: statusOf($c) read returned '${st}'"; return 1; }
    if [ "$st" = 2 ]; then # SETTLING
      fin=$(cast_call "$VAULT" "keeperFinalize(uint32)(bool,uint256)" "$c" --from "$keeper" | first) || fin=""
      case "$fin" in
        true) ops "keeper-finalize" "$SIGNER_KEEPER" "keeperFinalize()" ARUNA_COHORT="$c" \
          || { keeper_action_failed "finalize($c)"; ok=1; } ;;
        false) ;;
        *) log "  WARN: keeperFinalize($c) simulation returned '${fin}'"; ok=1 ;;
      esac
      # A reverting simulation means nothing to settle; a transport error is a failed read.
      if out=$(cast call --rpc-url "$RPC_URL" --from "$keeper" "$VAULT" "settleBatch(uint32,uint32)" "$c" 50 2>&1); then
        ops "settle-batch" "$SIGNER_KEEPER" "settleBatch()" ARUNA_COHORT="$c" \
          || { keeper_action_failed "settle($c)"; ok=1; }
      elif is_rpc_error "$out"; then
        log "  WARN: settleBatch($c) simulation: RPC error"; ok=1
      fi
    fi
    c=$((c + 1))
  done
  return "$ok"
}

keeper_loop() {
  local keeper now fails=0 backoff tick_ok
  keeper=$(signer_address "$SIGNER_KEEPER") || die "cannot resolve the keeper signer address"
  log "keeper-only as $keeper (max $KEEPER_MAX_FAILS consecutive failed ticks)"
  OPS_SOFT=1
  while :; do
    if [ "$MAX_POKES" != 0 ] && [ "$POKES" -ge "$MAX_POKES" ]; then break; fi
    tick_ok=1
    if [ "$UNTIL" != 0 ] && ! now=$(chain_now_try); then
      log "  WARN: skipping tick: cannot read chain time to check --until"
      tick_ok=0
    elif [ "$UNTIL" != 0 ] && [ "$now" -ge "$UNTIL" ]; then
      break
    elif ! keeper_tick "$keeper"; then
      tick_ok=0
    fi
    if [ "$tick_ok" = 1 ]; then fails=0; continue; fi
    fails=$((fails + 1))
    [ "$fails" -lt "$KEEPER_MAX_FAILS" ] || { OPS_SOFT=0; die "keeper: $fails consecutive failed ticks"; }
    backoff=$((KEEPER_BACKOFF << (fails - 1)))
    [ "$backoff" -le "$KEEPER_BACKOFF_MAX" ] || backoff="$KEEPER_BACKOFF_MAX"
    log "  WARN: tick failed ($fails/$KEEPER_MAX_FAILS consecutive); backing off ${backoff}s"
    sleep "$backoff"
  done
  OPS_SOFT=0
}

# ---------------------------------------------------------------- main
# The results file is finalized on every exit path: complete (exit 0), interrupted
# (SIGINT/SIGTERM, e.g. stopping --keeper-only), failed (anything else, incl. set -e).
on_exit() {
  local rc=$?
  case "$rc" in
    0) finish_results complete; rm -rf "$WORK_DIR" ;;
    130 | 143) finish_results interrupted ;;
    *) finish_results failed ;;
  esac
  [ "$rc" = 0 ] || log "exit $rc; step logs kept in $WORK_DIR; results -> ${RESULTS_FILE:-none}"
}
init_results "$SCENARIO"
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$SCENARIO" in
  pay) scenario_pay ;;
  nopay | refund) scenario_simple ;;
  keeper) keeper_loop ;;
esac
missing=$(jq '[.steps[] | select(.txHash == null or .txHash == "" or .status != 1)] | length' "$RESULTS_FILE")
total=$(jq '.steps | length' "$RESULTS_FILE")
log "done: $total transactions recorded, $missing without a successful receipt -> $RESULTS_FILE"
[ "$missing" = 0 ] || exit 1
