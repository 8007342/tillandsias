#!/usr/bin/env bash
# @trace order:1204-3s2s, order:1916-tsel, spec:ci-release
#
# gate-step-metrics-attribution.sh <shared-log> <lines-before> <run-id>
#
# The 1204-3s2s leak check used to refuse a gate step when the shared fallback
# timing log (/tmp/tillandsias-timing.jsonl) GREW while the step ran. On a host
# running two gates at once (a land queue and a release gate, or an agent's
# worktree gate) the other gate's records grew it too, and the running step
# was blamed and its PR evicted (coordinator, 2026-10-29: two evictions).
#
# Attribution is by the gate's run id. build.sh exports TILLANDSIAS_TIMING_RUN_ID
# (1915-gtph) and every child inherits it, so cycle-metrics.sh stamps it into
# each record a step's children write. Steps inside one gate run one at a
# time, so a new record carrying THIS gate's run id was written by THIS step.
#
# Prints one line:  ours=<n> foreign=<n> unattributed=<n>
#   ours          new records carrying <run-id>          -> the step leaked
#   foreign       new records carrying another run id    -> another gate; ignore
#   unattributed  new records with no run id at all      -> cannot be blamed on
#                 the step; build.sh reports them as a warning, not a refusal
# Exit 0 always when it could read; 2 on a usage error.
set -uo pipefail
log="${1:-}"; before="${2:-}"; run="${3:-}"
if [ -z "$log" ] || [ -z "$run" ]; then
    echo "could-not-run:gate-step-metrics-attribution:usage" >&2
    echo "  why: without the log path and this gate's run id no record can be attributed" >&2
    echo "  remedy: gate-step-metrics-attribution.sh <shared-log> <lines-before> <run-id>" >&2
    exit 2
fi
case "$before" in ''|*[!0-9]*) before=0 ;; esac
if [ ! -f "$log" ]; then echo "ours=0 foreign=0 unattributed=0"; exit 0; fi
awk -v skip="$before" -v id="\"run_id\":\"$run\"" '
    NR <= skip { next }
    index($0, id) { o++; next }
    /"run_id":"/  { f++; next }
    { u++ }
    END { printf "ours=%d foreign=%d unattributed=%d\n", o, f, u }
' "$log"
