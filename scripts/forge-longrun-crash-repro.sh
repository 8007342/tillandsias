#!/usr/bin/env bash
# @trace plan/issues/forge-opencode-container-crash-trail-2026-08-02.md
# forge-longrun-crash-repro.sh — reproduce + forensically capture the
# "long-running OpenCode session crashes the container" bug, in automation.
#
# WHY: the operator reports that some OpenCode sessions (e.g. this forge
# session) crash the running container. Leading hypothesis: opencode runs as
# PID 1 and embeds Bun v1.3.14, the same runtime version that segfaulted on
# arm64 (plan/issues/forge-opencode-bun-segfault-2026-07-27.md). The crash is
# load/spawn-churn correlated and does not reproduce in minutes, so we must
# run a LONG spawn-heavy session while capturing a forensic trail that
# SURVIVES the container dying.
#
# DESIGN:
#   - Runs the target opencode session under a coprocess/background child,
#     sampling every N seconds: PID 1 identity, RSS/CPU, cgroup events,
#     pids.current, disk /tmp + root fill, db + log growth, process/thread
#     counts, Bun-relevant strings.
#   - Every sample + a heartbeat go to a TRAIL DIR on the DURABLE host mount
#     ($HOME/.cache/tillandsias-project/forge-crash-trail/), which is a btrfs
#     mount that survives container re-creation — unlike /tmp and the overlay.
#   - On child exit/crash: records the exit code + last log tail + cgroup
#     death evidence + core_pattern target, then reports where the trail went.
#   - Default session workload: `opencode run --print-logs --agent build`
#     running a spawn-heavy prompt in a scratch project, NOT this checkout
#     (so the repro cannot corrupt shared plan/ state mid-crash).
#
# Usage:
#   scripts/forge-longrun-crash-repro.sh run   [--duration 30m] [--sample 5]
#   scripts/forge-longrun-crash-repro.sh sample-only [--sample 5]  # observe current PID 1
#
# Output:
#   Writes trail to $TRAIL_DIR (printed on completion/crash). Exit codes:
#   0 = session completed without crash, 3 = session exited abnormally (crash
#   captured), 2 = usage/infra error.
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
DURATION="30m"
SAMPLE_INTERVAL=5
MODE="run"
WORKLOAD_PROMPT="${WORKLOAD_PROMPT:-Use the /meta-orchestration skill in smoke mode (verify-only) — run three cheap verify checks and exit.}"
TRAIL_ROOT="${TRAIL_DIR:-$HOME/.cache/tillandsias-project/forge-crash-trail}"
SNAPSHOT_ROOT="/tmp/forge-crash-trail"

usage() {
    cat >&2 <<'EOF'
Usage: $0 (run|sample-only) [--duration <dur>] [--sample <secs>]
  run         launch a long spawn-heavy opencode session and monitor it
  sample-only monitor the CURRENT PID 1 (no new session) and exit
  --duration  how long to monitor (default 30m; forms like 90m, 2h, 3600)
  --sample    sample interval in seconds (default 5)
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
MODE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2 ;;
        --sample) SAMPLE_INTERVAL="$2"; shift 2 ;;
        *) usage ;;
    esac
done

# Parse duration like 90m / 2h / 3600 into seconds.
parse_seconds() {
    local v="$1" n=0
    case "$v" in
        *m) n=$(( ${v%m} * 60 )) ;;
        *h) n=$(( ${v%h} * 3600 )) ;;
        *s) n=${v%s} ;;
        *)  n=$v ;;
    esac
    echo "$n"
}
MONITOR_SECS="$(parse_seconds "$DURATION")"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TRAIL_DIR="$TRAIL_ROOT/$STAMP"
DURABLE_READY=false
if [[ -w "$TRAIL_ROOT" ]] || mkdir -p "$TRAIL_ROOT" 2>/dev/null; then
    if touch "$TRAIL_ROOT/.write-test" 2>/dev/null; then
        rm -f "$TRAIL_ROOT/.write-test"
        DURABLE_READY=true
    fi
fi
mkdir -p "$TRAIL_DIR" "$SNAPSHOT_ROOT/$STAMP"
echo "trail: $TRAIL_DIR (durable=$DURABLE_READY)"
echo "started: $STAMP" > "$TRAIL_DIR/start.meta"
echo "mode: $MODE" >> "$TRAIL_DIR/start.meta"
echo "duration: $MONITOR_SECS" >> "$TRAIL_DIR/start.meta"
echo "sample: $SAMPLE_INTERVAL" >> "$TRAIL_DIR/start.meta"
echo "opencode: $(opencode --version 2>&1 || echo unknown)" >> "$TRAIL_DIR/start.meta"
echo "pid1: $(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')" >> "$TRAIL_DIR/start.meta"

# ── Forensics helpers ────────────────────────────────────────────────────────
bun_strings() {
    local bin="$1"
    strings "$bin" 2>/dev/null | grep -oE 'Bun v[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -3
}

