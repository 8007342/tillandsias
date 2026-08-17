#!/usr/bin/env bash
# fetch-cheatsheet-source.sh — verbatim fetcher for the cheatsheet-source layer.
#
# Thin wrapper over the Rust `tillandsias-policy fetch-cheatsheet-source`
# subcommand (no-python-runtime policy).
#
# Usage:
#   scripts/fetch-cheatsheet-source.sh <URL> [--cite cheatsheets/<path>] [--manual-review] [--force]
#   scripts/fetch-cheatsheet-source.sh --tier=bundled [--max-age-days N] [--dry-run]

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
    fetch-cheatsheet-source --repo-root "${REPO_ROOT}" "$@"
