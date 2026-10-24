# DECISIONS.md — Architecture Decision Log

Append-only. One ADR per decision. A decision is only changed by adding a superseding ADR, never by editing history.

Format: **Context → Decision → Consequences → Alternatives rejected**. Status: `ACCEPTED` (mine, within delegated authority), `PROPOSED` (needs client sign-off), `SUPERSEDED`.

---

## ADR-001 — Build on the OP Stack

**Status:** ACCEPTED 2026-10-24 (client approval) · **Date:** 2026-10-24

**Context.** We must supply an EVM-equivalent, `eth_*`-compatible, low-fee gaming chain with a permissioned-operator phase and a credible decentralisation path, without writing consensus or a VM. Options: OP Stack, a Geth fork with Clique PoA, Cosmos SDK + Cosmos EVM.

**Decision.** OP Stack: `op-geth` (execution) + `op-node` (derivation) + `op-batcher` + `op-proposer`, settling to Ethereum, company-operated sequencer.

**Consequences.**
- EVM equivalence and JSON-RPC fidelity come for free; Godot tooling is a plain web3 client.
- We inherit upstream security releases and must track them (pinning + upgrade runbook).
- We accept an L1 data-availability cost and a ~7-day canonical withdrawal window.
- Decentralisation is inherited from upstream work (fault proofs, sequencer decentralisation), not built by us.
- "PoA" means *one permissioned sequencer*, not a 3-signer set. We will say so publicly.

**Rejected.** Geth fork (best requirement fit, worst ownership cost: permanent rebase/security burden, no finality, no standard appchain tooling). Cosmos EVM (best consensus fit, but its EVM module is explicitly pre-v1 pending audit). Reth (no PoA engine). Besu QBFT (no public path). Arbitrum Orbit (strong, but outside the three requested options and adds a DAC assumption — kept as a fallback in §14).

---

## ADR-002 — Single sequencer now; decentralisation ladder published

**Status:** ACCEPTED 2026-10-24 (client approval) · **Date:** 2026-10-24

**Context.** The brief requires PoA with "a documented path to Proof of Stake and more validators". OP Stack does not have a validator set to grow.

**Decision.** Operate one sequencer, publish the S0→S4 ladder in [ARCHITECTURE.md](ARCHITECTURE.md) §5.2, and treat S1 (permissionless fault proofs) as a committed post-launch milestone, S4 (sovereign PoS) as an explicitly allowed future re-architecture.

**Consequences.** We must not market the chain as decentralised. The ladder commits us to real milestones with dates. A 3-signer Clique chain is rejected as *decentralisation theatre*: three keys in one trust domain are not more secure than one sequencer, but they are harder to audit and easier to lie about.

**Rejected.** Multi-signer L2 block production on OP Stack (not supported upstream; a fork would be required).

---

## ADR-003 — Prime is an immutable-supply ERC-20; gas stays ETH and is sponsored

**Status:** ACCEPTED 2026-10-24 — **D1 resolved to Model A** · **Date:** 2026-10-24

**Context.** The brief calls Prime the "native/base token" *and* a "Prime ERC-20 (fixed supply)" with 2B minted once at genesis. A chain has one native gas asset; on OP Stack the default is ETH. OP Stack offers a "Custom Gas Token" feature that makes an L1 ERC-20 the L2 gas asset.

**Decision (recommended).** Model A: `Prime` is a non-upgradeable ERC-20 with **no mint function at all**, supply fixed at construction (2,000,000,000 × 10¹⁸). Chain gas remains ETH and is fully sponsored for player actions via ERC-4337. Prime is the only token players ever see.

**Consequences.**
- Strongest possible supply guarantee: there is no code path to inflate, so "no hidden admin mint" is verifiable by inspection.
- The company funds gas in ETH; this is a budget line, not a player cost.
- If D1 later selects Model B, this ADR is superseded before genesis and Phase 1 acceptance changes (Blockscout/bundler/paymaster compatibility with a custom gas token must be proven first).

**Rejected.** Upgradeable token with `MINTER_ROLE` (reintroduces exactly the admin risk the brief forbids). Fee-on-transfer token (breaks composability; see ADR-004). Deploying Prime on L1 and bridging (adds an L1 dependency and a bridge to the critical path before we need it).

---

## ADR-004 — Fees to the sink live at the application layer, not in the token

**Status:** ACCEPTED 2026-10-24 — **D2 resolved to T1** · **Date:** 2026-10-24

**Context.** "Per-transaction tax/fee goes to a sink address". OP Stack burns the L2 base fee; priority fees route to a protocol fee vault. Diverting gas to a game address would require forking fee handling.

