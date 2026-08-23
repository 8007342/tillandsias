#!/usr/bin/env bash
# check-all-fragments-intact.sh — every ledger fragment on disk parses AND
# carries no conflict markers. Whole overlay, not just the outgoing diff.
#
# WHY THIS EXISTS, and it is an assumption that finally cost something.
#
# `check-added-fragments-parse.sh` refuses a push that ADDS an unreadable
# fragment, and check-fragment-status-loss.sh:125 already wrote the caveat
# down: "that gate is DIFF-SCOPED, so a malformed fragment that arrived by
# merge or hand edit" is outside it. On 2026-08-23 the macOS host merged
# origin/linux-next after BOTH sides had run a concurrent compaction, and git's
# RENAME DETECTION paired two set-field-generated fragments from different
# hosts — their content is ~90% identical boilerplate, one side's compaction
# supplied the "deleted" half and the other's new fragment the "added" half.
# Git merged their bodies and wrote one marker-laden blob under both names.
# Two immutable fragments held `<<<<<<<`, parsed by nothing, their packets
# invisible in every answer. The diff-scoped gate could not see it: the files
# presented as RENAMES of existing paths, not as additions.
#
# The fold's own `malformed=` counter was the single backstop that fired.
# This makes that backstop a gate instead of a thing someone noticed.
#
# TWO CHECKS, NOT ONE, and the second is the one a parse test misses. A
# conflict marker inside a block scalar — `summary: |` is where nearly all
# ledger prose lives — is VALID YAML. The document parses, the fold accepts it,
# and the corruption reads as content. So parseability alone is not integrity.
#
# Grammar (one line on stdout):
#   ok:all-fragments-intact:<n> checked
#   blocked:all-fragments-intact:<n> damaged
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FRAG_DIRS="plan/index.d plan/loop_status.d plan/mo-full-attestations.d"

checked=0
damaged=0

for d in $FRAG_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        case "$f" in */README.md) continue ;; esac
        checked=$((checked + 1))

        # (1) Conflict markers, anywhere. Checked FIRST because a marker inside
        # a block scalar parses cleanly and would sail past the YAML test.
        # LEADING WHITESPACE ALLOWED, and that is the whole point. My first
        # draft anchored at column 0 and therefore missed the exact case this
        # check was written for: markers INDENTED inside a `summary: |` block
        # scalar parse as valid YAML (verified — ruby loads such a file
        # cleanly), so they are invisible to a parse test AND were invisible to
        # a column-0 grep. The corruption then reads as content.
        if grep -qE '^[[:space:]]*(<{7}|={7}|>{7})( |$)' "$f"; then
            echo "  damaged: $f — carries a conflict marker" >&2
            damaged=$((damaged + 1))
            continue
        fi

        # (2) Parseability, for the .yaml channels. loop_status.d is markdown
        # and attestations are a line grammar, so neither is YAML-checked here;
        # their own gates cover shape, and the marker test above covers both.
        case "$f" in
            *.yaml)
                if ! ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$f" >/dev/null 2>&1; then
                    echo "  damaged: $f — does not parse as YAML" >&2
                    damaged=$((damaged + 1))
                fi
                ;;
        esac
    done
done

if [ "$damaged" -gt 0 ]; then
    echo "blocked:all-fragments-intact:$damaged damaged"
    echo "  A ledger fragment is APPEND-ONLY and IMMUTABLE; damage here is not a" >&2
    echo "  merge to resolve but a file to restore from its authoring commit." >&2
    echo "  If this appeared after merging a platform branch, suspect git rename" >&2
    echo "  detection pairing two hosts' set-field fragments (2026-08-23)." >&2
    exit 1
fi

echo "ok:all-fragments-intact:$checked checked"
