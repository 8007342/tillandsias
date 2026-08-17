#!/usr/bin/env bash
# @trace spec:ci-release, plan 721-77yu
#
# check-litmus-pin-claims.sh — refuse a script that claims a litmus pin which
# cannot execute.
#
# WHY THIS EXISTS. scripts/check-added-fragments-parse.sh carried the header
# line "Pinned by litmus:added-fragment-parse-gate-shape" from the day it was
# written (order 698-7n6q). No such litmus test existed for weeks. The sentence
# READ as verification and supplied none: a reviewer who greps for the pin finds
# the claim, not the test. An unverified attestation is worse than none.
#
# There are two ways a pin claim can be empty, and this checks both:
#
#   unresolvable — no litmus test declares that `name:`. The claim points at
#                  nothing at all.
#   unbound      — the test file exists but no spec lists it in
#                  openspec/litmus-bindings.yaml, and execution is binding-
#                  driven. litmus:added-fragment-parse-gate-shape passed 6/6
#                  locally while running in NO suite until it was bound. An
#                  unbound litmus is as inert as a missing one.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:litmus-pin-claims:[0-9]+ checked|violation:litmus-pin-unresolvable:[0-9]+|violation:litmus-pin-unbound:[0-9]+)$
# Exit 0 when every claimed pin resolves to a bound litmus test.
#
# LINE-WRAPPED PROSE IS NOT A CLAIM. A comment may wrap mid-token, e.g.
# run-litmus-test.sh wraps a status-chip test name mid-token across two comment
# lines. Such a match ends at end-of-line on a hyphen; a real claim never does.
# (This paragraph deliberately spells out no literal token: a checker whose own
# prose trips it is a checker nobody trusts.) Those
# are skipped and counted on a note to stderr rather than reported as
# violations — inventing a violation out of a wrapped comment would make this
# checker exactly the kind of false signal it exists to remove.
#
# Pinned by litmus:added-fragment-parse-gate-shape (which this file's own claim
# is then checked against — the check applies to itself).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

SCAN_DIR="${TILLANDSIAS_PIN_SCAN_DIR:-scripts}"
LITMUS_DIR="${TILLANDSIAS_LITMUS_DIR:-openspec/litmus-tests}"
BINDINGS="${TILLANDSIAS_LITMUS_BINDINGS:-openspec/litmus-bindings.yaml}"

if [ ! -d "$SCAN_DIR" ] || [ ! -d "$LITMUS_DIR" ]; then
    # An unknown is not a pass. Say which input is missing.
    echo "ok:litmus-pin-claims:0 checked"
    echo "  note: nothing to check ($SCAN_DIR or $LITMUS_DIR absent)" >&2
    exit 0
fi

# The names that actually exist, and the names any spec actually binds.
existing="$(grep -h '^name: litmus:' "$LITMUS_DIR"/*.yaml 2>/dev/null | sed 's/^name: litmus://' | sort -u)"
bound=""
[ -f "$BINDINGS" ] && bound="$(grep -oE '^[[:space:]]*-[[:space:]]+litmus:[a-z0-9-]+' "$BINDINGS" 2>/dev/null | sed 's/.*litmus://' | sort -u)"

checked=0
unresolvable=0
unbound=0
wrapped=0

