# PrimeChain — blockchain layer for *My Prime*

Prime Technologies Limited · EVM gaming chain + Godot 4 tooling.

> **Status: Phase 0 approved 2026-10-24 — Phase 1 in progress.**
> The token, its test suite and CI exist; the OP Stack devnet is written as a pinned runbook but has not been booted (no Docker host in the authoring environment — see [PROGRESS.md](PROGRESS.md)).

---

## Read these in order

| Document | Why |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | **The decision.** OP Stack, why, what it costs, what it cannot do, and the questions only the client can answer (D1–D7). |
| [THREAT_MODEL.md](THREAT_MODEL.md) | STRIDE analysis, the eight named attack classes, risk register, and the controls that become CI gates. |
| [DECISIONS.md](DECISIONS.md) | ADR-001…012. Append-only. Every reversal is a new ADR. |
| [PROGRESS.md](PROGRESS.md) | Phase tracker, verification log, environment limits, resume instructions. |

## The decision in one paragraph

PrimeChain is an **OP Stack** chain: `op-geth` for execution, `op-node` for derivation, batcher and proposer posting to Ethereum, and one company-operated sequencer for the permissioned phase. It is EVM-equivalent, so Godot talks to it with ordinary `eth_*` JSON-RPC. Players never pay gas — an ERC-4337 paymaster with on-chain caps sponsors their actions. The treasury releases Prime on an enforceable on-chain schedule, and Prime has **no mint function at all**, so "no hidden admin mint" is a property of the bytecode rather than a promise. Phones verify signed checkpoints and Merkle proofs; they are not light clients in the trustless sense, and the docs say so.

Rejected, with reasons recorded: a Geth/Clique PoA fork (best requirement fit, worst ownership cost), Cosmos SDK + Cosmos EVM (best consensus fit, EVM module still pre-v1 pending audit).

## Planned repository layout (Phases 1–6)

```
contracts/            Foundry project — Prime, Treasury, RewardDistributor,
                      ItemRegistry, Crafting, Marketplace, Storage, FeeSink, Paymaster
  src/  test/  script/  invariant/
infra/
  devnet/             docker-compose: L1 + L2 sequencer + 2 replicas + Blockscout + monitoring
  testnet/            deployment + runbooks
  monitoring/         Prometheus rules, Grafana dashboards, Alertmanager
gateway/              Node/TS backend: sessions, anti-abuse, sponsorship policy, reward attestation
godot/                GDScript SDK + C++ GDExtension (secp256k1, keccak) + demo scene
ops/                  key-rotation, backup, upgrade, incident-response runbooks
.github/workflows/    contracts (build/test/coverage/slither), sdk, infra lint, secret scan
```

## Working agreements

1. **No secrets in the repo.** Ever. `gitleaks` runs pre-commit and in CI.
2. **No version ranges.** Every dependency is pinned to an exact release and recorded in ARCHITECTURE §15.
3. **Green means CI, not a local run.** ADR-012.
4. **Every privileged action** goes through Safe (4/7) + Timelock (48h). No EOA admin in production.
5. **No mainnet without an independent audit.** See `AUDIT_READINESS.md` (Phase 6).
6. **If a requirement is not achievable as written, it is said out loud** and an alternative is proposed — see ARCHITECTURE §6.1 (native token vs ERC-20), §6.3 (fee sink vs OP Stack burn), §10 (phones cannot trustlessly verify), §5.1 ("PoA" means one sequencer).

## Not in this repository

Wallet private keys, deployment keys, RPC provider keys, KMS credentials, or any production configuration containing secrets.
