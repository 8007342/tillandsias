#!/usr/bin/env bash
# @trace spec:ci-release
#
# reclaim-stranded-claims.sh — return abandoned claims to `ready`.
#
# Order 641-e2qa exit criterion 2. check-stranded-in-progress.sh REPORTS the
# leak; this closes it. Without a reclaim path the stranded set regenerates
# continuously, because every interrupted cycle adds one and nothing ever
# removes one.
#
# WHY THIS IS SAFE TO AUTOMATE WHEN CLOSING IS NOT
# ------------------------------------------------
# 641-e2qa refuses to auto-CLOSE a stranded packet, and that refusal stands:
# deciding work is finished requires checking exit criteria against the tree,
# and a wrong guess marks unfinished work done — silently, permanently, and in
# the direction nobody audits.
#
# Reclaiming is the opposite direction and the asymmetry is the whole argument.
# Returning a packet to `ready` cannot destroy work: the code, the commits and
# the events all survive untouched. The worst case is that a still-live claim is
# released and two hosts briefly consider the same packet — which the lease
# protocol already treats as normal and safe (advisory, CRDT-friendly,
# idempotent-merge). Being wrong here costs a duplicated glance. Being wrong
# about closure costs the work.
#
# EVIDENCE REQUIRED. A packet is reclaimed only when ALL hold:
#   * status is in_progress,
#   * no progress / completed / blocked event was ever recorded,
#   * its newest claim event is older than the TTL (default 4h, matching
#     scripts/claim-ledger-node.sh).
# A packet with no claim event at all is NOT reclaimed — absent evidence is not
# evidence of abandonment, and that case wants a human.
#
# DRY RUN BY DEFAULT. Prints the fragment it would write. `--apply` writes it.
#
# GRAMMAR:
#   ^reclaim\t<packet_id>\t<claim_ts>\tage=<hours>h$
#   ^summary: candidates=<n> reclaimed=<n> mode=(dry-run|apply)$

set -uo pipefail

TTL_HOURS=4
APPLY=0
NOW_EPOCH=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --ttl-hours) TTL_HOURS="${2:-4}"; shift 2 ;;
        --ttl-hours=*) TTL_HOURS="${1#--ttl-hours=}"; shift ;;
        --now) NOW_EPOCH="${2:-}"; shift 2 ;;   # test seam: fixed clock
        *) echo "usage: reclaim-stranded-claims.sh [--apply] [--ttl-hours N] [--now EPOCH]" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

command -v jq >/dev/null 2>&1 || { echo "summary: candidates=0 reclaimed=0 mode=refused-missing-jq"; exit 1; }
PLAN=""
for c in ./target/release/tillandsias-plan ./target/debug/tillandsias-plan "$(command -v tillandsias-plan 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { PLAN="$c"; break; }
done
[ -n "$PLAN" ] || { echo "summary: candidates=0 reclaimed=0 mode=refused-no-plan-binary"; exit 1; }

[ -n "$NOW_EPOCH" ] || NOW_EPOCH="$(date -u +%s)"
CUTOFF=$((NOW_EPOCH - TTL_HOURS * 3600))

# Portable ISO8601 -> epoch. GNU date takes -d; BSD date needs -j -f.
iso_to_epoch() {
    local iso="$1"
    date -u -d "$iso" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
        || echo ""
}

stranded="$(./scripts/check-stranded-in-progress.sh 2>/dev/null | awk -F'\t' '$1=="stranded"{print $4}')"
candidates=0
reclaimed=0
entries=""

if [ -n "$stranded" ]; then
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        candidates=$((candidates + 1))
        # Newest claim ts for this packet.
        #
        # Scope to the packet BLOCK rather than a fixed -A window: in the base
        # ledger a packet's events can sit hundreds of lines below its
        # packet_id, so `grep -A6` silently found nothing and the reclaimer
        # reported 20 candidates and 0 reclaims — a no-op wearing the costume of
        # "nothing was eligible". The block ends at the next packet_id at the
        # same-or-shallower indent.
        claim_ts="$(awk -v pid="$pid" '
            $0 ~ ("packet_id: " pid "$") { inpkt = 1; next }
            inpkt && /packet_id:/        { inpkt = 0 }
            inpkt && (/type: claim/ || /event: claim/) { want = 1; next }
            inpkt && want && /ts:/ { v = $2; gsub(/[",]/, "", v); print v; want = 0 }
        ' plan/index.yaml plan/index.d/*.yaml 2>/dev/null | sort | tail -1)"
        [ -n "$claim_ts" ] || continue          # no claim recorded -> not evidence of abandonment
        ce="$(iso_to_epoch "$claim_ts")"
        [ -n "$ce" ] || continue
        [ "$ce" -lt "$CUTOFF" ] || continue
        age=$(( (NOW_EPOCH - ce) / 3600 ))
        printf 'reclaim\t%s\t%s\tage=%sh\n' "$pid" "$claim_ts" "$age"
        entries="${entries}  - packet_id: ${pid}
    field: status
    value: ready
    ts: \"$(date -u -d "@${NOW_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "${NOW_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)\"
    host: $(hostname -s 2>/dev/null || echo unknown)
"
        reclaimed=$((reclaimed + 1))
    done <<< "$stranded"
fi

if [ "$reclaimed" -gt 0 ]; then
    ts_file="$(date -u -d "@${NOW_EPOCH}" +%Y%m%dt%H%M%Sz 2>/dev/null || date -u -r "${NOW_EPOCH}" +%Y%m%dt%H%M%Sz)"
    frag="plan/index.d/${ts_file}-reclaim-stranded-$(hostname -s 2>/dev/null || echo host).yaml"
    body="# Ledger fragment — append-only, IMMUTABLE once written.
# Generated by scripts/reclaim-stranded-claims.sh (order 641-e2qa).
#
# Each packet below was in_progress with NO progress/completed/blocked event
# ever recorded and a claim older than ${TTL_HOURS}h. Returning it to \`ready\`
# destroys nothing — code, commits and events are untouched — it only makes the
# packet visible to claimants again.
status:
${entries}"
    if [ "$APPLY" -eq 1 ]; then
        printf '%s' "$body" > "$frag"
        echo "wrote: $frag"
    else
        echo "--- would write (dry run; pass --apply) ---"
        printf '%s' "$body"
    fi
fi

printf 'summary: candidates=%s reclaimed=%s mode=%s\n' \
    "$candidates" "$reclaimed" "$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)"
