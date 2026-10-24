# Phase 2 Plan — Game contracts, treasury semantics, fee sink

| | |
|---|---|
| **Status** | **AWAITING CLIENT APPROVAL — no code written** |
| **Depends on** | Phase 1A green (CI run #4) · D4 approved with both objections accepted |
| **Scope** | `RewardDistributor`, `ItemRegistry`, `Crafting`, `Marketplace`, `Storage`, `FeeSink` |
| **Out of scope** | Paymaster/bundler (Phase 3), Godot SDK (Phase 4), testnet deploy (Phase 5) |
| **Estimate** | ~4 engineer-weeks (6 if marketplace offers are in scope) |

---

## 1. What Phase 2 must guarantee

1. **The emission schedule is enforced by code, not policy.** Daily cap, per-account cap,
   lifetime ceiling, no rollover, and a hard `MAX_EPOCH_CAP` that no role can exceed.
2. **The 1B reserve is structurally unreachable** from the distributor. Not "we promise".
3. **Every privileged action is Timelock-gated.** No EOA admin anywhere in production.
4. **Items are data + hashes.** No assets on-chain; content hashes immutable per item type.
5. **Every contract is fuzzed and invariant-tested**, with 100% coverage on treasury and fee
   logic — the same bar Phase 1 met for the token.

---

## 2. Contract inventory

| Contract | Purpose | Upgradeable | Key roles |
|---|---|---|---|
| `RewardDistributor` | Epoch-sealed merkle claims against D4 caps | **No** (see Q2) | `SEALER`, `CONFIG`, `PAUSER` |
| `FeeSink` | Receives game fees; policy-bound outflow | No | `SWEEPER` |
| `ItemRegistry` (ERC-1155) | Item types: content hash, URI, supply cap | UUPS + Timelock | `REGISTRAR`, `MODULE` |
| `Crafting` | Recipe registry + craft execution | UUPS + Timelock | `RECIPE_ADMIN` |
| `Marketplace` | Fixed-price listings, escrowed | UUPS + Timelock | `FEE_ADMIN`, `PAUSER` |
| `Storage` | On-chain index of item instances (UIDs/hashes) | UUPS + Timelock | `MODULE` |

Everything inherits OpenZeppelin v5.7.0. `AccessControl` everywhere; `DEFAULT_ADMIN_ROLE`
is the Timelock, never a person. Game contracts are UUPS (OZ `UUPSUpgradeable`) with
`_authorizeUpgrade` restricted to the Timelock and a storage-layout diff in CI.

---

## 3. `RewardDistributor` — the core of the phase

### 3.1 Constants (genuinely immutable)

```solidity
uint256 public constant ALLOCATION     = 1_000_000_000e18; // emissions budget, not the 2B supply
uint256 public constant MAX_EPOCH_CAP  =     2_000_000e18; // D4 objection 2, accepted
uint256 public constant EPOCH_DURATION =           1 days;
uint256 public constant MAX_ACCOUNT_CAP =     500_000e18; // sanity ceiling on the per-account knob
```

`ALLOCATION` is the **distributor's** budget. The other 1B never enters this contract.

### 3.2 Configurable (Timelock only, bounded)

| Setter | Bound |
|---|---|
| `setMaxPerEpoch(v)` | `v <= MAX_EPOCH_CAP`, `v > 0` |
| `setMaxPerAccountPerEpoch(v)` | `v <= maxPerEpoch` |
| `pause()/unpause()` | `PAUSER` role only; does **not** move funds |

### 3.3 Epoch lifecycle

```
sealEpoch(epochId, merkleRoot, declaredTotal)   [SEALER]
    require epochId == currentEpoch()           (no sealing the past or the far future)
    require root != 0, not already sealed
    require declaredTotal <= maxPerEpoch
    require totalReleased + declaredTotal <= ALLOCATION
    store root; emit EpochSealed(epochId, root, declaredTotal)

claim(epochId, amount, proof)                    [anyone]
    require sealed, not paused
    leaf = keccak256(abi.encode(epochId, msg.sender, amount))   (double-hashed)
    require MerkleProof.verify(proof, root, leaf)
    require !claimed[epochId][msg.sender]
    require amount <= maxPerAccountPerEpoch
    require epochPaid[epochId] + amount <= maxPerEpoch          <- hard backstop
    require totalReleased + amount <= ALLOCATION
    effects, then prime.transfer(msg.sender, amount)
```

**Why `epochPaid` exists:** the sealer's `declaredTotal` is a claim, not a proof — the
contract cannot sum a merkle tree. `epochPaid` caps the *actual* outflow per epoch on-chain,
so even a buggy or compromised sealer cannot exceed the daily limit. Per-account caps are
enforced per claim, not per tree, for the same reason.

**The race D4 objection 1 warned about is an allocation-time problem, not a claim-time one.**
Because the root is sealed only after the server has applied the caps, a claimant is never
crowded out by another claimant. `epochPaid` is a backstop that should never bind in normal
operation; if it ever does, that is an incident, and it will be alerted on.

Claim window: **indefinite** (Q6). Unclaimed amounts still count against `ALLOCATION` once
sealed, so an abandoned epoch cannot inflate later epochs.

### 3.4 Structural reserve accounting (D4 open item, implemented as proposed)

- The distributor is funded **once**, with exactly `ALLOCATION`, by the treasury (Safe).
- Invariant, enforced by tests and readable on-chain:
  `prime.balanceOf(distributor) >= ALLOCATION - totalReleased`.
- The reserve 1B sits in the Safe; the distributor has no code path that can reach it.
- Donations to the distributor cannot break the invariant (they only increase the balance),
  but they are *not* claimable — `totalReleased` is the only accounting that matters.

### 3.5 Merkle construction (client-side, documented for the backend)

- Leaf pre-image: `abi.encode(epochId, account, amount)`; leaf hash: `keccak256`; tree: OZ
  `MerkleProof` compatible, sorted pairs, double-hashed leaf to prevent second-preimage.
- The manifest (epoch, all allocations, root) is published and pinned; the root is on-chain.
- Verification script ships with the repo so finance can recompute a root independently.

---

## 4. `FeeSink`

- Receives Prime only, via `ERC20.safeTransfer` from the charging contracts.
- `sweep(address to, uint256 amount)` restricted to `SWEEPER` (Timelock), emits
  `Swept(to, amount, balanceAfter)`. No arbitrary calls, no ETH.
- `totalReceived` monotonic counter; `FeeReceived(source, amount)` event for attribution.
- Fee *rates* are not stored here — each charging contract enforces its own `MAX_FEE_BPS`.

---

## 5. `ItemRegistry` + `Storage` — data, not assets

**`ItemRegistry` (ERC-1155).** Per `itemTypeId`:

```
contentHash   keccak256 of the canonical asset manifest   (immutable once registered)
metadataURI   CDN pointer, Timelock-changeable, emits ItemContentUpdated
supplyCap     hard cap; mint reverts above it
minted        counter
```

- `registerItemType` is Timelock-only and one-shot per id (content hash cannot be swapped).
- Mint/burn gated to `MODULE` contracts (Crafting, Marketplace escrow return).
- No `uri` mutation without an event; clients verify `contentHash` before rendering, so a
  bait-and-switch is detectable even if the CDN is compromised.

**`Storage`.** An index of *instances*, not a second balance ledger (Q4):

```
instanceId -> { typeId, owner, contentHash, createdAt, lockedBy }
```

Written only by `MODULE` contracts. ERC-1155 balances stay the canonical ownership ledger;
`Storage` answers "which specific item does this player own, and what is its hash" without
duplicating balances. Avoids the classic two-sources-of-truth bug.

---

## 6. `Crafting`

- `Recipe { inputs[](typeId, qty), outputs[](typeId, qty), feePrime, cooldown }`, registered
  by Timelock; the recipe definition hash is emitted so off-chain JSON can be verified.
- `craft(recipeId, times)`: pull inputs (transferFrom to the sink-and-burn path), `burn` via
  `ItemRegistry` module role, mint outputs (supply caps enforced), `feePrime * times` to
  `FeeSink`. `nonReentrant`, strict CEI.
- **No randomness in v1** (Q3). A single sequencer can bias block-hash RNG, so crafting is
  deterministic; any future RNG goes through commit-reveal or an oracle, not `prevrandao`.

---

## 7. `Marketplace`

- Prime-denominated, escrowed fixed-price listings (Q3): seller escrows ERC-1155 units,
  buyer pays Prime; fee in bps to `FeeSink`, remainder to seller.
- `feeBps <= MAX_FEE_BPS` (immutable, proposed 500 = 5%). No native ETH → no ETH-send
  reentrancy surface. `nonReentrant` + CEI + pull-payment for any refunds.
- Cancel, buy, and expiry. No offers/auctions in v1.
- Deliberately no on-chain price oracle and no AMM: the brief's "no promises of returns"
  constraint is easier to honour without a price mechanism we control.

---

## 8. Test and CI plan

| Layer | Target |
|---|---|
| Unit | every function, every revert path, every role check |
| Fuzz | fee arithmetic, merkle proofs (valid/invalid/replayed), cap boundaries (`cap-1`, `cap`, `cap+1`) |
| Invariants | `totalReleased <= ALLOCATION`; `balance >= ALLOCATION - totalReleased`; `epochPaid[e] <= maxPerEpoch`; double-claim impossible; ERC-1155 supply caps; escrow conservation; `feeSink.balance == Σ fees` |
| Coverage | **100%** on `RewardDistributor` + `FeeSink`, added to the existing gate |
| Static | Slither re-enabled, **pinned**, blocking |
| Upgrade safety | storage-layout diff per UUPS contract in CI |

Vacuity guard stays: every invariant suite must prove its handler executed (Phase 1 lesson).

---

## 9. Deployment sequence (scripted, Timelock-first)

1. Deploy `TimelockController` (48h) + Safe 4/7 as proposer.
2. Deploy implementations; deploy UUPS proxies with `initialize(...)`.
3. Deploy `RewardDistributor` (non-upgradeable); grant `SEALER`/`CONFIG` to the ops key /
   Safe; grant `DEFAULT_ADMIN_ROLE` to the Timelock.
4. Safe transfers exactly `ALLOCATION` to the distributor; asserts `balance == ALLOCATION`.
5. Renounce every deployer role; verify on Blockscout; record addresses in `deployments/`.
6. Post-deploy assertions: caps, roles, `ALLOCATION` balance, token supply unchanged.

---

## 10. Open questions — **answered 2026-10-24, see [DECISIONS.md](DECISIONS.md) ADR-016 / ADR-018**

Q1 Safe only · Q2 not upgradeable · Q3 fixed-price only · Q4 index, not custody ·
Q5 marketplace 250 bps, crafting 0.5 PRIME flat (proposed), storage free, `MAX_FEE_BPS = 500` ·
Q6 indefinite window · Q7 ops key on testnet, multisig mandatory before mainnet (hard gate).

| # | Question | My recommendation |
|---|---|---|
| **Q1** | Treasury: keep the Safe as treasury, or build a custom `Treasury` contract? | **Safe only.** A bespoke treasury is audit surface with no benefit; the distributor is where the rules live. |
| **Q2** | Is `RewardDistributor` upgradeable? | **No.** Immutability is the product promise; bugs are fixed by deploying `V2` and having the Timelock move the remaining balance. |
| **Q3** | Marketplace scope for v1: fixed-price only, or offers/auctions too? | **Fixed-price only.** Offers roughly double the state machine and the audit surface. |
| **Q4** | `Storage` semantics: instance index, or a custody vault with its own balances? | **Instance index.** Two balance ledgers is a known bug factory. |
| **Q5** | Fee numbers: marketplace bps, crafting flat fee, `MAX_FEE_BPS` | Need your values. I propose `MAX_FEE_BPS = 500` (5%) as the immutable ceiling, actual rate configurable below it. |
| **Q6** | Claim window: indefinite, or expire after N epochs? | **Indefinite.** Expiry is user-hostile and mostly profits treasury optics. |
| **Q7** | Who holds `SEALER`, and can one key publish a root? | Prefer a dedicated ops key with `declaredTotal` caps, plus a daily reconciliation alert; higher assurance option is a 2-of-3 Safe signing roots (slower, safer). |

---

## 11. Acceptance criteria for Phase 2

- [ ] All six contracts implemented against OZ v5.7.0, compiling on solc 0.8.28
- [ ] CI green including fuzz, invariants, 100% coverage on distributor + sink, Slither pinned
- [ ] Cap-boundary tests prove `MAX_EPOCH_CAP` cannot be exceeded by any role
- [ ] Reserve invariants hold under stateful fuzzing
- [ ] Deployment script runs end-to-end against anvil, then against the devnet when 1B is up
- [ ] THREAT_MODEL.md updated for the new trust boundaries (sealer, fee sweeper, modules)
- [ ] DECISIONS.md gains ADRs for Q1–Q7 outcomes

---

## 12. What I will not do without a decision

- Write `Treasury` code if Q1 says Safe-only (no custom vault).
- Add randomness to crafting (Q3) — a single sequencer can bias it.
- Ship a marketplace with offers/auctions before fixed-price is audited.
- Implement the reserve invariant in a way that depends on operator discipline.
