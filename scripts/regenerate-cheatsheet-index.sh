#!/usr/bin/env bash
# regenerate-cheatsheet-index.sh — rebuild cheatsheets/INDEX.md from frontmatter.
#
# Thin wrapper over the Rust `tillandsias-policy regenerate-cheatsheet-index`
# subcommand (no-python-runtime policy).
#
# Usage:
#   scripts/regenerate-cheatsheet-index.sh           # rewrite cheatsheets/INDEX.md
#   scripts/regenerate-cheatsheet-index.sh --check   # exit non-zero if rewrite would diff

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
POLICY_BIN="${REPO_ROOT}/target/debug/tillandsias-policy"
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    if [[ "$CARGO_TARGET_DIR" = /* ]]; then
        [[ -x "${CARGO_TARGET_DIR}/debug/tillandsias-policy" ]] && POLICY_BIN="${CARGO_TARGET_DIR}/debug/tillandsias-policy"
    else
        [[ -x "${REPO_ROOT}/${CARGO_TARGET_DIR}/debug/tillandsias-policy" ]] && POLICY_BIN="${REPO_ROOT}/${CARGO_TARGET_DIR}/debug/tillandsias-policy"
    fi
fi
exec "${POLICY_BIN}" \
    regenerate-cheatsheet-index --repo-root "${REPO_ROOT}" "$@"
