# PrimeChain — Threat Model

| | |
|---|---|
| **Document** | THREAT_MODEL.md |
| **Phase** | 0 |
| **Status** | Draft for approval — accompanies [ARCHITECTURE.md](ARCHITECTURE.md) |
| **Method** | STRIDE per trust boundary, plus attack-tree walkthroughs for the eight threats named in the brief |
| **Date** | 2026-10-24 |
| **Review cadence** | Re-reviewed at the end of every phase; changes recorded in [DECISIONS.md](DECISIONS.md) |

---

## 1. Scope and method

**In scope:** the L2 chain and its operator, bridge and settlement contracts on L1, the six game contract families, the ERC-4337 paymaster + bundler, the game backend gateway, the Godot client and its key storage, CI/CD and key custody.

**Out of scope (declared, not ignored):** compromise of Ethereum L1 itself; compromise of the cloud provider's control plane; nation-state endpoint attacks; physical coercion of key holders (noted as a residual risk with a duress policy requirement); the game's own server-authoritative gameplay (assumed separately security-reviewed); legal/regulatory risk (flagged, owned by counsel).

**Assumptions:** the ops team is competent and follows runbooks; signer keys are on hardware wallets in separate locations; the company is the only entity with sequencer authority at launch; players are untrusted by default and may be financially motivated.

**STRIDE categories** are used per component, then aggregated into a risk register with an owner phase and a residual-risk verdict.

---

## 2. Assets, actors and trust boundaries

### 2.1 Assets, ranked by loss impact

| ID | Asset | Why it matters |
|---|---|---|
| A1 | Bridge escrow (ETH/Prime locked on L1) | Largest single pool; a bridge exploit is existential |
| A2 | 2,000,000,000 Prime (treasury) | Whole economy; token has no mint, so theft is permanent |
| A3 | Sequencer key | Can reorder, censor, and extract MEV; can also halt the chain |
| A4 | Paymaster deposit + sponsor budget | Directly drainable by abuse |
| A5 | Batcher / proposer hot keys | Can post invalid data / wrong roots → chain halt or fraud |
| A6 | Upgrade authority (Safe + Timelock) | Can change game contracts; must not be single-key |
| A7 | Player keys and session tokens | Theft = loss of player assets and reputation |
| A8 | Reward integrity (emission caps) | Inflation or unfair distribution destroys trust |
| A9 | Item metadata integrity | Bait-and-switch on purchased cosmetics |
| A10 | Availability (RPC, sequencer, explorer) | A game that cannot transact is a game that is down |

### 2.2 Actors

- **Player** — untrusted, financially motivated, may run modified clients, bots, or emulators.
- **Game backend** — trusted for gameplay outcomes, *not* trusted for money movement beyond caps.
- **Company operator** — trusted, but humans make mistakes; assume at least one compromised laptop.
- **Bundler** — semi-trusted infrastructure we operate.
- **External attacker** — contracts, infra, or supply chain.
- **Insider** — disgruntled or bribed employee with partial access.
- **L1 / Ethereum** — trusted for settlement correctness, not for liveness of our chain.

### 2.3 Trust boundaries

| # | Boundary | Crosses | Default posture |
|---|---|---|---|
| B1 | Device ↔ Gateway | Internet | Hostile; device may be rooted |
| B2 | Gateway ↔ Chain | RPC | Gateway authority must be *capped on-chain* |
| B3 | L2 ↔ L1 bridge | OptimismPortal / dispute game | Highest value, lowest tolerance |
| B4 | Ops ↔ everything | Safe + Timelock | Two-person rule, 48h delay |
| B5 | Build ↔ production | CI/CD | Compromised dependency = compromised contracts |
| B6 | Sequencer ↔ replicas | P2P/RPC | Replicas must independently verify, not trust |

---

## 3. STRIDE by component

