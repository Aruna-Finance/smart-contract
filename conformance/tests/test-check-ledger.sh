#!/usr/bin/env bash
# Tests for conformance/check-ledger (plan U10 test scenarios).
#
#   conformance/tests/test-check-ledger.sh            # runs `forge test --json` once
#   FORGE_JSON=out.json conformance/tests/test-check-ledger.sh   # reuse a results file
#
# Every case runs the real checker on a ledger derived from the real one, against the real
# test results (or a copy with one result flipped). On-chain verification uses a stub `cast`
# on PATH that serves receipts from a fixture file, so no RPC is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/conformance/check-ledger"
LEDGER="$ROOT/conformance/ledger.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-ledger-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${FORGE_JSON:-}" ]; then
  cp "$FORGE_JSON" "$TMP/forge.json"
else
  echo "running forge test --json ..." >&2
  (cd "$ROOT" && forge test --json 2>/dev/null | grep '^{' | tail -n 1) >"$TMP/forge.json" || true
fi
jq -e 'type == "object" and length > 0' "$TMP/forge.json" >/dev/null || { echo "no forge results"; exit 2; }

# ---- fixtures -------------------------------------------------------------------------------
VAULT=0x00000000000000000000000000000000000000aa
FACTORY=0x00000000000000000000000000000000000000fa
OUTSIDER=0x00000000000000000000000000000000000000ee
H_OK=0x$(printf '1%.0s' $(seq 64))
H_REVERTED=0x$(printf '2%.0s' $(seq 64))
H_OUTSIDE=0x$(printf '3%.0s' $(seq 64))
H_UNKNOWN=0x$(printf '4%.0s' $(seq 64))

cat >"$TMP/manifest.json" <<EOF
{ "chainId": 421614, "profile": "sandbox",
  "contracts": { "ArunaFactory": "$FACTORY" },
  "markets": { "0": { "vault": "$VAULT", "tenor": 3600 } } }
EOF
cat >"$TMP/receipts.json" <<EOF
{ "$H_OK":       { "status": "0x1", "to": "$VAULT",    "contractAddress": null, "blockNumber": "0x64" },
  "$H_REVERTED": { "status": "0x0", "to": "$VAULT",    "contractAddress": null, "blockNumber": "0x65" },
  "$H_OUTSIDE":  { "status": "0x1", "to": "$OUTSIDER", "contractAddress": null, "blockNumber": "0x66" } }
EOF
mkdir -p "$TMP/bin"
cat >"$TMP/bin/cast" <<'EOF'
#!/usr/bin/env bash
# stub cast: chain-id and receipt only
case "$1" in
  chain-id) echo "${STUB_CHAIN_ID:-421614}" ;;
  receipt) h="${@: -1}"; jq -ce --arg h "$h" '.[$h] // empty' "$STUB_RECEIPTS" || { echo "no receipt" >&2; exit 1; } ;;
  *) echo "stub cast: unsupported $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/cast"
export STUB_RECEIPTS="$TMP/receipts.json"

# All-green ledger: every lifecycle row cites a verified tx, doc rows are n-a, SC-08 drops the
# (skipped) fork test. This is what the ledger looks like after Phase 2 + U11.
jq --arg m "$TMP/manifest.json" --arg h "$H_OK" '
  .rcManifest = $m | .status = "green"
  | .rows |= map(
      if .lifecycle == true then
        .status = "green" | del(.reason)
        | .rcTx = [{network: 421614, hash: $h, expectAddressIn: "markets.0.vault", block: 100}]
      elif .id == "SC-08" then
        .status = "green" | del(.reason) | .tests |= map(select(test("ReplayArbitrum") | not))
      elif .status == "pending" then .status = "n-a" | .reason = "fixture"
      else . end)
' "$LEDGER" >"$TMP/green.json"