**Decision.** Implement the sink as `FeeSink`, fed by explicit fees on game actions (crafting, marketplace, storage, renaming) at rates configurable behind Safe+Timelock. **No transfer tax on Prime transfers** by default, because the brief also requires that players can "transfer freely" and because a transfer tax breaks DEXes, escrows and third-party integrations.

**Consequences.** Fee revenue is transparent and attributable per system. We lose the "every transfer pays" property — deliberate. If the client insists on a transfer tax, it ships behind a global switch, off at launch, and must be disclosed to any exchange listing Prime.

**Rejected.** Custom gas token + modified fee vault (fork risk). Native-token transfer tax (permanent audit finding, breaks integrators).

---

## ADR-005 — ERC-4337 v0.8 with a two-layer paymaster policy

**Status:** ACCEPTED (implementation detail delegated) · **Date:** 2026-10-24

**Context.** Sponsored gas must be abuse-resistant even if our backend is compromised.

**Decision.** ERC-4337 (Final) with EntryPoint v0.8, OpenZeppelin v5.7.0 `Paymaster`/`PaymasterSigner` building blocks, and policy split into (1) on-chain hard caps and target allowlist, (2) gateway-signed soft policy bound by EIP-712 to `chainId`, paymaster address, `userOpHash`, nonce and expiry.

**Consequences.** Two layers to test; a compromised gateway can only spend up to the on-chain daily ceiling. We must run a bundler and monitor its inclusion rate. Exact EntryPoint address to be pinned from the eth-infinitism deployment manifest in Phase 3 — **not** hard-coded from memory.

**Rejected.** ERC-2771 meta-transactions alone (simpler, but no smart-account recovery/passkey path for phones). Unlimited sponsorship gated only by server logic (single point of drain).

---

## ADR-006 — Godot crypto via a minimal C++ GDExtension

**Status:** ACCEPTED 2026-10-24 — **D5 resolved to GDExtension** · **Date:** 2026-10-24

**Context.** Godot 4.7.2 has no secp256k1 or keccak-256.

**Decision.** A small GDExtension built with godot-cpp (branch matching 4.7.x) linking a pinned libsecp256k1 release and a vendored keccak-256 implementation, exposing: `privkey_to_address`, `sign_hash`, `sign_typed_data`, `keccak256`, `rlp_encode`. Private keys never enter GDScript strings; the extension zeroises buffers.

**Consequences.** We own a native build matrix (Android arm64/armv7, iOS arm64, Windows, macOS, Linux). CI must build and run known-answer tests against published vectors. C#/Nethereum 7.0.0 stays a documented alternative for .NET-first teams but requires the .NET editor build and excludes web export.

**Rejected.** Pure GDScript crypto (not constant-time, too slow on a Note 8). Server-side signing for player wallets (violates self-custody).

---

## ADR-007 — Phones verify checkpoints + Merkle proofs, not consensus

**Status:** ACCEPTED (product must disclose) · **Date:** 2026-10-24

**Decision.** Tier T2 (M-of-N signed checkpoints over `(blockNumber, blockHash, stateRoot)`) + T1 (`eth_getProof` against that root, queried across ≥2 independent RPCs). T3 (op-node on device) declared infeasible on target hardware.

**Consequences.** The trust assumption is a 2-of-3 checkpoint committee. The UI and public docs must say "attested", not "trustless". If the client demands trustless mobile verification, the project scope changes materially.

---

## ADR-008 — Canonical bridge only; no custom bridge

**Status:** ACCEPTED · **Date:** 2026-10-24

**Context.** Ronin lost ~$624M in 2022 through a custom M-of-N bridge (5/9 keys compromised).

**Decision.** Launch with the OP Standard Bridge only. Any third-party fast bridge is a separate, capped, disclosed integration.

**Consequences.** 7-day exits for players moving funds to L1. If the product needs fast exits, we integrate a third-party bridge with a per-bridge exposure cap rather than build one.

---

## ADR-009 — Multisig + timelock for every privileged action; token not upgradeable

**Status:** ACCEPTED · **Date:** 2026-10-24

**Decision.** Safe 4/7 as Timelock proposer; OpenZeppelin `TimelockController` with 48h delay as the owner of every game contract and the paymaster. `Prime` and the token's supply rules are **not** upgradeable. Game contracts are UUPS upgradeable behind the Timelock, with a storage-layout CI check. No EOA holds a privileged role in production.

**Consequences.** Slower incident response (48h) — mitigated by a separate, narrowly scoped `Pauser` role (pause only, no upgrade, no funds movement). Signer geography and hardware-wallet policy required (D6).

---

## ADR-010 — Self-hosted explorer and indexer

**Status:** ACCEPTED · **Date:** 2026-10-24

