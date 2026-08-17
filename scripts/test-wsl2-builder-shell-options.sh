#!/usr/bin/env bash
# =============================================================================
# test-wsl2-builder-shell-options.sh — order 764-sunk (WSL2 sibling of 731-pc5r)
#
# `source scripts/with-wsl2-builder.sh` runs in the CALLER's shell. Before
# 764-sunk it declared `set -euo pipefail` unconditionally, so a sourcer that
# deliberately runs WITHOUT errexit (local-ci.sh: run-every-check, report-at-end)
# silently got errexit re-armed and died at its own advisory step on the happy
# path. That is the 731-pc5r leak, and this file is the executable constraint
# that keeps it closed on the Windows lane.
#
# The assertion is one-directional on purpose: the wrapper may only ADD options
# for its own body, and must hand a sourcer back exactly what it entered with.
#
# TILLANDSIAS_WSL2_WRAPPER_UNDER_TEST=<path> aims the cases at a different copy
# of the wrapper. That exists so the fix can be shown RED against the pre-764
# file (`git show <sha>:scripts/with-wsl2-builder.sh`) and green against HEAD —
# a test that has never failed against the bug it names is not evidence.
#
# Deliberately does NOT `set -e`: each case captures its status unmasked.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${TILLANDSIAS_WSL2_WRAPPER_UNDER_TEST:-$REPO_ROOT/scripts/with-wsl2-builder.sh}"

if [[ ! -r "$WRAPPER" ]]; then
    echo "fail:wsl2-builder-shell-options:wrapper-unreadable:$WRAPPER"
    exit 2
fi

# Prints the verdict and RETURNS the status, so a case function ending in a
# report() call propagates failure out of its subshell. (First draft ended each
# case on a counter assignment, which always returns 0 — the test could not
# fail. Kept as a comment because that is the exact shape this file exists to
# catch in other people's scripts.)
report() {
    if [[ "$2" == 0 ]]; then
        printf 'ok   %s\n' "$1"
        return 0
    fi
    printf 'FAIL %s — %s\n' "$1" "$3"
    return 1
}

# ── Case 1: a sourcer WITHOUT -e/-u/pipefail keeps all three off ────────────
# This is the regression itself. TILLANDSIAS_SKIP_WSL2=1 takes the explicit-skip
# return site on Windows; on non-Windows the uname guard returns even earlier.
# Both are sourced return sites, so whichever this host takes, the claim is the
# same: the wrapper must not have changed the caller's options.
case1() {
    set +e; set +u; set +o pipefail
    # shellcheck source=/dev/null
    TILLANDSIAS_SKIP_WSL2=1 source "$WRAPPER"
    local flags="$-" pf=0 bad=""
    [[ -o pipefail ]] && pf=1
    [[ "$flags" == *e* ]] && bad+="errexit re-armed; "
    [[ "$flags" == *u* ]] && bad+="nounset re-armed; "
    [[ "$pf" == 1 ]] && bad+="pipefail re-armed; "
    if [[ -n "$bad" ]]; then
        report "sourcer without -euo keeps its options" 1 "$bad(flags=$flags pipefail=$pf)"
    else
        report "sourcer without -euo keeps its options" 0 ""
    fi
}

# ── Case 2: a sourcer WITH -euo pipefail still has them afterwards ──────────
# The restore removes only what the caller LACKED; it must never strip options
# the caller genuinely had.
case2() {
    set -e; set -u; set -o pipefail
    # shellcheck source=/dev/null
    TILLANDSIAS_SKIP_WSL2=1 source "$WRAPPER"
    local flags="$-" pf=0 bad=""
    [[ -o pipefail ]] && pf=1
    [[ "$flags" == *e* ]] || bad+="errexit stripped; "
    [[ "$flags" == *u* ]] || bad+="nounset stripped; "
    [[ "$pf" == 1 ]] || bad+="pipefail stripped; "
    if [[ -n "$bad" ]]; then
        report "sourcer with -euo keeps its options" 1 "$bad(flags=$flags pipefail=$pf)"
    else
        report "sourcer with -euo keeps its options" 0 ""
    fi
}

# ── Case 3: mixed — caller has -e but not -u/pipefail ──────────────────────
# Guards against a restore that blanket-applies or blanket-clears.
case3() {
    set -e; set +u; set +o pipefail
    # shellcheck source=/dev/null
    TILLANDSIAS_SKIP_WSL2=1 source "$WRAPPER"
    local flags="$-" pf=0 bad=""
    [[ -o pipefail ]] && pf=1
    [[ "$flags" == *e* ]] || bad+="errexit stripped; "
    [[ "$flags" == *u* ]] && bad+="nounset re-armed; "
    [[ "$pf" == 1 ]] && bad+="pipefail re-armed; "
    if [[ -n "$bad" ]]; then
        report "mixed caller (-e only) is preserved exactly" 1 "$bad(flags=$flags pipefail=$pf)"
    else
        report "mixed caller (-e only) is preserved exactly" 0 ""
    fi
}

# ── Case 4: the helper leaves no bookkeeping variables behind ──────────────
case4() {
    set +e; set +u
    # shellcheck source=/dev/null
    TILLANDSIAS_SKIP_WSL2=1 source "$WRAPPER"
    local bad=""
    [[ -n "${_W2_CALLER_FLAGS:-}" ]] && bad+="_W2_CALLER_FLAGS leaked; "
    [[ -n "${_W2_CALLER_PIPEFAIL:-}" ]] && bad+="_W2_CALLER_PIPEFAIL leaked; "
    if [[ -n "$bad" ]]; then
        report "no bookkeeping variables leak to the sourcer" 1 "$bad"
    else
        report "no bookkeeping variables leak to the sourcer" 0 ""
    fi
}

# Each case runs in its own subshell so one case's options cannot reach another.
FAILED=0
for c in case1 case2 case3 case4; do
    ( "$c" )
    rc=$?
    [[ "$rc" == 0 ]] || FAILED=$((FAILED + 1))
done

if [[ "$FAILED" == 0 ]]; then
    echo "ok:wsl2-builder-shell-options:4 cases"
    exit 0
fi
echo "fail:wsl2-builder-shell-options:$FAILED of 4 cases"
exit 1
