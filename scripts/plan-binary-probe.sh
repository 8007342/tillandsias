#!/usr/bin/env bash
# @trace spec:ci-release
#
# ONE probe for "which tillandsias-plan can this host actually run?", sourced by
# every script that needs the binary. Order 704-zcgi.
#
# WHY A SHARED COPY. Three scripts independently wrote the same wrong probe —
# `[ -x ./target/release/tillandsias-plan ]`, first match wins — and all three
# failed the same way on a shared Windows/WSL checkout, where a WSL build leaves
# a **Linux ELF** at exactly that path beside the usable `.exe`. Two of them
# (check-stranded-in-progress.sh, check-fragment-closure-evidence-added.sh) were
# fixed in place under 702-68zj; select-work-batch.sh then arrived from another
# host carrying a fresh copy of the same bug, which is the signal that fixing
# instances is not enough.
#
# THE RULE: an executable BIT is a claim; RUNNING the binary is evidence. The
# bit lies across the Windows/WSL boundary in both directions, and file
# extension alone cannot tell you which artifact a shared target/ dir last
# received. So probe by execution.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
#   PLAN="$(resolve_plan_binary)" || { echo "refused:no-plan-binary:..."; exit 1; }
#   plan_binary_has closure-evidence-check || echo "skip:stale-plan-binary"
#
# `resolve_plan_binary` prints the path and exits 0, or prints nothing and
# returns 1. It never prints a verdict — the caller owns its own grammar.

# Print the first candidate that actually runs. `.exe` first: on the host where
# both exist, that is the runnable one.
resolve_plan_binary() {
    local candidate
    # An EXPLICIT override is the caller naming the binary, not a candidate to
    # be judged: honour it on existence alone. Running `capabilities` on it
    # would collapse a distinction the callers depend on — the litmus injects a
    # stub that fails the way a STALE binary fails, and a stale binary must
    # refuse as `stale-plan-binary`, never as `no-plan-binary`. Probing the
    # override turned the former into the latter and the corpus caught it
    # immediately (704-zcgi, first run).
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
        [ -f "${TILLANDSIAS_PLAN_BIN}" ] || return 1
        printf '%s\n' "${TILLANDSIAS_PLAN_BIN}"
        return 0
    fi
    for candidate in \
        ./target/release/tillandsias-plan.exe \
        ./target/debug/tillandsias-plan.exe \
        ./target/release/tillandsias-plan \
        ./target/debug/tillandsias-plan \
        "$(command -v tillandsias-plan 2>/dev/null)"; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate" ] || continue
        # `capabilities` is the right probe rather than `--help`: it exits 0
        # only on a binary built from sources carrying order 569, and its
        # output is the capability set the caller may want next.
        if "$candidate" capabilities >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# True when the resolved binary carries a named subcommand. Lets a caller
# distinguish "this binary predates the rule I enforce" (host state — skip and
# say so) from "the thing I check is wrong" (a real finding). Conflating those
# is how a stale binary produced a red gate naming three violations that did
# not exist (702-68zj).
plan_binary_has() {
    local bin="$1" subcommand="$2"
    "$bin" capabilities 2>/dev/null | grep -qx "$subcommand"
}
