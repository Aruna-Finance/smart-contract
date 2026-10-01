# Aruna — smart contracts (v2)

Aruna sells realized-variance cover to Uniswap v3 LPs on Arbitrum. Underwriters fund a
per-(pool, tenor) vault; LPs buy cover for a cohort; at cohort end the realized variance
measured on-chain is settled against the strike. Design SSOT:
`context/aruna - desain smart contract.md` (sections cited as `§x.y` in NatSpec).

No admin role, no pause, no proxy: every contract is immutable once deployed.

## Contracts (`src/`)

| Contract | Role |
|---|---|
| `ArunaFactory` | Permissionless factory with no canonical slot: any number of `CoverVault`s per (pool, tenor), one shared `VarianceAccumulator` per (factory, pool) with a baseline sample at creation. Validates tenor set, canonical Uniswap pool, settlement token and keeper bounds; time parameters (tenor set, gap, sample interval) are constructor immutables. |
| `deployers/VaultDeployer` | Holds `CoverVault` creation code so the factory stays under EIP-170 (watch its size: it tracks the vault's initcode). |
| `deployers/AccumulatorDeployer` | Holds `VarianceAccumulator` creation code. |
| `CoverVault` | Underwriter capital, cohort calendar, cover sales, escrow of the LP position NFT, settlement. |
| `VarianceAccumulator` | Samples the pool TWAP and accumulates squared log returns (§3.2). Never blocks a vault action. |
| `FlatVegaPricer` | `IPremiumPricer` — premium from moneyness knots and utilization (§6.3). Deployed outside the factory. |
| `PositionValuer` | `IPositionValuer` — variance notional of an LP position (§8.4). Deployed outside the factory. |
| `libraries/Math` | Explicit-rounding `mulDivUp` / `mulDivDown` helpers. |
| `interfaces/` | Minimal local interfaces (ERC20, NFPM, pool, and the Aruna modules). |

## Tests (`test/`)

- `*.t.sol` — unit tests per contract.
- `CoverVaultInvariants.t.sol` — handler-based invariant suite (§9.1), configured under
  `[invariant]` in `foundry.toml`.
- `mocks/` — NFPM, pool, accumulator, ERC20, pricer and valuer mocks.
- Optional fork tests: `FOUNDRY_PROFILE=fork forge test` with `ARBITRUM_RPC_URL` set. The
  default profile never needs an RPC.

## Scripts (`script/`)

- `Deploy.s.sol` — `DeployFactory` (chain infra) and `DeployMarket` (per-market calibration
  + `createVault`). Inputs come from the environment; see `.env.example`.
- `Testnet.s.sol` — Arbitrum Sepolia setup: mock tokens, a real Uniswap v3 pool, and seed
  swaps.

## Build

```shell
forge build --sizes   # fails if any contract exceeds EIP-170 (24,576 B runtime)
forge test
forge fmt --check
```

Builds are reproducible: solc is pinned to `0.8.26` and the metadata hash / CBOR trailer
are disabled (`bytecode_hash = "none"`, `cbor_metadata = false`), so two clean builds of
the same commit produce identical runtime code and init code hashes. CI
(`.github/workflows/test.yml`) runs the format check, the size gate and the full suite.

## Release evidence (forthcoming)

- `deployments/` — deployment manifest per network (addresses, init code hashes, time and
  calibration parameters). *Added in plan unit U9.*
- `conformance/` — conformance ledger mapping each requirement / acceptance example to its
  proving test and on-chain transaction, plus a checker run in CI. *Added in plan unit U10.*
