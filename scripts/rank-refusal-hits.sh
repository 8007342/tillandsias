#!/usr/bin/env bash
# @trace order:1494-kkbi, order:1247-amcu
#
# rank-refusal-hits.sh — rank the BARE refusal verdict sites (no affordance)
# by how often agents ACTUALLY hit them, so 1247-amcu's conversion starts with
# the refusals that fire, not with the alphabet (criterion 3).
#
# WHERE "HOW OFTEN" COMES FROM, and why not gate logs. A green gate log is full
# of refusal tokens that FIXTURES provoke on purpose (every negative-control
# arm), so ranking by gate logs puts the best-tested refusals first. What an
# agent is actually stopped by, it RECORDS: plan ledger events and plan/issues
# notes quote the verdict. That corpus is the rank. Logs given with --logs are
# reported in their own column and NEVER enter the rank.
#
# Input: the per-site audit of scripts/check-refusal-affordance-added.sh
# (slice 4, 1470-v67y): `bare <file>:<line> <token>` lines.
#
# Usage: rank-refusal-hits.sh [--top N] [--ledger DIR]... [--audit-file F] [--logs F...]
# Output: one line per bare TOKEN, ranked:
#   <rank> hits=<recorded> logs=<log-only> sites=<n> <token> <first-site>
# then `rank-refusal-hits:tokens=<t> with-hits=<h> sites=<n>`.
# A token counts every recorded verdict that BEGINS with it, since audit
# tokens are often a static prefix of a verdict completed at run time; when
# several bare tokens prefix the same verdict, the LONGEST one owns it, so a
# verdict is never counted twice.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
top=0; audit_file=""; ledgers=(); logs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --top) top="${2:-0}"; shift 2 ;;
        --ledger) ledgers+=("$2"); shift 2 ;;
        --audit-file) audit_file="$2"; shift 2 ;;
        --logs) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do logs+=("$1"); shift; done ;;
        *) echo "could-not-run:rank-refusal-hits:unknown-argument:$1"; exit 3 ;;
    esac
done
[ "${#ledgers[@]}" -gt 0 ] || ledgers=("$ROOT/plan/index.d" "$ROOT/plan/issues")

work="$(mktemp -d "${TMPDIR:-/tmp}/rank-refusal.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ -n "$audit_file" ]; then
    cp "$audit_file" "$work/audit"
else
    bash "$ROOT/scripts/check-refusal-affordance-added.sh" --audit > "$work/audit" 2>/dev/null
fi
grep '^bare ' "$work/audit" > "$work/bare" || true
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
if [ ! -s "$work/bare" ]; then
    echo "blocked:rank-refusal-hits:no-bare-sites"
    _afford "the audit listed no bare verdict sites, which is either a broken audit or a finished conversion, and a rank cannot tell which" \
        "run scripts/check-refusal-affordance-added.sh --audit and read its summary line: sites=0 means the audit found nothing to scan (fix the audit); bare=0 with sites>0 means the conversion is done"
    exit 1
fi

TOK='(refused|blocked|violation):[A-Za-z0-9._/:-]+'
# A REPORT is not an encounter. A pasted ranking or audit quotes every token it
# lists, so counting it would make each published ranking inflate itself (the
# first run's own top-10 event on 1247-amcu added one hit to each of its
# entries). Files carrying this tool's or the audit's summary line are skipped.
grep -rlE 'rank-refusal-hits:tokens=|audit:refusal-affordance:covered=' "${ledgers[@]}" 2>/dev/null | sort > "$work/reports" || true
grep -rlE "$TOK" "${ledgers[@]}" 2>/dev/null | sort | comm -23 - "$work/reports" > "$work/sources" || true
: > "$work/recorded"
if [ -s "$work/sources" ]; then
    tr '\n' '\0' < "$work/sources" | xargs -0 grep -hoE "$TOK" 2>/dev/null | sort | uniq -c > "$work/recorded" || true
fi
: > "$work/logged"
[ "${#logs[@]}" -gt 0 ] && { grep -hoE "$TOK" "${logs[@]}" 2>/dev/null | sort | uniq -c > "$work/logged" || true; }

awk -v top="$top" '
    FILENAME ~ /recorded$/ { rec[$2] += $1; next }
    FILENAME ~ /logged$/   { lg[$2]  += $1; next }
    {   tok = $3; sites[tok]++; if (!(tok in first)) first[tok] = $2 }
    # Each recorded verdict is attributed ONCE, to the LONGEST bare token it
    # begins with (macbookair, 2026-09-29): with both refused:preflight: and
    # refused:preflight:accounting-mismatch: in the audit, a quote of the
    # latter must not also count for the former.
    function owner(c,    t, best) {
        best = ""
        for (t in sites) if (index(c, t) == 1 && length(t) > length(best)) best = t
        return best
    }
    END {
        for (c in rec) { o = owner(c); if (o != "") H[o] += rec[c] }
        for (c in lg)  { o = owner(c); if (o != "") L[o] += lg[c] }
        for (t in sites)
            printf "%d\t%d\t%d\t%s\t%s\n", H[t] + 0, L[t] + 0, sites[t], t, first[t]
    }' "$work/recorded" "$work/logged" "$work/bare" \
  | sort -t$'\t' -k1,1nr -k4,4 > "$work/ranked"

tokens=0; withhits=0; nsites=0; rank=0
while IFS=$'\t' read -r h l n t s; do
    tokens=$((tokens + 1)); nsites=$((nsites + n)); [ "$h" -gt 0 ] && withhits=$((withhits + 1))
    rank=$((rank + 1))
    if [ "$top" -eq 0 ] || [ "$rank" -le "$top" ]; then
        printf '%d hits=%d logs=%d sites=%d %s %s\n' "$rank" "$h" "$l" "$n" "$t" "$s"
    fi
done < "$work/ranked"
echo "rank-refusal-hits:tokens=$tokens with-hits=$withhits sites=$nsites"
