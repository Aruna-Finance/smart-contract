# runner

External scenario runner for the Aruna v2 release candidate (plan U9). `forge script`
simulates a whole script at one timestamp, so this bash + `cast` loop drives every sequence
that spans time. It runs one `script/Ops.s.sol` entrypoint per step, with real delays between
steps. During Phase 2 it also acts as the temporary keeper.

Requirements: `forge`, `cast`, `jq`, bash 3.2+.

## Files

- `run.sh` is the runner. It covers the scenarios and `--keeper-only`.
- `lib.sh` holds the helpers: RPC retries, time handling, the results file, and the `ops` step
  wrapper.
- `anvil-e2e.sh` is a local rehearsal. It starts a throwaway anvil, runs
  `script/Local.s.sol` (mock Uniswap) and `DeployFactory` + `DeployMarket` (sandbox profile),
  then runs the scenarios with `--anvil`.
- `results/` holds the committed RC results. `results/local/` holds anvil results and is
  gitignored.

## Usage

```bash
# local, about one minute: full sandbox cycle with time acceleration
runner/anvil-e2e.sh                        # default scenarios: pay nopay refund
runner/anvil-e2e.sh pay keeper             # 'keeper' = --keeper-only, 3 pokes

# live RC (Arbitrum Sepolia); signers are keystores or hardware wallets
export RPC_URL=<dedicated rpc>
export SIGNER_LP="--account rc-lp" SIGNER_UW="--account rc-uw1" SIGNER_UW2="--account rc-uw2"
export SIGNER_KEEPER="--account rc-keeper"
runner/run.sh --scenario pay    --manifest deployments/421614/sandbox.json
runner/run.sh --scenario nopay  --manifest deployments/421614/sandbox.json
runner/run.sh --scenario refund --manifest deployments/421614/sandbox.json
runner/run.sh --keeper-only     --manifest deployments/421614/sandbox.json [--until <unix>] [--max-pokes N]
```

Flags: `--scenario`, `--keeper-only`, `--anvil`, `--manifest`, `--market N`, `--rpc-url`,
`--until`, `--max-pokes`, `--results-dir`. The header of `run.sh` lists every environment knob:
deposit sizes, `SWAP_IN`, `STRIKE`, `LEAD_SECS`, `POLL_SECS`, `RETRIES`, `RETRY_BACKOFF`,
`RECEIPT_WAIT`, `KEEPER_MAX_FAILS`, `KEEPER_BACKOFF`, `KEEPER_BACKOFF_MAX`, `ANVIL_STEP_DELAY`, and the others.

### Time

- **Live:** the chain clock is the authority. `wait_until` polls the head every `POLL_SECS`
  until the target timestamp, so a scenario takes about one tenor plus the gap in real time.
- **`--anvil`:** time is accelerated with `evm_increaseTime` + `evm_mine`. Set
  `ANVIL_STEP_DELAY=<s>` to also sleep for real after each jump.

### Scenarios

Each scenario uses one cohort `n`: the first cohort that starts at least `LEAD_SECS` from now.

