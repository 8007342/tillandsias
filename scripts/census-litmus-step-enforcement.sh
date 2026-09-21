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
    "") ;;
    *) echo "usage: $0 [--list-long|--list-succeed]" >&2; exit 2 ;;
esac

commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

awk -v MODE="$mode" '
function flush_step() {
    if (!in_step) return
    steps++
    has_eb  = (eb_line != "")
    if (has_eb) with_eb++
    if (enforced) {
        n_enf++
    } else {
        n_unenf++
        if (!has_eb) { unenf_no_eb++; return }
        unenf_eb++
        # Bucket precedence: succeed first, then long sentence, then the rest.
        if (eb_val ~ /succeed/) {
            b_succeed++
            if (MODE == "succeed") print eb_file ":" eb_lineno
        } else if (length(eb_val) > 60) {
            b_long++
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
        in_step = 1; enforced = 0; eb_line = ""; eb_val = ""
        eb_file = FILENAME; eb_lineno = FNR
        next
    }
    if (!in_step) next
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
    printf "  UNENFORCED (none)                          %6d\n", n_unenf
    printf "    without expected_behavior                %6d\n", unenf_no_eb
    printf "    with expected_behavior                   %6d\n", unenf_eb
    printf "  UNENFORCED + expected_behavior, by bucket:\n"
    printf "    mentions \"succeed\"                       %6d\n", b_succeed
    printf "    long sentence (>60 chars)                %6d\n", b_long
    printf "    anything else                            %6d\n", b_other
    printf "                                             ------\n"
    printf "    sum                                      %6d\n", b_succeed + b_long + b_other
}
' "$TESTS_DIR"/*.yaml

[ "$mode" = "table" ] && echo "  commit: $commit"
exit 0
