#!/usr/bin/env bash
# Shared helpers for runner/run.sh (bash 3.2 compatible: no associative arrays).
#
# Every on-chain step goes through `ops` (one `forge script script/Ops.s.sol:Ops` run per
# lifecycle action). Its transactions are read back from forge's broadcast file and appended
# to the results file: one entry per transaction (scenario, step, action, tx hash, block,
# to, from, status). The conformance ledger (U10) reads these files.

# ---------------------------------------------------------------- logging

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; finish_results failed; exit 1; }

# ---------------------------------------------------------------- chain reads

# First word of a cast output ("123 [1.23e2]" -> "123").
first() { awk 'NR==1{print $1}'; }

cast_call() { # cast_call <to> <sig> [args...]
  local out attempt=1
  while :; do
    if out=$(cast call --rpc-url "$RPC_URL" "$@" 2>&1); then printf '%s\n' "$out"; return 0; fi
    if is_rpc_error "$out" && [ "$attempt" -lt "$RETRIES" ]; then
      attempt=$((attempt + 1)); sleep "$RETRY_BACKOFF"; continue
    fi
    log "cast call failed: $* -> $out"; return 1
  done
}

chain_now() {
  local out attempt=1
  while :; do
    if out=$(cast block latest -f timestamp --rpc-url "$RPC_URL" 2>&1); then echo "$out"; return 0; fi
    if [ "$attempt" -lt "$RETRIES" ]; then attempt=$((attempt + 1)); sleep "$RETRY_BACKOFF"; continue; fi
    die "cannot read chain time: $out"
  done
}

# Transport-level failures worth retrying. A revert is NOT retried: it fails the same way
# twice, and blindly re-sending a state change (deposit) could double it.
is_rpc_error() {
  printf '%s' "$1" | grep -Eqi \
    'error sending request|connection (refused|reset|closed)|timed? ?out|429|too many requests|rate.?limit|502|503|504|bad gateway|service unavailable|EOF while|failed to get|header not found|could not instantiate forked environment'
}

# ---------------------------------------------------------------- time

# Advance chain time to >= target. --anvil: evm_increaseTime + evm_mine (instant).
# Real network: poll the chain head every POLL_SECS (the chain's clock is the authority).
wait_until() {
  local target="$1" now
  now=$(chain_now)
  [ "$now" -ge "$target" ] && return 0
  if [ "$ANVIL" = 1 ]; then
    cast rpc --rpc-url "$RPC_URL" evm_increaseTime $((target - now)) >/dev/null
    cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null
    [ "${ANVIL_STEP_DELAY:-0}" != 0 ] && sleep "$ANVIL_STEP_DELAY"
    return 0
  fi
  while [ "$now" -lt "$target" ]; do
    local d=$((target - now))
    [ "$d" -gt "$POLL_SECS" ] && d="$POLL_SECS"
    sleep "$d"
    now=$(chain_now)
  done
}

# ---------------------------------------------------------------- results file

init_results() { # init_results <scenario>
  mkdir -p "$RESULTS_DIR"
  RESULTS_FILE="$RESULTS_DIR/$1-$(date -u +%Y%m%dT%H%M%SZ).json"
  jq -n \
    --arg scenario "$1" --argjson chainId "$CHAIN_ID" --arg rpcMode "$([ "$ANVIL" = 1 ] && echo anvil || echo live)" \
    --arg manifest "$MANIFEST" --arg vault "$VAULT" --arg gitCommit "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{scenario:$scenario, chainId:$chainId, mode:$rpcMode, manifest:$manifest, vault:$vault,
      gitCommit:$gitCommit, startedAt:$startedAt, finishedAt:null, status:"running", steps:[]}' \
    >"$RESULTS_FILE"
  log "results -> $RESULTS_FILE"
}

