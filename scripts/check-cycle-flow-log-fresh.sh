#!/usr/bin/env bash
# @trace order:943-7dn5
#
# The cycle-flow log must be FRESH, not merely well-formed.
#
# THE DEFECT THIS EXISTS FOR IS A SUBSTITUTION. 682-epud shipped
# `cycle-metrics.sh --emit-flow`, its fixture proves the emitter works, and the
# emitter is `done`. What was never built is the CALL. The instruction to emit
# lives in skills/meta-orchestration (the coordinator's hourly skill) and was
# absent from skills/advance-work-from-plan — the skill every worker host runs
# every cycle — so the log collected seven records from a single day in August
# and nothing since.
#
# WHY THE EXISTING LITMUS COULD NOT SEE IT. litmus-cycle-flow-telemetry-shape
# invokes `--emit-flow` ITSELF and then asserts on what it just wrote. That is a
# correct test of the emitter and a green light over a dead log: it can never
# fail for the reason the log is empty, because it fills the log first. A guard
# that only validates record SHAPE has the same blind spot — every row in a
# four-day-dead log is perfectly well-formed.
#
# `completed` was 0 in all seven rows, and cycle-metrics computes
# overhead_ratio only `if completed > 0`, so the metric has printed `-` for its
# entire existence. 689-zwzm gates a concurrency ramp on that number. A ramp
# gated on a structurally absent metric either never lifts or lifts because the
# absence reads as calm — which is why this is p1 and why the packet records
# the rule that an unfed metric is a RED gate, never a pass.
#
# WHAT IT REFUSES, AND WHAT IT DELIBERATELY DOES NOT. It refuses a log that is
# absent or stale ON A HOST THAT HAS BEEN RUNNING CYCLES. Commits in the
# horizon window are the evidence of that: a host with no recent commits has
# not run a cycle, so it owes no record and gets a NAMED SKIP rather than a
# failure. A fresh checkout, a host between sessions and a forge that never
# commits must not go red for a defect they do not have (1024-c3h3: a check
# that cannot run says so, and never reports clean).
#
# NOT WIRED INTO ./build.sh --check ON PURPOSE. Every host's log is stale today
# — that is the finding — so a blocking gate step would refuse every land in
# the fleet at once, on hosts that are mid-cycle. It is bound to the litmus
# instead (an activation surface), and the sequencing for promoting it to a
# blocking gate is: the worker protocol emits first, hosts accumulate records,
# then the gate. Wiring a guard the whole fleet fails is how a correct guard
# gets switched off.
#
# Grammar (one line on stdout):
# THE HORIZON IS ACTIVITY, NOT A CLOCK, and picking that took a measurement.
# An absolute "older than N hours" horizon is arbitrary and wrong in both
# directions: it accuses a host that has been idle legitimately, and it excuses
# one that ran fifty cycles inside the window without emitting. The question the
# packet actually asks is "did cycles run since the last record", and commits
# after the newest record answer it directly.
#
# MEASURED HERE 2026-09-06: newest record 2026-09-04T05:20:23Z, and 979 commits
# land after it. A 48h clock horizon called that FRESH at 44h. The activity rule
# refuses it, which is what criterion 2 asks for.
#
# GRACE EXISTS BECAUSE THE CURRENT CYCLE HAS NOT EMITTED YET. A cycle commits
# and then emits, so its own commits are always newer than the last record for
# as long as it is running. Only commits older than the grace window count, so
# an in-flight cycle is never accused of the omission it is about to fix.
#
# Grammar (one line on stdout):
#   ok:cycle-flow-log-fresh:newest=<iso> commits_since=<n>
#   violation:cycle-flow-log-stale:<absent|newest=<iso>>:commits_since=<n>
#   skip:cycle-flow-log-fresh:<reason>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

GRACE_H=2
LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grace-hours) GRACE_H="${2:-}"; shift 2 ;;
        --log)   LOG="${2:-}";       shift 2 ;;
        *) echo "usage: check-cycle-flow-log-fresh.sh [--grace-hours N] [--log PATH]" >&2; exit 2 ;;
    esac
done
case "$GRACE_H" in
    ''|*[!0-9]*) echo "error: --grace-hours needs a non-negative integer" >&2; exit 2 ;;
esac