# ---- harness --------------------------------------------------------------------------------
PASS=0; FAIL=0
# run <name> <expect: pass|fail> <expected-output-substring|-> <ledger> [online] [forge-json]
run() {
  local name="$1" expect="$2" needle="$3" ledger="$4" online="${5:-}" fj="${6:-$TMP/forge.json}"
  local out code=0
  if [ "$online" = online ]; then
    out="$(PATH="$TMP/bin:$PATH" ARUNA_LEDGER_RPC_URL=http://stub "$CHECK" --ledger "$ledger" --forge-json "$fj" 2>&1)" || code=$?
  else
    out="$(env -u ARUNA_LEDGER_RPC_URL "$CHECK" --offline --ledger "$ledger" --forge-json "$fj" 2>&1)" || code=$?
  fi
  local ok=1
  if [ "$expect" = pass ] && [ "$code" -ne 0 ]; then ok=0; fi
  if [ "$expect" = fail ] && [ "$code" -ne 1 ]; then ok=0; fi
  if [ "$needle" != - ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    PASS=$((PASS + 1)); echo "ok   - $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $name (exit $code, expected $expect, needle: $needle)"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/       /'
  fi
}
# derive <name> <jq filter> [base]: write a ledger variant
derive() { jq "$2" "${3:-$TMP/green.json}" >"$TMP/$1.json"; echo "$TMP/$1.json"; }

# ---- cases ----------------------------------------------------------------------------------
run "real ledger, offline: pending RC rows are fine" pass "OK" "$LEDGER"

run "all-green ledger with real tests and verified tx" pass "verified on-chain: 15" "$TMP/green.json" online

L="$(derive missing-test '(.rows[] | select(.id == "I3") | .tests) += ["test/CoverVaultInvariants.t.sol:CoverVaultInvariants:invariant_I3_doesNotExist"]')"
run "AE12: green row citing a missing test fails" fail "test not found" "$L" online

jq '."test/CoverVaultInvariants.t.sol:CoverVaultInvariants".test_results[]
      .invariant_predicate_results |= map(if .name == "invariant_I3_balanceCoversObligations" then .status = "Failure" else . end)' \
   "$TMP/forge.json" >"$TMP/forge-i3-red.json"
run "AE12: green row citing a failing invariant fails" fail "test did not pass (Failure)" "$TMP/green.json" online "$TMP/forge-i3-red.json"

jq '."test/CoverVaultPolicy.t.sol:CoverVaultPolicyTest".test_results["test_AE8_CancelDay3_FreesCapacityAndSlot_PremiumStays()"].status = "Failure"' \
   "$TMP/forge.json" >"$TMP/forge-ae8-red.json"
run "green row citing a failing unit test fails" fail "row AE8: test did not pass" "$TMP/green.json" online "$TMP/forge-ae8-red.json"

L="$(derive no-tests '(.rows[] | select(.id == "SC-01") | .tests) = []')"
run "green row without tests fails" fail "green row has no tests" "$L" online

L="$(derive lifecycle-no-tx '(.rows[] | select(.id == "RC-PAY") | .rcTx) = []')"
run "lifecycle row green without tx hash fails" fail "row RC-PAY: lifecycle row is green without any RC transaction hash" "$L" online

run "green rcTx rows cannot pass offline" fail "no RPC verification ran" "$TMP/green.json"

jq --arg h "$H_REVERTED" '(.rows[] | select(.id == "RC-CANCEL") | .rcTx[0]) |= (.hash = $h | .block = 101)' "$TMP/green.json" >"$TMP/reverted.json"
run "tx with a failed receipt fails" fail "row RC-CANCEL: tx $H_REVERTED failed (receipt status 0x0)" "$TMP/reverted.json" online

jq --arg h "$H_OUTSIDE" '(.rows[] | select(.id == "CH-1") | .rcTx[0]) |= (.hash = $h | .block = 102)' "$TMP/green.json" >"$TMP/outside.json"
run "tx targeting an address outside the manifest fails" fail "not an address under manifest key" "$TMP/outside.json" online

jq --arg h "$H_UNKNOWN" '(.rows[] | select(.id == "CH-2") | .rcTx[0].hash) = $h' "$TMP/green.json" >"$TMP/unknown.json"
run "unknown tx hash fails" fail "no receipt for $H_UNKNOWN" "$TMP/unknown.json" online

L="$(derive wrong-block '(.rows[] | select(.id == "CH-3") | .rcTx[0].block) = 7')"
run "recorded block mismatch fails" fail "ledger says 7" "$L" online

L="$(derive bad-key '(.rows[] | select(.id == "CH-4") | .rcTx[0].expectAddressIn) = "markets.9.vault"')"
run "rcTx manifest key without addresses fails" fail "holds no address" "$L" online

L="$(derive wrong-chain '(.rows[] | select(.id == "CH-5") | .rcTx[0].network) = 1')"
run "rcTx on another network fails" fail "network 1 != manifest chainId 421614" "$L" online

L="$(derive na-no-reason '(.rows[] | select(.id == "RC-NFT-PARKED")) |= del(.reason)')"
run "n-a row without reason fails" fail "status n-a requires a reason" "$L" online

L="$(derive status-lie '.status = "green" | (.rows[] | select(.id == "SC-18")) |= (.status = "pending" | .reason = "x")')"
run "top-level status disagreeing with rows fails" fail "but the rows make it \"pending\"" "$L" online

L="$(derive missing-row 'del(.rows[] | select(.id == "SC-13"))')"
run "missing audit row fails" fail "coverage: missing row SC-13" "$L" online

L="$(derive decision-no-ref '(.rows[] | select(.id == "SC-05")) |= del(.decisionRef)')"
run "decision row without origin reference fails" fail "decisionRef" "$L" online

L="$(derive green-no-manifest '.rcManifest = null')"
run "green ledger without rcManifest fails" fail "must name its rcManifest" "$L" online

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
