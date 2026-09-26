#!/usr/bin/env bash
# @trace order:1395-ue3i
#
# check-centicolon-ratchet.sh — print the CentiColon R line on every --check.
# ADVISORY (operator ruling 2026-09-26, recorded on 1395-ue3i): it WARNS and
# never refuses; it always exits 0.
#
#   centicolon: R=<n> satisfied=<n> denominator=<n> histogram=declared:<a>,traced:<b>,positively_tested:<c> regime=<r> (advisory)
#
# MONOTONIC means the SATISFIED count and NO LOST SATISFACTION, never the raw
# ratio: adding a requirement raises the denominator and R honestly, and that is
# scope, not regression. Against the previous run on this host (the snapshot
# <out>/last.txt, untracked):
#   regime=monotone           nothing satisfied was lost, no obligation came or went
#   regime=scope-added:<n>    <n> new obligation ids (reported, never a warning)
#   regime=scope-removed:<n>  <n> obligation ids vanished (reported; the
#                             tombstone-or-change-record rule is a later bar raise)
#   regime=lost:<n>           <n> ids satisfied last run, still in the
#                             denominator, not satisfied now — plus a line
#                             warn:centicolon-ratchet:lost=<n>:<first id>
#   regime=baseline           no previous snapshot on this host
# Several apply at once -> joined with "+", lost first.
#
# A pipeline that cannot run prints `centicolon: blocked:<why> (advisory)` —
# never an R of 0. The grader's static refusals (unresolved requirement keys,
# zero resolved keys) pass through as their warn: lines.
#
# --no-snapshot: report without advancing the snapshot (cycle-metrics.sh uses
# this, so a reporting pass never swallows the next --check's lost warning).
set -uo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TILLANDSIAS_REPO_ROOT:-$(cd "$SCRIPTS/.." && pwd)}"
OUT="$ROOT/${TILLANDSIAS_CENTICOLON_DIR:-target/centicolon}"
snapshot=1
[ "${1:-}" = "--no-snapshot" ] && snapshot=0

res="$(bash "$SCRIPTS/centicolon-grade.sh" 2>&1)"
grep '^warn:' <<<"$res" || true
verdict="$(grep -m1 -E '^(ok|blocked):centicolon-grade:' <<<"$res")"
if [ "${verdict%%:*}" != ok ] || [ ! -s "$OUT/grade.json" ]; then
    echo "centicolon: blocked:${verdict#blocked:centicolon-grade:} (advisory)"
    exit 0
fi

kv() { sed -n "s/.* $1=\([0-9]*\).*/\1/p" <<<" ${verdict#ok:centicolon-grade:}"; }
R="$(kv R)"; sat="$(kv satisfied)"; den="$(kv denominator)"
dec="$(kv declared)"; tra="$(kv traced)"; pt="$(kv positively_tested)"

# One line per obligation: "<id> <state>", sorted — the snapshot and the diff.
now="$(jq -r '.obligations[] | "\(.id) \(.state)"' "$OUT/grade.json" 2>/dev/null | tr -d '\r' | LC_ALL=C sort)"
regime=""
if [ -s "$OUT/last.txt" ]; then
    prev="$(cat "$OUT/last.txt")"
    prev_ids="$(cut -d' ' -f1 <<<"$prev")"; now_ids="$(cut -d' ' -f1 <<<"$now")"
    added="$(LC_ALL=C comm -13 <(printf '%s\n' "$prev_ids") <(printf '%s\n' "$now_ids") | grep -c . || true)"
    removed="$(LC_ALL=C comm -23 <(printf '%s\n' "$prev_ids") <(printf '%s\n' "$now_ids") | grep -c . || true)"
    prev_sat="$(awk '$2 == "positively_tested" {print $1}' <<<"$prev")"
    now_sat="$(awk '$2 == "positively_tested" {print $1}' <<<"$now")"
    lost_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$prev_sat" | grep . || true) <(printf '%s\n' "$now_sat" | grep . || true) \
        | LC_ALL=C comm -12 - <(printf '%s\n' "$now_ids"))"
    lost="$(grep -c . <<<"$lost_ids" || true)"
    [ "${lost:-0}" -gt 0 ] && { regime="lost:$lost"; echo "warn:centicolon-ratchet:lost=$lost:$(head -1 <<<"$lost_ids")"; }
    [ "${added:-0}" -gt 0 ] && regime="${regime:+$regime+}scope-added:$added"
    [ "${removed:-0}" -gt 0 ] && regime="${regime:+$regime+}scope-removed:$removed"
    [ -n "$regime" ] || regime="monotone"
else
    regime="baseline"
fi
[ "$snapshot" -eq 1 ] && printf '%s\n' "$now" >"$OUT/last.txt"

echo "centicolon: R=$R satisfied=$sat denominator=$den histogram=declared:$dec,traced:$tra,positively_tested:$pt regime=$regime (advisory)"
exit 0