if [ -z "$LOG" ]; then
    # shellcheck source=/dev/null
    . "$PWD/scripts/metrics-log-path.sh" 2>/dev/null || true
    if command -v metrics_default_log >/dev/null 2>&1; then
        LOG="${TILLANDSIAS_CYCLE_FLOW_LOG:-$(metrics_default_log tillandsias-cycle-flow.jsonl "$PWD")}"
    else
        LOG="${TILLANDSIAS_CYCLE_FLOW_LOG:-}"
    fi
fi
if [ -z "$LOG" ]; then
    echo "skip:cycle-flow-log-fresh:cannot-resolve-log-path"
    exit 0
fi

# NO SHELL DATE ARITHMETIC ANYWHERE, and the dialect guard (761-g36m) is why.
# The first draft converted the newest timestamp to an epoch with the GNU `-d`
# flag. That flag is an extension: BSD date SUCCEEDS WITH GARBAGE on it, so the
# `|| echo ""` fallback guarding it could never fire, and this check would have
# compared a nonsense number on every macOS host — accusing or excusing at
# random while looking perfectly healthy. Exactly the shape it exists to catch.
# Git parses both absolute ISO-8601 and relative dates itself, on every
# platform, so the comparison is handed to git and no shell parsing remains.
GRACE="${GRACE_H} hours ago"

# EVIDENCE THE HOST RUNS CYCLES AT ALL. Not "is this a repo" — a repo nobody
# works in owes nothing. If git cannot answer, skip rather than accuse.
settled="$(git log --until="$GRACE" --oneline -1 2>/dev/null | wc -l | tr -d ' ')"
case "$settled" in
    ''|*[!0-9]*) echo "skip:cycle-flow-log-fresh:git-log-unavailable"; exit 0 ;;
esac
if [ "$settled" -eq 0 ]; then
    echo "skip:cycle-flow-log-fresh:no-settled-commits-so-no-cycle-owes-a-record"
    exit 0
fi

if [ ! -s "$LOG" ]; then
    n="$(git log --until="$GRACE" --oneline 2>/dev/null | wc -l | tr -d ' ')"
    echo "violation:cycle-flow-log-stale:absent:commits_since=$n"
    {
        echo "  $n settled commit(s) and NO flow record at all:"
        echo "    $LOG"
        echo "  Cycles ran and none emitted. overhead_ratio cannot be computed"
        echo "  from an empty log, and a metric that is structurally absent is a"
        echo "  RED gate, never a pass (943-7dn5, 689-zwzm G1)."
        echo "  Fix: emit once per cycle — skills/advance-work-from-plan 7.0b."
    } >&2
    exit 1
fi

# Newest ts. MAXIMUM, not last line: append order is not guaranteed to be
# timestamp order when a cycle is interrupted and resumed. ISO-8601 UTC sorts
# lexicographically, which is the other reason no epoch conversion is needed.
newest="$(grep -o '"ts"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOG" 2>/dev/null \
    | sed 's/.*"\([^"]*\)"$/\1/' | sort | tail -1)"
if [ -z "$newest" ]; then
    echo "violation:cycle-flow-log-stale:no-parsable-ts:commits_since=-"
    echo "  $LOG has content but no record carries a \"ts\" field." >&2
    exit 1
fi

# THE RULE: commits that had time to emit (settled past the grace window) and
# are newer than the newest record are cycles that ran without emitting.
since="$(git log --since="$newest" --until="$GRACE" --oneline 2>/dev/null | wc -l | tr -d ' ')"
case "$since" in ''|*[!0-9]*) since=0 ;; esac

if [ "$since" -gt 0 ]; then
    echo "violation:cycle-flow-log-stale:newest=$newest:commits_since=$since"
    {
        echo "  $since settled commit(s) landed AFTER the newest flow record:"
        echo "    $LOG"
        echo "    newest record: $newest"
        echo "  Cycles have run since and none appended a record. This is the"
        echo "  substitution shape 943-7dn5 names: the emitter works, its fixture"
        echo "  proves it, the call is missing, and every row already in the log"
        echo "  is perfectly well-formed — so a shape check stays green over it."
    } >&2
    exit 1
fi

echo "ok:cycle-flow-log-fresh:newest=$newest commits_since=0"
