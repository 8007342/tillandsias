#!/usr/bin/env bash
# @trace order:1144-jfr5
# check-stale-ready-rows.sh — FIRST PASS of the stale-ready-row reconciliation.
#
# A landed commit whose SUBJECT cites <order> as work — fix(<order>),
# feat(<order>), close(<order>), test(<order>), record(<order>), style, docs,
# refactor — while <order> still folds `ready` is a staleness CANDIDATE:
# somebody believed they were working that row and the row was never moved.
# MEASURED 2026-09-13: 1127-apa8 sat ready after e357f3f87
# "fix(1125-wi4d, 1126-w8rq, 1127-apa8)" landed, and two hosts each spent a
# cycle re-verifying it. This query has no owned_files heuristic and no false
# positives from a commit that merely edited a file a row mentions; it is the
# cheap pass that runs BEFORE the fuzzier owned_files pass the row also asks
# for (not built here; the row stays open for it).
#
# A candidate is SURFACED, never closed: a commit can cite three orders and
# complete two (e357f3f87 did exactly that). A host verifies the exit
# criteria against the tree and appends the closing event with evidence.
#
# NEGATIVE CONTROLS, pinned by scripts/test-stale-ready-rows.sh: claim(<order>)
# and file(<order>) are not work citations; an order mentioned only in a
# commit BODY or without the (<order>) shape is not a candidate; an order that
# does not fold ready is never reported.
#
# Usage:
#   scripts/check-stale-ready-rows.sh [--ref <rev>] [--orders-file <file>] [--repo <dir>]
#     --ref          history to search (default: HEAD)
#     --orders-file  newline list of ready orders (default: the plan binary's
#                    `ready` output); the fixture uses this to stay hermetic
#     --repo         run in another checkout (fixture)
# Output (stdout), grammar pinned by the fixture:
#   stale-candidate:<order>:<n-commits>:<newest-sha>     one per candidate
#   ok:stale-ready-rows:<candidates>/<ready-rows>:pass=cites-order
# Exit 0 always — advisory; the coordination pass reads it. Exit 2 on usage.
# bash 3.2 clean (761-g36m): no mapfile, no associative arrays.
set -u

ref="HEAD"; orders_file=""; repo="."
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) ref="$2"; shift 2 ;;
        --orders-file) orders_file="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        *) echo "usage: $0 [--ref rev] [--orders-file file] [--repo dir]" >&2; exit 2 ;;
    esac
done
cd "$repo" || { echo "usage: --repo $repo is not a directory" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stale-ready-rows.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -n "$orders_file" ]; then
    grep -v -E '^\s*(#|$)' "$orders_file" > "$tmp/orders"
else
    # shellcheck disable=SC1091
    . scripts/plan-binary-probe.sh 2>/dev/null || { echo "ok:stale-ready-rows:0/0:pass=cites-order:no-plan-binary-probe"; exit 0; }
    PLAN="$(resolve_plan_binary 2>/dev/null)" || { echo "ok:stale-ready-rows:0/0:pass=cites-order:no-plan-binary"; exit 0; }
    "$PLAN" ready 2>/dev/null | awk -F'\t' '$2=="ready"{print $1}' > "$tmp/orders"
fi

# One history walk, then a per-order grep over it: 500 ready rows must not
# mean 500 history walks.
git log --format='%h %s' "$ref" 2>/dev/null \
    | grep -E '^[0-9a-f]+ (fix|feat|close|test|record|style|docs|refactor)\(' > "$tmp/work" || true

candidates=0; rows=0
while IFS= read -r order; do
    [ -n "$order" ] || continue
    rows=$((rows + 1))
    # (<order>) or (<a>, <order>, <b>): the order bounded by ( , or ) so 278
    # never matches 1278 and 1001-aaaa never matches 1001-aaaab.
    hits="$(grep -E "^[0-9a-f]+ [a-z]+\(([^)]*[ ,])?${order}[,)]" "$tmp/work" || true)"
    [ -n "$hits" ] || continue
    n="$(printf '%s\n' "$hits" | grep -c .)"
    newest="$(printf '%s\n' "$hits" | head -1 | cut -d' ' -f1)"
    echo "stale-candidate:${order}:${n}:${newest}"
    candidates=$((candidates + 1))
done < "$tmp/orders"

echo "ok:stale-ready-rows:${candidates}/${rows}:pass=cites-order"
exit 0
