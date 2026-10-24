#!/usr/bin/env bash
# Phase 1B helpers. Discovery-first: this script never guesses upstream recipe names.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
set -a
. "$here/versions.env"
set +a

STACK_DIR="$here/_stack/optimism"

usage() {
  cat <<'EOF'
Usage: ./devnet.sh <command>

  stack      clone the pinned optimism checkout into _stack/optimism
  recipes    list upstream devnet recipes from that checkout (requires `just`)
  devnet     boot the single *devnet* recipe the pinned checkout exposes
  check      verify versions.env has no unresolved TODOs
  smoke      run acceptance checks against a running L2 (see smoke.py)
  image      print the pinned op-node image reference

Nothing here starts a chain. Phase 1B boots the devnet via the upstream recipe
discovered by `recipes`, on a host with Docker (see README.md).
EOF
}

case "${1:-help}" in
  stack)
    if [ -d "$STACK_DIR/.git" ]; then
      echo "already cloned: $STACK_DIR"
    else
      mkdir -p "$(dirname "$STACK_DIR")"
      git clone --depth 1 --branch "$OPTIMISM_TAG" "$OPTIMISM_REPO" "$STACK_DIR"
    fi
    echo "checked out: $(git -C "$STACK_DIR" rev-parse --short HEAD) ($OPTIMISM_TAG)"
    ;;

  recipes)
    if [ ! -d "$STACK_DIR" ]; then
      echo "run './devnet.sh stack' first" >&2
      exit 1
    fi
    if ! command -v just >/dev/null 2>&1; then
      echo "FATAL: 'just' is not installed; the optimism Makefile targets are deprecated." >&2
      echo "       install: https://github.com/casey/just" >&2
      exit 1
    fi
    ( cd "$STACK_DIR" && just --list )
    ;;

  devnet)
    # Boot using the recipe the pinned tree actually exposes, instead of a
    # hard-coded name that may have been renamed upstream.
    if [ ! -d "$STACK_DIR" ]; then
      echo "run './devnet.sh stack' first" >&2
      exit 1
    fi
    if ! command -v just >/dev/null 2>&1; then
      echo "FATAL: 'just' is not installed (https://github.com/casey/just)" >&2
      exit 1
    fi

    list="$( cd "$STACK_DIR" && just --list 2>/dev/null | grep -iE '^[[:space:]]+[a-zA-Z0-9_-]*devnet[a-zA-Z0-9_-]*' | awk '{print $1}' | sort -u )"
    count="$(printf '%s\n' "$list" | grep -c . || true)"

    if [ "$count" -eq 0 ]; then
      echo "No devnet recipe found in the pinned checkout." >&2
      echo "Inspect manually: ./devnet.sh recipes" >&2
      exit 1
    fi

    if [ "$count" -gt 1 ]; then
      echo "Multiple devnet recipes found; refusing to guess:" >&2
      printf '  %s\n' $list >&2
      echo "Run the intended one:  ( cd $STACK_DIR && just <recipe> )" >&2
      exit 1
    fi

    echo "booting devnet via upstream recipe: $list"
    ( cd "$STACK_DIR" && just "$list" )
    ;;

  check)
    if grep -q 'TODO-' "$here/versions.env"; then
      echo "unresolved pins in versions.env:" >&2
      grep -n 'TODO-' "$here/versions.env" >&2
      exit 1
    fi
    echo "versions.env fully pinned"
    ;;

  smoke)
    exec python3 "$here/smoke.py" "${2:-$L2_RPC_URL}"
    ;;

  image)
    echo "$OP_NODE_IMAGE"
    ;;

  help | *)
    usage
    ;;
esac
