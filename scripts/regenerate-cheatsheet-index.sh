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
# Run-don't-stat (order 770-ifeg): on a shared Windows/WSL checkout the
# extensionless target/ path can hold the OTHER platform's artifact, and an
# existence check execs it into "Exec format error". Probe by execution.
. "${REPO_ROOT}/scripts/plan-binary-probe.sh"
if ! POLICY_BIN="$(resolve_target_binary tillandsias-policy debug "${REPO_ROOT}")"; then
    echo "refused:no-runnable-tillandsias-policy (probed target/debug and CARGO_TARGET_DIR by execution)" >&2
    exit 1
fi
exec "${POLICY_BIN}" \
    regenerate-cheatsheet-index --repo-root "${REPO_ROOT}" "$@"
