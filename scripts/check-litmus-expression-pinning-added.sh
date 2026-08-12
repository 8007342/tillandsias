#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-litmus-expression-pinning-added.sh — the ENFORCEMENT rung for litmus
# expression-pinning. Approved by The Tlatoāni 2026-08-11 under
# methodology/convergence.yaml -> bar_raise_governance (packet 634-39ik),
# with the recorded scope: "no NEWLY ADDED litmus step may pin a literal source
# expression without a negative control", and the operator's CRDT/Erlang
# posture — enforcement never halts the line; the existing backlog is accepted
# standing debt (drained via 624-cf9f), and a misfire is filed and worked, not
# a reason to stop.
#
# DIFF-SCOPED BY CONSTRUCTION. It examines ONLY litmus step commands ADDED on
# this branch (git diff vs origin/linux-next, plus wholly-untracked litmus
# files). The 643-step existing corpus (622-rmit ranking) is therefore
# STRUCTURALLY UNREACHABLE by this check — it can never turn pre-existing debt
# into a red, no matter how it is invoked.
#
# WHAT IT REFUSES. A newly added `command:` that pins a literal source
# expression — the scanner's candidate class `literal-grep AND src-pinned`
# (greps fixed text against a .sh/.rs/.ps1/.yml/.yaml/.toml file) — WHEN the
# test file carries no negative control. Signal detection mirrors
# scripts/scan-litmus-expression-pinning.sh so ranking and enforcement agree.
#
# EXEMPTION. Add a negative control to the same test (a step proving the check
# can distinguish "property violated" from "text merely drifted"), or assert
# the behavior by running the binary/script and checking its OUTPUT instead of
# grepping its source. Either makes the added step compliant.
#
# Pinned by litmus:litmus-expression-pinning-enforcement-shape.

set -uo pipefail

# ── signal detection ─────────────────────────────────────────────────────────
# The ranking scanner (622-rmit) flags `literal-grep AND src-pinned` where
# src-pinned means "a source extension appears ANYWHERE in the command". For
# RANKING that over-flags harmlessly. For ENFORCEMENT (which REFUSES) it would
# false-red the legitimate pattern `./build.sh | grep -F 'output text'` — the
# executed script carries a `.sh`, but the grep reads its OUTPUT, not its
# source. So enforcement is deliberately PRECISE: a pin is a literal grep that
# reads a source FILE DIRECTLY (grep's target), never one fed from a pipe.
_is_literal_grep() { printf '%s' "$1" | grep -qE 'grep [^|]*-[A-Za-z]*F'; }
# An OFFENDING PIN: a literal grep whose TARGET is a source file, not a pipe.
_is_pin() {
    local c="$1"
    _is_literal_grep "$c" || return 1
    # Piped INTO grep -> grep reads stdout of a prior command (output), not
    # source. Not a pin, even if an earlier token carries a source extension.
    printf '%s' "$c" | grep -qE '\|[[:space:]]*grep' && return 1
    # No pipe into grep: a grep naming a source file reads that file's text.
    printf '%s' "$c" | grep -qE 'grep [^|]*\.(sh|rs|ps1|yml|yaml|toml)([^a-z]|$)'
}

_file_has_negative() {
    grep -qiE 'negative control|NEG-|negative_control|must FAIL|really is present' "$1"
}

# ── testable seam: judge a single command line in isolation ──────────────────
#   --check-line "<command>" <has_negative:0|1>  -> exit 1 iff it would be refused
# This is what the litmus dogfoods (negative + positive controls), git-free.
if [ "${1:-}" = "--check-line" ]; then
    cmd="${2:-}"; has_neg="${3:-0}"
    if _is_pin "$cmd" && [ "$has_neg" != "1" ]; then exit 1; fi
    exit 0
fi

LITMUS_GLOB="openspec/litmus-tests"
base_ref="${TILLANDSIAS_PIN_ENFORCE_BASE:-origin/linux-next}"

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok: base ref '$base_ref' unavailable — added-step enforcement skipped (nothing to diff against)"
    exit 0
fi

violations=0
report_violation() {
    local f="$1" cmd="$2"
    echo "REFUSED: $f adds a litmus step that pins a literal source expression with no negative control:"
    printf '   %s\n' "$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//' | cut -c1-100)"
    violations=$((violations + 1))
}

# 1) Tracked litmus files changed vs base: inspect only ADDED command lines.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    _file_has_negative "$f" && continue   # a negative control anywhere exempts the file
    while IFS= read -r addln; do
        cmd="${addln#*command:}"
        _is_pin "$cmd" && report_violation "$f" "$cmd"
    done < <(git diff "$base_ref" -- "$f" | sed -n 's/^+//p' | grep 'command:')
done < <(git diff --name-only "$base_ref" -- "$LITMUS_GLOB"/'*.yaml' 2>/dev/null)

# 2) Wholly-untracked new litmus files: every command line is "added".
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    _file_has_negative "$f" && continue
    while IFS= read -r cmdln; do
        cmd="${cmdln#*command:}"
        _is_pin "$cmd" && report_violation "$f" "$cmd"
    done < <(grep 'command:' "$f")
done < <(git ls-files --others --exclude-standard -- "$LITMUS_GLOB"/'*.yaml' 2>/dev/null)

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "Expression-pinning enforcement (634-39ik): a NEW litmus step must assert a PROPERTY,"
    echo "not pin how source is currently written. Fix by asserting the behavior (run the"
    echo "binary/script and check its OUTPUT) or by adding a negative control to the test."
    echo "This check is diff-scoped — it flags ONLY steps added in this change, never the existing corpus."
    exit 1
fi
echo "ok: no newly-added litmus step pins a literal source expression without a negative control"
exit 0
