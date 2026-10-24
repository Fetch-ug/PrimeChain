#!/usr/bin/env python3
"""Phase 1B acceptance checks for a PrimeChain devnet.

Stdlib only (no web3 dependency) and plain eth_* JSON-RPC, so it works against a
local OP Stack node, a testnet node, or a replica.

Usage:
    PRIME_ADDRESS=0x... PRIME_TREASURY=0x... CHAIN_ID=... \
        python3 smoke.py http://localhost:8545

Exit codes: 0 = all checks passed, 1 = at least one failed, 2 = bad usage.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

TOTAL_SUPPLY = 2_000_000_000 * 10**18  # 2e27, 18 decimals
SEL_BALANCE_OF = "0x70a08231"
SEL_TOTAL_SUPPLY = "0x18160ddd"
SEL_DECIMALS = "0x313ce567"

failures: list[str] = []
warnings: list[str] = []


def rpc(url: str, method: str, params: list | None = None):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    request = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = json.loads(response.read().decode())
    except urllib.error.URLError as exc:
        raise SystemExit(f"FATAL: cannot reach {url}: {exc}") from exc
    if "error" in body:
        raise RuntimeError(f"{method} failed: {body['error']}")
    return body["result"]


def pad_address(address: str) -> str:
    return address.lower().replace("0x", "").rjust(64, "0")


def eth_call(url: str, to: str, data: str) -> int:
    result = rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])
    return int(result, 16) if result and result != "0x" else 0


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}  {detail}")
        failures.append(label)


def main(argv: list[str]) -> int:
    url = os.environ.get("L2_RPC_URL", "http://localhost:8545")
    if len(argv) > 1:
        url = argv[1]

    prime = os.environ.get("PRIME_ADDRESS", "")
    treasury = os.environ.get("PRIME_TREASURY", "")
    expected_chain_id = os.environ.get("CHAIN_ID", "")

    if not prime or not treasury:
        print("ERROR: set PRIME_ADDRESS and PRIME_TREASURY", file=sys.stderr)
        return 2

    print(f"PrimeChain devnet smoke test → {url}")

    # 1. Chain identity
    chain_id = int(rpc(url, "eth_chainId"), 16)
    if expected_chain_id:
        check("chain id matches configuration", chain_id == int(expected_chain_id), f"got {chain_id}")
    else:
        warnings.append(f"CHAIN_ID unset; observed {chain_id}")

    # 2. Sequencer is producing
    first = int(rpc(url, "eth_blockNumber"), 16)
    time.sleep(5)
    second = int(rpc(url, "eth_blockNumber"), 16)
    check("block number advances within 5s", second > first, f"{first} → {second}")

    # 3. Contract is deployed
    code = rpc(url, "eth_getCode", [prime, "latest"])
    check("Prime has bytecode", code not in ("0x", "0x0", ""), f"got {code[:10]}…")

    # 4. Supply invariants
    total = eth_call(url, prime, SEL_TOTAL_SUPPLY)
    check("totalSupply == 2,000,000,000e18", total == TOTAL_SUPPLY, f"got {total}")

    balance = eth_call(url, prime, SEL_BALANCE_OF + pad_address(treasury))
    check("treasury holds the entire supply", balance == TOTAL_SUPPLY, f"got {balance}")

    decimals = eth_call(url, prime, SEL_DECIMALS)
    check("decimals == 18", decimals == 18, f"got {decimals}")

    # 5. Optional: the emission distributor is deployed (bytecode present).
    #    The allocation value itself is asserted by DeployRewardDistributor.s.sol,
    #    which the deploy-smoke job runs; this check proves the deployment landed.
    distributor = os.environ.get("REWARD_DISTRIBUTOR", "")
    if distributor:
        distributor_code = rpc(url, "eth_getCode", [distributor, "latest"])
        check(
            "RewardDistributor has bytecode",
            distributor_code not in ("0x", "0x0", ""),
            f"got {distributor_code[:10]}…",
        )

    # 6. Replica consistency (same height, same hash)
    replicas = os.environ.get("L2_REPLICA_RPC_URLS", "").split()
    for replica in replicas:
        try:
            block = rpc(url, "eth_getBlockByNumber", [hex(second), False])
            replica_block = rpc(replica, "eth_getBlockByNumber", [hex(second), False])
            if replica_block is None:
                warnings.append(f"{replica} has not reached block {second} yet")
                continue
            check(f"replica agrees at height {second} ({replica})", block["hash"] == replica_block["hash"])
        except RuntimeError as exc:
            warnings.append(f"{replica}: {exc}")

    for warning in warnings:
        print(f"  WARN  {warning}")

    if failures:
        print(f"\nFAILED: {len(failures)} check(s)")
        return 1

    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
