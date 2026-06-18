#!/usr/bin/env bash
# @trace spec:default-image, spec:forge-as-only-runtime
# @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
# @trace plan/issues/no-python-runtime-policy-2026-06-16.md
# distill-forge-diagnostics.sh — Summarize raw forge diagnostics into durable plan/ records.
#
# Thin wrapper over the Rust `tillandsias-policy distill-forge-diagnostics`
# subcommand (no-python-runtime policy). Reads the latest diagnostics log from
# target/forge-diagnostics/, flattens the capabilities JSON, and writes a dated
# summary to plan/diagnostics/ — with regression detection vs the previous run,
# an envelope-line metadata fallback, and container-start stream forensics from
# the .stderr.log companion.
#
# Output is byte-for-byte identical to the former CPython-backed extractor over
# the full target/forge-diagnostics corpus (45/45 logs verified at port time).
#
# Usage:
#   scripts/distill-forge-diagnostics.sh
#   scripts/distill-forge-diagnostics.sh --latest <path>   # Explicit log file
#   scripts/distill-forge-diagnostics.sh --all             # Re-summarize all logs

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
exec "${REPO_ROOT}/target/debug/tillandsias-policy" \
    distill-forge-diagnostics --repo-root "${REPO_ROOT}" "$@"
