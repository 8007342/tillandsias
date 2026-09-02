#!/usr/bin/env bash
# ORDER 956-llei (finding from the esmeraldinha audit, 2026-09-01). The
# shipped diagnostics must never tell an END USER to `brew install` a
# developer tool (799-tb7q). The litmus that guarded this grepped the SOURCE
# for the phrase and matched the COMMENT documenting the removal — a guard
# that punishes explaining a removal teaches people not to explain removals
# (cheatsheet: grep-REDS-on-comments). This guard reads only executable lines.
#
# Usage: scripts/check-no-end-user-brew-instruction.sh <script>...
# Prints exactly one line:
#   ok:no-end-user-brew-instruction:<n files>
#   FAIL:end-user-brew-instruction:<file>:<line>  (first offender; exit 1)
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <script>..." >&2; exit 2; }
n=0
for f in "$@"; do
    [ -r "$f" ] || { echo "FAIL:unreadable:$f"; exit 2; }
    n=$((n + 1))
    # Strip comment-only lines and trailing comments before matching, so the
    # phrase counts only where a user could ever see it printed.
    hit="$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//' "$f" | grep -n 'brew install jq' | head -1 | cut -d: -f1)"
    if [ -n "$hit" ]; then
        echo "FAIL:end-user-brew-instruction:$f:$hit"
        exit 1
    fi
done
echo "ok:no-end-user-brew-instruction:$n"
