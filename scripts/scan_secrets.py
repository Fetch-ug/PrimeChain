#!/usr/bin/env python3
"""Fail CI if anything that looks like a credential is committed.

Deliberately dependency-free (stdlib only) so it runs on a fresh runner with no
network and no pinned action to trust. It is a coarse net, not a replacement for
a real scanner: Phase 6 adds gitleaks/trufflehog on top.

What it flags:
  * 32-byte hex literals (Ethereum private keys) anywhere except the allowlist
  * PEM private-key blocks
  * `private_key = "..."`, `secret = "..."`, `mnemonic = "..."` style assignments
  * URLs carrying an api key / token query parameter
  * any committed .env file

Exit codes: 0 clean, 1 findings, 2 usage error.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Directories that are build output, vendored code or harness internals.
SKIP_DIRS = {
    ".git",
    ".dsh",
    "lib",
    "out",
    "cache",
    "broadcast",
    "node_modules",
    "_stack",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
    "build",
    "crytic-export",
}

# Files that legitimately contain credential-shaped text.
SKIP_FILES = {
    "scripts/scan_secrets.py",  # contains the patterns themselves
}

# Publicly documented Anvil/Hardhat development key. Worthless by construction:
# it is the same on every installation and holds only test ETH on a local chain.
ALLOWED_LITERALS = {
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
}

BINARY_SUFFIXES = {
    ".zip", ".gz", ".tar", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".pdf", ".so", ".dylib", ".dll", ".a", ".lib", ".o", ".pyc", ".woff", ".woff2",
}

PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private key (32-byte hex)", re.compile(r"0x[0-9a-fA-F]{64}\b")),
    ("PEM private key block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    (
        "assigned credential",
        re.compile(
            r"(?i)\b(private[_-]?key|secret|mnemonic|seed[_-]?phrase|api[_-]?key|passphrase)\b"
            r"\s*[:=]\s*[\"'][^\"']{8,}[\"']"
        ),
    ),
    ("URL with embedded key", re.compile(r"https?://[^\s\"']*(?:api[_-]?key|apikey|token|key)=[A-Za-z0-9]{8,}")),
)


def iter_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts[:-1]):
            continue
        if rel.as_posix() in SKIP_FILES:
            continue
        if path.suffix.lower() in BINARY_SUFFIXES:
            continue
        files.append(path)
    return sorted(files)


def main() -> int:
    findings: list[str] = []

    for path in ROOT.rglob(".env*"):
        if path.is_file() and path.name != ".env.example":
            findings.append(f"{path.relative_to(ROOT)}: committed .env file")

    for path in iter_files():
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError as exc:
            print(f"warning: could not read {path}: {exc}", file=sys.stderr)
            continue

        rel = path.relative_to(ROOT).as_posix()
        for lineno, line in enumerate(text.splitlines(), start=1):
            for label, pattern in PATTERNS:
                for match in pattern.finditer(line):
                    value = match.group(0)
                    if any(allowed in value for allowed in ALLOWED_LITERALS):
                        continue
                    findings.append(f"{rel}:{lineno}: {label} -> {value[:80]}")

    if findings:
        print("Secret scan FAILED:\n", file=sys.stderr)
        for finding in findings:
            print("  " + finding, file=sys.stderr)
        print(
            "\nIf a finding is a deliberate public test vector (e.g. an Anvil key),"
            " add it to ALLOWED_LITERALS with a comment explaining why.",
            file=sys.stderr,
        )
        return 1

    print(f"Secret scan clean ({len(iter_files())} files scanned).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
