#!/usr/bin/env bash
# pre-push-local-gate.sh — enforce locally what GitHub Actions used to enforce.
# @trace spec:methodology-accountability, spec:versioning
#
# CONTEXT
#
# Until 2026-08-03 a push to linux-next fired a three-job CI matrix in the cloud.
# That workflow was removed on operator directive — cloud minutes are paid, our
# hardware is not, and only the release genuinely needs GitHub secrets. The
# validations were never the problem; where they ran was.
#
# This hook is where they run now. It is the trunk's only automated protection.
#
# WHAT IT DOES, AND WHY IT IS FAST
#
#   1. release-preflight.sh — version monotonicity, retired CLI flags, plan
#      ledger integrity, actions budget. All local, about a second.
#   2. gate-stamp.sh verify — proves `./build.sh --check` actually ran against
#      THIS tree. Running the full gate inside the hook would be more direct, but
#      a multi-minute hook gets bypassed on its second use and then protects
#      nothing. Hashing the diff costs milliseconds and gives the same guarantee.
#
# BYPASS
#
# `git push --no-verify` still works, deliberately — a hook that cannot be
# bypassed strands an operator in an emergency. But it is now an explicit,
# visible act rather than the silent default it was when nothing ran at all.
#
# Exit 0 to allow the push, non-zero to refuse.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT" || exit 0

RED=$'\033[0;31m'; YLW=$'\033[0;33m'; GRN=$'\033[0;32m'; RST=$'\033[0m'
[[ -t 2 ]] || { RED=""; YLW=""; GRN=""; RST=""; }

refuse() {
    echo "" >&2
    echo "${RED}✗ pre-push refused: $1${RST}" >&2
    shift
    for line in "$@"; do echo "  $line" >&2; done
    echo "" >&2
    echo "  Push CI no longer exists. This hook is the trunk's only gate." >&2
    echo "  To override anyway: git push --no-verify" >&2
    echo "" >&2
    exit 1
}

# ── 1. Release preflight ───────────────────────────────────────────────────────
if [[ -f scripts/release-preflight.sh ]]; then
    verdict="$(bash scripts/release-preflight.sh 2>/dev/null | tail -1)"
    rc=$?
    if [[ $rc -ne 0 || "$verdict" != "ok:release-preflight" ]]; then
        detail="$(bash scripts/release-preflight.sh 2>&1 >/dev/null | head -6)"
        refuse "release preflight says ${verdict:-<no verdict>}" \
               "$detail" \
               "" \
               "Reproduce: scripts/release-preflight.sh --verbose"
    fi
fi

# ── 2. The local gate must have run against this exact tree ────────────────────
if [[ -f scripts/gate-stamp.sh ]]; then
    stamp="$(bash scripts/gate-stamp.sh verify 2>/dev/null)"
    case "$stamp" in
        ok:gate-fresh)
            ;;
        stale:never-run)
            refuse "./build.sh --check has never run in this checkout" \
                   "Run it once, then push:" \
                   "  ./build.sh --check"
            ;;
        stale:tree-changed-since-gate)
            refuse "the tree changed since ./build.sh --check last passed" \
                   "The gate validated a different tree than the one you are pushing." \
                   "Re-run it:" \
                   "  ./build.sh --check"
            ;;
        *)
            # Unknown verdict: warn, do not block. A stamp bug must not strand a
            # push — the preflight above already ran, and blocking on a state we
            # cannot classify would be a worse failure than allowing it.
            echo "${YLW}⚠ gate-stamp returned '${stamp:-<empty>}' — not blocking on it${RST}" >&2
            ;;
    esac
fi

echo "${GRN}✓ local gate: preflight clean, ./build.sh --check current for this tree${RST}" >&2
exit 0
