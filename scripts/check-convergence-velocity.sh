#!/usr/bin/env bash
# scripts/check-convergence-velocity.sh — Shell entry point for checking
# convergence velocity and proximity thresholds.
#
# @trace spec:observability-convergence
# @cheatsheet runtime/plan-discipline.md
#
# A RULE THAT ALWAYS PASSES IS NOT A RULE (order 831-ezea).
#
# This script was backed by a Python checker. Under the no-Python runtime
# policy the Python implementation was retired
# (plan/archive/no-python-runtime-policy-2026-06-16.md:61) and the wrapper was
# left as sixteen lines that printed
#
#     WARN: check-convergence-velocity is currently a no-op (Python retired)
#
# on stderr and exited 0. Every caller — and the litmus that pins this file —
# saw a green exit forever. That is worse than deleting it: a deleted checker
# is a visible hole, an always-0 checker is an invisible one wearing a guard's
# name. The retirement note itself says a Rust replacement "is still desired
# for real enforcement", i.e. the enforcement does not exist.
#
# DO NOT DELETE THIS FILE and do not delete the litmus step that pins it. The
# pin is deliberate: it is what catches the SILENT no-op (599-w5jd class), the
# failure where the stub loses even its warning and nothing marks the absent
# rule. The reconciliation is recorded as intentional in that archive note.
#
# WHAT CHANGED. Instead of a green lie, this now emits the one verdict it can
# honestly compute — `unavailable:<reason>`, the THIRD verdict convention
# already shipped in scripts/check-stranded-in-progress.sh (order 702-68zj)
# and, before it, verify:skip-stale-staging (447) and skip:no-tray-binary
# (620-duta). "I could not compute this" is a distinct state from "I computed
# this and it is clean", and collapsing the two is how an unenforced rule
# reads as an enforced one.
#
# GRAMMAR — exactly one summary line on stdout:
#   ^summary: (velocity=<f> proximity=<f> population=<n>|unavailable:<reason>)$
#
# POPULATION AND THE UNAVAILABLE VERDICT. Order 831-ezea requires every check
# verdict to print `population=<n>`, the size of the set it examined, so that
# green over an empty set cannot be misread as health. An `unavailable:`
# verdict deliberately carries NO population field: the sweep did not look, so
# its denominator is unknown, not zero. Printing `population=0` here would
# reintroduce exactly the false all-clear the third verdict exists to prevent
# (the 702-68zj scar: "reporting zero because the sweep could not look").
# The computed branch, when a Rust checker lands, MUST carry population.
#
# EXIT 0 ALWAYS: advisory, like check-stranded-in-progress.sh. An unavailable
# sweep is a missing capability, not a broken tree, and failing every build on
# it would block all work until the Rust checker ships.

# `-e` is deliberately omitted, matching check-stranded-in-progress.sh. This
# script's whole job is to reach its summary line and print it; an advisory
# probe that dies on a grep-found-nothing before printing its verdict is the
# scar recorded at scripts/local-ci.sh:41-60, where leaked errexit killed a
# run at a step whose own comment said it never fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# An executable BIT is a claim; RUNNING the binary is evidence (order 704-zcgi,
# generalized as resolve_target_binary under 770-ifeg). Probe by execution
# rather than hardcoding "no Rust checker exists" — a hardcoded answer is the
# same always-true constant this change is removing, just with a better string.
# The day the replacement lands in a workspace crate, this script must notice.
#
# A BROKEN PROBE IS ITS OWN REASON. Measured while writing this: with
# plan-binary-probe.sh absent, `resolve_target_binary` was undefined, every
# candidate loop iteration died `command not found`, `|| continue` swallowed
# it, and the script printed `unavailable:no-rust-checker` — reporting "the
# successor does not exist" when the truth was "I could not look". Both are
# `unavailable:`, so it was never a green lie, but a wrong REASON sends the
# reader to build a checker instead of restoring the probe. Separate them.
if ! . "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh" 2>/dev/null \
    || ! command -v resolve_target_binary >/dev/null 2>&1; then
    echo "WARN: scripts/plan-binary-probe.sh missing or did not define resolve_target_binary — cannot probe for a Rust checker" >&2
    echo "summary: unavailable:no-binary-probe"
    exit 0
fi

# Candidate homes named by the retirement note: "the Rust replacement being
# integrated into the tillandsias-metrics or tillandsias-logging crate".
# tillandsias-policy is included because that is where the other retired
# Python checkers actually landed (same archive note, 2026-06-18/06-20).
CHECKER=""
for _cv_name in tillandsias-metrics tillandsias-logging tillandsias-policy; do
    for _cv_profile in release debug; do
        _cv_bin="$(resolve_target_binary "$_cv_name" "$_cv_profile" "$ROOT")" || continue
        # `capabilities` is the version-aware probe (704-zcgi): a binary that
        # predates the subcommand answers --help fine and still cannot do this.
        if "$_cv_bin" capabilities 2>/dev/null | grep -qx 'convergence-velocity'; then
            CHECKER="$_cv_bin"
            break 2
        fi
    done
done

if [ -z "$CHECKER" ]; then
    # TODAY'S BRANCH. The Python checker was retired and no Rust checker
    # exists in any workspace crate, so convergence velocity is UNENFORCED.
    echo "WARN: convergence velocity is unenforced — Python retired, no Rust checker built" >&2
    echo "summary: unavailable:no-rust-checker"
    exit 0
fi

# THE HALF-MIGRATED STATE. The successor binary exists and declares the
# capability, but this wrapper still does not call it — its output contract
# was never specified here. That is a real, distinguishable state and it must
# not be reported as either "no checker" or "clean": both would let the
# migration stall silently at 90%, which is the shape of the original defect.
echo "WARN: ${CHECKER} declares convergence-velocity but this wrapper does not call it yet" >&2
echo "summary: unavailable:rust-checker-unwired"
exit 0
