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
# @trace spec:cheatsheets-license-tiered

set -euo pipefail

QUIET=0
STRICT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=1 ;;
        --strict) STRICT=1 ;;
        *) echo "usage: $0 [--quiet] [--strict]" >&2; exit 2 ;;
    esac
    shift
done

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"

if [[ ! -d "${CHEATSHEETS_DIR}" ]]; then
    echo "ERROR: cheatsheets/ directory not found at ${CHEATSHEETS_DIR}" >&2
    exit 1
fi

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
args=(check-cheatsheet-tiers --repo-root "${REPO_ROOT}")
[[ "${QUIET}" == "1" ]] && args+=(--quiet)
[[ "${STRICT}" == "1" ]] && args+=(--strict)
exec "${REPO_ROOT}/target/debug/tillandsias-policy" "${args[@]}"
