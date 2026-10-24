#!/usr/bin/env bash
# Fetch the exact dependency versions this repo is pinned to (ADR-011, ADR-014).
#
# Why not git submodules: a submodule pins a commit in the parent repo, which
# requires the parent to be a git repo. This project is handed over as files and
# initialised by the client/CI, so a deterministic clone script is more robust
# and shows the pin in one place. The OpenZeppelin commit SHA is verified after
# cloning, so a moved tag cannot silently change our dependency.
set -euo pipefail

cd "$(dirname "$0")/.."

OZ_TAG="v5.7.0"
# Commit behind OpenZeppelin Contracts v5.7.0 (from the GitHub release metadata,
# target_commitish, fetched 2026-10-24).
OZ_SHA="cab19933c33c2ad1d4c7a84864a3601dddfd16f3"
FORGE_STD_TAG="v1.17.0"

mkdir -p lib

clone_pinned() {
  local name="$1" url="$2" tag="$3" dir="lib/$1"
  if [ -d "$dir/.git" ]; then
    echo "== $name already present, verifying tag"
  else
    echo "== cloning $name @ $tag"
    rm -rf "$dir"
    git clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
  fi
}

clone_pinned openzeppelin-contracts https://github.com/OpenZeppelin/openzeppelin-contracts.git "$OZ_TAG"
clone_pinned forge-std https://github.com/foundry-rs/forge-std.git "$FORGE_STD_TAG"

actual_oz="$(git -C lib/openzeppelin-contracts rev-parse HEAD)"
if [ "$actual_oz" != "$OZ_SHA" ]; then
  echo "FATAL: openzeppelin-contracts is at $actual_oz, expected $OZ_SHA" >&2
  echo "       (tag $OZ_TAG has moved; update the pin deliberately, not silently)" >&2
  exit 1
fi

echo "== deps OK: openzeppelin-contracts $OZ_TAG ($OZ_SHA), forge-std $FORGE_STD_TAG"
