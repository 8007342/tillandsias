#!/usr/bin/env bash
# freshness: auditor=linux-yoga-opus5-20260825T2200Z date=2026-08-25 verdict=updated scope=order-372 standing audit. WIRED, not orphaned — pre-commit-openspec.sh:286 plus two litmus (cheatsheet-source-layer-shape, -validation) — so my first hypothesis was wrong and this is not dead code. What it WAS: vacuous and actively misleading. All four checks key on cheatsheet-sources/INDEX.json, which the 2026-08-23 tombstone deleted when the verbatim source layer was retired in favour of cheatsheets-license-tiered. The validator could not tell "not fetched yet" (migration; fetch is right) from "deliberately retired" (tombstone; fetching would UNDO the retirement), so it exited 0 on every openspec pre-commit while printing "Run: scripts/fetch-cheatsheet-source.sh" into a directory someone had emptied on purpose. It now detects the tombstone and answers ok:cheatsheet-sources-retired, naming the replacement. NOT obsoleted despite the discard-over-repair bias: the tombstone reserves removal for 0.1.<N+3>.x under the three-release retention rule, and that call belongs to the cheatsheets-license-tiered owner, not to a passing audit. Filed 888-jfsz for it.
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
# Run-don't-stat (order 770-ifeg): on a shared Windows/WSL checkout the
# extensionless target/ path can hold the OTHER platform's artifact, and an
# existence check execs it into "Exec format error". Probe by execution.
. "${REPO_ROOT}/scripts/plan-binary-probe.sh"
if ! POLICY_BIN="$(resolve_target_binary tillandsias-policy debug "${REPO_ROOT}")"; then
    echo "refused:no-runnable-tillandsias-policy (probed target/debug and CARGO_TARGET_DIR by execution)" >&2
    exit 1
fi
exec "${POLICY_BIN}" \
    check-cheatsheet-sources --repo-root "${REPO_ROOT}" "$@"
