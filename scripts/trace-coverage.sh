#!/usr/bin/env bash
# @trace spec:ci-release
#
# trace-coverage.sh — compute `trace_coverage_summary` from the @trace
# annotations in source, and detect ghost traces.
#
# Order 625-* (operator directive 2026-08-09). This REPLACES the 171 committed
# TRACES.md rendering files that scripts/generate-traces.sh used to emit.
#
# WHY THE RENDERING WENT AWAY, AND WHY THIS IS NOT A LOSS OF GUARANTEE
# --------------------------------------------------------------------
# `trace_coverage_summary` is a REQUIRED field of the evidence bundle in
# methodology/convergence.yaml and methodology/verification.yaml. Nothing in the
# repo ever produced it. TRACES.md did not: it is a spec -> file:line link
# index, not a coverage summary. So the declared obligation was open the whole
# time while ~4000 lines of rendered markdown were regenerated and re-committed
# every cycle — churn that dirtied trees, tripped the self-clean gate, and
# forced extra commits, without discharging the obligation it looked like it
# served.
#
# What actually carries the convergence guarantee, per convergence.yaml:
#   * the @trace annotations themselves      <- GROUND TRUTH, still in source
#   * validate_spec_existence (phase_1)      <- ghost detection, now a GATE
#   * litmus-to-spec binding                 <- unchanged
#   * the CentiColon signature + dashboard   <- unchanged
#
# This script strengthens two of those: it computes the missing summary, and it
# turns ghost detection from a warning nobody actioned into a falsifiable check
# with a non-zero exit. The rendered index was the only thing removed, and it
# was never load-bearing.
#
# USAGE
#   scripts/trace-coverage.sh               # one summary line
#   scripts/trace-coverage.sh --json        # evidence-bundle field, JSON
#   scripts/trace-coverage.sh --ghosts      # list ghost traces; exit 1 if any
#   scripts/trace-coverage.sh --gate        # RATCHET: fail only on NEW/stale ghosts
#
# GRAMMAR (default mode) — exactly one line:
#   ^trace_coverage: specs=N traced=N ghost=N annotations=N files=N$
# Exit 0 always in default/--json mode; --ghosts exits 1 when ghosts exist.
#
# THE RATCHET (--gate), and why it is not a way of tolerating the debt
# --------------------------------------------------------------------
# Turning ghost detection into a hard failure on the day it first ran would
# have broken the build: nine ghosts already existed, one of them
# (spec:meta-orchestration) referenced from nine separate scripts. A gate that
# cannot be satisfied gets bypassed, and a bypassed gate is worse than no gate.
#
# So --gate compares against openspec/ghost-trace-baseline.txt and fails on
# either direction of drift:
#   * a ghost NOT in the baseline  -> a new one was introduced. Fail.
#   * a baseline entry that is no longer a ghost -> it was fixed but the
#     baseline was not pruned. Fail, and say so.
# The second half is what makes this monotonic rather than a mute button: the
# baseline can only shrink, and the build tells you to shrink it the moment you
# earn it. See methodology/convergence.yaml -> drift_control.

BASELINE_FILE="openspec/ghost-trace-baseline.txt"

set -uo pipefail

MODE="summary"
case "${1:-}" in
    --json)   MODE="json" ;;
    --ghosts) MODE="ghosts" ;;
    --gate)   MODE="gate" ;;
    "")       MODE="summary" ;;
    *) echo "usage: trace-coverage.sh [--json|--ghosts|--gate]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# ── Scan: every @trace spec: token, with its file and line ──────────────────
