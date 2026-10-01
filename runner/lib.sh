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

# Read-only calls are always safe to repeat: transport errors are retried with backoff.
cast_call() { # cast_call <to> <sig> [args...]
  local out attempt=1
  while :; do
    if out=$(cast call --rpc-url "$RPC_URL" "$@" 2>&1); then printf '%s\n' "$out"; return 0; fi
    if is_rpc_error "$out" && [ "$attempt" -lt "$RETRIES" ]; then
      sleep $((RETRY_BACKOFF * attempt)); attempt=$((attempt + 1)); continue
    fi
    log "cast call failed: $* -> $out"; return 1
  done
}

# Chain head timestamp; returns 1 (no exit) when it cannot be read after RETRIES.
chain_now_try() {
  local out attempt=1
  while :; do
    if out=$(cast block latest -f timestamp --rpc-url "$RPC_URL" 2>&1) && is_uint "$out"; then
      echo "$out"; return 0
    fi
    if [ "$attempt" -lt "$RETRIES" ]; then sleep $((RETRY_BACKOFF * attempt)); attempt=$((attempt + 1)); continue; fi
    log "cannot read chain time: $out"; return 1
  done
}
chain_now() { chain_now_try || die "cannot read chain time"; }

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Transport-level failures worth retrying. Patterns are anchored so that a revert payload,
# an address or an amount that merely CONTAINS "429"/"503" (e.g. 0x…5030…, 4290000) is not
# mistaken for an HTTP status: a status code must follow an HTTP/status/code label or be
# followed by its reason phrase, and stand alone (no adjacent digit).
# A revert is NOT a transport error: it fails the same way twice.
is_rpc_error() {
  printf '%s' "$1" | grep -Eqi \
    -e '(http|status|code)( (code|error|status))?[ :=("]{0,3}(429|502|503|504)([^0-9]|$)' \
    -e '(^|[^0-9])(429 too many requests|502 bad gateway|503 service unavailable|504 gateway time-?out)' \
    -e 'too many requests|rate[ -]?limit(ed)?|exceeded .*(compute units|request limit)' \
    -e 'error sending request|connection (refused|reset|closed)|broken pipe|connection timed out' \
    -e 'operation timed out|request timed out|timed out waiting|deadline (has )?elapsed|(^|[^a-z_])timeout( |:|$)' \
    -e 'EOF while parsing|unexpected EOF|header not found|could not instantiate forked environment' \
    -e 'failed to get (block|chain id|account|nonce|balance|code|storage|transaction|receipt)'
}

# Signer-side conditions forge/the node report on send (not reverts):
#   nonce   - nonce too low/high, "already known" (same tx already in the mempool): the
#             previous attempt may have landed or be pending -> check before resending.
#   price   - replacement / transaction underpriced, fee below base fee: retry, fees are
#             re-estimated on the next run.
#   funds   - insufficient funds for gas: never retried, needs a top-up.
is_nonce_error() { printf '%s' "$1" | grep -Eqi 'nonce too (low|high)|invalid nonce|nonce has already been used|already known|known transaction'; }
is_price_error() { printf '%s' "$1" | grep -Eqi 'replacement transaction underpriced|transaction underpriced|max fee per gas less than block base fee|fee cap less than block base fee'; }
is_funds_error() { printf '%s' "$1" | grep -Eqi 'insufficient funds|insufficient balance for transfer|gas required exceeds allowance'; }

# ---------------------------------------------------------------- time

# Advance chain time to >= target. --anvil: evm_increaseTime + evm_mine (instant).
# Real network: poll the chain head every POLL_SECS (the chain's clock is the authority).
# Returns 1 (OPS_SOFT=1) or dies when the chain clock cannot be read / moved.
wait_until() {
  local target="$1" now
  is_uint "$target" || { ops_fail read "wait_until: empty or invalid target '$target'"; return 1; }
  now=$(chain_now_try) || { ops_fail read "cannot read chain time"; return 1; }
  [ "$now" -ge "$target" ] && return 0
  if [ "$ANVIL" = 1 ]; then
    { cast rpc --rpc-url "$RPC_URL" evm_increaseTime $((target - now)) >/dev/null \
      && cast rpc --rpc-url "$RPC_URL" evm_mine >/dev/null; } || { ops_fail rpc "anvil time jump failed"; return 1; }
    [ "${ANVIL_STEP_DELAY:-0}" != 0 ] && sleep "$ANVIL_STEP_DELAY"
    return 0
  fi
  while [ "$now" -lt "$target" ]; do
    local d=$((target - now))
    [ "$d" -gt "$POLL_SECS" ] && d="$POLL_SECS"
    sleep "$d"
    now=$(chain_now_try) || { ops_fail read "cannot read chain time"; return 1; }
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

finish_results() { # finish_results <status>   (no-op once the file is no longer "running")
  [ -n "${RESULTS_FILE:-}" ] && [ -f "$RESULTS_FILE" ] || return 0
  [ "$(jq -r .status "$RESULTS_FILE" 2>/dev/null)" = running ] || return 0
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

# Ops entrypoints that may be blindly re-sent after an RPC/timeout error: a second copy is
# either a no-op (throttled poke, already-finalized cohort, skipped final policies) or
# toggles the same flag. Everything else (deposit, fundKeeperBudget, approveAndBuy,
# rollTo, withdraw, cancel, claim*, collectFees, swap, mintPosition, ...) moves value and is
# resent only once it is established that the failed attempt did NOT land.
is_idempotent_op() {
  case "$1" in keeperPoke | keeperFinalize | settleBatch | settlePolicy | setRejectIncoming) return 0 ;; *) return 1 ;; esac
}

