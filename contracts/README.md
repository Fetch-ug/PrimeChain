# Prime contracts

Foundry project for PrimeChain. Phase 1 delivers the **Prime** token; the rest of
the contract suite lands in Phase 2.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| Solidity | `0.8.28` (`evm_version = cancun`) | `foundry.toml` |
| Foundry | `v1.8.6` | CI (`foundry-toolchain@v1`) |
| OpenZeppelin Contracts | `v5.7.0` @ `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | `scripts/bootstrap-deps.sh` |
| forge-std | `v1.17.0` | `scripts/bootstrap-deps.sh` |

There are no floating versions anywhere. `bootstrap-deps.sh` verifies the
OpenZeppelin commit SHA after cloning, so a moved tag fails the build instead of
silently changing the dependency.

## Quickstart

```bash
cd contracts
bash scripts/bootstrap-deps.sh   # clones the two pinned dependencies into lib/
forge build
forge test -vvv
forge coverage --report lcov && python3 scripts/check_coverage.py lcov.info
```

Requires Foundry `v1.8.6` or newer on `PATH`. Invoke the bootstrap script via
`bash` — the checkout may not carry the executable bit on Windows.

> The first CI run may need a formatting-only commit (`forge fmt`), because
> `forge fmt --check` is enforced in CI and the formatter was not available
> during authoring.

## What is tested, and why it is enough for the supply guarantee

`src/Prime.sol` has no owner, no role, no setter, no proxy and **no external mint
function**. The whole supply is minted in the constructor to one treasury address.
That claim is backed by three independent checks:

1. `test_NoMintSelectorExists` — `mint(address,uint256)` and `mint(uint256)` both
   fail to execute on the deployed token.
2. `testFuzz_TotalSupplyCannotBeInflated` — fuzzes `mint`, `setTotalSupply` and
   `burn` selectors against the token and asserts supply is unchanged.
3. `invariant_TotalSupplyIsConstant` and `invariant_BalancesSumToTotalSupply` —
   stateful fuzzing over thousands of transfer/transferFrom sequences; supply is
   constant and balances always sum to it.

Plus `test_GenesisEmitsTransferAndGenesisMint` for indexer correctness, the full
ERC-20 happy path, and the exact OZ v5.7.0 revert paths for the failure cases.

Coverage is gated at **100% lines, functions and branches** for `src/Prime.sol`
(`scripts/check_coverage.py`). The gate fails the build rather than printing a
warning.

## Deploying

The constructor mints to `PRIME_TREASURY`, **not** to `msg.sender`. A compromised
deployer key therefore cannot redirect genesis supply.

```bash
PRIME_TREASURY=0xYourSafeOrTimelock \
forge script script/DeployPrime.s.sol:DeployPrime \
  --rpc-url $PRIME_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast
```

Local smoke test without a full devnet (Foundry's `anvil` is enough):

```bash
anvil &
PRIME_TREASURY=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
forge script script/DeployPrime.s.sol:DeployPrime \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

In production `PRIME_TREASURY` must be the Safe or the Timelock, never an EOA
(ADR-009).

## Deliberate omissions

`ERC20Permit`, `ERC20Pausable` and `ERC20Burnable` were each considered and
rejected for v1 — reasons are recorded in the NatSpec header of `Prime.sol`. The
short version: fewer signature surfaces, no admin pause on money, and burning is a
game-design policy that belongs in a sink contract, not in the token.

## Status of this phase

The test suite is written but has **not been executed** — the authoring
environment has no Solidity toolchain and no outbound TLS (see
[DECISIONS.md](../DECISIONS.md) ADR-012). The GitHub Actions workflow
`.github/workflows/contracts.yml` is the source of truth: a green run there is
what "tested" means for this repository. Do not treat this README as evidence
that the suite passes.
