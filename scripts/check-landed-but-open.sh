#!/usr/bin/env bash
# @trace order:1367-emjg
#
# check-landed-but-open.sh — list every order cited by a CODE-landing commit on
# trunk whose ledger row is still open, so "implemented but never closed" is a
# count rather than an impression.
#
# WHY. Measured 2026-09-23: of 177 orders cited in code-landing commits over ten
# days, 21 (12%) still carried ready, in_progress or implemented. Real work
# landed and the row was never flipped, so it kept competing in the queue and
# inflated the open count the operator reads as "all incomplete". Found again
# 2026-09-28: 920-tqhs sat `ready` a month after relay 1425-t9v9 landed it.
#
# WHAT COUNTS
#   a landing  a NON-MERGE commit reachable from --ref (default origin/linux-next)
#              within --since (default "10 days ago") that touches at least one
#              path OUTSIDE plan/ — a plan-only commit citing an order (a claim,
#              a note, a filing) is not a landing;
#   an order   every NNN-xxxx / NNNN-xxxx token in that commit's SUBJECT (the
#              orders it lands: `feat(1443-8pur): …`, `relay: land work/1446-xqi6`).
#              A body cites orders as CONTEXT ("slice 3 of…", "related:"), and
#              reading it measured 155 suspects where subjects give the real list;
#              --cite message restores the wide read;
#   open       the row's current status is ready, pending, in_progress or
#              implemented (landed code whose row still competes or waits).
# Orders the ledger does not know are skipped. Each suspect is listed once,
# with the NEWEST landing that cites it.
#
# ADVISORY BY DESIGN: exit 0 always. An in_progress row with a partial slice
# landed is a true suspect only to a reader; the list is where the coordinator
# looks, not a gate.
#
# USAGE  check-landed-but-open.sh [--ref R] [--since S] [--cite subject|message] [--status-file F]
#   --status-file  "order status" lines instead of asking the plan binary
#                  (fixtures)
# OUTPUT suspect:<order>:<status>:<landing-sha12> <subject> ... then
#        summary:landed-but-open:<n> window=<since> ref=<ref> landings=<m> orders=<k>
#        (<n> always equals the number of suspect lines).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "summary:landed-but-open:0 could-not-run=not-a-git-repo"; exit 0; }
cd "$ROOT" || exit 0

REF="origin/linux-next"
SINCE="10 days ago"
STATUS_FILE=""
CITE=subject
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --status-file) STATUS_FILE="$2"; shift 2 ;;
        --cite) CITE="$2"; shift 2 ;;
        *) echo "usage: $0 [--ref R] [--since S] [--cite subject|message] [--status-file F]" >&2; exit 2 ;;
    esac
done
git rev-parse --verify -q "$REF" >/dev/null || { echo "summary:landed-but-open:0 could-not-run=unknown-ref:$REF"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/landed-but-open.XXXXXX")" || exit 0
trap 'rm -rf "$W"' EXIT

# order -> status
if [ -n "$STATUS_FILE" ]; then
    cp "$STATUS_FILE" "$W/status"
else
    . "$ROOT/scripts/plan-binary-probe.sh"
    PLAN="$(resolve_plan_binary 2>/dev/null)" || PLAN=""
    case "$PLAN" in "" | /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
    [ -n "$PLAN" ] || { echo "summary:landed-but-open:0 could-not-run=no-plan-binary"; exit 0; }
    "$PLAN" query --json --limit 1000000 2>/dev/null >"$W/rows.json"
    "$PLAN" json get -c '.[] | [.order, .status]' <"$W/rows.json" 2>/dev/null |
        sed -n 's/^\["\{0,1\}\([^",]*\)"\{0,1\},"\([^"]*\)"\]$/\1 \2/p' >"$W/status"
fi

# landings: non-merge commits in the window touching something outside plan/
git log --no-merges --since="$SINCE" --format='%H' "$REF" >"$W/shas" 2>/dev/null
landings=0
: >"$W/cites"
while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    nonplan="$(git diff-tree --root --no-commit-id --name-only -r "$sha" 2>/dev/null | grep -vc '^plan/')"
    [ "${nonplan:-0}" -gt 0 ] || continue
    landings=$((landings + 1))
    fmt='%s'; [ "$CITE" = message ] && fmt='%B'
    git log -1 --format="$fmt" "$sha" | grep -oE '(^|[^0-9A-Za-z-])[0-9]{3,4}-[a-z0-9]{4}([^0-9A-Za-z-]|$)' |
        grep -oE '[0-9]{3,4}-[a-z0-9]{4}' | sort -u | while IFS= read -r o; do
        printf '%s %s\n' "$o" "$sha"
    done >>"$W/cites"
done <"$W/shas"

# newest landing per order (git log is newest-first, so the first seen wins)
awk '!seen[$1]++' "$W/cites" >"$W/newest"
orders="$(grep -c . "$W/newest")"
n=0
while read -r o sha; do
    st="$(awk -v o="$o" '$1 == o { print $2; exit }' "$W/status")"
    case "$st" in
        ready | pending | in_progress | implemented)
            printf 'suspect:%s:%s:%s %s\n' "$o" "$st" "${sha:0:12}" "$(git log -1 --format='%s' "$sha" | cut -c1-100)"
            n=$((n + 1))
            ;;
    esac
done <"$W/newest"
echo "summary:landed-but-open:${n} window=${SINCE// /-} ref=${REF} cite=${CITE} landings=${landings} orders=${orders}"
exit 0