| Scenario | Steps |
|---|---|
| `pay` | `ScenarioSetup` (`RejectingReceiver`, LP positions, funded actors) → 3 deposits + keeper-budget donation before `startsAt` → 3 buys (LP ×2, receiver) → keeper poke + large alternating swap every interval, `collectFees` at poke 2, `cancel` at poke 3 → after `endsAt`: `keeperFinalize`, `settlePolicy` (receiver's payout **parked**), `settleBatch`, `claimUnclaimed`, `withdraw`, `rollTo n+1` in the gap → after `startsAt(n+1)`: late `rollTo n+2` |
| `nopay` | mint position, deposit, buy, pokes with no swaps, finalize, `settleBatch` (measured, pays 0), withdraw |
| `refund` | deposit, buy, then the keeper stops, `settlePolicy` refunds the premium, withdraw |
| `--keeper-only` | poke every interval, then `keeperFinalize` + `settleBatch` for every cohort that is due |

The runner asserts the expected outcome of each scenario (parked payout, policy statuses,
cohort SETTLED) and exits non-zero if one fails.

## Results file

`runner/results/<scenario>-<UTC timestamp>.json` contains one entry per transaction:

```jsonc
{ "scenario": "pay", "chainId": 421614, "mode": "live", "manifest": "…", "vault": "0x…",
  "gitCommit": "…", "startedAt": "…", "finishedAt": "…", "status": "complete",
  "steps": [ { "scenario": "pay", "step": "deposit-uw", "cohort": 3, "action": "deposit(uint32,uint128)",
               "txHash": "0x…", "block": 123, "address": "0x…", "from": "0x…", "status": 1 } ] }
```

`status` is `running`, `complete`, `interrupted`, or `failed`. A run exits non-zero if any step has no hash or
no successful receipt. The conformance ledger (U10) cites these hashes.

## Reliability

**What counts as a transport error.** `is_rpc_error` (in `lib.sh`) matches only anchored
patterns: an HTTP status 429/502/503/504 must follow an `HTTP`/`status`/`code` label or be
followed by its reason phrase (`503 Service Unavailable`) and must not touch another digit, so an
address, amount or revert payload that merely contains `429` is never treated as an RPC error.
The other patterns are explicit strings: connection refused/reset/closed, `error sending
request`, `operation timed out`/`request timed out`, rate limits (`too many requests`), `header
not found`, and similar. Signer-side errors are classified separately: nonce errors (`nonce too
low/high`, `already known`), underpriced sends, and `insufficient funds`.

**What is retried.**

- Read-only calls (`cast call`, chain time, nonces) are retried up to `RETRIES` times with a
  linear backoff (`RETRY_BACKOFF` × attempt).
- Idempotent keeper ops (`keeperPoke`, `keeperFinalize`, `settleBatch`, `settlePolicy`,
  `setRejectIncoming`) are re-sent after a transport, nonce, or underpriced error. A second copy
  is a no-op or toggles the same flag. The runner still checks first whether the failed attempt
  landed, so a landed tx is recorded rather than sent again.
- Everything else changes state in a way that is not idempotent: `deposit`, `fundKeeperBudget`,
  `approveAndBuy`, `rollTo`, `withdraw`, `cancel`, `claim*`, `collectFees`, `swap`, and
  `mintPosition`. These are **never blindly re-broadcast**. Before each attempt the runner reads
  the signer's pending nonce. After a transport, nonce, or underpriced error it reads the tx
  hashes that forge wrote to `broadcast/Ops.s.sol/<chainId>/<fn>-latest.json` for this attempt,
  then waits up to `RECEIPT_WAIT` seconds for each receipt with `cast receipt`.
  - All mined with status 1: the step succeeded. It is recorded from a copy of the broadcast file
    with the fetched receipts and is not sent again.
  - Any mined with status 0: the step failed as a revert. It is not resent.
  - No hash recorded and the pending nonce is unchanged: nothing was sent, so the step is resent.
  - Anything else (a hash with no receipt yet, a nonce that moved without a hash): the run stops
    with the broadcast file path. Reconcile by hand before rerunning.
- Reverts and insufficient funds are never retried.

**Keeper loop (`--keeper-only`).** A failed poke, finalize, or settle in one tick is logged and
the loop continues. If a scheduling read (`lastSampleAt`, `currentCohortId`, `statusOf`, chain
time) comes back empty, the tick is skipped with a warning. The runner never schedules from a
blank value. After a failed tick the loop backs off exponentially (`KEEPER_BACKOFF` doubling, capped
at `KEEPER_BACKOFF_MAX`). It exits non-zero after `KEEPER_MAX_FAILS` consecutive failed ticks, and
at once on insufficient funds.

**Exit.** An exit trap always finalizes the results file. The status is `complete` on exit 0,
`interrupted` on SIGINT/SIGTERM (the normal way to stop `--keeper-only`), and `failed` otherwise.
Each step's forge log stays in a temp dir unless the run succeeds, and the path is printed on
failure.

## Keys

Live mode requires explicit `SIGNER_*` wallet arguments (`--account`, `--ledger`). The only
built-in keys are the public anvil dev keys, which are used only with `--anvil`. Never commit a
private key or a keyed RPC URL. See `deployments/README.md`.
