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

# ORDER 1005-m6rz. Resolve cargo the way cycle-preflight does before assuming
# it is on PATH, and if it is genuinely absent say so as a SKIP rather than
# letting the shell print `cargo: command not found`.
#
# MEASURED on pirria-cachyos 2026-09-04: this line ran from the pre-commit hook
# on a host with no toolchain and emitted a bare command-not-found under a
# "validation ERRORs (non-blocking)" heading. It was the third site of the same
# assumption after cycle-preflight (876-irn7) and host-capability-probe; the
# registry of all of them is scripts/lib-cargo-sites.sh, which is also where the
# next one goes.
#
# COULD-NOT-RUN IS NOT A VIOLATION, and that distinction is the fix. A reader
# seeing ERROR next to a cheatsheet check reasonably concludes a cheatsheet is
# wrong. The check did not run at all, which is a different fact and needs a
# different word — the same lesson 965-sxec applied to the archiver's absent
# ruby.
# shellcheck source=scripts/lib-cargo-sites.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-cargo-sites.sh"
if ! cargo_resolve; then
    echo "skip:cheatsheet-tiers:cargo-absent (no toolchain on this host; check not run)"
    exit 0
fi

cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy
args=(check-cheatsheet-tiers --repo-root "${REPO_ROOT}")
[[ "${QUIET}" == "1" ]] && args+=(--quiet)
[[ "${STRICT}" == "1" ]] && args+=(--strict)

# Run-don't-stat via the shared probe (orders 672-4nts + 770-ifeg). This
# script's own inline `--help` probe was the prototype; resolve_target_binary
# generalizes it AND tries the runnable `.exe` sibling first, so on Windows
# the gate now RUNS against the PE cargo just built instead of skipping over
# the stale Linux ELF at the extensionless path. A probe that cannot run on
# this host at all remains a SKIP, said once — an "Exec format error" banner
# provides zero coverage and trains readers to ignore red gate text.
. "${REPO_ROOT}/scripts/plan-binary-probe.sh"
if ! POLICY_BIN="$(resolve_target_binary tillandsias-policy debug "${REPO_ROOT}")"; then
    echo "skip:policy-binary-not-host-executable (no runnable tillandsias-policy under target/debug or CARGO_TARGET_DIR)"
    exit 0
fi
exec "${POLICY_BIN}" "${args[@]}"
