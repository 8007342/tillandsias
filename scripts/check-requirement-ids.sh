#!/usr/bin/env bash
# @trace spec:spec-traceability, spec:methodology-accountability
# @trace order:976-suab
#
# ORDER 976-suab. Every spec requirement carries a stable identifier, and no two
# carry the same one.
#
# WHY THIS GUARD EXISTS AND NOT JUST THE GENERATOR. `methodology/proximity.yaml`
# pays `requirement_has_stable_id: 0.10` — ten percent of evidence credit — and
# before this order ZERO of 177 spec files carried an identifier. A weight paid
# for a property no artifact has is not a scoring bug so much as a claim nothing
# can check. The generator makes the property true once; only a guard keeps it
# true, because the next requirement anyone writes by hand will not have one.
#
# WHAT IT CHECKS, and the second half is the one that matters:
#   PRESENCE   — every `### Requirement:` heading is followed by a req-id.
#   UNIQUENESS — no identifier appears twice anywhere in the corpus.
#
# Uniqueness is not paranoia about the random generator. Identifiers are copied
# by hand when a requirement is split, and a duplicate is WORSE than a missing
# one: a missing identifier is visibly absent, while a duplicate silently merges
# two obligations into one row in every cross-release comparison, and the
# comparison still reports a number.
#
# TOMBSTONED SPECS ARE CHECKED TOO, deliberately. Exempting them would leave the
# 9 requirements still living in a tombstoned file unidentifiable, so a
# non-regression check would stop counting them and get EASIER to pass as
# requirements are retired — a check that narrows its own denominator.
#
# WHAT IT CANNOT CHECK, stated because the documentation must not imply a guard
# covers it. The operator's rule is that a REFINEMENT keeps its identifier while
# a CHANGED OBLIGATION gets a tombstone and a new one. Whether an edit refines
# or replaces is author judgement about meaning; no validator can see it. This
# guard enforces that identifiers EXIST and are UNIQUE, never that the right one
# was kept.
#
# Verdict grammar, one line on stdout:
#   ok:requirement-ids:<n> requirement(s), all identified and unique
#   violation:requirement-ids-missing:<n>
#   violation:requirement-ids-duplicated:<n>
#   blocked:<reason>
set -uo pipefail

REPO_ROOT="${TILLANDSIAS_SPEC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT" || exit 2

SPEC_GLOB="${TILLANDSIAS_SPEC_GLOB:-openspec/specs/*/spec.md}"

missing=0
total=0
for f in $SPEC_GLOB; do
    [ -e "$f" ] || continue
    prev_was_heading=0
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        if [ "$prev_was_heading" -eq 1 ]; then
            prev_was_heading=0
            case "$line" in
                '<!-- req-id: '*' -->') ;;
                *)
                    echo "  $f:$((lineno - 1)) requirement has no req-id on the line below it" >&2
                    missing=$((missing + 1))
                    ;;
            esac
        fi
        case "$line" in
            '### Requirement:'*) prev_was_heading=1; total=$((total + 1)) ;;
        esac
    done < "$f"
    if [ "$prev_was_heading" -eq 1 ]; then
        echo "  $f:$lineno requirement heading is the last line and has no req-id" >&2
        missing=$((missing + 1))
    fi
done

if [ "$missing" -gt 0 ]; then
    echo "  run scripts/stamp-requirement-ids.sh to stamp what is missing (it never reassigns)" >&2
    echo "violation:requirement-ids-missing:$missing"
    exit 1
fi

dupes="$(grep -rhoE '<!-- req-id: [0-9a-f]+ -->' $SPEC_GLOB 2>/dev/null \
    | sed -E 's/<!-- req-id: ([0-9a-f]+) -->/\1/' | sort | uniq -d)"
if [ -n "$dupes" ]; then
    n=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        n=$((n + 1))
        echo "  duplicate req-id '$d' in:" >&2
        grep -rln "req-id: $d " $SPEC_GLOB 2>/dev/null | sed 's/^/    /' >&2
    done <<< "$dupes"
    echo "violation:requirement-ids-duplicated:$n"
    exit 1
fi

echo "ok:requirement-ids:$total requirement(s), all identified and unique"
