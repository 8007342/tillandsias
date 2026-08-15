#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-fragment-closure-evidence-added.sh — 686-7qcm criterion 3. Refuse a
# push that ADDS a ledger fragment recording a closure rung
# (completed/verified/done) with NO evidence-bearing event for that packet.
#
# WHY. The set-field write gate already requires --evidence to write a closure
# rung, and writes the matching `completed`/`falsified` event. But a fragment
# HAND-AUTHORED under `packets:`/`status:` bypasses set-field entirely, so a
# closure with no trace of what justified it can still reach the ledger. This is
# the gate-time backstop: the evidence event must exist in the same fragment.
#
# DIFF-SCOPED BY CONSTRUCTION, exactly like check-added-fragments-parse.sh
# (698-7n6q) and check-litmus-expression-pinning-added.sh (634-39ik): it judges
# only fragments ADDED or MODIFIED versus the base ref, plus wholly-untracked
# ones. The base ledger's historical closures are therefore never re-judged —
# raising this bar accepts standing history rather than redding it.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:closure-evidence:[0-9]+ checked|violation:closure-without-evidence:[0-9]+|skip:stale-plan-binary)$
# Exit 0 when every added fragment's closures carry evidence, and on the skip.
#
# `skip:stale-plan-binary` (702-68zj) is the third verdict: the gate could not
# be computed because the workspace binary predates the rule. It is NOT a pass
# dressed up as one — a caller that wants enforcement should treat the skip as
# "rebuild and re-run", not as evidence the ledger is clean.
#
# Pinned by litmus:fragment-closure-evidence-gate-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FRAG_DIR="plan/index.d"
base_ref="${TILLANDSIAS_CLOSURE_EVIDENCE_BASE:-origin/linux-next}"

# The workspace binary carries the parser + rule (closure-evidence-check).
#
# ORDER 702-68zj: probe by RUNNING a candidate, not by testing an executable
# bit, and prefer `.exe`. On a shared Windows/WSL checkout a WSL build leaves a
# Linux ELF at target/release/tillandsias-plan beside the usable .exe, and the
# bit test picks the ELF.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
_bin="$(resolve_plan_binary)" || _bin=""
if [ -z "$_bin" ]; then
    # No binary is an UNKNOWN, not a pass — say so and skip (build to enable).
    echo "ok:closure-evidence:0 checked"
    echo "  note: tillandsias-plan not built — closure-evidence gate skipped" >&2
    exit 0
fi

# ORDER 702-68zj: a binary that predates this rule is STALE HOST STATE, not a
# ledger defect. Without this branch the per-file loop below reads "unknown
# subcommand" as a failed check and reports it as a violation — which is
# exactly what happened on 2026-08-12: a red gate claiming three
# closures-without-evidence in a change that recorded no closure at all. The
# binary had already printed the correct diagnosis ("the ARTIFACT is stale
# relative to the checkout: rebuild it") and the wrapper replaced it with a
# wrong one. Same ruling as order 447 for stale staging: skip, name it, pass.
if ! plan_binary_has "$_bin" closure-evidence-check; then
    echo "skip:stale-plan-binary"
    echo "  note: $_bin predates closure-evidence-check — rebuild with 'cargo build --release -p tillandsias-plan' to enable this gate" >&2
    exit 0
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok:closure-evidence:0 checked"
    echo "  note: base ref '$base_ref' unavailable — closure-evidence enforcement skipped" >&2
    exit 0
fi

candidates="$(
    {
        git diff --name-only --diff-filter=AM "$base_ref" -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git ls-files --others --exclude-standard -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
        git diff --name-only --cached --diff-filter=AM -- "$FRAG_DIR"/'*.yaml' 2>/dev/null
    } | sort -u
)"

checked=0
violations=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    checked=$((checked + 1))
    if ! out="$("$_bin" closure-evidence-check "$f" 2>&1)"; then
        violations=$((violations + 1))
        printf '%s\n' "$out" | sed 's/^/  /' >&2
    fi
done <<< "$candidates"

if [ "$violations" -gt 0 ]; then
    echo "violation:closure-without-evidence:${violations}"
    exit 1
fi
echo "ok:closure-evidence:${checked} checked"
exit 0