### 3.1 Chain / sequencer (A3, A5, A10)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **S** | Attacker impersonates sequencer RPC and feeds clients forged state | Clients pin TLS + chain ID + checkpoint attestations (T1/T2, ARCHITECTURE §10); never trust a single RPC for value-bearing reads | Low |
| **T** | Sequencer reorders/censors a player's transaction (e.g. a marketplace sale) | L1 forced-inclusion path; published inclusion policy; monitoring of inclusion latency; SLO breach page | **Medium** — inherent to a single sequencer until S1 |
| **T** | Batcher posts malformed batch data | op-node rejects invalid data; alerting on derivation errors; batcher key rotation runbook | Low |
| **R** | Operator denies having censored a tx | All txs are public on L1; we publish an inclusion-latency dashboard | Low |
| **I** | Sequencer sees pending txs → front-running of marketplace listings | Commit-reveal for high-value listings; short block time limits the window; acceptable at launch | Medium |
| **D** | Sequencer down → chain halts for players | Hot standby with documented promotion; status page; replica RPC for reads; game degrades gracefully (queue writes client-side) | **Medium** |
| **D** | Batcher/proposer key outage → L2 keeps producing but stops settling | Separate budgets and alerts; batch age alarm; key rotation | Low-Medium |
| **E** | Operator (or attacker) uses sequencer to mint/drain via admin | All privileged actions are L1 contracts behind Safe+Timelock; no L2 admin mint exists | Low |

### 3.2 Prime token (A2, A8)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **T** | Hidden mint / supply inflation | **No mint function exists.** Supply fixed in constructor; `totalSupply` invariant asserted in Foundry invariants | Very low |
| **T** | Malicious `transfer` hook steals funds | No transfer hooks; no fee-on-transfer on Prime by default (ARCHITECTURE §6.3 T1) | Very low |
| **T** | Approval phishing (`approve(max)` to a malicious contract) | Client blocks approvals to non-allowlisted spenders; sponsored-gas allowlist excludes arbitrary approvals; warnings in UI | Medium (user-driven) |
| **I** | Balance/transfer graph leaks player identity | No PII on-chain; UIDs are pseudonymous; document that addresses are public | Accepted |
| **D** | Token contract paused forever by admin | Prime is **non-pausable** by design; only game contracts are pausable | Low |

### 3.3 Treasury & reward distribution (A2, A8)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **S** | Attacker forges a reward claim | EIP-712 domain bound to `chainId` + `verifyingContract`; per-account nonce; expiry; merkle root bound to epoch | Low |
| **T** | Replay of a claim on another chain / another distributor | Domain separation + chainId; distributor address in domain; nonce consumed on-chain | Low |
| **T** | Treasury drained faster than schedule | `maxPerEpoch`, `maxPerAccountPerEpoch`, no rollover; global `totalReleased` cap | Low |
| **T** | Admin raises caps silently | Caps behind Safe+Timelock (48h); `CapChanged` event; public dashboard diffing params | Low |
| **T** | Insider mints to self (impossible) / grants self rewards | Reward grants are merkle-root-limited; any discretionary transfer from treasury requires Safe threshold + timelock | Low-Medium |
| **R** | Dispute over "who was supposed to be paid" | Merkle root published per epoch with an IPFS-pinned manifest; on-chain event log | Low |
| **E** | Compromised signer escalates privileges | 4/7 Safe, 48h timelock, separate hardware wallets, no signer is also an ops admin | Medium |

### 3.4 Paymaster (A4) — *the most abusable component*

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **T** | **Draining by sponsoring arbitrary calls** — attacker uses our gas to run their own contract | On-chain allowlist of `(target, selector)`; anything else reverts. Allowlist changed only by Timelock | Low |
| **T** | **Sybil draining** — thousands of fresh accounts each claiming a daily allowance | Per-account caps alone are useless; add device attestation (Play Integrity / App Attest), proof-of-play, account age, invite graph, and per-device caps server-side; global daily budget caps the blast radius | **Medium** — economic, not technical |
| **T** | **Gas griefing via `postOp`** — op that reverts after consuming all gas, paymaster still pays | Strict `postOpGasLimit`, revert-safe `postOp`, penalty accounting, per-op gas ceiling | Low |
| **T** | Bundle stuffing / same-sender spam | Bundler enforces one op per sender per bundle; per-account nonce keys | Low |
| **T** | Forged sponsorship authorization | EIP-712 sig from gateway key, bound to account + `userOpHash` + expiry + nonce; paymaster checks signer allowlist | Low |
| **T** | Replay of a sponsorship auth | Nonce + expiry + `userOpHash` binding; consumed in paymaster storage | Low |
| **T** | Compromised gateway key mints unlimited sponsorships | **On-chain caps are the backstop** — daily global budget cannot be exceeded regardless of gateway state; key rotation + revoke in <15 min | Low-Medium |
| **E** | Paymaster owner upgrades to a drainer | UUPS upgrade behind Safe+Timelock; implementation address pinned; upgrade event alerts | Medium |
| **D** | Paymaster deposit exhausted → all sponsored txs fail | Deposit alarm at 30%/15%/5%; auto-topup from budget contract; graceful degradation to user-paid mode | Medium |

