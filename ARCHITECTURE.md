# PrimeChain — Architecture Decision & System Architecture

| | |
|---|---|
| **Document** | ARCHITECTURE.md |
| **Phase** | 0 — Architecture decision & threat model |
| **Status** | **APPROVED 2026-10-24** with recommended defaults — Phase 1 in progress |
| **Author** | Blockchain engineering (contractor), for Prime Technologies Limited |
| **Date** | 2026-10-24 |
| **Companion docs** | [THREAT_MODEL.md](THREAT_MODEL.md) · [DECISIONS.md](DECISIONS.md) · [PROGRESS.md](PROGRESS.md) |
| **Version facts verified** | 2026-10-24 against primary sources (see §15) |

---

## 0. TL;DR — the recommendation

**Build PrimeChain on the OP Stack** (op-geth execution client + op-node derivation + batcher + proposer), settling to Ethereum, with a **company-operated sequencer** for the first phase of the chain's life.

Three points drive this:

1. **The reference design for "Ronin-style" has changed.** Ronin — our stated inspiration — now documents its consensus as **OP Stack**, with ~2s blocks and L1 finality ([Ronin network docs](https://docs.roninchain.com/developers/network/), fetched 2026-10-24). Taking "heavy inspiration from Ronin" in 2026 means taking OP Stack, not a bespoke Geth/PoA fork. The chain Ronin used to be (a Geth fork with Proof of Authority) is precisely the option I recommend **against**, because it is the option that quietly costs the most to own.
2. **It satisfies every hard requirement** — EVM equivalence, standard `eth_*` JSON-RPC, low fees, ERC-4337 sponsorship, Blockscout, Docker devnet — with components that other people already operate at scale.
3. **It makes the "PoA now, decentralise later" promise honest.** A single company sequencer *is* a permissioned validator in practice, and the path forward is fault proofs, multi-prover, and upstream sequencer decentralisation — not us inventing a consensus protocol.

Three requirements contain a real conflict that I will not paper over. They need your decision **before genesis** (§13): the literal gas token, the P2P transfer tax, and what "3 validators" is allowed to mean on this stack.

---

## 1. What the requirements actually force

| # | Requirement (from brief) | Architectural consequence |
|---|---|---|
| R1 | EVM-compatible, standard `eth_*` JSON-RPC | Must be an **EVM-equivalent** client, not merely "EVM-ish". Rules out most custom appchains. |
| R2 | PoA now, documented path to PoS and more validators | Must not require us to *write* consensus. Must have a credible decentralisation path that is **not** "someday we fork". |
| R3 | Sponsored gas, rate-limited, abuse-protected | Needs ERC-4337 EntryPoint + a **policy-enforcing paymaster**, plus a bundler we operate. |
| R4 | Data-only game state, assets off-chain | Contract design constraint; no architecture impact. |
| R5 | Six contract families | Standard Solidity; no architecture impact. |
| R6 | Phones are light clients/verifiers, **not** validators | Needs an explicit verification tier model, and an honest statement of what a phone cannot prove. |
| R7 | Ordinary transfers + public API for non-game apps | Chain must be a normal EVM chain; no private/enterprise quirks. |
| E1 | Prime fixed supply 2B, minted once, no admin mint | Token must have **no mint function at all** (stronger than "renounced"). |
| E2 | Treasury releases on a published, enforceable schedule | On-chain emission caps + per-account rate limits, not policy promises. |
| E3 | Per-tx fee to a sink address | **Conflicts** with how OP Stack handles gas fees (§6.3). Decision required. |
| E4 | No promises of returns to players | Product/legal constraint on contract design and marketing copy. |
| Ops | Devnet, testnet, explorer, monitoring, CI, runbooks | Wants a stack with published ops guides — a strong discriminator. |

The decisive forces are **time-to-ship**, **ownership cost**, and **how much novel consensus code we are willing to own forever**. Everything else is commodity.

---

## 2. Options evaluated

### (a) OP Stack L2 / gaming rollup — *recommended*

Execution is `op-geth` (a Geth fork maintained by OP Labs, so EVM-equivalence is inherited), derivation/consensus-view is `op-node`, plus `op-batcher` (posts transaction data to L1) and `op-proposer` (posts output roots). Settlement and data availability are Ethereum; the sequencer is a single company-run node today.

- **Security maturity:** highest of the three. Shared codebase with OP Mainnet and Base; dedicated audit reports and a bug bounty are published in the OP Stack docs ([Audit reports](https://docs.optimism.io/op-stack/security/audit-reports)); releases are frequent and security-driven (e.g. `op-node v1.19.11`, published 2026-10-22, was a *strongly recommended security release*).
- **Godot / JSON-RPC:** perfect. It is a normal EVM chain; every `eth_*` call, `eth_getProof`, `eth_subscribe` and standard tool behaves. No custom SDK required for reads.
- **Cost to run:** mid. Needs an L1 RPC endpoint, L2 data posting, and ~6–8 services. Data posting is the variable cost.
- **Validator requirements:** low, because there are no validators to run in the PoA sense — one sequencer, optionally a proposer/challenger, plus verifiers for RPC.
- **Time to ship:** mid. Tooling exists (`op-deployer`), but it is a five-service distributed system, not one binary.

**Main weakness:** R2 and E3 do not map 1:1 onto OP Stack vocabulary. "Validators" become sequencer + provers; "fee to sink address" collides with EIP-1559 base-fee burn. Both are addressable — but only by being explicit (§5.2, §6.3), not by hoping nobody notices.

### (b) Geth (or Reth) fork with Clique PoA — *rejected*

This is what Ronin originally was, and it matches the brief almost word for word: own native gas token, 3 signers, fees to a company address, instant finality, cheap to run.

Facts checked: Geth still carries `consensus/clique` on `master` (verified via the GitHub contents API on 2026-10-24), so a Clique-based PoA chain is technically available. Reth does **not** offer a PoA engine (it ships Ethereum PoS and OP Stack consensus), so option (b) realistically means a **geth fork**.

- **Security maturity:** the *engine* is mature; our *fork* is not. Every upstream Geth security release becomes our emergency patch. This is the single largest hidden cost in the whole project.
- **Godot / JSON-RPC:** excellent.
- **Cost to run:** lowest — three VMs.
- **Validator requirements:** lowest — three signer keys.
- **Time to ship:** slow. Fork + rebase discipline + custom genesis + no standard appchain tooling for explorer/indexer/monitoring.
- **Path to PoS:** we would have to design and audit it ourselves. Clique is deprecated for public networks and has no finality guarantee (reorgs are possible), which directly harms a marketplace.

**Verdict:** the best *requirement fit*, the worst *total cost of ownership* for a game studio. Rejected on §2's weighting, and I want that trade recorded rather than hidden.

### (c) Cosmos SDK + Cosmos EVM — *rejected, with regret*

CometBFT gives BFT consensus with a permissioned validator set and a built-in staking path — a near-perfect fit for R2 — and the EVM module exposes Ethereum JSON-RPC.

The disqualifier is maturity of the EVM layer, in the project's own words:

> "This repo is undergoing changes while the code is being audited and tested. For the time being we will be making v0.x releases… Cosmos Labs will only mark the Cosmos EVM repository as stable with a v1 release after the audit…"
> — [cosmos/evm README](https://github.com/cosmos/evm), fetched 2026-10-24

For a production game economy, "pre-v1 while being audited" is a schedule risk we cannot absorb, and the dual-address (bech32 + `0x`) model plus Cosmos-specific gas semantics are a permanent tax on every Godot developer and every third-party integrator.

### Also considered, and why excluded

| Option | Why not |
|---|---|
| **Reth + custom consensus** | No PoA engine; writing one contradicts "do not write consensus". |
| **Hyperledger Besu (QBFT)** | Mature permissioned BFT with JSON-RPC, but no credible path to a public PoS/permissionless validator set, and a thinner gaming ecosystem. |
| **Arbitrum Orbit** | Genuinely strong for games (AnyTrust DA, native account abstraction), but outside the three requested options, and adds a DAC trust assumption plus licensing/governance coupling. Worth a follow-up if OP Stack's L1 data costs disappoint on testnet. |
| **Polygon CDK / zkEVM** | ZK-proving operational burden for a 3-validator game chain is unjustified. |

### Scoring

Weights reflect a game studio shipping in 2026, not a research lab.

| Criterion | Weight | (a) OP Stack | (b) Geth fork | (c) Cosmos EVM |
|---|---|---|---|---|
| Security maturity & audit surface | 25% | 5 | 4 | 4 |
| Ecosystem, tooling, JSON-RPC fidelity | 20% | 5 | 5 | 3 |
| Requirement fit (PoA→decentr., token, fees) | 20% | 3 | 5 | 5 |
| Time to ship | 15% | 3 | 1 | 2 |
| Cost to run | 10% | 3 | 5 | 4 |
| Ops & maintenance burden | 10% | 4 | 1 | 3 |
| **Weighted total** | | **4.00** | **3.75** | **3.60** |

**Sensitivity (stated honestly):** if we double the weight of "requirement fit" and halve "time to ship", option (b) wins. That is exactly the trade you are approving. If Prime Technologies has a dedicated protocol team willing to own a Geth fork for years, (b) is defensible. If the team is a game studio, it is a trap.

---

## 3. Decision

**Adopt OP Stack.** Concretely:

- **Execution:** `op-geth` (pinned release, never `latest`).
- **Derivation:** `op-node` (pinned; e.g. `v1.19.11` as of 2026-10-24).
- **Data availability:** Ethereum L2 blobs (EIP-4844), not Alt-DA, at launch.
- **Settlement:** Ethereum; canonical OP Standard Bridge only at launch.
- **Sequencing:** one company sequencer, in a hardened, monitored environment, with a documented hot-standby and key-rotation procedure.
- **Fault proofs:** enabled as soon as the chain is stable, initially with a permissioned challenger, then permissionless.
- **Explorer:** Blockscout (self-hosted).
- **Indexing:** a self-hosted indexer (Ponder or equivalent) plus Blockscout's API; no dependency on a hosted subgraph for gameplay reads.

We do **not** fork consensus, do **not** write a VM, and do **not** operate a bridge of our own design.

---

## 4. Target architecture

```
                        ┌─────────────────────────── Ethereum (L1) ───────────────────────────┐
                        │  OptimismPortal · SystemConfig · L1StandardBridge · DisputeGame    │
                        │  (owned by Safe 4/7 + 48h Timelock)                                 │
                        └───────▲──────────────▲───────────────────▲──────────────────────────┘
              batch data / blobs│    output roots  │        deposits/withdrawals│
                        ┌───────┴──────┐  ┌──────┴───────┐   ┌───────┴────────┐
                        │  op-batcher  │  │ op-proposer  │   │  op-node (L1   │
                        │  (hot key)   │  │  (hot key)   │   │  view/deriv.)  │
                        └───────┬──────┘  └──────┬───────┘   └───────┬────────┘
                                └────────────────┼───────────────────┘
                                                 ▼
   ┌──────────────────────────── PrimeChain (L2, chainId TBD) ─────────────────────────────┐
   │  op-geth SEQUENCER  ──> op-geth REPLICA ×2 (RPC HA, independent verification)          │
   │        │                                                                              │
   │        ├── System contracts: Prime (ERC-20, fixed 2B) · Treasury · RewardDistributor   │
   │        │                    ItemRegistry (ERC-1155) · Crafting · Marketplace ·        │
   │        │                    Storage · FeeSink · Paymaster (ERC-4337)                  │
   │        └── EntryPoint v0.8 (canonical deployment, pinned) + bundler (self-hosted)      │
   └───────────────▲──────────────────────────────▲───────────────────────▲────────────────┘
                   │ JSON-RPC (eth_*, WSS)        │ JSON-RPC              │ JSON-RPC
        ┌──────────┴──────────┐        ┌──────────┴──────────┐   ┌────────┴─────────┐
        │  Godot 4.7 client   │        │  Game backend       │   │ Blockscout,       │
        │  GDScript SDK +     │        │  gateway (sessions, │   │ indexer, Grafana, │
        │  native crypto ext. │        │  anti-abuse, policy)│   │ public API        │
        └─────────────────────┘        └─────────────────────┘   └──────────────────┘
```

**Trust boundaries (full STRIDE analysis in [THREAT_MODEL.md](THREAT_MODEL.md)):**

1. Client device → gateway: hostile network, untrusted input, rooted devices possible.
2. Gateway → chain: gateway holds paymaster/relayer authority; must be capped on-chain.
3. L2 → L1: bridge and dispute game; the largest single-value attack surface.
4. Ops → all: Safe + Timelock is the only path to privileged action.

---

## 5. Consensus, validation and the honest meaning of "PoA"

### 5.1 What actually orders blocks

One sequencer builds L2 blocks. It is operated by Prime Technologies. That is functionally **permissioned block production** — the property the brief calls PoA — and I will describe it that way publicly rather than claiming a validator set that does not exist.

### 5.2 The decentralisation path (documented, not aspirational)

| Stage | Mechanism | Trust assumption | Trigger |
|---|---|---|---|
| **S0 (launch)** | Single sequencer; L1 settlement; canonical bridge; permissioned challenger | Company must not censor or reorder maliciously; L1 guarantees funds | Mainnet |
| **S1** | Open, permissionless fault proofs; multiple independent provers | No correctness trust; only liveness/censorship trust in sequencer | ≤3 months post-launch |
| **S2** | Sequencer hot-standby + escrowed rotation; published inclusion policy & uptime SLO | Reduced downtime risk; still permissioned | ≤6 months |
| **S3** | Upstream OP Stack sequencer decentralisation (shared sequencing / leader election) as it matures | Trust-minimised ordering | When upstream ships it |
| **S4 (optional)** | Migrate to a sovereign PoS chain (Cosmos EVM or a PoS Geth fork) if Ethereum L1 economics or governance become unacceptable | Full validator set | Only with a new architecture decision |

**S4 exists on purpose.** If your long-term goal is a chain with its own validator economics, OP Stack is the right *first* chain and possibly the wrong *forever* chain. I would rather write that down now than discover it in year three.

### 5.3 Why this is not "PoA theatre"

A 3-signer Clique chain would *look* more decentralised than one sequencer. It would not be. Three keys held by one company in one cloud account are one trust domain with three failure modes. The OP Stack model is honest: one operator, but every block is settled to Ethereum, and correctness is eventually enforced by fault proofs rather than by counting signers.

---

## 6. Token, fees and the economy

### 6.1 The requirement conflict (must be resolved by you)

The brief says Prime is the **native/base token**, *and* says the contracts include a **Prime ERC-20 (fixed supply)**. On OP Stack, a chain has exactly one native gas asset, and by default it is ETH. There are two coherent readings:

| | **Model A — Prime is an ERC-20; gas is ETH; all gas is sponsored** *(recommended)* | **Model B — Prime is the literal gas token (OP Stack "Custom Gas Token")** |
|---|---|---|
| How supply is created | One-time deployment, fixed at construction, **no mint function exists** | L1 ERC-20 minted once, bridged to L2 as the gas asset |
| What players hold | Prime only (gas invisible, paid by company) | Prime only (gas is Prime) |
| Company gas cost | Company buys ETH | Company spends Prime it already owns |
| Tooling risk | None — this is every OP chain | Feature is newer; touches bridging, fee markets, indexers, wallets |
| Reversibility | N/A | One-way protocol choice; must be decided **before genesis** |
| Fee "sink" | Base fee burned in ETH; game tax goes to FeeSink contract | Base fee burned in Prime (deflationary) |
| Verdict | **Recommended** | Viable, but a Phase-1 spike must prove Blockscout/bundler/paymaster compatibility |

I recommend **Model A**. It gives players exactly the experience the brief wants (they never touch gas), keeps the chain on the most battle-tested configuration, and keeps Prime's supply story clean: a token with no mint function is a stronger promise than a renounced `mint` role.

If you want Prime to be the literal gas asset, say so now — Model B must be locked in before the mainnet genesis block, and it changes Phase 1's acceptance criteria.

### 6.2 Emission discipline (enforceable, not a promise)

`RewardDistributor` holds no discretionary power beyond limits set on-chain (approved values in [DECISIONS.md](DECISIONS.md) D4):

- `maxPerEpoch` — **500,000 PRIME/day**, hard cap, no rollover.
- `MAX_EPOCH_CAP` — **2,000,000 PRIME**, `immutable`; no role (including the Timelock) can set `maxPerEpoch` above it, so the 1B ceiling cannot be drained in fewer than 500 epochs.
- `maxPerAccountPerEpoch` — **200 PRIME/account/day**; allocations are computed server-side and the epoch merkle root is sealed after the cap is applied, so there is no claim-time race.
- `epochDuration` — **1 day** (86,400 s), sealed epochs.
- `totalReleased ≤ 1,000,000,000` — lifetime emissions ceiling; the other 1,000,000,000 stays in treasury as an unreleased reserve.
- Unused epoch capacity **does not roll over** (prevents a burst that looks like a pump).
- Merkle-root claims for batch rewards (cheap), plus a direct-claim path with EIP-712 signatures, per-account nonce and expiry.

The treasury can be late. It cannot be generous beyond the cap. That distinction is the whole point.

### 6.3 The "per-transaction tax to a sink" problem

OP Stack burns the L2 base fee. Priority fees flow to a protocol fee vault, not to an arbitrary game address. Routing *gas* to a game sink would require forking fee handling — rejected (see §2b).

So the tax must live at the application layer. Three options:

| Option | Mechanism | Effect on players | Recommendation |
|---|---|---|---|
| **T1 Game-action fee** | Crafting, marketplace, storage, naming actions charge a fee routed 100% to `FeeSink` | Transparent, expected, easy to tune per system | **Recommended** |
| **T2 Transfer tax** | ERC-20 takes a cut on every `transfer`/`transferFrom` | Breaks "transfer freely"; breaks DEX routing, escrows and third-party integrations; a recurring audit finding | Off by default; enable only for specific game token IDs, never for Prime |
| **T3 Burn** | Base fee burn (already happening in ETH) | Deflationary, invisible | Free, already on |

`FeeSink` is a contract, not an EOA: it can forward to the treasury, fund tournaments, or be burned by policy — all visible on-chain.

---

## 7. Sponsored gas design (ERC-4337)

- **EntryPoint:** v0.8 (ERC-4337 is now a **Final** ERC; the spec requires `PackedUserOperation`, EIP-712 domain binding to `chainId` + `EntryPoint`, and supports `paymasterSignature`). Exact canonical address will be pinned from the official eth-infinitism deployment manifest in Phase 3 — I will not hard-code an address from memory.
- **Accounts:** OpenZeppelin v5.7.0 account abstractions (this release ships audited `Paymaster`, `PaymasterSigner`, `PaymasterERC20*`, `ERC4337Utils` with the `draft-` prefix dropped — verified from the v5.7.0 release notes).
- **Policy in two layers, so a compromised gateway cannot drain the treasury:**
  1. **On-chain hard limits** (in the paymaster, non-bypassable): target contract + method-selector allowlist, per-account daily sponsored-op cap, per-account gas ceiling, global daily budget ceiling, pause switch behind Safe+Timelock.
  2. **Off-chain soft policy** (gateway, cheap to change): session validity, device attestation, gameplay heuristics, per-IP/ASN rates. Expressed as a short-lived EIP-712 sponsorship authorization with nonce + expiry, bound to `chainId`, paymaster address and a hash of the intended call.
- **Budget:** a dedicated `SponsorBudget` accounting contract; the paymaster's EntryPoint deposit is topped up from it, and reported daily against the ad/sponsor budget.
- **Abuse controls:** per-account and per-device caps, proof-of-play attestations for reward-bearing actions, and a denylist of contract targets that are never sponsored (approvals to unknown spenders, transfers to fresh addresses above a value threshold).

---

## 8. On-chain data model

Strictly data and hashes. No models, textures, audio or bundles.

| Contract | Stores | Explicitly does **not** store |
|---|---|---|
| `Prime` (ERC-20) | balances, total supply (immutable) | any admin/mint hook |
| `Treasury` | Safe ownership, release policy refs | player data |
| `RewardDistributor` | epoch accounting, merkle roots, claim nonces | PII |
| `ItemRegistry` (ERC-1155) | `itemTypeId → {contentHash (keccak256), metadataURI, supplyCap, minted}` | 3D assets |
| `Crafting` | recipe id → input/output hashes, fees | recipes in plaintext |
| `Marketplace` | listings, offers, escrow, fee bps | prices history (indexer's job) |
| `Storage` | per-account vault slots, lock reasons | inventory metadata |
| `FeeSink` | received fees, policy | — |
| `Paymaster` | allowlist, caps, usage counters | user identity |

`contentHash` is `keccak256` over a canonical asset-bundle manifest, so a client can verify a downloaded model against the chain. The URI is mutable only by Timelock and always accompanied by an `ItemContentUpdated` event, so a silent bait-and-switch is impossible.

---

## 9. Godot 4 client architecture

**Verified baseline:** Godot **4.7.2** (stable, 2026-08-18). C# is supported on desktop and mobile only. Nethereum is at **7.0.0** (`net8.0`/`net9.0`/`net10.0`, AOT-compatible).

Godot has no built-in secp256k1 or keccak-256. This is the one place where custom native code is unavoidable, so it must be the *most* boring code in the project:

| Approach | Assessment |
|---|---|
| **GDExtension (C++, godot-cpp) linking libsecp256k1 + a vendored keccak-256** | **Recommended.** One small library, no managed runtime, works on Android/iOS/desktop, fast enough for low-end phones. Pin godot-cpp to the branch matching Godot 4.7.x and libsecp256k1 to a tagged release; record both in `DECISIONS.md`. |
| C# + Nethereum 7.0.0 | Good developer ergonomics and a real, maintained library — but requires the .NET build of Godot, larger binaries, and excludes web export. Recommended only if the team is already .NET-first. |
| Pure GDScript | Rejected. Constant-time secp256k1 in an interpreted language is not credible, and the performance on a Note 8 would be unacceptable. |

**Key storage (mobile) — the uncomfortable truth:** Android Keystore and iOS Secure Enclave do **not** support secp256k1; they support P-256. So a secp256k1 key cannot live inside the secure element. The honest design is:

- **v1 (ship):** generate secp256k1 in the native extension; encrypt at rest with an AES key that *is* hardware-backed (Keystore/Secure Enclave); require device unlock; never log or serialise plaintext; support export/import via a 12/24-word BIP-39 phrase shown once.
- **v2 (optional, better):** a smart account whose signer is a **P-256 passkey**, verified on-chain by a WebAuthn verifier (OpenZeppelin 5.7 ships `ERC7913WebAuthnVerifier` and `MultiSignerERC7913`). This gets hardware-backed signing, but adds contract and client complexity — a Phase 4 decision, not a launch blocker.

**Gateway:** the game *never* holds paymaster or company keys. The client talks to a thin backend (TLS, HSTS, pinned certs optional) that owns sessions, anti-abuse, sponsorship signing and reward attestations. Keys live in KMS/HSM, never in the client, never in the repo.

---

## 10. Phones as verifiers — what is actually possible

Requirement R6 is achievable only in a weaker sense than "light client", and the gap must be stated in the product, not just the docs.

| Tier | What the phone does | Trust assumption | Cost on a Note 8 |
|---|---|---|---|
| T0 | Trusts one RPC | Operator is honest | ~0 |
| T1 | Queries N independent RPCs, requires matching block hash + verifies `eth_getProof` Merkle proofs for balances/items against a pinned state root | ≥1 honest RPC, and the root is authentic | ~10–50 ms/proof |
| T2 | **Checkpoint attestations:** verifies an M-of-N committee signature over `(blockNumber, blockHash, stateRoot)`, then T1 proofs against that root | Committee is not colluding; no full consensus verification | ~5 ms |
| T3 | Full OP derivation (op-node on device) | Trustless | **Not feasible** on target hardware |
| T4 | Succinct proof of derivation (zk) | Trustless | Not available in 2026 for this use case |

**Recommendation: T2 + T1.** A 2-of-3 checkpoint signature from independently operated keys is cheap, verifiable in a few milliseconds, and materially better than trusting one RPC. Be explicit in the UI and the docs that this is *attestation*, not trustless verification. T3 stays off the table for phones; it is what a desktop verifier or the gateway can do if needed.

---

## 11. Operations, cost and scale

**Services at mainnet:** 1 sequencer (`op-geth`), 2 replicas, 1 `op-node` (+1 HA), 1 batcher, 1 proposer, 1 L1 RPC (self-hosted or provider), Blockscout + Postgres, Prometheus/Grafana/Alertmanager, indexer, gateway (2+), bundler.

**Cost model (formula, not fake precision):**

```
monthly_cost ≈ compute (6–8 VMs) + L1 RPC + DA_cost + monitoring/storage
DA_cost/day  ≈ bytes_posted_per_day × L1_blob_or_calldata_price
```

At gaming volumes the L1 data cost dominates and is the one number that must be measured on testnet (Phase 5) before mainnet. That measurement is a **go/no-go gate**, not a formality.

**Performance targets:** 2s blocks (OP Stack default; Ronin documents ~2s), sub-second preconfirmations where the upstream feature is available, gas limit tuned on testnet. Target p95 confirmation for a player action ≤ 2 blocks.

---

## 12. Delivery plan and acceptance criteria

| Phase | Deliverable | Acceptance criteria (how it is proven) |
|---|---|---|
| **0** | This document, threat model, ADR log | Your written approval |
| **1** | Docker Compose devnet (L1 + L2 + 3 L2 nodes), Prime token, genesis, deploy scripts | Chain starts from clean clone; `eth_chainId`/`eth_blockNumber` correct; token invariants pass |
| **2** | Item registry, crafting, marketplace, storage, fee sink | 100% branch coverage on treasury/token; Foundry invariant + fuzz suites green; Slither clean or triaged |
| **3** | Paymaster + bundler + gateway + rate limits | Drain attempts in a red-team test suite all fail; on-chain caps hold with gateway assumed compromised |
| **4** | Godot SDK (GDScript + native ext.), demo scene, key storage | Demo reads balance and sends a sponsored tx on a real Android device (Note 8 class) |
| **5** | Sepolia testnet, explorer, monitoring, runbooks | Public testnet URL, Grafana dashboards live, alert fires on a drilled failure |
| **6** | Hardening, audit readiness | `AUDIT_READINESS.md` complete; third-party audit booked |

Estimates (engineer-weeks, one senior engineer + part-time reviewer): P1 3, P2 4, P3 3, P4 4, P5 3, P6 4, plus 4–8 weeks of external audit. **Mainnet: ~5–6 months from approval, audit included.** I will not compress this by skipping verification.

---

## 13. Decisions I need from you (blocking)

| # | Question | My recommendation | Deadline |
|---|---|---|---|
| **D1** | Prime as literal gas token (Model B) or ERC-20 + sponsored ETH gas (Model A)? | **Model A** | Before Phase 1 ends |
| **D2** | Per-transaction tax on plain P2P transfers? | **No** — tax game actions (T1) | Before Phase 2 |
| **D3** | Is "3 validators" acceptable as "1 sequencer + 2 verifier replicas"? | **Yes**, with §5.2 published | Before Phase 1 |
| **D4** | Emission numbers: daily cap, per-account cap, epoch length | Needs your economy team | Before Phase 2 |
| **D5** | Godot crypto: GDExtension (C++) or C#/Nethereum? | **GDExtension** | Before Phase 4 |
| **D6** | Who signs for the Safe (4/7) and where do signer keys live? | Hardware wallets, geographically split | Before Phase 5 |
| **D7** | Audit budget & firm selection | Book in Phase 5 | Before mainnet |

**Explicit non-goal:** *no mainnet launch without an independent third-party audit of all contracts and the deployment procedure.* That will be written into `AUDIT_READINESS.md` (Phase 6) as a hard gate, not a recommendation.

---

## 14. What would make this decision wrong

Good architecture documents state their own failure modes. This decision should be revisited if:

1. **L1 data costs** on testnet exceed the sponsor budget by >3× (→ evaluate Arbitrum Orbit/AnyTrust, or Model B where gas is paid in Prime).
2. **The company wants its own validator economics** (staking, delegation, fee capture) — that is a sovereign chain, i.e. option (c) or a PoS fork, and OP Stack will never provide it.
3. **Regulatory requirements** demand a permissioned, KYC-gated chain — at which point an enterprise chain (Besu QBFT) fits better than a public rollup.
4. **Upstream OP Stack changes licence or governance** in a way that makes chain operation contingent on a third party we do not trust.
5. **Ronin-style latency** turns out to require features not available upstream; we would then evaluate their Flashblocks-equivalent path rather than build one.

---

## 15. Verified versions & sources (fetched 2026-10-24)

| Component | Version / fact | Source |
|---|---|---|
| OP Stack `op-node` | `v1.19.11`, 2026-10-22 (security release) | GitHub releases API |
| OP Stack existence of privileged roles, audit reports, custom gas token, subblocks | Confirmed page titles in docs nav | [docs.optimism.io](https://docs.optimism.io/op-stack/architecture) |
| Ronin consensus | "OP Stack", block time ~2s, chainId 2020, RON | [Ronin network docs](https://docs.roninchain.com/developers/network/) |
| Geth Clique | `consensus/clique` still present on `master` | GitHub contents API |
| Cosmos EVM | pre-v1, "v0.x releases… until audit completes" | [cosmos/evm README](https://github.com/cosmos/evm) |
| OpenZeppelin Contracts | `v5.7.0` (2026-07-29); ships `Paymaster`, `PaymasterSigner`, `ERC4337Utils` (final, no `draft-`), `ERC7913WebAuthnVerifier` | GitHub releases API |
| ERC-4337 | **Final**; `PackedUserOperation`, EIP-712 `userOpHash`, `paymasterSignature` | [EIP-4337](https://eips.ethereum.org/EIPS/eip-4337) |
| Foundry | `v1.8.6`, 2026-10-21 (Windows binary available) | GitHub releases API |
| Godot | `4.7.2` stable (2026-08-18); C# desktop+mobile only | [godotengine.org](https://godotengine.org/) |
| Nethereum | `7.0.0` (`net8.0`+, AOT-compatible) | [NuGet](https://www.nuget.org/packages/Nethereum.Web3) |

Versions not yet verified (will be pinned in the phase that uses them, never guessed): EntryPoint v0.8 canonical address, bundler (rundler/alto) release and custom-chain support, Blockscout OP Stack support matrix, godot-cpp 4.7 branch, libsecp256k1 tag, Slither version and Solidity compiler version.

---

## 16. Sign-off

Approving this document approves: OP Stack, the single-sequencer PoA model with the §5.2 path, Model A token design (§6.1), application-layer fee sink (§6.3), ERC-4337 sponsorship (§7), GDExtension crypto (§9), and the Phase 1 plan (§12).

Reply with approval, or with answers to D1–D7. I will then start Phase 1 and will not touch code before that.

> **Approved 2026-10-24** with the recommended defaults: D1 → Model A, D2 → T1, D3 → 1 sequencer + 2 replicas, D5 → GDExtension. Answers recorded in [PROGRESS.md](PROGRESS.md) "Client decisions received". D4/D6/D7 remain open and are needed in Phases 2 and 5.
