#!/usr/bin/env bash
# @trace order:1204-3s2s, order:1916-tsel, spec:ci-release
#
# gate-step-metrics-attribution.sh <shared-log> <lines-before> <run-id> [<own-gate-pid>]
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
# Prints one line:  ours=<n> foreign=<n> unattributed=<n> concurrent=<0|1> verdict=<v>
#   ours          new records carrying <run-id>          -> the step leaked
#   foreign       new records carrying another run id    -> another gate; ignore
#   unattributed  new records with no run id at all
# verdict:
#   refuse  ours>0, OR unattributed>0 with NO concurrent gate: an id-less
#           record with nobody else running can only be this step's (a
#           fixture that scrubbed its env), so the leak gate keeps its teeth
#   warn    unattributed>0 while another gate is live: it may be theirs
#   ok      nothing of ours
# A gate is CONCURRENT when a foreign run id landed in the same window, or a
# sibling gate process (build.sh --check / --ci-full / --gate-steps) is alive
# outside this gate's own ancestry (own-gate-pid and its ancestors are
# excluded). TILLANDSIAS_GATE_SIBLING_PATTERN overrides the pgrep pattern so
# a fixture can control the probe.
# Exit 0 always when it could read; 2 on a usage error.
set -uo pipefail
log="${1:-}"; before="${2:-}"; run="${3:-}"
if [ -z "$log" ] || [ -z "$run" ]; then
    echo "could-not-run:gate-step-metrics-attribution:usage" >&2
    echo "  why: without the log path and this gate's run id no record can be attributed" >&2
    echo "  remedy: gate-step-metrics-attribution.sh <shared-log> <lines-before> <run-id>" >&2
    exit 2
fi
own="${4:-$PPID}"
case "$before" in ''|*[!0-9]*) before=0 ;; esac
if [ ! -f "$log" ]; then echo "ours=0 foreign=0 unattributed=0 concurrent=0 verdict=ok"; exit 0; fi
counts="$(awk -v skip="$before" -v id="\"run_id\":\"$run\"" '
    NR <= skip { next }
    index($0, id) { o++; next }
    /"run_id":"/  { f++; next }
    { u++ }
    END { printf "%d %d %d\n", o, f, u }
' "$log")"
read -r o f u <<<"$counts"

# This gate's own process chain, so its own build.sh never counts as a sibling.
ancestors=" $$ "
p="$own"
while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    ancestors="$ancestors$p "
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
done
concurrent=0
[ "${f:-0}" -gt 0 ] && concurrent=1
if [ "$concurrent" -eq 0 ]; then
    pat="${TILLANDSIAS_GATE_SIBLING_PATTERN:-build\.sh --(check|ci-full|gate-steps)}"
    for sp in $(pgrep -f -- "$pat" 2>/dev/null); do
        case "$ancestors" in *" $sp "*) continue ;; esac
        # a child of this gate (a fixture driving --gate-steps) is not a sibling
        q="$sp"; mine=0
        while [ -n "$q" ] && [ "$q" -gt 1 ] 2>/dev/null; do
            case "$ancestors" in *" $q "*) mine=1; break ;; esac
            q="$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' ')"
        done
        [ "$mine" -eq 1 ] && continue
        concurrent=1; break
    done
fi
verdict=ok
if [ "${o:-0}" -gt 0 ]; then verdict=refuse
elif [ "${u:-0}" -gt 0 ]; then
    if [ "$concurrent" -eq 1 ]; then verdict=warn; else verdict=refuse; fi
fi
echo "ours=${o:-0} foreign=${f:-0} unattributed=${u:-0} concurrent=$concurrent verdict=$verdict"