### 3.5 Game contracts (items, crafting, marketplace, storage)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **T** | **Reentrancy** on marketplace withdraw/refund paths | `ReentrancyGuard` on all external state-changing entry points; checks-effects-interactions; no native ETH sends to arbitrary callers (use pull payments) | Low |
| **T** | **Read-only reentrancy** via a view used as an oracle by a third party | Views never used for pricing decisions in-contract; document the risk for integrators | Low |
| **T** | Crafting duplication — craft consumes nothing | Invariant test: sum(inputs burned) accounting; ERC-1155 supply caps; `SafeERC20` for token pulls | Low |
| **T** | Marketplace escrow theft via malicious `onERC1155Received` | Escrow holds tokens, not callbacks; receiver hooks only on transfer out, guarded | Low |
| **T** | Metadata bait-and-switch after purchase | `contentHash` is immutable per `itemTypeId`; URI changes emit events and are Timelock-gated; hash mismatch makes the client refuse to render | Very low |
| **T** | Randomness manipulation in crafting (if RNG added) | **Do not ship RNG in v1.** If required: commit-reveal with server secret + Chainlink VRF; note that a single sequencer can bias block-hash RNG — never use `block.prevrandao` | Medium if RNG added |
| **T** | Integer/rounding bugs in fees | `Math.mulDiv` with explicit rounding direction; fuzz tests around bps boundaries | Low |
| **T** | Storage slot collision in upgradeable contracts | ERC-7201 namespaced storage; `forge inspect storage-layout` diff in CI | Low |
| **E** | Game contract admin mints items freely | Mint authority is role-gated, capped per item, and every mint emits an event; admin role held by Timelock, not a person | Medium |

### 3.6 Bridge and L1 settlement (A1) — *existential*

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **T** | **Bridge validator-key compromise** (the Ronin 2022 failure mode) | Use the canonical OP Standard Bridge whose security is Ethereum + fault proofs, **not** a custom M-of-N bridge. No custom bridge at launch. | Low-Medium |
| **T** | Withdrawal forgery | Output roots proposed by `op-proposer`, challengeable during the dispute window; 7-day exit period is a feature, not a bug | Low |
| **T** | Deposit replay / double credit | Portal nonce + consumed-hash mapping; standard audited contracts | Very low |
| **D** | L1 congestion delays settlement | L2 keeps running; withdrawals delayed; status page communicates | Medium |
| **T** | Third-party "fast bridge" rug | Not integrated at launch; if added later, cap exposure per bridge and disclose trust | Accepted if added |

**Case study — Ronin bridge, March 2022:** ~173,600 ETH and ~25.5M USDC (≈$624M) drained after attackers obtained 5 of 9 validator signatures via social engineering of Sky Mavis staff, then abused a backdoor in the Axie DAO's allowlist. Lessons applied here: (1) do not build a custom bridge; (2) if any M-of-N attestation exists, its threshold must be high and its signers independent; (3) any privileged allowlist is an attack surface and must be removed, not documented.

### 3.7 Gateway & client (A7)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **S** | Session token theft | Short-lived JWTs + refresh binding to device attestation; revocation list; re-auth on value-bearing actions | Medium |
| **T** | **Key theft at rest** | AES key in Android Keystore / iOS Secure Enclave wrapping the secp256k1 key; device-unlock required; no plaintext key ever on disk or in logs | Medium (malware on rooted device) |
| **T** | Key theft in memory (debugger, memory dump) | Native extension zeroises buffers; no key in GDScript strings; Play Integrity warns on rooted/debug builds | Medium — **cannot be eliminated on a general-purpose phone** |
| **T** | **Replay of a signed transaction** | EIP-155 `chainId` in the tx; nonce monotonic; EIP-712 domain for off-chain signatures; session nonce for gateway requests | Low |
| **T** | Malicious "update" replaces the crypto extension | Code signing + Play App Signing + reproducible builds; pin extension hash; integrity check at startup | Low-Medium |
| **I** | Client telemetry leaks wallet↔identity link | Separate analytics ID from wallet; no address in crash reports; privacy review before launch | Medium |
| **D** | Weak device stalls on RPC polling | Exponential backoff, WSS subscriptions where available, batched reads, local cache with block-hash invalidation | Low |

