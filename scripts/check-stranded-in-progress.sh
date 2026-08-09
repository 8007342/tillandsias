#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-stranded-in-progress.sh — report packets stuck in `in_progress`.
#
# Order 642-*.
#
# THE LEAK. A packet in `in_progress` is invisible in BOTH directions: `ready`
# queries skip it so nobody claims it, and burndown does not count it so nobody
# notices it is unfinished. It is neither work nor done. 23 packets were in that
# state when this was written (16 linux, 6 windows), the oldest at order 153.
#
# This is a DIFFERENT leak from 635-i6vm, and the guard written for that one
# cannot see it:
#
#   635-i6vm  completion WAS declared, and the G-Set fold discarded it.
#             check-fragment-status-loss.sh catches that.
#   this      completion was NEVER declared. 627-k4mz was filed
#             `status: in_progress`, the fix was written, reviewed and merged —
#             and no fragment ever said so. Nothing was discarded, so nothing
#             looks wrong.
#
# WHAT THIS DOES NOT DO. It does not close anything. Deciding a packet is
# finished requires checking its exit criteria against the tree, and an
# automated closer that guesses would silently mark unfinished work done — the
# most expensive possible version of this bug. It reports; owners close.
#
# GRAMMAR — one line per stranded packet, then one summary line:
#   ^stranded\t<order>\t<role>\t<packet_id>$
#   ^summary: in_progress=<n> stranded=<n> threshold_events=<n>$
# Exit 0 always: this is an advisory report, not a gate. A packet legitimately
# in flight right now is indistinguishable from one abandoned an hour ago, so
# failing a build on it would block work for a state that is often correct.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

PLAN=""
for c in ./target/release/tillandsias-plan ./target/debug/tillandsias-plan "$(command -v tillandsias-plan 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { PLAN="$c"; break; }
done
[ -n "$PLAN" ] || { echo "summary: in_progress=0 stranded=0 threshold_events=0"; exit 0; }

command -v jq >/dev/null 2>&1 || {
    echo "summary: in_progress=0 stranded=0 threshold_events=0"
    exit 0
}

rows="$("$PLAN" query --status in_progress --limit 200 --json 2>/dev/null \
    | jq -r '.[] | [(.order|tostring), (.pickup_role // "unassigned"), .packet_id] | @tsv' 2>/dev/null)"

total=0
[ -n "$rows" ] && total="$(printf '%s\n' "$rows" | grep -c .)"

# A packet is STRANDED when its most recent recorded activity is the claim
# itself — no progress event since. That is the signature of an interrupted
# cycle: something took it, wrote nothing, and never came back.
stranded=0
out=""
if [ -n "$rows" ]; then
    while IFS=$'\t' read -r order role pid; do
        [ -n "$pid" ] || continue
        # Count progress-ish events recorded for this packet anywhere in the
        # fragments. `filed` and `claim` do not count as activity.
        events=$(grep -rh -A3 "packet_id: ${pid}\$" plan/index.d/*.yaml 2>/dev/null \
            | grep -cE 'event: (progress|completed|blocked)|type: (progress|completed|blocked)' || true)
        if [ "${events:-0}" -eq 0 ]; then
            out="${out}stranded	${order}	${role}	${pid}"$'\n'
            stranded=$((stranded + 1))
        fi
    done <<< "$rows"
fi

[ -n "$out" ] && printf '%s' "$out"
printf 'summary: in_progress=%s stranded=%s threshold_events=0\n' "$total" "$stranded"
