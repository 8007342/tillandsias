#!/usr/bin/env bash
# @trace order:1115-srfr, spec:ci-release
#
# report-held-claims.sh — what is THIS host still holding, right now?
#
# Claims are cycle-scoped: a host claims one session's slice, not the packet.
# So a claim still held by this host at its own finalization is unreleased BY
# DEFINITION. There is nothing to adjudicate — the host either finishes it or
# releases it, and it is the only party that knows which.
#
# WHY THIS IS NOT check-stranded-in-progress.sh. That is a FLEET sweep for a
# COORDINATOR: STRANDED_HOURS defaults to 8 and it carries no host filter at
# all. Its advisory-never-a-gate discipline is correct for what it does,
# because a packet legitimately in flight is indistinguishable from one
# abandoned an hour ago, so bulk-closing what it reports would mark unfinished
# work done. This question needs no judgement and no aging.
#
# THE AGING IS EXACTLY WHAT MAKES THE SWEEP UNABLE TO SERVE AS THE FIX. Both
# instances that produced this script — 1071-adhj left in_progress ~24h and
# 1063-nraf ~20h, same host, one day — would have surfaced EIGHT HOURS after
# the cycle that stranded them, on someone else's screen, needing human
# judgement. The exiting host could have resolved either in one command, with
# none.
#
# ZERO HELD CLAIMS PRINTS AN AFFIRMATIVE LINE, never silence. Silence is
# indistinguishable from the check not running, which is the failure this
# stretch of orders keeps meeting: a verdict asserting more than its check
# supports, or no verdict at all where one was assumed.
#
# ADVISORY. Exit 0 in every reachable state, including when it cannot run.
# Making this a refusal is a fleet decision (1115-srfr criterion 3), not this
# script's to take: it runs on every host. If a host strands a claim again WITH
# this in place, that is the evidence to escalate — and the escalation is a
# refusal naming the release command, since releasing at that point is always
# correct and costs seconds.
#
# Verdict grammar, one line, then optional detail:
#   ok:cycle-claims-released:0 held by <host>
#   warn:cycle-claims-held:<n> by <host> — ...
#   skip:cycle-claims:no-plan-binary — ...
#   skip:cycle-claims:no-host-identity — ...
#
# usage: scripts/report-held-claims.sh [host]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 721-nyev: resolve the binary through the SHARED probe. An executable bit is a
# claim; running the binary is evidence.
. "$SCRIPT_DIR/plan-binary-probe.sh"

PLAN="$(resolve_plan_binary)" || PLAN=""
HOST="${1:-$("$SCRIPT_DIR/agent-identity.sh" node-name 2>/dev/null || echo "")}"

if [ -z "$PLAN" ]; then
    echo "skip:cycle-claims:no-plan-binary — cannot ask what this host holds"
    exit 0
fi
if [ -z "$HOST" ]; then
    echo "skip:cycle-claims:no-host-identity — cannot scope the question to this host"
    exit 0
fi

# `expire-claims --list-live` is READ-ONLY in this form and already derives the
# live set; column 4 is the holding host. No aging: any held claim is the answer.
held="$("$PLAN" expire-claims --list-live 2>/dev/null \
    | awk -F'\t' -v h="$HOST" '$1=="live-claim" && $4==h')"

if [ -z "$held" ]; then
    echo "ok:cycle-claims-released:0 held by $HOST"
    exit 0
fi

n="$(printf '%s\n' "$held" | grep -c .)"
echo "warn:cycle-claims-held:$n by $HOST — a cycle-scoped claim held at finalization is unreleased; finish it or release it:"
printf '%s\n' "$held" | while IFS="$(printf '\t')" read -r _tag order packet _rest; do
    [ -n "$order" ] || continue
    echo "  $order  $packet"
    echo "    tillandsias-plan set-field $order status ready --reason \"released on cycle exit: <what remains>\""
done
exit 0
