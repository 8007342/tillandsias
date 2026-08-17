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
        # HERE-STRING, NOT A PIPE (found 2026-08-17 while landing 765-5efu).
        # `printf '%s\n' "$existing" | grep -qx "$tok"` raced: `grep -q` exits
        # the instant it matches, `printf` then takes SIGPIPE, and `set -o
        # pipefail` (line 39) turns that into pipeline status 141 — so a token
        # that MATCHED was reported as "no litmus test declares that name".
        # The race is won or lost on whether printf finished writing 358 lines
        # before grep exited, so alphabetically EARLY names failed most often
        # and load decided the rest: five consecutive runs on an unchanged tree
        # gave 6, 13, 3, 3 and 2 violations, all of them false. Demonstrated
        # minimally: `printf | grep -qx accel-capability-probe-contract-shape`
        # -> 141 while the same check for a late name -> 0.
        # A here-string has no second process to signal, so the status is
        # grep's own verdict. Same family as 731-pc5r / 702-pwhc: a pipeline's
        # exit status deciding a guard's verdict for reasons unrelated to the
        # guard's question.
        if ! grep -qx "$tok" <<<"$existing"; then
            unresolvable=$((unresolvable + 1))
            echo "REFUSED: $file claims litmus:$tok — no litmus test declares that name." >&2
            echo "         The claim reads as verification and supplies none." >&2
            continue
        fi
        # Same SIGPIPE-under-pipefail race as the existence check above.
        if [ -n "$bound" ] && ! grep -qx "$tok" <<<"$bound"; then
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