finish_results() { # finish_results <status>
  [ -n "${RESULTS_FILE:-}" ] && [ -f "$RESULTS_FILE" ] || return 0
  local tmp="$RESULTS_FILE.tmp"
  jq --arg s "$1" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status=$s | .finishedAt=$t' \
    "$RESULTS_FILE" >"$tmp" && mv "$tmp" "$RESULTS_FILE"
}

# Append every transaction of a forge broadcast file as steps.
record_broadcast() { # record_broadcast <step> <cohort-or-empty> <broadcast-file>
  local step="$1" cohort="$2" bfile="$3" tmp="$RESULTS_FILE.tmp"
  jq --arg scenario "$SCENARIO" --arg step "$step" --arg cohort "$cohort" \
    --slurpfile b "$bfile" '
    def hex2dec: if type == "number" then . else ltrimstr("0x") | ascii_downcase | explode
      | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end)) end;
    ($b[0]) as $bc
    | .steps += [ $bc.transactions[] as $t
        | ($bc.receipts | map(select(.transactionHash == $t.hash)) | .[0]) as $r
        | { scenario: $scenario, step: $step,
            cohort: (if $cohort == "" then null else ($cohort|tonumber) end),
            action: $t.function, txHash: $t.hash,
            block: (if $r then ($r.blockNumber | hex2dec) else null end),
            address: $t.transaction.to, from: $t.transaction.from,
            status: (if $r then ($r.status | hex2dec) else null end) } ]' \
    "$RESULTS_FILE" >"$tmp" && mv "$tmp" "$RESULTS_FILE"
}

# ---------------------------------------------------------------- Ops runner

# ops <step> <signer-args> <sig> [VAR=VALUE ...]
# Runs one Ops entrypoint with --broadcast, retrying on RPC errors, and records its txs.
# Sets OPS_BROADCAST to the broadcast file (read returns with `ret <name>`).
ops() {
  local step="$1" signer="$2" sig="$3"
  shift 3
  local fn="${sig%%(*}" attempt=1 started out
  local bfile="$ROOT/broadcast/Ops.s.sol/$CHAIN_ID/${fn}-latest.json"
  local logf="$WORK_DIR/$(printf '%03d' "$STEP_NO")-$step.log"
  STEP_NO=$((STEP_NO + 1))
  local cohort=""
  local kv
  for kv in "$@"; do case "$kv" in ARUNA_COHORT=*) cohort="${kv#ARUNA_COHORT=}" ;; esac; done
  while :; do
    started=$(date +%s)
    # shellcheck disable=SC2086
    if (cd "$ROOT" && env "${BASE_ENV[@]}" "$@" forge script script/Ops.s.sol:Ops \
      --sig "$sig" --rpc-url "$RPC_URL" --broadcast $FORGE_FLAGS $signer) >"$logf" 2>&1; then
      break
    fi
    out=$(tail -40 "$logf")
    if is_rpc_error "$out" && [ "$attempt" -lt "$RETRIES" ]; then
      log "  $step: RPC error, retry $attempt/$RETRIES"
      attempt=$((attempt + 1)); sleep $((RETRY_BACKOFF * attempt)); continue
    fi
    printf '%s\n' "$out" >&2
    die "step '$step' ($sig) failed; log: $logf"
  done
  [ -f "$bfile" ] || die "step '$step': no broadcast file $bfile"
  local ts
  ts=$(jq -r '.timestamp // 0' "$bfile")
  # forge writes the timestamp in ms in recent versions; accept either.
  [ "${#ts}" -gt 11 ] && ts=$((ts / 1000))
  [ "$ts" -ge "$((started - 5))" ] || die "step '$step': stale broadcast file (no tx sent?)"
  OPS_BROADCAST="$bfile"
  record_broadcast "$step" "$cohort" "$bfile"
  local n
  n=$(jq '.transactions | length' "$bfile")
  log "  $step: $n tx, last $(jq -r '.transactions[-1].hash' "$bfile")"
}

ret() { jq -r --arg k "$1" '.returns[$k].value' "$OPS_BROADCAST"; }
