#!/usr/bin/env bash
# @trace order:823-u5zf
#
# check-wt-reparse-workarounds-deleted.sh — the wt.exe re-parse workarounds must
# stay deleted, and a NOTE ABOUT THEIR DELETION MUST NOT COUNT AS ONE.
#
# 823-u5zf's closure reads "a source scan finds no argv_survives_wt_reparse and
# no wt_safe_title". Taken literally that scan is a `grep`, and a grep cannot
# close this packet: the predicates are gone, but three comments RECORDING that
# they are gone still name them (host-shell/src/pty/mod.rs, notify_icon.rs
# twice). A literal scan reports the packet incomplete forever, and the obvious
# repair — deleting the comments so the grep passes — destroys the only
# explanation of why the code looks the way it does.
#
# That is not a quirk of this packet. It is the same defect twice this week: a
# litmus step grepped for a DELETED test's name and matched the doc comment
# explaining the deletion, passing over an absence (1055-6yp8); and 1049-s35z
# documents the general shape. A name that appears in both the live text and
# the prose about it cannot be classified by matching the name.
#
# So this scan classifies by POSITION, not by presence: an occurrence counts
# only if it survives stripping the comment part of its line. Comments may
# discuss the deleted predicates freely; code may not name them at all.
#
# GRAMMAR — exactly one line:
#   ok:wt-reparse-workarounds-deleted:<n> mention(s), all in comments
#   violation:wt-reparse-workaround-live:<n> code occurrence(s)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# The scan may be pointed at a fixture tree; default is the workspace.
SCAN_DIR="${1:-crates}"

SYMBOLS="argv_survives_wt_reparse wt_safe_title"

live=""
mentions=0

for sym in $SYMBOLS; do
    # -F: these are identifiers, not patterns.
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        mentions=$((mentions + 1))
        file="${hit%%:*}"
        rest="${hit#*:}"
        line="${rest%%:*}"
        text="${rest#*:}"
        # The code part is everything before the first `//`. A line whose text
        # begins with the comment marker has no code part at all.
        code="${text%%//*}"
        case "$code" in
            *"$sym"*)
                live="${live}${file}:${line}: ${sym} appears in CODE, not in a comment"$'\n'
                ;;
        esac
    done < <(grep -rnF "$sym" "$SCAN_DIR" --include=*.rs 2>/dev/null)
done

if [ -n "$live" ]; then
    n="$(printf '%s' "$live" | grep -c .)"
    echo "violation:wt-reparse-workaround-live:$n code occurrence(s)"
    printf '%s' "$live" | sed 's/^/  /' >&2
    {
        echo "  The wt.exe re-parse workarounds were deleted under 823-u5zf: every"
        echo "  lane now emits a verbatim argv whose tokens are wt-safe, so a"
        echo "  predicate deciding whether a FLATTENED string survives wt's"
        echo "  re-parse has nothing left to guard. Re-introducing one means a"
        echo "  lane fell back to conhost, which is the field failure 805-ek9e"
        echo "  reports: no clickable links and no working paste, so an operator"
        echo "  cannot complete a device-code login."
    } >&2
    exit 1
fi

echo "ok:wt-reparse-workarounds-deleted:$mentions mention(s), all in comments"
