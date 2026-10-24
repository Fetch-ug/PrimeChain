#!/usr/bin/env python3
"""Fail the build when security-critical contracts are not fully covered.

Why a script instead of a `forge coverage` flag: coverage flags have changed
between Foundry releases, and the requirement here is specific — exactly 100%
line, function and branch coverage on the token and treasury logic. Parsing the
lcov report is version-stable and makes the threshold auditable in one place.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Files that must be at 100% across every metric. Add treasury/reward files here
# as they are implemented (Phase 2).
REQUIRED_FILES: tuple[str, ...] = ("src/Prime.sol", "src/RewardDistributor.sol")
THRESHOLD: float = 100.0

METRICS = (
    ("lines", "LH", "LF"),
    ("functions", "FNH", "FNF"),
    ("branches", "BRH", "BRF"),
)


def parse_lcov(path: Path) -> dict[str, dict[str, int]]:
    records: dict[str, dict[str, int]] = {}
    current: str | None = None

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = line[3:].strip()
            records[current] = {"LH": 0, "LF": 0, "FNH": 0, "FNF": 0, "BRH": 0, "BRF": 0}
            continue
        if current is None or ":" not in line:
            continue
        key, _, value = line.partition(":")
        if key in ("LH", "LF", "FNH", "FNF", "BRH", "BRF"):
            try:
                records[current][key] = int(value.strip() or 0)
            except ValueError:
                pass

    return records


def pct(hit: int, found: int) -> float:
    return 100.0 if found == 0 else 100.0 * hit / found


def main(argv: list[str]) -> int:
    report = Path(argv[1] if len(argv) > 1 else "lcov.info")

    if not report.exists():
        print(f"ERROR: coverage report not found: {report}", file=sys.stderr)
        print("       run `forge coverage --report lcov` first", file=sys.stderr)
        return 2

    records = parse_lcov(report)
    if not records:
        print(f"ERROR: no records parsed from {report}", file=sys.stderr)
        return 2

    failures: list[str] = []

    for required in REQUIRED_FILES:
        match = next((p for p in records if p.replace("\\", "/").endswith(required)), None)
        if match is None:
            failures.append(f"MISSING  {required} (not present in coverage report)")
            continue

        stats = records[match]
        parts = []
        for label, hit_key, found_key in METRICS:
            value = pct(stats[hit_key], stats[found_key])
            parts.append(f"{label}={value:6.2f}%")
            if value < THRESHOLD:
                failures.append(f"LOW      {required}: {label} {value:.2f}% < {THRESHOLD:.0f}%")

        print(f"{required}: " + "  ".join(parts))

    if failures:
        print("\nCoverage gate FAILED:", file=sys.stderr)
        for failure in failures:
            print("  " + failure, file=sys.stderr)
        return 1

    print(f"\nCoverage gate passed: {', '.join(REQUIRED_FILES)} at {THRESHOLD:.0f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
