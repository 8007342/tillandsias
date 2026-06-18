#!/usr/bin/env bash
# check-cheatsheet-tiers.sh — tier-aware validation of cheatsheet frontmatter
# and pull-on-demand stub completeness.
#
# Usage:
#   scripts/check-cheatsheet-tiers.sh [--quiet] [--strict]
#
# Validates (per cheatsheets-license-tiered spec):
#   1. tier:             must be one of: bundled | distro-packaged | pull-on-demand
#                        (or absent — validator infers from cheatsheets/license-allowlist.toml,
#                         safe default pull-on-demand)
#   2. tier-conditional fields:
#                        - tier=bundled        → image_baked_sha256 + structural_drift_fingerprint set at build (warn if pre-build)
#                        - tier=distro-packaged → package: present, local: present
#                        - tier=pull-on-demand → pull_recipe: see-section-pull-on-demand
#                                                AND ## Pull on Demand section present
#                                                AND license SPDX + license URL in ### Source block
#   3. CRDT override discipline:
#                        - if shadows_forge_default set → require all of override_reason +
#                          override_consequences + override_fallback (non-empty)
#
# Exits 0 only if all ERROR-level checks pass. With --strict, warnings also
# cause a non-zero exit and are treated as CI drift.
#
# Complement to scripts/check-cheatsheet-sources.sh (the legacy verbatim-source
# validator); they overlap on cheatsheet enumeration but apply orthogonal
# checks. Once the verbatim source layer is fully retired (Wave 4 tombstones),
# this script becomes the canonical validator.
#
# This is a thin wrapper over the Rust `tillandsias-cheatsheet-tools tiers`
# binary. Per the no-Python-runtime policy (methodology.yaml), the validation
# logic is implemented in Rust (crates/tillandsias-cheatsheet-tools); this
# wrapper only locates a prebuilt binary or falls back to `cargo run`.
#
# @trace spec:cheatsheets-license-tiered

set -euo pipefail

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# Validate flags here so usage errors stay identical to the historical script.
for arg in "$@"; do
    case "$arg" in
        --quiet|--strict) ;;
        *) echo "usage: $0 [--quiet] [--strict]" >&2; exit 2 ;;
    esac
done

BIN="${REPO_ROOT}/target/release/tillandsias-cheatsheet-tools"
if [[ ! -x "${BIN}" ]]; then
    BIN="${REPO_ROOT}/target/debug/tillandsias-cheatsheet-tools"
fi

if [[ -x "${BIN}" ]]; then
    exec "${BIN}" tiers "$@"
else
    exec cargo run --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" \
        -p tillandsias-cheatsheet-tools -- tiers "$@"
fi
