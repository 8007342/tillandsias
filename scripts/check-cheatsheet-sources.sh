#!/usr/bin/env bash
# check-cheatsheet-sources.sh — validate cheatsheet ↔ verbatim-source binding.
#
# Usage:
#   scripts/check-cheatsheet-sources.sh [--no-sha]
#
# Checks (per §5 of docs/strategy/cheatsheet-source-layer-plan.md):
#   1. For every cheatsheet's ## Provenance URL: must be in INDEX.json
#      (WARNING if unfetched — not yet blocking).
#   2. For every local: path in ## Provenance: file exists OR sidecar has
#      redistribution: do-not-bundle / manual-review-required.
#   3. Orphan detection: every INDEX.json entry must be cited by at least
#      one cheatsheet (WARNING, not ERROR — new fetches may not be cited yet).
#   4. SHA-check: re-hash present files, compare to INDEX.json manifest
#      (skip with --no-sha for speed in pre-commit contexts).
#
# Exits 0 only if all ERROR-level checks pass.
# Warnings are printed but do not cause a non-zero exit.
#
# This is a thin wrapper over the Rust `tillandsias-policy
# check-cheatsheet-sources` subcommand. Per the no-Python-runtime policy
# (methodology.yaml), the validation logic is implemented in Rust
# (crates/tillandsias-policy); this wrapper only builds and execs the binary.
#
# @trace spec:cheatsheet-source-layer
# OpenSpec change: cheatsheet-source-layer

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Validate flags here so usage errors stay identical to the historical script.
for arg in "$@"; do
    case "$arg" in
        --no-sha) ;;
        *) echo "error: unknown argument: ${arg}" >&2
           echo "usage: $(basename "$0") [--no-sha]" >&2
           exit 2 ;;
    esac
done

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
exec "${REPO_ROOT}/target/debug/tillandsias-policy" \
    check-cheatsheet-sources --repo-root "${REPO_ROOT}" "$@"