**Decision.** Blockscout for the explorer; a self-hosted indexer for gameplay reads. No hosted-subgraph dependency for anything a player sees.

**Consequences.** More ops surface (Postgres, indexer workers). Removes a third-party outage from the critical path.

---

## ADR-011 — Pin every version; never deploy `latest`

**Status:** ACCEPTED · **Date:** 2026-10-24

**Decision.** Every component is pinned to an exact release and recorded in [ARCHITECTURE.md](ARCHITECTURE.md) §15. Upgrades are deliberate, tested on testnet first, and documented in the upgrade runbook. No `:latest` Docker tags in any environment.

**Consequences.** Security patches require a deliberate release cycle (target: ≤72h for a critical upstream CVE).

---

## ADR-012 — Verification runs in CI, not on the authoring machine

**Status:** ACCEPTED (environment constraint, disclosed) · **Date:** 2026-10-24

**Context.** The authoring environment has no Docker, no WSL, no outbound TLS for shell processes, and no Solidity toolchain installed. Downloads are blocked.

**Decision.** All compilation, tests, fuzzing, coverage and static analysis run in GitHub Actions (Linux runners) with pinned tool versions. Local authoring produces code plus the exact commands; CI is the source of truth for "green". Where offline verification is possible (pure-Python reference implementations of keccak/secp256k1 cross-checked against published EIP test vectors), it will be used to validate constants and test vectors before they enter Solidity or GDScript.

**Consequences.** I will not claim a test passed unless CI output says so. Phase 1 acceptance is defined as "CI green", not "works on my machine". This is slower but honest, and it is the only defensible way to work without a local toolchain.

---

## ADR-013 — Prime is a plain, non-upgradeable ERC-20; no permit, pause or burn

**Status:** ACCEPTED (implementation of ADR-003) · **Date:** 2026-10-24

**Context.** ADR-003 fixed the supply model. This records the token's surface area, which is the thing auditors and integrators actually care about.

**Decision.** `Prime` inherits only `ERC20` from OpenZeppelin v5.7.0. 18 decimals. `TOTAL_SUPPLY` is a `constant`; the treasury is `immutable`; the constructor mints once to the treasury passed in; zero treasury reverts. No `ERC20Permit`, no `ERC20Pausable`, no `ERC20Burnable`, no owner, no roles, no proxy, no hooks. `bytecode_hash = none` and `cbor_metadata = false` so the deployed bytecode is reproducible.

**Consequences.**
- Supply inflation is impossible by construction, not by policy: there is no external `mint` selector, and the fuzz/invariant suites assert it.
- Gasless approvals (`permit`) are unavailable; with ERC-4337 sponsorship the approve+action flow is one user operation anyway, so the UX cost is zero.
- Burning (economy sink) must be implemented as a separate sink contract in Phase 2, not as a token method — which is better anyway: sink policy is game design, not money primitive.
- Deployment is a one-shot: a mistake in the constructor means redeploying and redistributing, so the deploy script asserts supply invariants immediately after broadcast.

**Rejected.** `ERC20Permit` (extra signature surface for no UX gain under sponsorship). `ERC20Pausable` (an admin switch over player money). `ERC20Burnable` (mixes sink policy into the money primitive). Upgradeable proxy token (reintroduces the admin-mint risk the brief forbids).

---

## ADR-014 — Dependencies are fetched by a pinned script, verified by commit SHA

**Status:** ACCEPTED · **Date:** 2026-10-24

**Context.** Foundry conventionally uses git submodules. This project is handed over as files, and CI runs against a fresh clone; a submodule pin requires the parent repo to exist, which it does not in the authoring environment (`git init` is blocked).

**Decision.** `contracts/scripts/bootstrap-deps.sh` clones OpenZeppelin Contracts at `v5.7.0` and **verifies the commit SHA** (`cab19933…`) after cloning, and forge-std at `v1.17.0`. `lib/` is git-ignored.

**Consequences.** A moved tag fails the build loudly instead of silently changing the dependency. Dependency identity is visible in one file. Revisit if the repo becomes a normal git repo with working submodules — but the SHA check is worth keeping either way.

---

## ADR-015 — Phase 1B (devnet boot) is deferred to a Docker host; no fabricated compose file

**Status:** ACCEPTED (constraint disclosure) · **Date:** 2026-10-24

**Context.** The authoring environment has no Docker, no WSL, no outbound TLS, and cannot create dot-directories. An OP Stack devnet needs `op-geth`, `op-node`, batcher, proposer and an L1, with roughly forty CLI flags between them. Additionally the upstream `optimism` `Makefile` at `op-node/v1.19.11` declares its own targets deprecated in favour of `just` recipes.