### 3.8 CI/CD and supply chain (B5)

| Cat | Threat | Mitigation | Residual |
|---|---|---|---|
| **T** | Malicious npm/pip/cargo dependency | Pinned versions + lockfiles; `pnpm install --frozen-lockfile`; OSV/dependabot review; no postinstall scripts from unknown packages | Low-Medium |
| **T** | Compromised GitHub Action | Pin actions by full commit SHA; least-privilege `GITHUB_TOKEN`; no secrets in PR-triggered workflows | Low |
| **T** | Secret committed to repo | `gitleaks` pre-commit + CI; secrets only in vault/env; deploy keys scoped per environment | Low |
| **T** | Deploy script drift from audited bytecode | Verify deployed bytecode against a committed build artefact; `forge verify`; deterministic builds and recorded salts | Low |

---

## 4. Attack walkthroughs (the eight named threats)

### 4.1 Key theft → treasury drain
**Path:** phish a Safe signer → sign a Timelock proposal → wait 48h → upgrade Treasury → transfer 2B Prime.
**Controls:** 4/7 threshold means one phish is insufficient; timelock gives a 48h detection window; the proposal's calldata is announced to a monitored channel and diffed by a bot; any signer can veto; hardware wallets with on-device calldata display.
**Residual:** collusion of 4 signers. Mitigated organisationally (geographic split, independent employment, no shared cloud account).

### 4.2 Replay attacks
**Vectors:** (a) same signed tx on another chain; (b) same EIP-712 reward claim replayed; (c) same sponsorship auth replayed; (d) same UserOperation across EntryPoint versions.
**Controls:** EIP-155 `chainId`; EIP-712 domain includes `chainId` + `verifyingContract`; per-account nonces consumed on-chain; 4337 `userOpHash` includes `entryPoint` and `chainId` (spec requirement); expiry timestamps.
**Test:** a dedicated Foundry suite that replays every signature type across chains/domains and asserts revert.

### 4.3 Double-spend
**Vectors:** (a) reorg after a marketplace delivery; (b) relying on "0-conf" from the sequencer; (c) withdrawal double-claim.
**Controls:** game logic waits for N confirmations (proposal: 2 blocks for cosmetic delivery, more for high-value trades); no off-chain delivery on unsafe heads; canonical portal prevents double withdrawals.
**Residual:** a sequencer that reorgs its own chain can double-spend against a naive merchant. Publish a confirmation policy and enforce it in the SDK, not in documentation.

### 4.4 Validator collusion / sequencer capture
**Path:** operator silently censors a player's withdrawal or marketplace sale, or extracts MEV.
**Controls:** forced inclusion via L1; public inclusion-latency metrics; fault proofs; eventually permissionless proving.
**Residual:** a single sequencer *can* censor. This is disclosed, not denied. The economic damage is bounded because settlement and exits remain available via L1.

### 4.5 Paymaster draining
**Path:** scripted accounts × daily allowance × many devices; or sponsorship of a call to an attacker contract that burns gas.
**Controls:** target/selector allowlist; per-account daily cap; per-device cap via attestation; global daily budget; anomaly alerting (sponsorship per account per hour, new-account burst detection); circuit breaker that pauses sponsorship without pausing the chain.
**Residual:** determined Sybil farming within the budget. Treated as a **cost of business with a hard ceiling**, reviewed weekly.

### 4.6 Bot farming of rewards
**Path:** emulator farms, scripted accounts, referral rings, wash trading to inflate "engagement".
**Controls:** server-side proof-of-play attestation (signed, non-replayable, bound to session); on-chain per-account caps; reward eligibility requires account age + non-trivial progression; marketplace fee makes wash trading lossy; device fingerprint clustering; manual review queue for outliers.
**Residual:** sophisticated farms will extract some rewards. The cap makes it survivable; the invariant is "the schedule cannot be exceeded", not "nobody cheats".

### 4.7 Reentrancy
**Path:** marketplace `buy` → external call to attacker → re-enter `withdraw` → drain escrow.
**Controls:** `ReentrancyGuard` on every value-moving external function; CEI ordering; pull-payment pattern; no `call{value:}` to user-supplied addresses without a withdrawal step; Slither `reentrancy-*` detectors as a CI gate; Foundry fuzz tests with a malicious receiver contract.
**Residual:** low, given no custom AMM and no flash-loan surface at launch.

