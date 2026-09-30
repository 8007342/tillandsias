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
SCAN_ROOT="${TILLANDSIAS_FRAGMENT_SCAN_ROOT:-$ROOT}"
cd "$SCAN_ROOT"

# One repository-owned reader in every locus. Ruby is absent in a fresh forge
# and is represented there by an on-demand Homebrew shim. Calling that shim
# once per fragment spent tens of minutes installing Ruby; early invocations
# then failed and valid fragments were falsely reported as damaged. The policy
# facade resolves the binary built earlier by `./build.sh --check` and can build
# it for standalone use (order 746-htj9).
POLICY="$ROOT/scripts/tillandsias-policy"
if [ ! -x "$POLICY" ]; then
    echo "blocked:all-fragments-intact:no-yaml-validator"
    echo "  missing repository validator facade: $POLICY" >&2
    exit 2
fi

FRAG_DIRS="plan/index.d plan/loop_status.d plan/mo-full-attestations.d"

checked=0
damaged=0

# ORDER 1500-gu5r: TWO BULK PASSES, THEN ONE ORDERED WALK. This loop used to
# spawn a grep AND a validate-yaml per fragment (3,300+ fragments): 14 s on
# yoga, three times the preflight door's deadline. The judgement is
# unchanged. (1) The conflict-marker test is one `grep -l` over every
# fragment. (2) validate-yaml takes many paths, keeps going past a bad one,
# and prints `ok: <path>` for each that parses, so one batched call names every
# parseable file and any .yaml without an ok line does not parse. (3) One awk
# then walks the fragments in the ORIGINAL order and emits the same messages
# in the same order: a marker is reported first and skips the parse test, as
# before. No associative arrays (bash 3.2, check-bash-dialect).
_frag_tmp="$(mktemp -d "${TMPDIR:-/tmp}/all-fragments.XXXXXX")" || { echo "blocked:all-fragments-intact:no-tmp"; exit 2; }
trap 'rm -rf "$_frag_tmp"' EXIT
: > "$_frag_tmp/list"
for d in $FRAG_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        case "$f" in */README.md) continue ;; esac
        printf '%s\n' "$f" >> "$_frag_tmp/list"
    done
done
# LEADING WHITESPACE ALLOWED in the marker test, and that is the whole point:
# markers INDENTED inside a `summary: |` block scalar parse as valid YAML, so
# they are invisible to a parse test and to a column-0 grep.
tr '\n' '\0' < "$_frag_tmp/list" \
    | xargs -0 grep -lE '^[[:space:]]*(<{7}|={7}|>{7})( |$)' -- > "$_frag_tmp/markers" 2>/dev/null || true
grep -E '\.yaml$' "$_frag_tmp/list" | grep -vxF -f "$_frag_tmp/markers" \
    | tr '\n' '\0' \
    | xargs -0 "$POLICY" validate-yaml 2>/dev/null \
    | sed -n 's/^ok: //p' > "$_frag_tmp/parsed" || true
_counts="$(awk -v MK="$_frag_tmp/markers" -v OK="$_frag_tmp/parsed" '
    BEGIN {
        while ((getline l < MK) > 0) marker[l] = 1
        while ((getline l < OK) > 0) parsed[l] = 1
        c = 0; d = 0
    }
    {
        c++
        if ($0 in marker) { printf "  damaged: %s — carries a conflict marker\n", $0 > "/dev/stderr"; d++; next }
        if ($0 ~ /\.yaml$/ && !($0 in parsed)) { printf "  damaged: %s — does not parse as YAML\n", $0 > "/dev/stderr"; d++ }
    }
    END { print c, d }' "$_frag_tmp/list")"
checked="${_counts% *}"
damaged="${_counts#* }"

if [ "$damaged" -gt 0 ]; then
    echo "blocked:all-fragments-intact:$damaged damaged"
    echo "  A ledger fragment is APPEND-ONLY and IMMUTABLE; damage here is not a" >&2
    echo "  merge to resolve but a file to restore from its authoring commit." >&2
    echo "  If this appeared after merging a platform branch, suspect git rename" >&2
    echo "  detection pairing two hosts' set-field fragments (2026-08-23)." >&2
    exit 1
fi

echo "ok:all-fragments-intact:$checked checked"