**Decision.** Ship the devnet as a **pinned runbook plus real acceptance checks** (`infra/devnet/`), and make the bootstrap discovery-first: clone the pinned tag, print `just --list`, then boot with the recipe that the pinned tree actually exposes. Do not commit a compose file with flags reconstructed from memory.

**Consequences.** Phase 1 is split: 1A (token, tests, CI) is complete as code; 1B requires one command on a Docker host. The alternative — a plausible-looking compose file that fails at boot — would waste more time and would violate the "never invent APIs" rule. If a Docker host is provisioned, 1B closes in under a day.

---

## D4 — Emission parameters (client decision)

**Status:** **APPROVED BY CLIENT, 2026-10-24 — recorded, not implemented.** Implementation is Phase 2 and is gated on the Phase 1 CI result. · **Date:** 2026-10-24

**Context.** `RewardDistributor` enforces the emission schedule on-chain. These are the client's numbers, recorded verbatim; the observations below are mine and do not change the approved values.

| Parameter | Approved value | Notes |
|---|---|---|
| `epochDuration` | **1 day** = 86,400 s | sealed epochs, not rolling |
| `maxPerEpoch` | **500,000 PRIME** (`500_000e18`) | hard cap, no rollover |
| `maxPerAccountPerEpoch` | **200 PRIME** (`200e18`) | hard per-account cap |
| Total emissions ceiling | **1,000,000,000 PRIME** (`1_000_000_000e18`) | lifetime cap for the distributor |
| Reserve | **1,000,000,000 PRIME** | stays in treasury, never reachable by the distributor |
| Unused epoch capacity | **does not roll over** | expires when the epoch is sealed |
| Change control | Safe 4/7 + 48h Timelock | may raise, never above the ceiling |

**Derived facts (arithmetic, not opinion).**

- `1,000,000,000 / 500,000 = 2,000` epochs ≈ **5.5 years** at maximum rate. The
  ceiling is the binding constraint long before the calendar is.
- `500,000 / 200 = 2,500` — the two caps are calibrated to **at most 2,500
  fully-capped accounts per day**. That is the intended launch scale.

**Observations I am flagging rather than silently implementing (items 1–3 are not approved and will not be built without a decision).**

1. **The per-account cap binds before the epoch cap does.** Above ~2,500 daily
   recipients, either most players receive less than 200 PRIME, or the epoch cap
   is exhausted and the remainder gets nothing. To avoid a daily "race for
   rewards", allocations must be computed server-side and the epoch's merkle root
   sealed **only after** the cap has been applied. The on-chain contract then
   enforces the cap at root publication, not at claim time. Worth stating in the
   published schedule.
2. **"Never above the ceiling" is weaker than it sounds.** With only the 1B
   lifetime ceiling enforced, one compromised Timelock proposal could set
   `maxPerEpoch = 1,000,000,000` and drain the entire emissions budget in a single
   epoch — a real risk given the 48h delay is the only backstop. I recommend an
   **immutable `MAX_EPOCH_CAP`** (e.g. 2,000,000 = 4× the launch value) that no
   role, including the Timelock, can exceed.
3. **Reserve accounting must be structural, not documentary.** The distributor
   should hold (or be able to draw) exactly the 1B emissions allocation, with an
   invariant `released + remaining == 1_000_000_000e18`; the other 1B must sit in
   the treasury and be unreachable from the distributor's code path. "We promise
   not to spend the reserve" is not a control.
4. **No rollover is the right call** and I would not change it: banked capacity
   creates a burst that looks like a pump and breaks the published schedule.

---

## Decision index

| ADR | Topic | Status |
|---|---|---|
| 001 | OP Stack | ACCEPTED |
| 002 | Single sequencer + ladder | ACCEPTED |
| 003 | Prime token model (Model A) | ACCEPTED |
| 004 | Fee sink at app layer (T1) | ACCEPTED |
| 005 | ERC-4337 + two-layer paymaster | ACCEPTED |
| 006 | Godot GDExtension crypto | ACCEPTED |
| 007 | Phone verification tiers | ACCEPTED |
| 008 | Canonical bridge only | ACCEPTED |
| 009 | Safe + Timelock | ACCEPTED |
| 010 | Self-hosted explorer/indexer | ACCEPTED |
| 011 | Version pinning | ACCEPTED |
| 012 | CI-based verification | ACCEPTED |
| 013 | Plain non-upgradeable token | ACCEPTED |
| 014 | Pinned dependency script | ACCEPTED |
| 015 | Phase 1B deferred to Docker host | ACCEPTED |
| D4 | Emission parameters | APPROVED (pending CI result) |