### 4.8 Bridge / treasury risk
**Path:** custom bridge with 5-of-9 signers (Ronin) or a treasury upgrade that redirects emissions.
**Controls:** canonical bridge only; no custom validator attestations; treasury has no upgrade path to change token supply (token is immutable); emission caps behind Timelock.
**Residual:** Ethereum-level risk (contract bug in OptimismPortal, dispute game bug). Mitigated by using upstream audited contracts and tracking upstream security releases.

---

## 5. Risk register (prioritised)

L/I on 1–5; Score = L×I.

| ID | Risk | L | I | Score | Primary control | Phase |
|---|---|---|---|---|---|---|
| R-01 | Paymaster Sybil drain | 4 | 3 | 12 | On-chain budget ceiling + attestation | 3 |
| R-02 | Sequencer outage halts gameplay | 3 | 3 | 9 | Hot standby + graceful degradation | 5 |
| R-03 | Bot farming of rewards | 4 | 2 | 8 | Proof-of-play + caps | 2/3 |
| R-04 | Safe signer compromise (collusion) | 2 | 5 | 10 | 4/7 + timelock + geography | 5 |
| R-05 | Game contract bug (reentrancy/logic) | 2 | 4 | 8 | OZ + invariants + audit | 2/6 |
| R-06 | Bridge exploit (upstream) | 1 | 5 | 5 | Canonical contracts only, monitor upstream | 5/6 |
| R-07 | L1 DA cost overrun | 3 | 3 | 9 | Measure on testnet; Model B fallback | 5 |
| R-08 | Key theft on rooted device | 3 | 2 | 6 | Keystore wrap + attestation | 4 |
| R-09 | Supply-chain compromise | 2 | 5 | 10 | Pinning, SHA-pinned actions, review | 1–6 |
| R-10 | Metadata bait-and-switch | 1 | 3 | 3 | Immutable contentHash + events | 2 |
| R-11 | Reward claim replay | 2 | 4 | 8 | EIP-712 domain + nonce | 2 |
| R-12 | Sequencer censorship / MEV | 3 | 3 | 9 | Forced inclusion, disclosure, fault proofs | 5/6 |

**Risk accepted at launch only with written sign-off:** R-01 (residual Sybil cost), R-02 (downtime), R-07 (cost), R-12 (censorship).

---

## 6. Security controls as engineering requirements

These become CI gates and phase acceptance criteria, not aspirations:

1. **No single-key admin.** Every privileged function is `onlyRole` where the role's admin is the Timelock; the Timelock's proposer is the Safe.
2. **Every signature is domain-separated.** EIP-712 with `name`, `version`, `chainId`, `verifyingContract`; no `ecrecover` on raw hashes.
3. **Every state-changing external function is reentrancy-guarded** if it moves value or calls out.
4. **100% branch coverage** on `Prime`, `Treasury`, `RewardDistributor` (enforced with `forge coverage --fail-under`).
5. **Fuzz + invariant suites** run on every commit; invariants include `totalSupply == 2e27` (2B × 1e18) and `sum(balances) == totalSupply`.
6. **Slither zero high/medium findings**, or a documented triage with owner and expiry.
7. **Storage layout diff** in CI for every upgradeable contract.
8. **Secrets never in repo** — `gitleaks` blocks the commit; deployment keys exist only in the vault.
9. **Red-team suite for the paymaster** (drain attempts) must fail to drain in Phase 3 acceptance.
10. **Incident response runbook** reviewed and drilled before mainnet.

---

## 7. Open questions for the client

1. Is a **2-of-3 checkpoint attestation** (ARCHITECTURE §10, T2) acceptable for phone verification, or does the product require trustless verification (which would exclude mobile)?
2. What is the **maximum acceptable daily sponsorship budget** in USD? This sets the paymaster's hard on-chain ceiling.
3. Who are the **7 Safe signers**, and do they span at least 3 legal jurisdictions / 3 independent key-storage technologies?
4. Is there a **duress/coercion policy** for signers (e.g. panic button that pauses Timelock execution)?
5. Should the chain expose a **public, unauthenticated RPC** at launch, or a rate-limited gateway only? (Public RPC is required by "public API for non-game apps", but invites abuse.)

---

## 8. Sign-off

This threat model is approved together with [ARCHITECTURE.md](ARCHITECTURE.md). Any phase that changes a trust boundary or a privileged role must update this document in the same pull request — enforced by a CI check on the `SECURITY:` trailer in commit messages (Phase 6).
