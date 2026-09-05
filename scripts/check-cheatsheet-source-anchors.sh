#!/usr/bin/env bash
# @trace order:1053-a7qr
#
# check-cheatsheet-source-anchors.sh — a cheatsheet `sources:` anchor of the
# form `<file> order:<id>` must name a file that EXISTS and that DECLARES that
# order.
#
# WHY THIS EXISTS: NOTHING VALIDATED THESE. The reported defect was that
# cheatsheets/architecture/authorship-blindness.md anchors
# `plan/index.yaml order:804-ckst` while that packet is declared only in
# plan/archive/packets-2026-08.yaml, and the ghost-trace gate passed it. The
# question filed with it was WHICH HALF of that gate was broken — whether it
# failed to follow orders across the archive boundary, or failed to check the
# file half of an anchor.
#
# MEASURED 2026-09-05, and it is neither. I replaced a live anchor with
# `openspec/specs/NOT-A-FILE.md order:9999-zzzz` — a file that does not exist
# and an order that does not exist anywhere — and ran both
# scripts/test-ghost-trace-yaml-anchoring.sh and scripts/trace-coverage.sh.
# Both PASSED. The ghost-trace gate scans `@trace` ANNOTATIONS; a cheatsheet's
# `sources:` frontmatter is a different field and no gate reads it. So the
# anchor was never resolved by anything, and asking which half of the check was
# wrong presumed a check that was not there.
#
# THE DECLARATION/MENTION DISTINCTION IS THE WHOLE JOB. A naive grep for the
# order id in the named file would have passed the original defect anyway:
# 804-ckst appears NINE times in plan/index.yaml and 899-q9di three times, all
# of them prose inside other packets' bodies. The packet is DECLARED in neither
# — `^ *order: <id>` matches zero times in the live ledger and once in the
# archive. Counting occurrences would ratify the bug; only the declaration
# form answers "does this file define this order".
#
# Grammar (one line on stdout):
#   ok:cheatsheet-source-anchors:<n> checked
#   violation:cheatsheet-source-anchor:<file>:<anchor> — <reason>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

checked=0
bad=0

# Authored cheatsheets only. images/default/cheatsheets/ is a DERIVED copy
# regenerated from this tree (stage-image-cheatsheets.sh), so checking it too
# would report every fault twice and invite someone to "fix" the generated one.
while IFS= read -r sheet; do
    # `sources:` is a frontmatter block; its entries are `  - <file> order:<id>`.
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        file="${entry%% order:*}"
        ord="${entry##* order:}"
        checked=$((checked + 1))

        if [ ! -f "$file" ]; then
            echo "violation:cheatsheet-source-anchor:$sheet:$entry — no such file"
            bad=$((bad + 1))
            continue
        fi

        # DECLARATION, not mention. `^ *order: <id>` is how a packet declares
        # itself; a bare id in prose is a reference to it.
        grep -qE "^ *order: *${ord}( |$)" "$file"
        declared=$?
        if [ "$declared" -ne 0 ]; then
            found="$(grep -rlE "^ *order: *${ord}( |$)" plan/index.yaml plan/archive/*.yaml 2>/dev/null | head -1)"
            if [ -n "$found" ]; then
                echo "violation:cheatsheet-source-anchor:$sheet:$entry — declared in $found, not the anchored file"
            else
                echo "violation:cheatsheet-source-anchor:$sheet:$entry — order declared nowhere"
            fi
            bad=$((bad + 1))
        fi
    done < <(awk '
        /^sources:/ { in_src = 1; next }
        in_src && /^[a-z_]+:/ { in_src = 0 }
        in_src && /^[[:space:]]*-[[:space:]]/ {
            sub(/^[[:space:]]*-[[:space:]]*/, "")
            if ($0 ~ / order:/) print
        }
    ' "$sheet")
done < <(find cheatsheets -name '*.md' -type f | sort)

if [ "$bad" -gt 0 ]; then
    {
        echo "  A cheatsheet anchors an order to a file that does not declare it."
        echo "  An anchor is a promise that the reader can follow it; one that"
        echo "  points at the live ledger for an archived packet sends them to a"
        echo "  file where the id appears only as prose in someone else's packet."
        echo "  Fix the anchor to name the file that DECLARES the order."
    } >&2
    exit 1
fi

echo "ok:cheatsheet-source-anchors:$checked checked"
