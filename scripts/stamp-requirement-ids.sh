#!/usr/bin/env bash
# @trace spec:spec-traceability, spec:methodology-accountability
# @trace order:976-suab
#
# ORDER 976-suab. Stamp every spec requirement with a STABLE RANDOM identifier,
# exactly once, and never again.
#
# WHY RANDOM AND NOT DERIVED. An identifier computed from the file path or the
# heading text is not stable — it is a hash of things that change. Moving
# `openspec/specs/foo/spec.md` or rewording a heading would silently mint a new
# identity for the same obligation, which is precisely what the identifier
# exists to prevent. Random once, then carried in the file forever.
#
# WHY A COMMENT AND NOT AN ANCHOR ON THE HEADING. The operator's rule is that a
# REFINEMENT of a requirement keeps its identifier; only a changed obligation
# gets a tombstone and a new one. Refinement most often means rewording the
# heading, so the identifier must not live in the text being reworded. On its
# own line, an author editing the heading cannot disturb it by accident, and it
# renders as nothing.
#
# IDEMPOTENCE IS THE WHOLE CONTRACT (exit criterion 2). This script stamps only
# what is MISSING and never reassigns. A re-run that shuffled identifiers would
# rebuild the original problem in a new shape while looking like success — the
# same defect family as a test that cannot fail, and just as invisible, because
# a shuffled corpus and a correct one are byte-different but both "have ids".
# The safety property is asserted directly by scripts/test-requirement-ids.sh:
# run twice, second run is a no-op and the tree is unchanged.
#
# TOMBSTONED SPECS ARE STAMPED TOO (exit criterion 4). 30 of 177 spec files
# carry `<!-- @tombstone ... -->`; 29 have had their bodies stripped, but
# `openspec/specs/opencode-web-session/spec.md` still holds 9 requirements.
# Skipping tombstones would leave those 9 unidentifiable, so a cross-release
# comparison would quietly stop counting them — a non-regression check that
# gets EASIER to pass as requirements are retired. The denominator must not
# shrink just because something was superseded.
#
# Verdict grammar, one line on stdout:
#   ok:requirement-ids-stamped:<new> new, <existing> already had one
#   blocked:<reason>
set -uo pipefail

REPO_ROOT="${TILLANDSIAS_SPEC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT" || exit 2

SPEC_GLOB="${TILLANDSIAS_SPEC_GLOB:-openspec/specs/*/spec.md}"
ID_LEN=8

# Every identifier already in the corpus, so a fresh one cannot collide with a
# stamped one even across concurrent hosts merging later.
existing_ids_file="$(mktemp)"
trap 'rm -f "$existing_ids_file"' EXIT
grep -rhoE '<!-- req-id: [0-9a-f]+ -->' $SPEC_GLOB 2>/dev/null \
    | sed -E 's/<!-- req-id: ([0-9a-f]+) -->/\1/' | sort -u > "$existing_ids_file"

mint_id() {
    local candidate
    while :; do
        candidate="$(od -An -tx1 -N$((ID_LEN / 2)) /dev/urandom 2>/dev/null | tr -d ' \n')"
        [ "${#candidate}" -eq "$ID_LEN" ] || continue
        grep -qxF "$candidate" "$existing_ids_file" && continue
        printf '%s\n' "$candidate" >> "$existing_ids_file"
        printf '%s' "$candidate"
        return 0
    done
}

new_count=0
existing_count=0
files_touched=0

for f in $SPEC_GLOB; do
    [ -e "$f" ] || continue
    grep -q '^### Requirement:' "$f" || continue

    tmp="$(mktemp)"
    changed=0
    prev_was_heading=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$prev_was_heading" -eq 1 ]; then
            prev_was_heading=0
            case "$line" in
                '<!-- req-id: '*' -->')
                    # Already stamped. NEVER REASSIGN — this is the branch that
                    # makes a re-run a no-op, and the one an "improvement" would
                    # most plausibly break.
                    existing_count=$((existing_count + 1))
                    printf '%s\n' "$line" >> "$tmp"
                    continue
                    ;;
                *)
                    printf '<!-- req-id: %s -->\n' "$(mint_id)" >> "$tmp"
                    new_count=$((new_count + 1))
                    changed=1
                    ;;
            esac
        fi
        case "$line" in
            '### Requirement:'*) prev_was_heading=1 ;;
        esac
        printf '%s\n' "$line" >> "$tmp"
    done < "$f"

    # A heading on the final line of a file still needs its stamp.
    if [ "$prev_was_heading" -eq 1 ]; then
        printf '<!-- req-id: %s -->\n' "$(mint_id)" >> "$tmp"
        new_count=$((new_count + 1))
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        cat "$tmp" > "$f"
        files_touched=$((files_touched + 1))
    fi
    rm -f "$tmp"
done

echo "ok:requirement-ids-stamped:$new_count new, $existing_count already had one, $files_touched file(s) rewritten"