# Signer address for a forge/cast wallet arg string, cached in WORK_DIR (one keystore
# prompt per signer at most).
signer_address() { # signer_address <signer-args>
  local cache="$WORK_DIR/signers" key addr
  key=$(printf '%s' "$1" | cksum | awk '{print $1}')
  addr=$(awk -v k="$key" '$1 == k {print $2}' "$cache" 2>/dev/null)
  if [ -z "$addr" ]; then
    # shellcheck disable=SC2086
    addr=$(cast wallet address $1 2>/dev/null) || return 1
    printf '%s %s\n' "$key" "$addr" >>"$cache"
  fi
  echo "$addr"
}

pending_nonce() { # pending_nonce <address>  (empty on failure)
  local out attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    out=$(cast nonce --block pending --rpc-url "$RPC_URL" "$1" 2>/dev/null) && is_uint "$out" && { echo "$out"; return 0; }
    sleep $((RETRY_BACKOFF * attempt)); attempt=$((attempt + 1))
  done
  return 1
}

# After a failed send: did the attempt's transactions land? Reads the hashes forge wrote
# to the broadcast file (only if it was written by THIS attempt), waits up to
# RECEIPT_WAIT seconds for each receipt, and falls back to the signer's pending nonce when
# forge recorded no hash at all. Prints one of:
#   landed <file>  every tx mined with status 1; <file> = broadcast copy with receipts
#   reverted       a tx mined with status 0 (never resend: it is a real failure)
#   none           nothing was sent (no hash, nonce unchanged): safe to resend
#   unknown        some tx may be in flight or mined but unaccounted: do NOT resend
check_landed() { # check_landed <bfile> <started> <copy> <signer-addr> <nonce-before>
  local bfile="$1" started="$2" copy="$3" addr="$4" nonce0="$5" ts hashes h r st n=0 missing=0 wait_end
  local fresh=0
  if [ -f "$bfile" ]; then
    ts=$(jq -r '.timestamp // 0' "$bfile"); [ "${#ts}" -gt 11 ] && ts=$((ts / 1000))
    [ "$ts" -ge "$((started - 5))" ] && fresh=1
  fi
  if [ "$fresh" = 1 ]; then
    hashes=$(jq -r '[.transactions[].hash, (.pending // [])[]] | map(select(. != null and . != "")) | unique | .[]' "$bfile")
    if [ -n "$hashes" ]; then
      [ "$(jq '[.transactions[] | select(.hash == null or .hash == "")] | length' "$bfile")" = 0 ] || missing=1
      : >"$copy.receipts"
      wait_end=$(($(date +%s) + ${RECEIPT_WAIT:-60}))
      for h in $hashes; do
        n=$((n + 1))
        while :; do
          r=$(cast receipt --async --json --rpc-url "$RPC_URL" "$h" 2>/dev/null) || r=""
          if [ -n "$r" ] && [ "$r" != null ] && printf '%s' "$r" | jq -e '.blockNumber' >/dev/null 2>&1; then
            printf '%s\n' "$r" >>"$copy.receipts"; break
          fi
          [ "$(date +%s)" -lt "$wait_end" ] || { missing=1; break; }
          sleep 2
        done
      done
      if jq -s -e 'any(.[]; (.status | tostring) == "0x0" or (.status | tostring) == "0")' "$copy.receipts" >/dev/null 2>&1; then
        echo reverted; return 0
      fi
      if [ "$missing" = 0 ]; then
        jq --slurpfile rs "$copy.receipts" '.receipts = $rs' "$bfile" >"$copy" && { echo "landed $copy"; return 0; }
      fi
      echo unknown; return 0
    fi
  fi
  # No hash on record. Without a nonce baseline (idempotent op) assume nothing landed.
  [ -n "$nonce0" ] || { echo none; return 0; }
  local nonce1
  nonce1=$(pending_nonce "$addr") || { echo unknown; return 0; }
  if [ "$nonce1" = "$nonce0" ]; then echo none; else echo unknown; fi
}

