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
#   ^summary: (in_progress=<n> stranded=<n> threshold_events=<n>|unavailable:<reason>)$
#
# `unavailable:<reason>` (702-68zj) is a THIRD verdict for "this sweep could not
# be computed" — no runnable plan binary, no jq, a failed or unparseable query.
# It is deliberately not an all-zero summary: reporting zero because the sweep
# could not look is how a stranded packet became invisible in a third way.
# Exit 0 always: this is an advisory report, not a gate. A packet legitimately
# in flight right now is indistinguishable from one abandoned an hour ago, so
# failing a build on it would block work for a state that is often correct.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# ORDER 702-68zj. Probe candidates by RUNNING one, not by testing an executable
# bit. On a shared Windows/WSL checkout a WSL build leaves a Linux ELF at
# ./target/release/tillandsias-plan beside the usable .exe, and the bit test
# picks the ELF: every later query dies with `Exec format error`, stderr is
# discarded, and empty output was counted as zero stranded packets. The sweep
# printed a clean all-clear while a stranded packet sat in the ledger.
#
# `.exe` candidates come first for the same reason — on the host where both
# exist, the runnable one is the .exe.
PLAN=""
for c in \
    ./target/release/tillandsias-plan.exe \
    ./target/debug/tillandsias-plan.exe \
    ./target/release/tillandsias-plan \
    ./target/debug/tillandsias-plan \
    "$(command -v tillandsias-plan 2>/dev/null)"; do
    [ -n "$c" ] || continue
    [ -f "$c" ] || continue
    # The probe IS the executability test: a binary that cannot run here fails
    # this, whatever its mode bits or extension claim.
    "$c" capabilities >/dev/null 2>&1 && { PLAN="$c"; break; }
done

# UNAVAILABLE is a THIRD verdict, not a quiet zero (702-68zj). This sweep exists
# to catch work that is invisible in both directions — `ready` queries skip an
# in_progress packet and burndown does not count it. Reporting zero because the
# sweep could not look makes that work invisible in a third way, and does it
# while printing the exact line an operator reads as "checked, nothing there".
# Same convention as verify:skip-stale-staging (447) and skip:no-tray-binary
# (620-duta). Exit stays 0: this is advisory, and an unavailable sweep is not a
# build failure.
[ -n "$PLAN" ] || {
    echo "summary: unavailable:no-runnable-plan-binary"
    exit 0
}

command -v jq >/dev/null 2>&1 || {
    echo "summary: unavailable:no-jq"
    exit 0
}

# Keep the query's own failure distinguishable from "the query found nothing"
# (702-68zj). Piping straight into jq collapses both into an empty string, which
# is how the original false all-clear was produced.
if ! raw="$("$PLAN" query --status in_progress --limit 200 --json 2>/dev/null)"; then
    echo "summary: unavailable:plan-query-failed"
    exit 0
fi
if ! rows="$(printf '%s' "$raw" \
    | jq -r '.[] | [(.order|tostring), (.pickup_role // "unassigned"), .packet_id] | @tsv' 2>/dev/null)"; then
    echo "summary: unavailable:plan-query-unparseable"
    exit 0
fi

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

# ORDER 672-bz7u: when the binary carries expire-claims, threshold_events
# reports how many stranded claims a `tillandsias-plan expire-claims` run
# would return to ready right now (24h TTL). Advisory only — this script
# still closes nothing; the expiry is an explicit, separate invocation.
threshold=0
if "$PLAN" capabilities 2>/dev/null | grep -qx 'expire-claims'; then
    threshold=$("$PLAN" expire-claims --dry-run 2>/dev/null \
        | grep -c '^expire-candidate' || true)
    if [ "${threshold:-0}" -gt 0 ]; then
        echo "hint: ${threshold} claim(s) past the 24h TTL — run 'tillandsias-plan expire-claims' to return them to ready (641-e2qa criterion 2)"
    fi
fi
printf 'summary: in_progress=%s stranded=%s threshold_events=%s\n' "$total" "$stranded" "${threshold:-0}"
