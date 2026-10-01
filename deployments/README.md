# Deployments

One JSON manifest per deployment: `deployments/<chainId>/<label>.json`. The manifest is the
single source of addresses for the release candidate (RC) and the release (R29). The deploy
scripts write it, `script/Ops.s.sol` / `script/Scenarios.s.sol` append to it, and the runner
(`runner/`) and the conformance ledger (`conformance/`, U10) read it.

- RC and release manifests (Arbitrum Sepolia `421614`, later the release chain) are committed,
  together with their `broadcast/` files.
- Local anvil artifacts are **gitignored**: `deployments/31337/`, `broadcast/*/31337/`,
  `runner/results/local/`.

## Profiles

| | `sandbox` (RC) | `release` |
|---|---|---|
| Time scale | small, e.g. tenor `3600`, sample interval `60`, gap `600` | real, e.g. tenor `604800`, gap `86400` |
| Calibration | placeholder allowed, recorded as `calibration.placeholder: true` | `ARUNA_CALIBRATION_PLACEHOLDER=false` and `ARUNA_CALIBRATION_ARTIFACT` required |
| Anchor | `ARUNA_ANCHOR=0` → now + `ARUNA_ANCHOR_LEAD` | explicit `ARUNA_ANCHOR` |
| Guards | none | see below |

The RC and the release run the **same bytecode**. They differ only in the factory constructor's
time parameters (and the per-market calibration). The init code hashes in the manifest
(`keccak256(creationCode)`, no constructor args) prove the bytecode is the same.

### Release guards (checked before any broadcast)

`DeployFactory` with `PROFILE=release` reverts with `ReleaseGuard(...)` unless all of these hold:

1. `GIT_COMMIT` is set.
2. `ARUNA_RC_MANIFEST` names an existing sandbox RC manifest.
3. The conformance ledger (`ARUNA_LEDGER`, default `conformance/ledger.json`) exists, its
   `status` is `"green"`, and its `rcManifest` equals `ARUNA_RC_MANIFEST`.
4. Every init code hash of this build (factory, both deployers, CoverVault,
   VarianceAccumulator, FlatVegaPricer, PositionValuer) equals the RC manifest's.

`DeployMarket` with `PROFILE=release` reverts unless `ARUNA_CALIBRATION_PLACEHOLDER=false`,
`ARUNA_CALIBRATION_ARTIFACT` is set, `ARUNA_ANCHOR` is explicit, and the build's hashes equal
the factory manifest's. A placeholder is marked by this explicit flag. The script never guesses
it from the values.

These guards are covered by `test/script/Deploy.t.sol`.

## Manifest format (`schema: "aruna-deployment/1"`)

```jsonc
{
  "schema": "aruna-deployment/1",
  "chainId": 421614, "profile": "sandbox", "label": "sandbox",
  "gitCommit": "<sha>", "deployer": "0x…", "blockNumber": 123, "timestamp": 1790000000,
  "rcManifest": "",                       // release: the RC manifest it was checked against
  "infra": { "positionManager": "0x…", "settlementToken": "0x…", "router": "0x…" },
  "contracts": { "ArunaFactory": "0x…", "VaultDeployer": "0x…", "AccumulatorDeployer": "0x…" },
  "factoryArgs": { "vaultDeployer": "0x…", "accumulatorDeployer": "0x…", "positionManager": "0x…",
                   "settlementToken": "0x…", "allowedTenors": [3600], "gap": 600, "sampleInterval": 60,
                   "maxKeeperShareBps": 1000, "maxPokeBounty": "…", "maxFinalizeBounty": "…",
                   "maxSettleBounty": "…" },
  "initCodeHashes": { "ArunaFactory": "0x…", "VaultDeployer": "0x…", "AccumulatorDeployer": "0x…",
                      "CoverVault": "0x…", "VarianceAccumulator": "0x…",
                      "FlatVegaPricer": "0x…", "PositionValuer": "0x…" },
  "markets": {
    "0": { "vault": "0x…", "accumulator": "0x…", "pool": "0x…", "pricer": "0x…", "valuer": "0x…",
           "factory": "0x…", "tenor": 3600, "anchor": 1790000600, "deployer": "0x…",
           "blockNumber": 124, "timestamp": 1790000000,
           "params": { … createVault params … }, "pricerArgs": { … }, "valuerArgs": { … },
           "calibration": { "artifact": "sandbox-placeholder", "placeholder": true },
           "keeperBudgetFunded": "10000000" }
  },
  "aux": { "rejectingReceiver_0": "0x…" }  // helper contracts the scenarios deployed
}
```

Large integers are written as decimal strings. A manifest is only written when the script really
broadcasts (or runs inside `forge test`), so a dry run never overwrites it with simulated
addresses. `DeployFactory` refuses to overwrite an existing manifest unless
`ARUNA_MANIFEST_OVERWRITE=true`.