# A failed step: fatal by default; with OPS_SOFT=1 (keeper loop) it returns 1 instead and
# leaves the reason in OPS_ERR (rpc | nonce | price | funds | revert | inflight | read | other).
ops_fail() { # ops_fail <kind> <message>
  OPS_ERR="$1"
  if [ "${OPS_SOFT:-0}" = 1 ]; then log "  WARN: $2"; return 1; fi
  die "$2"
}

# ops <step> <signer-args> <sig> [VAR=VALUE ...]
# Runs one Ops entrypoint with --broadcast and records its txs. On an RPC/timeout or
# nonce error it first checks whether the attempt landed (check_landed); it resends only if
# nothing was sent, or, for an idempotent op, if that cannot be established. Underpriced
# sends are retried; insufficient funds and reverts are not.
# Sets OPS_BROADCAST to the broadcast file (read returns with `ret <name>`).
ops() {
  local step="$1" signer="$2" sig="$3"
  shift 3
  local fn="${sig%%(*}" attempt=1 started out kind state addr="" nonce0=""
  local bfile="$ROOT/broadcast/Ops.s.sol/$CHAIN_ID/${fn}-latest.json"
  local logf="$WORK_DIR/$(printf '%03d' "$STEP_NO")-$step.log"
  local copy="$WORK_DIR/$(printf '%03d' "$STEP_NO")-$step.broadcast.json"
  STEP_NO=$((STEP_NO + 1))
  OPS_ERR=""
  local cohort=""
  local kv
  for kv in "$@"; do case "$kv" in ARUNA_COHORT=*) cohort="${kv#ARUNA_COHORT=}" ;; esac; done
  local src="$bfile"
  while :; do
    if ! is_idempotent_op "$fn"; then
      # Baseline for "did anything get sent?" when forge records no hash.
      addr=$(signer_address "$signer") || { ops_fail other "step '$step': cannot resolve signer address"; return 1; }
      nonce0=$(pending_nonce "$addr") || nonce0=""
      [ -n "$nonce0" ] || { ops_fail rpc "step '$step': cannot read nonce of $addr before sending"; return 1; }
    fi
    started=$(date +%s)
    # shellcheck disable=SC2086
    if (cd "$ROOT" && env "${BASE_ENV[@]}" "$@" forge script script/Ops.s.sol:Ops \
      --sig "$sig" --rpc-url "$RPC_URL" --broadcast $FORGE_FLAGS $signer) >"$logf" 2>&1; then
      src="$bfile"; break
    fi
    out=$(tail -40 "$logf")
    if is_funds_error "$out"; then kind=funds
    elif is_nonce_error "$out"; then kind=nonce
    elif is_price_error "$out"; then kind=price
    elif is_rpc_error "$out"; then kind=rpc
    else kind=other
    fi
    case "$kind" in
      funds)
        printf '%s\n' "$out" >&2
        ops_fail funds "step '$step' ($sig): insufficient funds for $signer; top up the signer. log: $logf"; return 1 ;;
      other)
        printf '%s\n' "$out" >&2
        ops_fail revert "step '$step' ($sig) failed; log: $logf"; return 1 ;;
    esac
    # rpc / nonce / price: never resend before knowing whether the attempt landed.
    state=$(check_landed "$bfile" "$started" "$copy" "$addr" "$nonce0")
    case "$state" in
      landed\ *)
        log "  $step: $kind error but the tx landed; not resending"
        src="${state#landed }"; break ;;
      reverted)
        ops_fail revert "step '$step' ($sig): tx mined but reverted after a $kind error; log: $logf"; return 1 ;;
      unknown)
        if ! is_idempotent_op "$fn"; then
          ops_fail inflight "step '$step' ($sig): $kind error and the tx may be in flight or mined; NOT resending a state change. Check $bfile / the signer's nonce, then rerun. log: $logf"
          return 1
        fi ;;
    esac
    if [ "$attempt" -ge "$RETRIES" ]; then
      printf '%s\n' "$out" >&2
      ops_fail "$kind" "step '$step' ($sig): $kind error after $attempt attempts; log: $logf"; return 1
    fi
    log "  $step: $kind error ($state), retry $attempt/$RETRIES"
    attempt=$((attempt + 1)); sleep $((RETRY_BACKOFF * attempt))
  done
  [ -f "$src" ] || { ops_fail other "step '$step': no broadcast file $src"; return 1; }
  local ts
  ts=$(jq -r '.timestamp // 0' "$src")
  # forge writes the timestamp in ms in recent versions; accept either.
  [ "${#ts}" -gt 11 ] && ts=$((ts / 1000))
  [ "$ts" -ge "$((started - 5))" ] || { ops_fail other "step '$step': stale broadcast file (no tx sent?)"; return 1; }
  OPS_BROADCAST="$src"
  record_broadcast "$step" "$cohort" "$src"
  local n
  n=$(jq '.transactions | length' "$src")
  log "  $step: $n tx, last $(jq -r '.transactions[-1].hash' "$src")"
}

ret() { jq -r --arg k "$1" '.returns[$k].value' "$OPS_BROADCAST"; }