# Same include/exclude set as the generator this replaces, so coverage numbers
# are comparable across the transition.
entries="$(
    grep -rn "@trace" \
        --include="*.rs" \
        --include="*.sh" \
        --include="*.toml" \
        --include="*.nix" \
        --include="*.ps1" \
        --include="Containerfile*" \
        --exclude-dir='.claude' \
        --exclude-dir='.git' \
        --exclude-dir='target' \
        --exclude-dir='target-musl' \
        . 2>/dev/null \
    | grep "spec:" \
    | awk '
        # ONE pass. This was a shell `while read` that spawned a grep, a sed
        # and a subshell FOR EVERY MATCHING LINE -- about 1868 lines in this
        # repo, so roughly six thousand processes. On windows, where a spawn
        # costs far more than the work it does, that was the bulk of the 455
        # seconds this script took. Same defect as the per-spec find walks
        # below and as the pre-commit hook (734-sjb3): per-item subprocesses.
        #
        # Emits exactly what the pipeline did: one <spec>\t<relpath>\t<lineno>
        # per spec: token per line, the token truncated at any "/" (a
        # spec:a/b annotation counts against spec "a"), path stripped of "./".
        {
            i = index($0, ":");            if (i == 0) next
            path = substr($0, 1, i - 1);   rest = substr($0, i + 1)
            j = index(rest, ":");          if (j == 0) next
            lineno = substr(rest, 1, j - 1)
            ann = substr(rest, j + 1)
            sub(/^\.\//, "", path)
            while (match(ann, /spec:[a-zA-Z0-9_-]+(\/[a-zA-Z0-9_-]+)?/)) {
                tok = substr(ann, RSTART + 5, RLENGTH - 5)
                sub(/\/.*/, "", tok)
                if (tok != "") print tok "\t" path "\t" lineno
                ann = substr(ann, RSTART + RLENGTH)
            }
        }
    '
)"

annotations=0
[ -n "$entries" ] && annotations="$(printf '%s\n' "$entries" | grep -c .)"

files=0
[ -n "$entries" ] && files="$(printf '%s\n' "$entries" | cut -f2 | sort -u | grep -c .)"

unique_specs=""
[ -n "$entries" ] && unique_specs="$(printf '%s\n' "$entries" | cut -f1 | sort -u)"

specs=0
[ -n "$unique_specs" ] && specs="$(printf '%s\n' "$unique_specs" | grep -c .)"

# ── Resolve: does each referenced spec exist? ───────────────────────────────
# Same three-place lookup the generator used: active spec, in-flight change,
# archive. A spec found in none of them is a GHOST — the annotation asserts a
# relationship whose other end does not exist.
# WALK EACH TREE ONCE, not once per referenced spec.
#
# This used to run TWO `find` walks PER SPEC: one over openspec/changes (1130
# files) and one over openspec/changes/archive (1062). With 189 referenced
# specs that is ~380 deep tree walks across ~1100 files each. Measured on
# windows: 455 SECONDS standalone, and ~58s inside every `./build.sh --check`
# — which a cycle runs three or four times, so this one lookup was minutes of
# fixed per-cycle cost, silently, with no output while it ran.
#
# Same defect the pre-commit hook had twice (734-sjb3), one directory over: a
# per-item subprocess on a host where a spawn costs orders of magnitude more
# than the work it does. Three walks total now; membership is a bash lookup.
#
# The sets are built lazily and once, so --json and --ghosts pay nothing extra
# and a run that never resolves a spec pays nothing at all.
_SPEC_SETS_BUILT=""
_build_spec_sets() {
    [ -z "$_SPEC_SETS_BUILT" ] || return 0
    _SPEC_SETS_BUILT=1
    declare -gA _SPEC_CHANGE=() _SPEC_ARCHIVE=()
    local n
    # `*/specs/<name>/spec.md` — the name is the second-to-last path element,
    # which is exactly what the per-spec `-path` glob used to match.
    while IFS= read -r n; do
        [ -n "$n" ] && _SPEC_CHANGE["$n"]=1
    done < <(find openspec/changes -maxdepth 4 -path "*/specs/*/spec.md" \
        ! -path "*/archive/*" 2>/dev/null | awk -F/ '{print $(NF-1)}')
    while IFS= read -r n; do
        [ -n "$n" ] && _SPEC_ARCHIVE["$n"]=1
    done < <(find openspec/changes/archive -path "*/specs/*/spec.md" 2>/dev/null \
        | awk -F/ '{print $(NF-1)}')
}

