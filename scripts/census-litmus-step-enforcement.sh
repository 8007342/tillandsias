#!/usr/bin/env bash
# @trace spec:ci-release, plan 1329-m8dk (parent 1252-znbn)
#
# census-litmus-step-enforcement.sh — how many litmus steps can actually FAIL?
#
# THE DELIVERABLE OF 1329-m8dk. The parent row's headline number went three days
# stale and two hosts disagreed about it, so the census exists as a SCRIPT and
# not as a number in a comment: re-running it at any commit is a ten-second job
# rather than an argument.
#
# THE READING RULE (yoga's, with the clause the re-run had to add):
#   * A STEP is a `- step:` block, delimited by the NEXT `- step:` AT ANY
#     INDENT. Line-block attribution, not a text split.
#   * ENFORCED means the block contains at least one of assert_exit,
#     assert_output_contains, assert_output_matches, assert_output_nonempty or
#     success_pattern — AS A KEY, matched `^[[:space:]]*<name>:`, NEVER as a
#     substring anywhere in the block.
#   * UNENFORCED means it contains none of them.
#
# THE `AS A KEY` CLAUSE IS THE WHOLE RECONCILIATION between the two hosts. A
# substring match counts a step as ENFORCED when a COMMENT merely MENTIONS one
# of the tokens, and this corpus contains exactly two such comments — prose
# ABOUT enforcement counted AS enforcement, a census of "is this step enforced?"
# fooled by a comment discussing the question. With the substring rule the count
# is 42/2,166; with the key rule it is 43/2,167, and the hosts agree exactly.
#
# Usage: scripts/census-litmus-step-enforcement.sh [--list-long] [--list-succeed]
#   --list-long     print `<file>:<line>` for every long-sentence step (the slice)
#   --list-succeed  print `<file>:<line>` for every surviving succeed-step
#   --list-named    print `<file>:<line>` for every step declared unadjudicable
#
# Emits the table on stdout, commit named, so a pasted result always says which
# tree it measured.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

TESTS_DIR="openspec/litmus-tests"
mode="table"
case "${1:-}" in
    --list-long) mode="long" ;;
    --list-succeed) mode="succeed" ;;
    --list-named) mode="named" ;;
    "") ;;
    *) echo "usage: $0 [--list-long|--list-succeed]" >&2; exit 2 ;;
esac

commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

# ORDER 1334-57at. WHICH FILES CAN ACTUALLY RUN? An assert in a file no
# suite executes is, in 1333-jpq5's words, "correct and inert": it can never
# go red, so counting it as ENFORCED overstates enforcement. Measured at
# 3048e72dc, 53 of 244 enforced steps were inert — 21.7%. REACHABLE here is
# the same definition census-litmus-reachability.sh uses: BOUND in
# litmus-bindings.yaml AND not `phase: retired`. Grandfathered-unbound is
# NOT reachable — the grandfather list exempts a file from the binding
# violation, it does not cause anything to run it.
#
# NAME FORM, NEVER THE FILENAME STEM. Bindings store `litmus:x`; the file is
# `litmus-x.yaml`. Matching one against the other yields an empty set that
# reads exactly like a real negative, which is how --list came to print zero
# suites on 444 files (1330-bb87). Read the declared `name:` and compare that.
_reach_list="$(mktemp)"
trap 'rm -f "$_reach_list"' EXIT
_bound="$(awk '/^  - litmus:/ {print $2}' openspec/litmus-bindings.yaml 2>/dev/null | sort -u)"
if [ -z "$_bound" ]; then
    echo "blocked:census:no-bound-names-read-from-litmus-bindings.yaml" >&2
    exit 2
fi
for _f in "$TESTS_DIR"/*.yaml; do
    [ -e "$_f" ] || continue
    _name="$(grep -m1 '^name:' "$_f" | sed 's/name: *//' | tr -d ' \r')"
    [ -n "$_name" ] || continue
    grep -qxF "$_name" <<< "$_bound" || continue
    grep -qE '^phase: *retired *$' "$_f" && continue
    printf '%s\n' "$_f" >> "$_reach_list"
done

