#!/usr/bin/env bash
# audit-cheatsheet-sources.sh — CSV migration triage for the cheatsheet-source layer.
#
# Usage:
#   scripts/audit-cheatsheet-sources.sh [> /tmp/audit.csv]
#
# Outputs a CSV with columns:
#   cheatsheet_path, source_url, in_index_json, license_allowlisted,
#   allowlist_key, sha256_present, local_path_if_fetched
#
# Designed for the bulk-migration step (Chunk 2) to identify which cheatsheets'
# Provenance URLs have already been fetched, which domains are allowlisted, and
# which are missing SHA-256 coverage.
#
# Exit code: always 0. Errors are reported in the csv as values.
#
# This is a thin wrapper over the Rust `tillandsias-policy
# audit-cheatsheet-sources` subcommand. Per the no-Python-runtime policy
# (methodology.yaml), the audit logic is implemented in Rust
# (crates/tillandsias-policy); this wrapper only builds and execs the binary.
#
# @trace spec:cheatsheet-source-layer
# OpenSpec change: cheatsheet-source-layer

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
exec "${REPO_ROOT}/target/debug/tillandsias-policy" \
    audit-cheatsheet-sources --repo-root "${REPO_ROOT}" "$@"