_locate_spec() {
    local name="$1"
    # The active check stays a direct stat: one file test is cheaper than any
    # set, and it must keep precedence over change/archive as before.
    [ -f "openspec/specs/${name}/spec.md" ] && { printf 'active'; return; }
    _build_spec_sets
    [ -n "${_SPEC_CHANGE[$name]:-}" ] && { printf 'change'; return; }
    [ -n "${_SPEC_ARCHIVE[$name]:-}" ] && { printf 'archive'; return; }
    printf ''
}

ghost_specs=""
traced=0
if [ -n "$unique_specs" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -n "$(_locate_spec "$name")" ]; then
            traced=$((traced + 1))
        else
            ghost_specs="${ghost_specs}${name}"$'\n'
        fi
    done <<< "$unique_specs"
fi

ghost=0
[ -n "$ghost_specs" ] && ghost="$(printf '%s' "$ghost_specs" | grep -c .)"

case "$MODE" in
    summary)
        printf 'trace_coverage: specs=%s traced=%s ghost=%s annotations=%s files=%s\n' \
            "$specs" "$traced" "$ghost" "$annotations" "$files"
        ;;
    json)
        printf '{"specs":%s,"traced":%s,"ghost":%s,"annotations":%s,"files":%s,"ghost_specs":[' \
            "$specs" "$traced" "$ghost" "$annotations" "$files"
        first=1
        if [ -n "$ghost_specs" ]; then
            while IFS= read -r g; do
                [ -n "$g" ] || continue
                [ "$first" -eq 1 ] || printf ','
                printf '"%s"' "$g"
                first=0
            done <<< "$ghost_specs"
        fi
        printf ']}\n'
        ;;
    ghosts)
        if [ "$ghost" -eq 0 ]; then
            echo "ok: no ghost traces"
            exit 0
        fi
        echo "ghost-traces: ${ghost} spec(s) referenced by @trace do not exist"
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            echo "  spec:${g}"
            printf '%s\n' "$entries" | awk -F'\t' -v s="$g" '$1==s {print "    " $2 ":" $3}'
        done <<< "$ghost_specs"
        echo "REMEDY: create the spec, archive the change that defines it, or delete the annotation."
        exit 1
        ;;
    gate)
        baseline=""
        [ -f "$BASELINE_FILE" ] && baseline="$(grep -v '^[[:space:]]*#' "$BASELINE_FILE" | grep -v '^[[:space:]]*$' | sort -u)"
        current="$(printf '%s' "$ghost_specs" | grep -v '^$' | sort -u)"

        introduced="$(comm -23 <(printf '%s\n' "$current" | grep -v '^$') <(printf '%s\n' "$baseline" | grep -v '^$'))"
        fixed="$(comm -13 <(printf '%s\n' "$current" | grep -v '^$') <(printf '%s\n' "$baseline" | grep -v '^$'))"

        rc=0
        if [ -n "$introduced" ]; then
            echo "ghost-trace-gate: NEW ghost trace(s) introduced — a spec was referenced that does not exist:"
            printf '  spec:%s\n' $introduced
            echo "  REMEDY: create the spec, archive the change defining it, or delete the annotation."
            rc=1
        fi
        if [ -n "$fixed" ]; then
            echo "ghost-trace-gate: baseline is STALE — these are no longer ghosts and must be removed from ${BASELINE_FILE}:"
            printf '  spec:%s\n' $fixed
            echo "  The baseline may only shrink. Prune it in the same commit that fixed them."
            rc=1
        fi
        [ "$rc" -eq 0 ] && echo "ok:ghost-trace-gate baseline=$(printf '%s\n' "$baseline" | grep -c .) current=${ghost}"
        exit "$rc"
        ;;
esac