awk -v MODE="$mode" -v REACH="$_reach_list" '
BEGIN {
    # Reachable file paths, one per line, as the glob below names them.
    while ((getline _l < REACH) > 0) if (_l != "") reach[_l] = 1
    close(REACH)
}
function flush_step() {
    if (!in_step) return
    steps++
    has_eb  = (eb_line != "")
    if (has_eb) with_eb++
    if (enforced) {
        n_enf++
        if (reach[eb_file]) n_enf_reach++; else n_enf_inert++
    } else {
        n_unenf++
        if (!has_eb) { unenf_no_eb++; return }
        unenf_eb++
        # ORDER 1329-m8dk, coordinator ruling 2026-09-21. NAMED REASON FIRST.
        # A step that genuinely cannot be adjudicated is a TERMINAL state under
        # the exit criteria of this row, but it stays UNENFORCED and so kept
        # landing in a debt bucket: the closure asked for long = 0 while the
        # criteria accepted a named reason, and both could not hold. Counted
        # separately it is neither hidden nor carried as backlog. Grammar: a
        # `# unenforced: <reason>` comment inside the step block.
        if (named_here) {
            b_named++
            if (MODE == "named") print eb_file ":" eb_lineno
            return
        }
        # Bucket precedence: succeed first, then long sentence, then the rest.
        if (eb_val ~ /succeed/) {
            b_succeed++
            if (MODE == "succeed") print eb_file ":" eb_lineno
        } else if (length(eb_val) > 60) {
            b_long++
            if (reach[eb_file]) b_long_reach++
            if (MODE == "long") print eb_file ":" eb_lineno
        } else {
            b_other++
        }
    }
}
FNR == 1 { files++ }
{
    # A new step block closes the previous one, at ANY indent.
    if ($0 ~ /^[[:space:]]*-[[:space:]]+step:/) {
        flush_step()
        in_step = 1; enforced = 0; eb_line = ""; eb_val = ""; named_here = 0
        eb_file = FILENAME; eb_lineno = FNR
        next
    }
    if (!in_step) next
    # A step block ENDS at the next column-0 key, not merely at the next step.
    # Without this, a `# unenforced:` marker sitting after the last step in a
    # file — or anywhere in a following top-level section such as
    # `observability:` — still attaches to the last step seen, and the bucket
    # meant to record an honest declaration becomes a way to launder a step out
    # of the debt count from anywhere in the file. Caught by its own negative
    # control (ORDER 1329-m8dk): a stray marker at file scope moved the count
    # from 2 to 3 with no step changed.
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) { flush_step(); in_step = 0; next }
    if ($0 ~ /^[[:space:]]*#[[:space:]]*unenforced:/) named_here = 1
    # AS A KEY, never a substring: a comment mentioning assert_exit is prose.
    if ($0 ~ /^[[:space:]]*(assert_exit|assert_output_contains|assert_output_matches|assert_output_nonempty|success_pattern):/) enforced = 1
    if ($0 ~ /^[[:space:]]*expected_behavior:/ && eb_line == "") {
        eb_line = $0
        eb_val = $0
        sub(/^[[:space:]]*expected_behavior:[[:space:]]*/, "", eb_val)
        gsub(/^["'"'"']|["'"'"']$/, "", eb_val)
        eb_lineno = FNR
    }
}
END {
    flush_step()
    if (MODE != "table") exit 0
    printf "  files                                      %6d\n", files
    printf "  step blocks                                %6d\n", steps
    printf "    with an expected_behavior                %6d\n", with_eb
    printf "  ENFORCED   (assert_* or success_pattern)   %6d\n", n_enf
    printf "    ENFORCED-REACHABLE (a suite runs it)     %6d\n", n_enf_reach
    printf "    ENFORCED-INERT     (nothing runs it)     %6d\n", n_enf_inert
    printf "  UNENFORCED (none)                          %6d\n", n_unenf
    printf "    without expected_behavior                %6d\n", unenf_no_eb
    printf "    with expected_behavior                   %6d\n", unenf_eb
    printf "  UNENFORCED + expected_behavior, by bucket:\n"
    printf "    mentions \"succeed\"                       %6d\n", b_succeed
    printf "    long sentence (>60 chars)                %6d\n", b_long
    printf "    named reason (declared unadjudicable)  %6d\n", b_named
    printf "    anything else                            %6d\n", b_other
    printf "                                             ------\n"
    printf "    sum                                      %6d\n", b_succeed + b_long + b_other + b_named
    printf "\n  CLOSURE FIGURE, long OUTSIDE named-reason, REACHABLE only: %d\n", b_long_reach
    printf "  (same figure counting inert files too:                     %d)\n", b_long
}
' "$TESTS_DIR"/*.yaml

[ "$mode" = "table" ] && echo "  commit: $commit"
exit 0
