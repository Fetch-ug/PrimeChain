# PROGRESS.md

A fresh session should be able to read this file plus [DECISIONS.md](DECISIONS.md) and continue without re-deriving anything.

**Current phase:** 1 — Local devnet + Prime token
**Status:** Phase 2 in progress — `RewardDistributor` + tests written, **awaiting CI**. Phase 1B open (rented server).
**Last updated:** 2026-10-24

---

## Phase tracker

| Phase | Scope | Status | Gate |
|---|---|---|---|
| 0 | Architecture decision + threat model | ✅ approved 2026-10-24 | — |
| 1 | Local devnet + Prime token | ✅ **1A done** (CI run #4) · ⬜ 1B open | rented server for 1B |
| 2 | Game contracts | 🟡 `RewardDistributor` written, awaiting CI; 5 contracts not started | CI green before the rest |
| 2 | Game contracts (items, crafting, market, storage, fees) | ⬜ not started | D2, D4 answered |
| 3 | Paymaster, bundler, gateway | ⬜ not started | — |
| 4 | Godot SDK + demo | ⬜ not started | D5 answered |
| 5 | Testnet deployment | ⬜ not started | D6 answered |
| 6 | Hardening + audit readiness | ⬜ not started | — |

---

## CI log (append-only)

### Run 1 — 2026-10-24

| Workflow | Result | Detail |
|---|---|---|
| `secrets` | ✅ passed | no credentials found |
| `contracts` | ❌ failed at `forge build --sizes` | `Error (9582): Member "TOTAL_SUPPLY" not found or not visible after argument-dependent lookup in type(contract Prime)` at `script/DeployPrime.s.sol:32:40` |

**Root cause.** `TOTAL_SUPPLY` is a `public constant`. In Solidity that generates an
*instance* getter; it is **not** a member of the contract *type*, so
`Prime.TOTAL_SUPPLY` is a compile error. (The code never reached tests, so this was
the only error reported — the same pattern was present in
`test/Prime.invariants.t.sol` and had not been reached yet.)

**Fix (all three places, plus an audit of every identifier).**

| File | Change |
|---|---|
| `contracts/script/DeployPrime.s.sol` | `Prime.TOTAL_SUPPLY` → local `EXPECTED_SUPPLY` literal. Better than the getter: asking the contract to confirm its own constant proves nothing; a literal fails the deploy if supply ever changes. Also `uint256(prime.decimals())` to remove `console2` overload ambiguity, and the supply log now uses `totalSupply()`. |
| `contracts/test/Prime.invariants.t.sol` | added local `TOTAL` constant; 4 × `Prime.TOTAL_SUPPLY` → `TOTAL` |
| `contracts/test/Prime.t.sol` | removed the last `prime.TOTAL_SUPPLY()` getter assertion (redundant with the genesis test) so nothing depends on the constant getter anywhere |

**Identifier audit after the fix:** no type-level constant access remains anywhere;
`TOTAL_SUPPLY` now appears only as (a) the declaration in `Prime.sol`, (b) internal
constructor uses, (c) prose in docs. `smoke.py` uses its own independent literal.
`PrimeHandler.transfer.selector` / `.transferFrom.selector` are function selectors
(valid). Remaining type-scoped error selectors (`Prime.InvalidTreasury`,
`IERC20Errors.*`) use the container-scoped error form, which is the standard
OpenZeppelin v5 test pattern.

**Awaiting:** run 2.

### Run 2 — commit `c65543b` — 2026-10-24

| Workflow | Result | Detail |
|---|---|---|
| `secrets` | ✅ passed | |
| `contracts` → build | ✅ passed | the `TOTAL_SUPPLY` fix worked |
| `contracts` → 16 unit/fuzz tests | ✅ passed | all `Prime.t.sol` tests green |
| `contracts` → invariant suite | ❌ failed | `invariant_BalancesSumToTotalSupply`: "handler never executed a transfer: 0 <= 0" — `transferCalls == 0` after 262,144 calls |

**Root cause.** The fixture was empty: actors were never funded, so every handler
action hit its `balance == 0` guard and returned without doing anything. The three
invariants then passed **vacuously** — `sum(0 + 0…) == totalSupply` only because the
treasury still held everything, and supply never changed because nothing changed.
The `afterInvariant()` guard is what exposed it; without that guard this would have
been reported as "invariant tests green", which is exactly the kind of false
confidence that gets repeated to an auditor.

**Fix (one file).**

| File | Change |
|---|---|
| `contracts/test/Prime.invariants.t.sol` | `setUp` funds each of 4 actors with `1_000_000e18` from the treasury (`vm.startPrank`), sets standing mutual `type(uint256).max` approvals so the pull path can execute, and extends the vacuity guard to `transferFromCalls`. `PrimeHandler` unchanged. |

**Handler review (requested).** No other vacuous path found: both actions early-return
only on a zero balance, which is now reachable-but-not-universal; `bound(amount, 1,
balance)` guarantees the transfer cannot revert on insufficient funds; the handler's
per-call `approve(amount)` overwrites the standing max approval, so the fuzzed path is
the **allowance-decrement** branch (the infinite-allowance branch stays covered by the
unit test `test_InfiniteAllowanceIsNotDecremented`). `fail_on_revert = true`, so any
handler revert would fail the run rather than be silently swallowed.

**Awaiting:** run 3.

### Run 3 — commit `1778bb9` — 2026-10-24

| Workflow | Result | Detail |
|---|---|---|
| `secrets` | ✅ passed | |
| `contracts` → build | ✅ passed | |
| `contracts` → invariant suite | ✅ passed | 3 invariants, **~130k transfer + ~130k transferFrom calls, 0 reverts** — the fixture fix worked and the suite is no longer vacuous |
| `contracts` → unit/fuzz | ❌ 1 failure | `testFuzz_TransfersPreserveSupply`, run 131: counterexample `amount=750e18`, `recipient=treasury` → `2000000750…e18 != 2000000000…e18` |

**Root cause (test, not token).** The test asserted `balanceOf(treasury) + amount == TOTAL`,
which assumes the recipient is not the treasury. When `from == to` the token correctly
does nothing (OZ `_update` decrements then re-increments the same slot) but the
assertion adds `amount` that never left. Classic double-count, same family as the
previous vacuity bug: the expectation was written for the common case only.

**Fix (one file).** Branch on `recipient == treasury`:
* self-transfer → assert the treasury balance is **unchanged** (and the token still
  emits `Transfer`, which `test_SelfTransferIsNoOp` pins down separately);
* otherwise → assert the exact sender/recipient deltas and that the pair sums to the
  pre-transfer balance;
* the pair-sum assertion lives **inside** the `else` — summing the same account twice
  would double-count it, which is the very mistake being fixed.

**Verified against the failing seed by hand:** `amount=750e18`, `recipient=treasury`,
`treasuryBefore=2e27` → `_update` sets `2e27-750e18` then `+750e18` → `2e27`;
`totalSupply` unchanged; self-branch passes.

**Same-pattern audit.**
* `testFuzz_TotalSupplyCannotBeInflated` — no from/to pair, unaffected.
* `PrimeHandler.transfer` — `from == to` is legal: `transfer(self, amount)` nets to zero,
  emits an event, increments the counter; no assertion assumes distinctness.
* `PrimeHandler.transferFrom` — `owner == spender == to` is the harshest overlap: it sets
  a self-allowance of exactly `amount`, then `_spendAllowance` decrements it to zero while
  the balance nets to zero. No revert, and the sum invariant is unaffected.
* Coverage: self-transfer is now exercised in the unit suite *and* under stateful fuzz.

**Awaiting:** run 4.

### Run 4 — commit `de80f1b` — 2026-10-24 — ✅ **GREEN**

Run: https://github.com/Fetch-ug/PrimeChain/actions/runs/40079845155

| Workflow / job | Result |
|---|---|
| `secrets` | ✅ |
| `contracts` → build / test / invariant / coverage | ✅ all steps passed |
| → Enforce 100% coverage on token logic | ✅ passed (the gate is real, not decorative) |
| `contracts` → deploy + RPC smoke (anvil) | ✅ passed |
| `Format check (advisory in Phase 1)` | ⚠️ exited 1 — **advisory only**, `continue-on-error: true` |

The job-level "exit code 1" annotation in the UI comes from the advisory format
step; it does not fail the job and does not block. **Exactly one step in the whole
pipeline is advisory** — every other step blocks (see the gate table below).

**Phase 1A is complete.**



| Artefact | Contents |
## Phase 0 — what was produced

| Artefact | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Decision (OP Stack), scoring matrix for all three options, target architecture, consensus/decentralisation ladder, token model, fee model, 4337 sponsorship design, on-chain data model, Godot client design, phone verification tiers, delivery plan, decision gates, verified version table |
| [THREAT_MODEL.md](THREAT_MODEL.md) | STRIDE per component and trust boundary, attack walkthroughs for the eight named threats, prioritised risk register, engineering controls that become CI gates |
| [DECISIONS.md](DECISIONS.md) | ADR-001 … ADR-012 with context, consequences and rejected alternatives |
| [PROGRESS.md](PROGRESS.md) | this file |
| [README.md](README.md) | repo orientation |

**Housekeeping:** `.github/workflows/_probe.yml` is a sandbox capability probe, clearly labelled; delete it in Phase 1. The Phase 0 files are **not committed to git** — `git init` is blocked in this environment (see constraints below). Hand them over as files, or initialise the repository on the target machine; no work is lost, only history.

---

## Phase 1 — what was produced

| Artefact | Contents | Executed? |
|---|---|---|
| `contracts/src/Prime.sol` | 2,000,000,000e18, minted once in the constructor; no mint function, no owner, no proxy | ❌ not compiled here |
| `contracts/test/Prime.t.sol` | 16 unit + fuzz tests, including "mint selector does not exist" and "supply cannot be inflated" | ❌ |
| `contracts/test/handlers/PrimeHandler.sol` | stateful fuzz handler (transfer + approve/transferFrom, actors only) | ❌ |
| `contracts/test/Prime.invariants.t.sol` | INV-1 supply constant, INV-2 balances sum to supply, INV-3 no balance exceeds supply, plus a vacuity guard | ❌ |
| `contracts/script/DeployPrime.s.sol` | deploys to an **existing** treasury; mints to `PRIME_TREASURY`, never to `msg.sender` | ❌ |
| `contracts/scripts/bootstrap-deps.sh` | pins OpenZeppelin v5.7.0 by commit SHA and forge-std v1.17.0 | ❌ |
| `contracts/scripts/check_coverage.py` | 100% line/function/branch gate parsed from lcov | ❌ |
| `.github/workflows/contracts.yml` | fmt → build → test → coverage gate; **anvil deploy + RPC smoke**; slither advisory until Phase 6 | ❌ never run |
| `infra/devnet/{README,versions.env,devnet.sh,smoke.py}` | pinned runbook + real `eth_*` acceptance checks | ❌ never run |

### Phase 1A acceptance criteria — final status

| Criterion | Status |
|---|---|
| Token has no externally reachable mint path | ✅ by construction (single internal call in constructor) |
| `forge build` green | ✅ run #4 |
| `forge test` + invariants green | ✅ 16 unit/fuzz + 3 invariants (~130k transfer + ~130k transferFrom calls, 0 reverts) |
| 100% coverage gate green | ✅ enforced and passed |
| Deploy + RPC smoke (anvil) | ✅ passed — deploy, `totalSupply`, `balanceOf`, `decimals` over JSON-RPC |
| **Real OP Stack devnet boots; `smoke.py` passes** | ⬜ **1B — open**, needs a rented Docker server |

### Which CI gates actually block

| Workflow | Step | Blocks the job? |
|---|---|---|
| `contracts` | bootstrap deps | ✅ yes |
| `contracts` | **Format check** | ⚠️ **no** — `continue-on-error: true`, Phase 1 only |
| `contracts` | build / test / coverage / 100% coverage gate | ✅ yes |
| `contracts` | upload coverage artifact (`if: always()`) | n/a |
| `contracts` → `deploy + RPC smoke` | every step, incl. `smoke.py` | ✅ yes |
| `secrets` | `python3 scripts/scan_secrets.py` | ✅ yes |
| `format` | all | n/a — manual `workflow_dispatch` only |
| `_probe.yml` | all | n/a — git-ignored, excluded from the zip |

**Exactly one advisory step exists in the whole pipeline.** When Phase 6 lands,
`Format check` becomes blocking and Slither is added (pinned) as a second gate.

### Phase 1 close-out

**Proven (by execution, not by inspection):**

- `Prime` compiles against OpenZeppelin v5.7.0 with solc 0.8.28 and deploys.
- Supply is 2e27, entirely at the treasury, and no `mint`/`setTotalSupply`/`burn`
  selector is callable on the deployed bytecode.
- ERC-20 semantics behave (transfers, allowances, infinite allowance, self-transfer,
  zero-address rejections) under 16 unit/fuzz tests.
- The three supply invariants hold under stateful fuzzing with real token movement.
- 100% line/function/branch coverage on `src/Prime.sol`, enforced by a gate that fails
  the build.
- Deployment to a live EVM node works end-to-end and the deployed values are readable
  over plain `eth_call` (the same path the Godot client will use).
- No credentials in the tree, checked on every push.

**Not proven:**

- **The OP Stack chain itself never ran.** No L1, no sequencer, no batcher, no replicas,
  no bridge. `anvil` is a single EVM node and says nothing about OP Stack behaviour.
- Blockscout, monitoring, and the devnet compose path are unexercised.
- Gas costs, block cadence and data-availability cost on a real OP chain are unmeasured.
- Nothing has been audited by a third party.

**Known limitations:**

- `Prime` is immutable: a bug requires a new token and a migration, by design.
- No pause, no permit, no burn — deliberate (ADR-013), but it means a compromised
  distributor cannot be stopped by pausing the token, only by pausing the distributor.
- The format gate is advisory, so formatting drift is possible until Phase 6.
- Creator/distributor of the token is a single deployment key; it receives nothing, but
  the deployment transaction itself is not yet reproducible across machines.

### Phase 1B blocker (open, not abandoned)

The OP Stack devnet needs Docker and outbound image pulls, neither of which exists here. Additionally, the upstream `optimism` root `Makefile` at `op-node/v1.19.11` declares its own targets **deprecated** (`DEPRECATED_TARGETS`, `include ./justfiles/deprecated.mk`), so the old `make devnet-up` path is gone and the current path is `just` recipes. Rather than invent those recipe names, `infra/devnet/devnet.sh` is discovery-first: it clones the pinned tag, prints `just --list`, and `devnet.sh devnet` boots the **single** recipe matching `*devnet*` — refusing to guess if there is more than one.

**Plan (client decision, 2026-10-24): 1B is proven on a rented server before testnet.**
CI covers the anvil smoke path; it cannot cover L1 + sequencer + batcher + replicas.
When a Docker host exists, the sequence is: `./infra/devnet/devnet.sh stack` →
`./infra/devnet/devnet.sh recipes` → resolve the `op-geth` pin → `./infra/devnet/devnet.sh devnet` →
`python3 infra/devnet/smoke.py`, and the PASS/FAIL table is pasted into this file.
Acceptance for 1B stays as written in [`infra/devnet/README.md`](infra/devnet/README.md).

Send back the workflow run URL (or the `smoke.py` PASS/FAIL table) and I will record the result here.



## Verification log

Everything below was checked against a primary source on 2026-10-24. Items I could **not** verify are listed separately and are deliberately not asserted anywhere in the docs.

**Verified**
- Ronin documents its consensus as **OP Stack**, chainId 2020, ~2s blocks (`docs.roninchain.com/developers/network`).
- Geth `master` still contains `consensus/clique` (GitHub contents API).
- Cosmos EVM is **pre-v1** and "undergoing changes while the code is being audited" (repo README).
- `op-node` `v1.19.11` published 2026-10-22 as a security release.
- OpenZeppelin Contracts `v5.7.0`: ships `Paymaster`, `PaymasterSigner`, `PaymasterERC20*`, `ERC4337Utils` (draft prefix removed), `ERC7913WebAuthnVerifier`.
- ERC-4337 is **Final**; uses `PackedUserOperation`, EIP-712 `userOpHash` bound to EntryPoint + chainId; `paymasterSignature` supported.
- Foundry `v1.8.6`; Godot `4.7.2` stable; Nethereum `7.0.0` (net8.0+).
- OP Stack docs contain pages for privileged roles, audit reports, custom gas token, subblocks.
- **Phase 1 additions:** OpenZeppelin `v5.7.0` `ERC20.sol` declares `pragma solidity ^0.8.20` and imports `interfaces/draft-IERC6093.sol` — so `0.8.28` compiles it and the error-selector import path used in the tests is real.
- `forge-std` latest is `v1.17.0` (2026-09-30); its release notes require Foundry `>=1.8.3` for the `Vm.Gas` struct layout, which we satisfy with `v1.8.6`.
- The `optimism` root `Makefile` at `op-node/v1.19.11` marks its targets **deprecated** and delegates to `justfiles/` — the devnet must be driven by `just`, not `make`.
- `op-node` publishes a per-release image: `…/images/op-node:v1.19.11`.

**Not yet verified — must be pinned in the phase that uses it (never guessed)**
- EntryPoint v0.8 canonical deployment address and the exact eth-infinitism deployment manifest format.
- Bundler choice (rundler vs alto): release, custom-chain support, OP Stack compatibility.
- Blockscout's current OP Stack deployment path and version.
- godot-cpp branch/tag matching Godot 4.7.x; libsecp256k1 tag; keccak implementation choice and licence.
- Slither version (CI currently installs latest; must be pinned in Phase 6) and whether `forge coverage` needs `--ir-minimum` for the Phase 2 contracts.
- OP Stack `op-deployer` stability and whether arbitrary L2 genesis alloc is supported (affects whether Prime is a genesis alloc or block-1 deployment).

---

## Environment constraints (read before planning work)

The authoring machine is **not** a build machine:

| Capability | State | Consequence |
|---|---|---|
| Docker / Compose | ❌ absent | Devnet compose files are authored and reviewed here, executed on a Docker host or CI |
| WSL2 | ❌ access denied | No Linux fallback locally |
| Admin rights | ❌ not available | Cannot install Docker Desktop or system toolchains |
| Outbound TLS from shell | ❌ blocked (`SEC_E_NO_CREDENTIALS`) | No `pip`/`npm`/`cargo`/binary downloads; only the `web_fetch` tool reaches the network |
| Foundry / solc | ❌ absent | Contracts cannot be compiled locally; CI is the source of truth |
| Node / Python | ✅ present | Useful for scripted generation and offline reference implementations |
| Shell file writes | ❌ blocked | Every file is authored through the harness file backend; shell redirection, `Out-File`, `mkdir` all fail |
| Hidden/dot directories | ⚠️ shell blocked, backend OK | `.github/workflows/` is writable via the file backend; `git init` is not |
| `git init` | ❌ blocked | Git 2.54.0 is installed but cannot create `.git`; **the repo must be initialized on the client machine or in CI** |

**Therefore:** [DECISIONS.md](DECISIONS.md) ADR-012 applies — all compilation, tests, coverage and static analysis run in GitHub Actions. I will never report "tests pass" unless CI output says so. Where a constant or test vector is needed offline, I will write a small pure-Python reference implementation and cross-check it against published EIP vectors before it is used in Solidity/GDScript.

---

## How to resume in a fresh session

1. Read this file, then [DECISIONS.md](DECISIONS.md) (current statuses), then [ARCHITECTURE.md](ARCHITECTURE.md) §13 (blocking decisions).
2. Check whether D1–D7 have been answered; record the answers as new ADRs (do not silently change existing ones).
3. Contract work can proceed without a running chain: `cd contracts && ./scripts/bootstrap-deps.sh && forge test`. The devnet (`infra/devnet/`) is a separate track and needs a Docker host.
4. Update this file at the end of every phase; append ADRs rather than editing them.

---

## Packaging & pre-push — 2026-10-24

Prepared for a machine with no Foundry and no Docker; CI is the only execution environment.

| Item | Result |
|---|---|
| Archive | `primechain-phase1.zip`, 28 entries, `.github/workflows` included and asserted by `scripts/package.ps1` |
| Manifest | `MANIFEST.sha256` inside the archive (SHA-256 per file) |
| Secrets scan | **clean** — `python3 scripts/scan_secrets.py` ran locally: 25 files scanned, 0 findings |
| only 64-hex literal in tree | Anvil's public dev key in `.github/workflows/contracts.yml`, labelled worthless |
| Dependencies | documented in [DEPENDENCIES.md](DEPENDENCIES.md); no submodules; `lib/` is git-ignored and re-fetched by `bootstrap-deps.sh` in every CI job |
| Pre-push steps | [PRE_PUSH_CHECKLIST.md](PRE_PUSH_CHECKLIST.md) |

**CI changes made during this review (all deliberate):**

1. `Format check` is `continue-on-error: true` for Phase 1, because no formatter existed here. A manual `format` workflow (workflow_dispatch) runs `forge fmt` and commits the fix — the only way to format without a local Foundry install.
2. Coverage now runs under `FOUNDRY_PROFILE=coverage` (small fuzz/invariant budget). Instrumented 2048-run invariants risked the job timeout; coverage depth is not the point, line/branch execution is.
3. The unpinned `slither-analyzer` install was **removed** from the gate: it violated the pinning rule and would have been noisy. It returns in Phase 6 pinned and blocking ([DEPENDENCIES.md](DEPENDENCIES.md)).
4. Added `secrets` workflow (`scripts/scan_secrets.py`, stdlib, no supply chain).
5. Added `timeout-minutes` to every job so a hung anvil or coverage run fails fast.
6. `deploy-smoke` now dumps the anvil log on failure.

**Still not executed:** `forge build`, `forge test`, `forge coverage`, `bash bootstrap-deps.sh`, `devnet.sh`, `smoke.py` against a real chain. Only CI can flip those.



## Known limitations (running list)

1. **`Prime` is immutable.** A bug requires a new token and a migration. Deliberate (ADR-013).
2. **No pause, no permit, no burn on the token.** A compromised distributor can only be
   stopped at the distributor, not at the token.
3. **Unclaimed sealed Prime is locked forever in V1.** The claim window is indefinite
   (Q6), so an unclaimed allocation is not recoverable and not re-allocatable: it still
   consumes `ALLOCATION` once sealed. Expiry is a **V2 design** and must not be bolted on.
4. **The format gate is advisory** until Phase 6, so formatting drift is possible.
5. **The OP Stack chain has never run.** Everything proven so far is single-node EVM
   behaviour; 1B is open.
6. **`RewardDistributor` allocates to one distributor per epoch scheme.** There is no
   on-chain notion of "why" a player was rewarded — the merkle manifest is the record.



## Client decisions received

**2026-10-24 — Phase 0 approved with recommended defaults.** Therefore:

| Decision | Resolution |
|---|---|
| D1 gas token | **Model A** — Prime is an immutable-supply ERC-20; gas is ETH and is sponsored (ADR-003) |
| D2 fee sink | **T1** — fees on game actions route to `FeeSink`; no transfer tax on Prime (ADR-004) |
| D3 "3 validators" | Accepted as **1 sequencer + 2 verifier replicas**, with §5.2 published (ADR-002) |
| D4 emissions | **Received 2026-10-24**: 1-day epochs, 500,000/epoch, 200/account/epoch, 1B lifetime ceiling, 1B reserve, no rollover — recorded in [DECISIONS.md](DECISIONS.md) **D4**, not yet implemented |
| D5 Godot crypto | GDExtension (C++ + libsecp256k1 + keccak) (ADR-006) |

Still outstanding before the phases that need them: **D6** (Safe signers, Phase 5), **D7** (audit firm, Phase 5). D4's three recommendations (epoch-cap upper bound, sealed-epoch allocation, reserve accounting) need a decision before Phase 2 implementation.

---

## Next actions

**Phase 1A — closed 2026-10-24** (CI run #4 green)

- [x] Push to GitHub and run `contracts` workflow; record run ID and result
- [x] Build, unit/fuzz, invariants, 100% coverage gate, deploy + RPC smoke all green
- [x] `secrets` green on every push

**Phase 1B — open, to be proven on a rented server before testnet**

- [ ] Provision a Docker host; `./infra/devnet/devnet.sh stack`
- [ ] Resolve the `op-geth` pin in `infra/devnet/versions.env` (currently `TODO-`)
- [ ] `./infra/devnet/devnet.sh devnet`, then `python3 infra/devnet/smoke.py`
- [ ] Paste the PASS/FAIL table here; accept against `infra/devnet/README.md`

**Phase 2 — plan written, awaiting approval**

- [ ] Client answers Q1–Q7 in [PHASE2_PLAN.md](PHASE2_PLAN.md) §10
- [ ] On approval: `RewardDistributor` first (it carries the money rules), then `FeeSink`,
  `ItemRegistry`, `Storage`, `Crafting`, `Marketplace`
- [ ] Add Slither (pinned, blocking) and storage-layout diff to CI before the first Phase 2 PR
