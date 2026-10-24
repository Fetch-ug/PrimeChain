# Devnet — Phase 1B

**Status: NOT DEPLOYED. The devnet has not been booted.** The authoring
environment has no Docker, no WSL and no outbound TLS, so an OP Stack devnet
cannot be started, and I will not ship a compose file whose `op-node`/`op-geth`
flags I could not verify against a running stack. Guessing those flags would
produce a stack that fails at boot and teaches nobody anything.

This directory therefore contains the **verified runbook and acceptance checks**,
not a fabricated compose file.

---

## What is verified today

| Fact | Source |
|---|---|
| `op-node` image is published per release: `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.19.11` | `op-node v1.19.11` release notes, 2026-10-22 |
| The optimism repo's root `Makefile` at `op-node/v1.19.11` lists its build/test targets as **deprecated** and includes `justfiles/deprecated.mk` | raw `Makefile` at that tag |
| `op-geth` is versioned separately from `op-node` | separate repository (`ethereum-optimism/op-geth`) |

That last row matters operationally: **do not assume `op-geth` and `op-node` share
a version number.** Resolve the op-geth tag from its own releases and record it in
`versions.env` before the first boot.

---

## Path to boot it (on a machine with Docker)

The upstream project has moved its developer workflow from `make` to `just`. The
sequence below is discovery-first on purpose: it asks the pinned checkout what it
supports, instead of hard-coding recipe names that may have changed.

```bash
# 1. Pinned checkout of the stack we intend to run
./infra/devnet/devnet.sh stack     # clones optimism at op-node/v1.19.11 into _stack/optimism

# 2. Ask the pinned tree which devnet recipes exist (do not guess)
./infra/devnet/devnet.sh recipes   # runs `just --list` in _stack/optimism

# 3. Resolve the op-geth tag in versions.env, then boot. The script selects the
#    single recipe matching *devnet* from the pinned tree and refuses to guess
#    if more than one exists.
./infra/devnet/devnet.sh devnet

#    If it reports multiple candidates, run the intended one explicitly:
#    ( cd infra/devnet/_stack/optimism && just <recipe> )

# 4. Acceptance checks against the running L2
PRIME_ADDRESS=0x... PRIME_TREASURY=0x... CHAIN_ID=... \
  python3 infra/devnet/smoke.py http://localhost:8545
```

`smoke.py` uses only the standard library and plain `eth_*` JSON-RPC, so it works
against any OP Stack node, local or testnet.

## What "devnet" means here (and what it must not pretend to be)

The Phase 1 devnet is **1 sequencer + 2 verifier replicas** on a local L1. It is
*not* a 3-validator network, because OP Stack has no validator set to make three
of (see [ARCHITECTURE.md](../../ARCHITECTURE.md) §5.1). The replicas exist to prove
that independent derivation works and to give the game two RPC endpoints — not to
provide Byzantine fault tolerance. Calling them "validators" would be the kind of
marketing that eventually becomes a security incident.

## Acceptance criteria (Phase 1B)

- [ ] `eth_chainId` returns the chain ID configured in genesis
- [ ] `eth_blockNumber` advances over a 5s window (sequencer producing)
- [ ] Both replicas return the same block hash at the same height
- [ ] `eth_getCode(PRIME_ADDRESS)` is non-empty
- [ ] `totalSupply()` == `2_000_000_000e18`
- [ ] `balanceOf(TREASURY)` == `totalSupply()`
- [ ] Deployment transaction is visible in Blockscout at the expected address

All but the Blockscout item are automated in `smoke.py`.
