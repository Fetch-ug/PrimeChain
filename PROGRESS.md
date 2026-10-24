# PROGRESS.md

A fresh session should be able to read this file plus [DECISIONS.md](DECISIONS.md) and continue without re-deriving anything.

**Current phase:** 1 — Local devnet + Prime token
**Status:** 1A in CI round 2 — round 1: `secrets` ✅, `contracts` ❌ at `forge build` (fixed); 1B **blocked on a Docker host**
**Last updated:** 2026-10-24

---

## Phase tracker

| Phase | Scope | Status | Gate |
|---|---|---|---|
| 0 | Architecture decision + threat model | ✅ approved 2026-10-24 | — |
| 1 | Local devnet + Prime token | 🟡 1A packaged, awaiting CI / 1B blocked | CI result; Docker host for 1B |
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

### Phase 1A acceptance criteria — actual status

| Criterion | Status |
|---|---|
| Token has no externally reachable mint path | ✅ by construction (single internal call in constructor) |
| `forge build` green | ❌ run 1 failed (`Error 9582`, fixed) — awaiting run 2 |
| `forge test` + invariants green | ⬜ never reached (build failed first) |
| 100% coverage gate green | ⬜ never reached |
| Devnet boots; `smoke.py` passes | ⬜ blocked — no Docker |

I am not marking those boxes. Only a CI run (or a machine with Foundry v1.8.6) can flip them, and per ADR-012 I will not claim a test result I have not seen.

### Phase 1B blocker

The OP Stack devnet needs Docker and outbound image pulls, neither of which exists here. Additionally, the upstream `optimism` root `Makefile` at `op-node/v1.19.11` declares its own targets **deprecated** (`DEPRECATED_TARGETS`, `include ./justfiles/deprecated.mk`), so the old `make devnet-up` path is gone and the current path is `just` recipes. Rather than invent those recipe names, `infra/devnet/devnet.sh` is discovery-first: it clones the pinned tag, prints `just --list`, and `devnet.sh devnet` boots the **single** recipe matching `*devnet*` — refusing to guess if there is more than one.

**I have no outbound network and no remote-execution tool, so I cannot drive an external Docker host or trigger GitHub Actions myself.** Closing 1B requires one of:

1. **CI (preferred):** push this tree to a GitHub repo with Actions enabled. `contracts.yml` then runs build → test → invariant → coverage → **anvil deploy + RPC smoke** on its own, which proves the token and `smoke.py` without Docker.
2. **Docker host:** copy the tree to a machine with Docker + internet and run `./infra/devnet/devnet.sh stack && ./infra/devnet/devnet.sh devnet`, then `smoke.py`. That is the only path that exercises the real OP Stack (L1, sequencer, batcher, replicas).

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

**To close Phase 1:**
- [ ] Push to GitHub and run `contracts` workflow once; record run ID and result here
- [ ] On a Docker host: `./infra/devnet/devnet.sh stack` → `recipes` → resolve op-geth pin → boot
- [ ] Run `infra/devnet/smoke.py` and paste the PASS/FAIL table into this file
- [ ] Deploy `Prime` to the devnet and confirm the treasury balance via `eth_call`

**Phase 2 (after Phase 1 sign-off):**
- [ ] `Treasury` + `RewardDistributor` with on-chain epoch caps (needs D4)
- [ ] `ItemRegistry` (ERC-1155, content hashes), `Crafting`, `Marketplace`, `Storage`, `FeeSink`
- [ ] Safe 4/7 + `TimelockController` wiring and a deployment runbook
- [ ] Storage-layout diff check in CI
