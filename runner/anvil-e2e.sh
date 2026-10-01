#!/usr/bin/env bash
# Local end-to-end rehearsal of the RC (plan U9 test scenario "runner menjalankan satu
# siklus sandbox penuh di anvil"): start a throwaway anvil, stand up the local Uniswap
# stand-ins (script/Local.s.sol), run DeployFactory + DeployMarket with the SANDBOX profile,
# then drive scenarios with runner/run.sh --anvil (time jumps via evm_increaseTime).
#
# Usage: runner/anvil-e2e.sh [scenario ...]        (default: pay nopay refund)
# Env:   ANVIL_PORT (default 8545), E2E_TENOR (900), E2E_GAP (300), E2E_INTERVAL (60),
#        KEEP_ANVIL=1 to leave anvil running afterwards.
# Writes deployments/31337/anvil-e2e.json and runner/results/local/*.json (both gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:$PORT"
TENOR="${E2E_TENOR:-900}" GAP="${E2E_GAP:-300}" INTERVAL="${E2E_INTERVAL:-60}"
SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -gt 0 ] || SCENARIOS=(pay nopay refund)
# anvil dev key 0 (public, worthless outside a local anvil)
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "something already listens on $RPC; set ANVIL_PORT" >&2
  exit 2
fi
anvil --port "$PORT" --silent &
ANVIL_PID=$!
cleanup() { [ "${KEEP_ANVIL:-0}" = 1 ] || kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

fs() { forge script "$@" --rpc-url "$RPC" --private-key "$PK0" --broadcast >"$LOGDIR/$(echo "$1" | tr '/:' '__').log" 2>&1 \
  || { tail -40 "$LOGDIR/$(echo "$1" | tr '/:' '__').log" >&2; exit 1; }; }
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/aruna-e2e.XXXXXX")"

echo "== local Uniswap stand-ins"
ARUNA_TN_FEE=500 ARUNA_LOCAL_AMOUNT_PER_TICK=1000000000 fs script/Local.s.sol:LocalSetup
INFRA=deployments/31337/local-infra.json

echo "== DeployFactory (sandbox: tenors $TENOR,3600 gap $GAP interval $INTERVAL)"
export PROFILE=sandbox ARUNA_DEPLOY_LABEL=anvil-e2e ARUNA_MANIFEST_OVERWRITE=true
GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
export GIT_COMMIT
export ARUNA_POSITION_MANAGER="$(jq -r .positionManager $INFRA)" ARUNA_SETTLEMENT_TOKEN="$(jq -r .usdc $INFRA)"
export ARUNA_ROUTER="$(jq -r .router $INFRA)" ARUNA_POOL="$(jq -r .pool $INFRA)"
export ARUNA_ALLOWED_TENORS="$TENOR,3600" ARUNA_GAP="$GAP" ARUNA_SAMPLE_INTERVAL="$INTERVAL"
export ARUNA_MAX_KEEPER_SHARE_BPS=1000 ARUNA_MAX_POKE_BOUNTY=1000000 ARUNA_MAX_FINALIZE_BOUNTY=5000000 ARUNA_MAX_SETTLE_BOUNTY=2000000
fs script/Deploy.s.sol:DeployFactory
MANIFEST=deployments/31337/anvil-e2e.json

echo "== DeployMarket (tenor $TENOR, placeholder calibration, keeper budget 1e7)"
export ARUNA_MANIFEST="$MANIFEST" ARUNA_FACTORY="$(jq -r .contracts.ArunaFactory $MANIFEST)"
export ARUNA_TENOR="$TENOR" ARUNA_ANCHOR=0 ARUNA_ANCHOR_LEAD=300
export ARUNA_MAX_UTIL_BPS=8000 ARUNA_MAX_EXCESS_VARIANCE=2000000000000000000 ARUNA_EWMA_ALPHA_BPS=2000
export ARUNA_SEED_VARIANCE=500000000000000000 ARUNA_POLICY_CAP=20 ARUNA_KEEPER_SHARE_BPS=500
export ARUNA_POKE_BOUNTY=10000 ARUNA_FINALIZE_BOUNTY=50000 ARUNA_SETTLE_BOUNTY=20000
export ARUNA_PRICER_MIN_PREMIUM=1000000 ARUNA_PRICER_LOAD_BPS=1000 ARUNA_PRICER_LAMBDA=500000000000000000
export ARUNA_PRICER_M_KNOTS=0,500000000000000000,1000000000000000000,2000000000000000000,4000000000000000000
export ARUNA_PRICER_G_KNOTS=1000000000000000000,600000000000000000,350000000000000000,150000000000000000,50000000000000000
export ARUNA_VALUER_KAPPA=1000000000000000000 ARUNA_VALUER_REF_WIDTH=2000
export ARUNA_VALUER_MIN_WIDTH_MULT=250000000000000000 ARUNA_VALUER_MAX_WIDTH_MULT=4000000000000000000
export ARUNA_CALIBRATION_ARTIFACT=sandbox-placeholder ARUNA_CALIBRATION_PLACEHOLDER=true
export ARUNA_KEEPER_BUDGET_FUNDING=10000000
cast send --rpc-url "$RPC" --private-key "$PK0" "$ARUNA_SETTLEMENT_TOKEN" "mint(address,uint256)" \
  "$(cast wallet address --private-key "$PK0")" 10000000 >/dev/null
fs script/Deploy.s.sol:DeployMarket

echo "== scenarios: ${SCENARIOS[*]}"
for sc in "${SCENARIOS[@]}"; do
  case "$sc" in
    keeper) runner/run.sh --anvil --rpc-url "$RPC" --manifest "$MANIFEST" --keeper-only --max-pokes 3 ;;
    *) runner/run.sh --anvil --rpc-url "$RPC" --manifest "$MANIFEST" --scenario "$sc" ;;
  esac
done
echo "== done; manifest $MANIFEST, results runner/results/local/"