## Scripts

| Script | Purpose |
|---|---|
| `script/Testnet.s.sol:SetupTestnet` | testnet only: mock mWETH/mUSDC, a real Uniswap v3 pool with a configurable initial `ARUNA_TN_SQRT_PRICE_X96`, grown observation cardinality, a small LP position |
| `script/Testnet.s.sol:SeedSwaps` | one manual swap on that pool |
| `script/Deploy.s.sol:DeployFactory` | deployers + factory, writes the manifest |
| `script/Deploy.s.sol:DeployMarket` | calibrated pricer + valuer, `createVault`, optional keeper-budget funding, appends `markets.<n>` |
| `script/Ops.s.sol:Ops` | one entrypoint per lifecycle action (`--sig "<name>()"`): `deposit`, `approveAndBuy`, `cancel`, `collectFees`, `keeperPoke`, `keeperFinalize`, `settlePolicy`, `settleBatch`, `rollTo`, `withdraw`, `claimUnclaimed`, `claimPosition`, `fundKeeperBudget`, `swap`, `mintPosition`, `setRejectIncoming` |
| `script/Scenarios.s.sol:ScenarioSetup` | single-timestamp scenario setup: actors funded, `RejectingReceiver` deployed, LP positions minted |
| `script/Local.s.sol:LocalSetup` | **anvil only**: mock Uniswap stand-ins behind the same call surface |

`forge script` simulates a whole script at **one** timestamp. Anything that has to happen at
different times (pokes, swaps over intervals, buy after `startsAt`, settle after `endsAt`, rolls)
is driven by the external runner. See [`runner/README.md`](../runner/README.md).

## RC runbook (Arbitrum Sepolia)

0. **Freeze the release commit** first. The RC is deployed from it, and the release must match
   its init code hashes.
1. **Pool.** Run `SetupTestnet` with `ARUNA_TN_SQRT_PRICE_X96` set to mirror the ETH price. Keep
   the LP position **small** (`ARUNA_TN_LP_AMOUNT0/1`, default `1e11`) so the position math stays
   inside `uint96`, and so a moderate swap can move the tick.
2. **Factory.** `PROFILE=sandbox GIT_COMMIT=$(git rev-parse HEAD)` → `DeployFactory` with
   tenor `3600`, sample interval `60`, gap `600` (see `.env.example`).
3. **Market.** `DeployMarket`. The first market on a pool creates its accumulator, and the
   factory takes the **baseline poke** in that same transaction. With `ARUNA_ANCHOR=0` the first
   cohort starts `ARUNA_ANCHOR_LEAD` seconds later. Optionally fund the keeper budget with
   `ARUNA_KEEPER_BUDGET_FUNDING`.
4. **Deposit before `startsAt`.** The runner picks a cohort at least `LEAD_SECS` ahead and
   deposits first. Underwriting deposits after `startsAt` are rejected.
5. **Swap sizes.** In the pay scenario, every swap must move the tick by a meaningful amount.
   Calibrate `SWAP_IN` against the pool's real liquidity. With a small LP position, `1e21` raw of
   an 18-decimal token is a large swing. In the no-pay scenario there are no swaps.
6. **Payout parking.** The pay scenario buys one policy through an on-chain
   `RejectingReceiver`, switches it to reject the settlement token, and settles. The payout is
   parked in `unclaimed`. Then it switches back and calls `claimUnclaimed`. **NFT parking** is
   unit-test-only: on the real NFPM, a hook-less `transferFrom` back to the owner cannot fail.
7. Run the scenarios: `runner/run.sh --scenario pay|nopay|refund`. Then run
   `runner/run.sh --keeper-only` as the temporary keeper for a full cycle with no other
   intervention. Commit `deployments/421614/*.json`, `broadcast/*/421614/`, and
   `runner/results/*.json`. The ledger (U10) cites these files.
8. **Release.** `PROFILE=release ARUNA_RC_MANIFEST=deployments/421614/sandbox.json` once the
   ledger is green. Then run `DeployMarket` with the real calibration artifact.

### Key management

- Sign with `--account <keystore>` (`cast wallet import <name> --interactive`) or a hardware
  wallet (`--ledger` / `--trezor`). **Never** put a `PRIVATE_KEY` / `--private-key` value in a
  committed file, a script, or the shell history of a shared machine. The only private keys in
  this repo are the public anvil dev keys, which `runner/anvil-e2e.sh` and `run.sh --anvil` use.
- Use **separate keys** for the RC (sandbox deployer and actors) and the release deployer.
  The release key never signs testnet traffic.
- Use a dedicated RPC endpoint. Treat a keyed RPC URL as a secret: before committing, grep
  `broadcast/**` and anything else you commit or share for the URL or its key.
- `forge` auto-loads `./.env`. Keep it gitignored, and keep it free of keys.
