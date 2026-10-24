# Dependencies

Principle: **every dependency is pinned to an exact released version and fetched by
a script that runs in CI.** No `latest`, no floating ranges, no git submodules
(they break on fresh clones unless the parent repo exists), no postinstall scripts.

## Contract build chain

| Dependency | Pinned version | Installed by | Fresh clone in CI? |
|---|---|---|---|
| Solidity compiler | `0.8.28` | Foundry downloads it into `~/.svm` on first build; pinned via `solc_version` in [`contracts/foundry.toml`](contracts/foundry.toml) | ✅ deterministic |
| Foundry | `v1.8.6` | `foundry-rs/foundry-toolchain@v1` with `version: v1.8.6` | ✅ |
| OpenZeppelin Contracts | `v5.7.0` @ `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | `bash contracts/scripts/bootstrap-deps.sh` → clones into `contracts/lib/` (git-ignored) and **verifies the commit SHA** | ✅ CI runs it before every build |
| forge-std | `v1.17.0` | same script | ✅ |

Because `contracts/lib/` is git-ignored, a fresh clone has no dependencies until
`bootstrap-deps.sh` runs. Every CI job that compiles runs it as its first step
after checkout. If you ever build locally:

```bash
cd contracts && bash scripts/bootstrap-deps.sh && forge build
```

## Why not `forge install` / submodules

`forge install` writes a git submodule and a `.gitmodules` pin. That is fine when
the parent repo already exists, but it is the most common cause of "works for me,
fails in CI" for a tree that is handed over as files. The script is explicit,
greppable and verifies OpenZeppelin's commit SHA, so a force-moved tag fails the
build instead of silently changing the dependency (ADR-014).

## Scripting / tooling

| Tool | Version | Notes |
|---|---|---|
| Python (CI) | `3.12` via `actions/setup-python@v5` | `scripts/scan_secrets.py`, `contracts/scripts/check_coverage.py`, `infra/devnet/smoke.py` are **stdlib only** — no `pip install` anywhere |
| Python (authoring) | `3.14.5` | same scripts, no third-party packages |
| Node / pnpm | not used | the Godot SDK phase will add them, pinned |

## GitHub Actions

| Action | Ref | Notes |
|---|---|---|
| `actions/checkout` | `@v4` | |
| `actions/setup-python` | `@v5` | |
| `actions/upload-artifact` | `@v4` | |
| `foundry-rs/foundry-toolchain` | `@v1` | `version: v1.8.6` |

These are pinned by **release tag, not commit SHA**. Tag → SHA pinning is a
Phase 6 hardening item (a compromised tag is a real, if rare, supply-chain
vector). Recorded here rather than silently ignored.

## Deliberately not present yet

| Dependency | Why | When |
|---|---|---|
| Slither | The only install path is `pip install slither-analyzer`, and I could not verify a current version offline. Shipping an unpinned security job would violate the pinning rule **and** produce noise on every push. | Phase 6, pinned and blocking, after triage |
| gitleaks / trufflehog | Replaced for now by `scripts/scan_secrets.py` (stdlib, deterministic, zero supply chain) | Phase 6 |
| Blockscout, op-geth, op-node images | Devnet only; pinned in [`infra/devnet/versions.env`](infra/devnet/versions.env) | Phase 1B / Phase 5 |
| Godot / Nethereum / libsecp256k1 | Phase 4 | Phase 4 |