snapshot() {
    local i="$1"
    local out="$TRAIL_DIR/sample-$i.txt"
    {
        echo "sample=$i ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "-- pid1 --"
        ps -o pid,ppid,rss,vsz,%cpu,%mem,etime,cmd -p 1 2>/dev/null || echo "PID1 GONE"
        echo "-- opencode procs --"
        pgrep -af opencode 2>/dev/null || echo "(none)"
        echo "-- cgroup --"
        echo "memory.current=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo n/a)"
        echo "memory.max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo n/a)"
        echo "pids.current=$(cat /sys/fs/cgroup/pids.current 2>/dev/null || echo n/a)"
        echo "pids.max=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo n/a)"
        echo "-- memory.events --"
        cat /sys/fs/cgroup/memory.events 2>/dev/null || echo "(n/a)"
        echo "-- disk --"
        df -h / /tmp 2>/dev/null
        echo "-- procs/threads --"
        echo "procs=$(ps -e --no-headers 2>/dev/null | wc -l) threads=$(ls /proc/1/task 2>/dev/null | wc -l)"
        echo "-- opencode data --"
        du -sh "$HOME/.local/share/opencode/opencode.db" 2>/dev/null || echo "(db absent)"
        stat -c 'db_size=%s mtime=%y' "$HOME/.local/share/opencode/opencode.db" 2>/dev/null || true
        echo "-- bun strings --"
        local ocbin="$HOME/.cache/tillandsias-project/npm/global/lib/node_modules/opencode-ai/bin/opencode.exe"
        [[ -f "$ocbin" ]] && bun_strings "$ocbin" || echo "(binary absent)"
        echo "-- log tail --"
        tail -3 "$HOME/.local/share/opencode/log/opencode.log" 2>/dev/null || echo "(no log)"
    } > "$out"
    cp "$out" "$SNAPSHOT_ROOT/$STAMP/sample-$i.txt" 2>/dev/null || true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sample=$i" >> "$TRAIL_DIR/heartbeat.log"
}

# ── sample-only mode ─────────────────────────────────────────────────────────
if [[ "$MODE" == "sample-only" ]]; then
    for ((i = 1; i * SAMPLE_INTERVAL <= MONITOR_SECS + SAMPLE_INTERVAL; i++)); do
        snapshot "$i"
        sleep "$SAMPLE_INTERVAL"
    done
    echo "sample-only done: $TRAIL_DIR"
    exit 0
fi

[[ "$MODE" == "run" ]] || usage

# ── run mode: launch a long spawn-heavy opencode session ────────────────────
SCRATCH_PROJECT="$(mktemp -d /tmp/crash-repro-project.XXXXXX)"
REPRO_SESSION_LOG="$TRAIL_DIR/repro-session.log"
OPENCODE_DATA_DIR="$SNAPSHOT_ROOT/$STAMP/opencode-data"
mkdir -p "$OPENCODE_DATA_DIR"

echo "launching opencode run in $SCRATCH_PROJECT (data $OPENCODE_DATA_DIR)"
# Isolate the repro session's data dir so it cannot corrupt the live session's
# opencode.db, and mirror XDG_DATA_HOME through opencode's lookup.
(
    cd "$SCRATCH_PROJECT"
    XDG_DATA_HOME="$OPENCODE_DATA_DIR" \
    XDG_STATE_HOME="$OPENCODE_DATA_DIR/state" \
    XDG_CACHE_HOME="$OPENCODE_DATA_DIR/cache" \
    nohup opencode run --print-logs --agent build "$WORKLOAD_PROMPT" \
        >> "$REPRO_SESSION_LOG" 2>&1 &
    echo $!
) > "$TRAIL_DIR/repro.pid"

REPRO_PID="$(cat "$TRAIL_DIR/repro.pid")"
echo "repro pid: $REPRO_PID"

# spawn a spawn-heavy churn loop in the scratch project to load the session
CHURN_LOG="$TRAIL_DIR/churn.log"
(
    for ((c = 0; c * 5 < MONITOR_SECS; c++)); do
        for _ in 1 2 3 4 5; do
            /bin/true
        done
        sleep 5
    done
) >> "$CHURN_LOG" 2>&1 &
CHURN_PID=$!
echo "churn pid: $CHURN_PID" >> "$TRAIL_DIR/start.meta"

# ── monitor loop ─────────────────────────────────────────────────────────────
DEAD=false
for ((i = 1; i * SAMPLE_INTERVAL <= MONITOR_SECS + SAMPLE_INTERVAL; i++)); do
    snapshot "$i"
    if ! kill -0 "$REPRO_PID" 2>/dev/null; then
        DEAD=true
        break
    fi
    sleep "$SAMPLE_INTERVAL"
done

kill -0 "$REPRO_PID" 2>/dev/null && { kill "$REPRO_PID" 2>/dev/null || true; }
kill "$CHURN_PID" 2>/dev/null || true

# ── death/exit capture ───────────────────────────────────────────────────────
{
    echo "monitor_exit=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$DEAD" == true ]]; then
        echo "verdict: SESSION_EXITED_ABNORMALLY"
        if ! kill -0 "$REPRO_PID" 2>/dev/null && [[ -n "$REPRO_PID" ]]; then
            wait "$REPRO_PID" 2>/dev/null; echo "repro_exit_code=$?"
        fi
        echo "-- repro session log tail --"
        tail -50 "$REPRO_SESSION_LOG" 2>/dev/null || echo "(no log)"
        echo "-- cgroup death evidence --"
        cat /sys/fs/cgroup/memory.events 2>/dev/null || true
        echo "-- core_pattern --"
        cat /proc/sys/kernel/core_pattern 2>/dev/null || true
    else
        echo "verdict: NO_CRASH_WITHIN_BUDGET"
    fi
    echo "-- pid1 final --"
    ps -o pid,rss,%cpu,etime,cmd -p 1 2>/dev/null || echo "PID1 GONE"
} > "$TRAIL_DIR/exit.meta"

if [[ "$DEAD" == true ]]; then
    echo "CRASH CAPTURED: $TRAIL_DIR"
    exit 3
else
    echo "NO CRASH within ${DURATION}: $TRAIL_DIR"
    exit 0
fi
