#!/usr/bin/env bash
# @trace spec:spec-traceability, plan 885-92iu
#
# check-declared-closures-added.sh — refuse a NEWLY FILED packet whose
# `verifiable_closure` names a litmus test that cannot run.
#
# WHY THIS EXISTS. Order 721-77yu established the defect for shell scripts:
# a "Pinned by litmus:<x>" header that READS as verification and supplies
# none, in two shapes — `unresolvable` (no test declares that name) and
# `unbound` (the file exists but no spec binds it, and execution is
# binding-driven, so it runs in no suite). What that checker never looked at
# is the LEDGER, where the same empty claim carries more weight:
# methodology/convergence.yaml makes the verifiable closure the thing that
# distinguishes a reduction from a restatement.
#
# Measured: packet 795-5itp declared `litmus:one-length-delimited-framing-impl`
# on 2026-08-17, and that string existed in exactly one place in the whole
# repository — the field itself — for the next eight days. Three slices of the
# migration landed against it, each reporting progress, and `./build.sh --check`
# was green throughout, truthfully.
#
# SCOPE IS DELIBERATE AND NARROW. This gates only fragments ADDED or MODIFIED
# versus the base ref, plus wholly-untracked ones — new debt refused at the
# door. The base ledger's standing debt (6 unresolvable closures at HEAD on
# 2026-08-25) is NOT redded here; `tillandsias-plan declared-closures` reports
# it, exit 0, for dispositioning. A gate that reds the trunk on day one gets
# switched off, which is the failure this whole packet is about.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:declared-closures:[0-9]+ checked|violation:declared-closure-(unresolvable|unbound):[0-9]+|skip:stale-plan-binary)$
# Exit 0 when every added fragment's declared closures resolve, and on the skip.
#
# Pinned by litmus:declared-closure-resolves.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FRAG_DIR="plan/index.d"
base_ref="${TILLANDSIAS_DECLARED_CLOSURES_BASE:-origin/linux-next}"

. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
_bin="$(resolve_plan_binary)" || _bin=""
if [ -z "$_bin" ]; then
    echo "ok:declared-closures:0 checked"
    echo "  note: tillandsias-plan not built — declared-closures gate skipped" >&2
    exit 0
fi

# Same ruling as order 702-68zj: a binary predating the rule is stale HOST
# state, not a ledger defect. Skip, name it, pass — never report the
# "unknown subcommand" diagnosis as a violation of the thing being checked.
if ! plan_binary_has "$_bin" declared-closures-check; then
    echo "skip:stale-plan-binary"
    echo "  note: $_bin predates declared-closures-check — rebuild with 'cargo build --release -p tillandsias-plan' to enable this gate" >&2
    exit 0
fi

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "ok:declared-closures:0 checked"
    echo "  note: base ref '$base_ref' unavailable — declared-closures enforcement skipped" >&2
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
    if ! out="$("$_bin" declared-closures-check "$f" 2>&1)"; then
        violations=$((violations + 1))
        printf '%s\n' "$out" | sed 's/^/  /' >&2
    fi
done <<< "$candidates"

if [ "$violations" -gt 0 ]; then
    echo "violation:declared-closure-unresolvable:${violations}"
    exit 1
fi
echo "ok:declared-closures:${checked} checked"
exit 0
