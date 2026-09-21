#!/usr/bin/env bash
# @trace spec:ci-release, plan 1325-ygq5 (family), 1329-m8dk (discovery)
#
# census-litmus-reachability.sh — how many litmus tests cannot be reached under
# the name they give themselves?
#
# THE QUESTION THIS ANSWERS is one level out from 1325-ygq5. That order asked
# whether an ADDED test is referenced by anything. This asks the standing-corpus
# version: of the tests that ARE bound, how many run credited to a spec they do
# not declare — so that asking for them by their own spec name returns
# "no litmus tests matched filter", and the spec they name reads covered with
# nothing behind it?
#
# WHY IT IS A POPULATION AND NOT THREE ANECDOTES. Three turned up inside a single
# slice of 1329-m8dk, by accident, while trying to run steps:
#   lit""mus:control-dispatch-shape   grandfathered unbound — no suite runs it, so
#                                   an assert added to it is correct and inert.
#   lit""mus:ca-ephemeral             grandfathered unbound AND phase e2e.
#   litmus:cross-target-cfg-gate-check
#                                   declares spec: cross-platform-compilation,
#                                   bound under spec_id: dev-build. Asking for it
#                                   by its own spec answers "no tests matched",
#                                   which is the likeliest reason its mutation
#                                   arms sat owed across two hosts.
# Three found without looking is the signal that counting is worth doing.
#
# WHAT A MISMATCH COSTS, in the words of the guard that already refuses NEW ones
# (check-litmus-bindings.sh, 1304-wbb2): "It will RUN and be credited to the
# wrong spec, while the spec it names reads covered with nothing behind it."
# That guard is DIFF-SCOPED — it fires only on newly ADDED bindings — so every
# pre-existing mismatch is inherited and silent. Correct construction, and it
# means nothing counts the standing set. This does.
#
# Multi-spec declarations are honoured: `spec: a, b, c` matches a binding under
# any of a, b or c, exactly as check-litmus-bindings.sh splits them. Counting
# them as mismatches inflates the number by 7 on this corpus, which is how the
# first version of this script was wrong.
#
# Grammar (one line on stdout, nothing else, plus an optional listing):
#   ^census:litmus-reachability files=[0-9]+ retired=[0-9]+ grandfathered-unbound=[0-9]+ unbound=[0-9]+ spec-binding-mismatch=[0-9]+$
#
# Usage: scripts/census-litmus-reachability.sh [--list]

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

TESTS_DIR="openspec/litmus-tests"
BINDINGS="openspec/litmus-bindings.yaml"
GRAND="$TESTS_DIR/unbound-grandfathered.txt"
list=0
[ "${1:-}" = "--list" ] && list=1

[ -f "$BINDINGS" ] || { echo "census:litmus-reachability files=0 retired=0 grandfathered-unbound=0 unbound=0 spec-binding-mismatch=0"; echo "  note: $BINDINGS absent" >&2; exit 0; }

bound="$(grep -oE 'litmus:[a-z0-9._-]+' "$BINDINGS" | sort -u)"
grand=""
[ -f "$GRAND" ] && grand="$(grep -v '^[[:space:]]*#' "$GRAND" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | grep . | sort -u || true)"

files=0; retired=0; gf=0; unbound=0; mismatch=0
for f in "$TESTS_DIR"/litmus-*.yaml; do
    [ -e "$f" ] || continue
    nm="$(grep -m1 '^name:' "$f" | sed 's/^name:[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$nm" ] || continue
    files=$((files + 1))
    if grep -qE '^phase:[[:space:]]*retired[[:space:]]*$' "$f"; then retired=$((retired + 1)); continue; fi
    # Herestrings, never `printf | grep -q`: the SIGPIPE-under-pipefail hazard.
    if ! grep -qxF -- "$nm" <<< "$bound"; then
        if [ -n "$grand" ] && grep -qxF -- "$nm" <<< "$grand"; then
            gf=$((gf + 1))
            [ "$list" -eq 1 ] && echo "grandfathered-unbound  $nm  ($(basename "$f"))"
        else
            unbound=$((unbound + 1))
            [ "$list" -eq 1 ] && echo "UNBOUND                $nm  ($(basename "$f"))"
        fi
        continue
    fi
    decl="$(grep -m1 '^spec:' "$f" | sed 's/^spec:[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$decl" ] || continue
    declset="$(printf '%s' "$decl" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . || true)"
    ln="$(grep -n "^  - ${nm}\$" "$BINDINGS" | head -1 | cut -d: -f1)"
    [ -n "$ln" ] || continue
    under="$(awk -v L="$ln" 'NR<=L && /^- spec_id:/{s=$3} END{print s}' "$BINDINGS")"
    [ -n "$under" ] || continue
    grep -qxF -- "$under" <<< "$declset" && continue
    mismatch=$((mismatch + 1))
    [ "$list" -eq 1 ] && echo "spec-binding-mismatch  $nm  declares=[$decl]  bound-under=$under"
done

echo "census:litmus-reachability files=$files retired=$retired grandfathered-unbound=$gf unbound=$unbound spec-binding-mismatch=$mismatch"
exit 0