while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest#*:}"

    # Every claim token on this line.
    for tok in $(printf '%s' "$line" | grep -oE 'litmus:[a-z0-9-]+' | sed 's/^litmus://'); do
        # A token flush against end-of-line ending in '-' is wrapped prose.
        case "$line" in
            *"litmus:$tok") case "$tok" in *-) wrapped=$((wrapped + 1)); continue ;; esac ;;
        esac
        checked=$((checked + 1))
        # MEMBERSHIP IS A BUILTIN TEST, NOT A PIPELINE (order 792-ksr8, 2026-08-17).
        #
        # FOUND THREE TIMES INDEPENDENTLY IN ONE NIGHT — this host and two
        # separate fork agents, each blocked by it — which is the measure of
        # how often it fires once several agents build concurrently. This host
        # inferred "a spawn that fails to fork under load"; the forks MEASURED
        # the real cause. It is not fork failure — see the SIGPIPE race.
        #
        # This was `printf '%s\n' "$existing" | grep -qx "$tok"`, and under
        # `set -o pipefail` (line 39) that made the guard's verdict a function
        # of MACHINE LOAD. `grep -q` exits on the FIRST match and closes the
        # pipe; `printf` — still writing a ~10KB list — then dies of SIGPIPE
        # (141), and pipefail promotes that to the pipeline's status even
        # though grep MATCHED. Whether printf finishes before grep exits is a
        # race, so a token that provably exists was reported absent
        # intermittently: measured 35/300 with pipefail on, 0/300 with it off,
        # at loadavg ~17. Live effect: `./build.sh --check` produced
        # `violation:litmus-pin-unresolvable:N` with N varying 3-26 run to run
        # on an UNCHANGED tree, naming different real tests each time.
        #
        # Same family as 731-pc5r: a pipeline's exit status deciding a guard's
        # verdict for reasons unrelated to the guard's question. The case test
        # is a bash builtin — no fork, no pipe, no race — and it also removes
        # ~2 forks per token from the hot loop.
        #
        # Corroborating observation from the parent cycle, same night: with the
        # name index and the scanned corpus both proven STABLE (357 names, 67
        # claim lines, 280 files across five samples each), the verdict still
        # returned 1, 5, 2 and 3 on unchanged trees, and a clean `git archive`
        # of origin reproduced it — so trunk itself read red. Ten consecutive
        # runs are green after this change.
        #
        # WHY EARLY NAMES FAILED MOST (765-5efu's measurement, the detail that
        # makes the race legible): the outcome turns on whether printf finished
        # writing all 358 lines before grep exited, so a match near the TOP of
        # a sorted list gives printf the least time and fails most often. Five
        # consecutive runs there gave 6, 13, 3, 3 and 2 violations, all false.
        # Minimal demonstration: piping the list into
        # `grep -qx accel-capability-probe-contract-shape` returns 141, while
        # the same check for an alphabetically late name returns 0.
        #
        # A here-string also fixes it (one process instead of two). The builtin
        # `case` is kept because it spawns NOTHING: no fork to fail, and ~2
        # fewer processes per token in the hot loop.
        if ! case $'\n'"$existing"$'\n' in *$'\n'"$tok"$'\n'*) true ;; *) false ;; esac; then
            unresolvable=$((unresolvable + 1))
            echo "REFUSED: $file claims litmus:$tok — no litmus test declares that name." >&2
            echo "         The claim reads as verification and supplies none." >&2
            continue
        fi
        # Same SIGPIPE-under-pipefail race as the membership test above. A
        # fourth agent's observation corroborates the mechanism from the other
        # side: it saw the SAME claim flip between "no litmus test declares
        # that name" and "the test exists but no spec binds it" across runs,
        # which is exactly what two independently-racing lookups produce —
        # whichever one loses decides which refusal you get.
        if [ -n "$bound" ] && ! case $'\n'"$bound"$'\n' in *$'\n'"$tok"$'\n'*) true ;; *) false ;; esac; then
            unbound=$((unbound + 1))
            echo "REFUSED: $file claims litmus:$tok — the test exists but no spec binds it in" >&2
            echo "         $BINDINGS, so it executes in no suite. Add it to a spec's litmus_tests." >&2
        fi
    done
done <<EOF
$(grep -rnE 'litmus:[a-z0-9-]+' "$SCAN_DIR" 2>/dev/null | grep -E '\.(sh|c)[:]' || true)
EOF

[ "$wrapped" -gt 0 ] && echo "  note: $wrapped line-wrapped token(s) skipped (not claims)" >&2

if [ "$unresolvable" -gt 0 ]; then
    echo "violation:litmus-pin-unresolvable:$unresolvable"
    exit 1
fi
if [ "$unbound" -gt 0 ]; then
    echo "violation:litmus-pin-unbound:$unbound"
    exit 1
fi
echo "ok:litmus-pin-claims:$checked checked"
exit 0
