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
exec "${REPO_ROOT}/target/debug/tillandsias-policy" \
    fetch-cheatsheet-source --repo-root "${REPO_ROOT}" "$@"
