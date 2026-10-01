# Conformance ledger

`ledger.json` is the objective finish line for "ready to release" (plan U10, R26). Every audit
finding, invariant, SSOT §8 chain link, acceptance example, RC scenario and release-profile
measurement is one row. Each row cites the named Foundry tests that prove it and, for
lifecycle behavior, the release-candidate (RC) transactions that show it on-chain.
`check-ledger` verifies those citations. `script/Deploy.s.sol:DeployFactory` refuses a release
unless the ledger's `status` is `"green"` and its `rcManifest` equals `ARUNA_RC_MANIFEST`.

## Format

```jsonc
{
  "schema": "aruna-conformance/1",
  "status": "pending",            // green | red | pending, recomputed and enforced by the checker
  "rcManifest": null,             // RC manifest path, e.g. "deployments/421614/sandbox.json"
  "updatedAt": "2026-10-01",
  "rows": [
    {
      "id": "SC-01",                         // SC-01..SC-24, I1..I8, I-KEEPER, CH-1..CH-6, AE1..AE12, RC-*, RP-*
      "kind": "bug",                         // see kinds below
      "requirements": ["R1"],                // origin R-IDs
      "description": "…",
      "tests": ["test/CoverVaultCalendar.t.sol:CoverVaultCalendarTest:test_Spec_SC01_FundingWithdrawReducesCapital_AE1"],
      "rcTx": [ { "network": 421614, "hash": "0x…", "expectAddressIn": "markets.0.vault", "block": 123 } ],
      "status": "green",                     // green | red | pending | n-a
      "reason": "…",                         // required for pending and n-a
      "lifecycle": true,                     // optional: row must cite RC tx before it can be green
      "decisionRef": "…",                    // required for kind "decision": the origin decision it follows
      "mapsTo": "U11"                        // optional: the unit that will close a pending row
    }
  ]
}
```

- **kind**: `bug`, `unbuilt`, `decision`, `out-of-spec`, `doc` (audit rows, by the audit's
  A/B/C/D classes), `invariant`, `chain` (SSOT §8), `acceptance` (AE), `rc-scenario`,
  `release-profile` (rows from `test/ReleaseProfile.t.sol`).
- **tests**: `path:Contract:testName`, without the parameter list. Each invariant of an
  invariant suite can be cited by its own name. Forge reports them under one suite entry, and
  the checker expands them.
- **rcTx**: `network` is the decimal chain id and must equal the manifest's `chainId`.
  `expectAddressIn` is a dot path into the RC manifest, for example `markets.0.vault`,
  `contracts.ArunaFactory`, or `aux.rejectingReceiver_0`. The transaction's `to`, or its created
  contract, must be one of the addresses under that key. `block` is optional. When it is
  present, it must match the receipt.
- **status**:
  - `green`: proven.
  - `red`: known broken, and blocks release.
  - `pending`: not proven yet. Needs a `reason`.
  - `n-a`: does not apply. Needs a justified `reason`.

  The top-level `status` is `green` only when every row is `green` or `n-a`. It is `red` if any
  row is `red`, and `pending` otherwise.

### Current state (before Phase 2)

- Every unit-provable row is green with passing tests.
- Pending rows:
  - SSOT §8 chain links (CH-1..CH-6) and RC scenarios: no RC has run yet.
  - SC-08: the fork replay needs `ARBITRUM_RPC_URL`.
  - SC-18, SC-21, SC-24: documentation work for U11.
- n-a rows:
  - SC-20: compiler pin, a build setting.
  - RC-NFT-PARKED: cannot be triggered on the real NFPM. A unit test proves it.
- `rcManifest` is `null`, so the release guard refuses to deploy.

## Running the checker

```bash
conformance/check-ledger --offline                       # runs forge test --json, structure + tests
conformance/check-ledger --offline --forge-json out.json # reuse a results file
ARUNA_LEDGER_RPC_URL=<rpc> conformance/check-ledger      # also verifies every rcTx on-chain
conformance/tests/test-check-ledger.sh                   # the checker's own tests (stub cast)
```

The checker fails, listing each violation, when any of these is true:
- A row is missing from the required set.
- A green row has no tests.
- A cited test is missing, or failed. A pending row may cite a skipped test, but not a failing one.
- A lifecycle row is green without an RC transaction.
- A green row cites `rcTx` but no RPC verification ran.
- An `rcTx` fails any of these:
  - its receipt is missing, or its status is not 1;
  - its target is not under its manifest key;
  - its block differs from the receipt;
  - its chain differs from the manifest.
- A pending or n-a row has no reason.
- A decision row has no `decisionRef`.
- The top-level `status` disagrees with the rows.

With `--offline`, or without `ARUNA_LEDGER_RPC_URL`, a green row that cites `rcTx` is always
refused. Release-time verification must run online.

## Updating rows after RC runs

1. Run the RC as in `deployments/README.md` ("RC runbook"). Commit `deployments/421614/<label>.json`,
   `broadcast/*/421614/`, and `runner/results/*.json`.
2. Set `rcManifest` to the RC manifest path.
3. For each lifecycle row, copy the relevant steps from the runner results into `rcTx`:

   ```bash
   jq '[.steps[] | select(.step == "settle-batch") | {network: 421614, hash: .txHash, block, expectAddressIn: "markets.0.vault"}]' \
     runner/results/pay-<ts>.json
   ```

   Here is which runner scenario supplies each row:

   | Row | Runner scenario |
   |---|---|
   | RC-PAY | `pay` |
   | RC-NOPAY | `nopay` |
   | RC-REFUND | `refund` |
   | RC-ROLL-N1 / RC-ROLL-N2-LATE | `pay` (`rollTo` steps) |
   | RC-CANCEL / RC-COLLECT-FEES | `pay` (`cancel` / `collectFees`) |
   | RC-PAYOUT-PARKED | `pay` (`settlePolicy` on the receiver, then `claimUnclaimed`) |
   | RC-KEEPER-CYCLE | `--keeper-only` |
   | CH-1..CH-6 | deposit, buy, poke, finalize/settle, withdraw/roll steps |

   Each step's `address` is the contract it called. Point `expectAddressIn` at the manifest
   key that holds that address.
4. Set the row to `green` and delete its `reason`. Then set the top-level `status` the checker
   computes, and bump `updatedAt`.
5. Run `ARUNA_LEDGER_RPC_URL=<rpc> conformance/check-ledger`. It must print `OK` before
   `PROFILE=release ARUNA_RC_MANIFEST=<same path> … DeployFactory`.
6. **SC-08:** run `FOUNDRY_PROFILE=fork forge test --mc ReplayArbitrum --json > fork.json`, then
   pass both results files: `--forge-json default.json --forge-json fork.json`. A test counts as
   passed if it passed in some file and failed in none.

If a row turns red on the RC (AE12), the release stays blocked. The fix goes into a new RC, and
the ledger is re-filled from that RC's manifest.

## CI

`.github/workflows/test.yml` runs `forge test --json` once after the test step. It then runs
`check-ledger --offline` on that file, along with the checker's own tests. The offline mode
passes on the current tree because no green row cites an RC transaction yet. Once RC rows are
green, run the online check at release time with an RPC (see step 5).
