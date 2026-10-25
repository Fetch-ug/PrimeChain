# MIGRATION.md — Replacing an immutable contract without stranding players

Applies to `ItemRegistry` and any future immutable game contract (ADR-019).
**Status:** plan only — no migration code written. No V2 is planned today.

---

## 1. The principle

Immutability moves the risk. It does not remove the possibility of change; it moves it from
*"an admin key can rewrite the rules whenever they like"* to *"changing the rules is a
planned migration with a published snapshot and a published audit trail"*.

Players keep their items because V2 **re-issues exactly the balances recorded at a frozen
block**. Nothing is invented, nothing is rounded, and the reconciliation is checkable by
anyone.

---

## 2. What V1 holds

`ItemRegistry` records, per item id: `contentHash` (immutable), `metadataURI` (mutable by
registrar), `supplyCap`, **cumulative** `minted`, and ERC-1155 balances.

Because `minted` is cumulative and burning never frees capacity, **re-issuing V1 balances in
V2 permanently consumes V2 cap headroom**. V2 caps must be sized as:

```
supplyCap_v2(id) = outstanding_v1(id) + planned_new_issuance_v2(id)
```

Sizing this too tightly is the single most likely way to strand players mid-migration.

---

## 3. Preconditions (in order)

1. An ADR naming the reason, the replacement, and the rollback criteria.
2. **V1 frozen** — no mint, no burn, ideally no transfer (see §4).
3. Marketplace delisted: escrow emptied, no open listings.
4. Announcement ≥ 7 days ahead: snapshot block number, V2 address, claim instructions.
5. Migration rehearsal on testnet with a copy of production state (Anvil fork or devnet).

---

## 4. Freezing V1 — decided

**Client decision 2026-10-24 (ADR-020): add a one-way `freeze()` to `ItemRegistry` before it
ships.** No unfreeze path exists. It is a hard migration tool, not an operating mode.

Constraints, all of which are test requirements:

| Constraint | Why |
|---|---|
| Callable **only** by `DEFAULT_ADMIN_ROLE` (the Timelock) | Not the registrar, not a game module, not an ops key. Exactly one authority can end trading, and it is the slowest one in the system. |
| **One-way** — no `unfreeze()` | A reversible "pause" is an operating control with ongoing risk; a one-way freeze is a terminal state with a single decision attached. |
| Blocks mint and transfer | The snapshot must be stable. |
| **Also blocks burn** | `_update` is the single choke point, and a MODULE burn after the snapshot would silently reduce a player's recorded balance. If burns must remain possible while frozen, say so — it is a one-line change. |
| Can never move, burn or reassign by itself | `freeze()` takes no arguments and touches no balance; it only flips a flag. Proven by asserting every balance and `totalSupply` are unchanged across the call. |
| Emits `Frozen(address indexed account)` | The migration moment is on-chain and indexed by every watcher. |
| Metadata URI stays mutable | URIs are not balances; moving a CDN during a migration is legitimate and emits its own event. |

After deployment this is the only path that makes the snapshot atomic. Without it, a
migration depends on a coordinated marketplace shutdown and any post-snapshot P2P transfer is
silently unhonoured.

**Crafting pauses while frozen — by design.** `Crafting` burns recipe inputs through
`MODULE_ROLE`. Because the freeze blocks `_update` and therefore `burn`, a craft attempt
while frozen reverts. That is intended: item supply must not change underneath the snapshot.
The client must show *"crafting paused for migration"* rather than surfacing a raw
`ContractFrozen` revert, and that UI copy belongs in the migration announcement, not in a
release note afterwards. The same applies to anything else that burns — currently only
crafting.

---

## 5. Snapshot

- Source of truth: `TransferSingle` / `TransferBatch` logs from genesis, or the self-hosted
  indexer's balances **at block N**. Compute it twice by two independent methods; a mismatch
  is an abort condition.
- Cross-check every id: `sum(balances) == totalSupply(id) == minted(id) - burned(id)`.
- Output: a manifest `[{account, itemTypeId, amount}]`, hashed into a merkle tree.
- Publish the manifest and its root; the root is committed on-chain by V2.

---

## 6. V2 and the claim contract

- V2 registers the **same ids, same contentHash, same metadataURI** so client-side asset
  verification keeps working unchanged.
- Deploy `ItemMigration` holding `MODULE_ROLE` on V2. It is the only minter.

```
leaf   = keccak256(bytes.concat(keccak256(abi.encode(chainId, v1, v2, account, itemTypeId, amount))))
claim  = verify(proof, root, leaf) -> mark claimed[account][itemTypeId] -> mint on V2
```

- The leaf is domain-separated by chain, V1 address and V2 address, so a proof cannot be
  replayed on another chain or against another pair of registries.
- One claim per `(account, itemTypeId)`; the flag is set before the mint (CEI).
- **No expiry.** A player who never claims stays unclaimed forever — the same honesty as
  the sealed-Prime limitation. A UI banner and an `unclaimed()` view are the mitigation.

---

## 7. Reconciliation after the claim window

- `V2.totalSupply(id) == Σ claimed(id)` and `≤ V1.outstanding(id)` for every id.
- Publish an address → claimed report; spot-check a random sample of holders.
- Invariant in V2 tests: no address can claim twice, and no id can exceed its imported
  outstanding amount.

---

## 8. Edge cases

| Case | Handling |
|---|---|
| Marketplace escrow | Must be emptied before snapshot, else items migrate to the escrow contract, not the player |
| Smart-contract accounts | Claim from their own address; gas sponsored through the paymaster |
| Dust / spam airdrops | Included by default. Excluding small balances would strand small holders; if exclusion is ever used it must be announced and bounded |
| Accounts that never claim | Stranded in V1 by choice; keep the claim path open indefinitely |
| Post-snapshot transfers in V1 | Not honoured. Freezing (§4a) prevents them entirely |

---

## 9. Abort conditions

Stop and roll back the announcement if any of these hold:

- snapshot totals disagree with on-chain `totalSupply`/`minted`/`burned`;
- V2 cap is insufficient for any id;
- marketplace escrow is not fully emptied;
- the V1 freeze did not take effect (path a);
- any required signer is unavailable.

---

## 10. Effort

Roughly 2–3 engineer-days: claim contract + tests (1), indexer snapshot + merkle manifest
(1), rehearsal + runbook (0.5). The expensive part is the public coordination, not the code.

---

## 11. What this document is not

It is not a reason to design V1 carelessly. A migration costs player trust even when it is
executed perfectly, and a schema change is worth doing **once**. The goal is that if we ever
need it, no player loses an item because of it.
