#!/usr/bin/env bash
# freshness: added 2026-08-23 linux-yoga (order 856-s56y)
# @trace order:856-s56y
#
# tillandsias-cycle-driver.sh — fire ONE unattended meta-orchestration cycle.
#
# This is the ExecStart of the durable scheduler (systemd user timer on Linux;
# the launchd/Task Scheduler children of 856-s56y wrap the same script). Each
# fire runs exactly one fresh agent session through ./repeat --times 1 — the
# operator's supervisor, mechanized. The TIMER is the operator's standing
# instruction; agents still never run ./repeat interactively from inside their
# own sessions.
#
# Properties this script owns (856-s56y exit criterion 4):
#   NO STACKING — a non-blocking flock on <git-dir>/tillandsias-cycle.lock.
#     If a cycle is already running (this scheduler, a sibling scheduler, or
#     an operator's ./repeat holding the same lock), the fire SKIPS, exit 0:
#     a skipped tick is the designed outcome, never a failure. The systemd
#     timer additionally cannot re-enter its own active service, and
#     OnUnitInactiveSec counts the interval FROM COMPLETION — three layers,
#     each sufficient alone.
#   FAILURE DOES NOT STOP THE SCHEDULE — the timer fires on its own clock
#     regardless of this script's exit code; the exit code and a JSONL record
#     (state dir below) keep the outcome observable per fire.
#
# Verdict grammar (exactly one line on stdout, last):
#   ^(ok:cycle-fired:rc=0|skip:overlap-lock-held|fail:cycle-driver:rc=[0-9]+)$
#
# Seams (all optional, fixture use — see scripts/test-cycle-driver.sh):
#   TILLANDSIAS_CYCLE_ROOT       checkout root (default: this script's repo)
#   TILLANDSIAS_CYCLE_CMD        command to run instead of ./repeat (fixture)
#   TILLANDSIAS_CYCLE_PROMPT     cycle prompt (default: the skill bootstrap)
#   TILLANDSIAS_CYCLE_AGENTS     comma list passed to --agent (default: the
#                                subset of claude,opencode,gemini,codex on PATH)
#   TILLANDSIAS_CYCLE_TIMEOUT    per-cycle hard cap (default 90m)
#   TILLANDSIAS_CYCLE_STATE_DIR  JSONL dir (default ~/.cache/tillandsias)
set -uo pipefail

ROOT="${TILLANDSIAS_CYCLE_ROOT:-}"
if [ -z "$ROOT" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi
cd "$ROOT" || { echo "fail:cycle-driver:rc=2"; exit 2; }

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR="$ROOT"
LOCK="$GIT_DIR/tillandsias-cycle.lock"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/cycle-scheduler.jsonl"
TS_START="$(date -u +%FT%TZ)"
EPOCH_START="$(date +%s)"

record() { # rc skipped
    printf '{"ts_start":"%s","ts_end":"%s","duration_s":%d,"rc":%d,"skipped":%s,"host":"%s"}\n' \
        "$TS_START" "$(date -u +%FT%TZ)" "$(( $(date +%s) - EPOCH_START ))" \
        "$1" "$2" "$(uname -n | cut -d. -f1)" >> "$LOG" 2>/dev/null || true
}

# ── no-stacking lock (held for the whole cycle via fd 9) ─────────────────────
exec 9>"$LOCK" || { echo "fail:cycle-driver:rc=3"; exit 3; }
if ! flock -n 9; then
    record 0 true
    echo "skip:overlap-lock-held"
    exit 0
fi

# ── resolve the one-cycle command ────────────────────────────────────────────
if [ -n "${TILLANDSIAS_CYCLE_CMD:-}" ]; then
    set -- bash -c "$TILLANDSIAS_CYCLE_CMD"
else
    AGENTS="${TILLANDSIAS_CYCLE_AGENTS:-}"
    if [ -z "$AGENTS" ]; then
        for a in claude opencode gemini codex; do
            command -v "$a" >/dev/null 2>&1 && AGENTS="${AGENTS:+$AGENTS,}$a"
        done
    fi
    if [ -z "$AGENTS" ]; then
        record 127 false
        echo "fail:cycle-driver:rc=127"
        exit 127
    fi
    set -- ./repeat --times 1 --wait 1s \
        --timeout "${TILLANDSIAS_CYCLE_TIMEOUT:-90m}" \
        --agent "$AGENTS" \
        --prompt "${TILLANDSIAS_CYCLE_PROMPT:-Use the ./skills/meta-orchestration skill.}"
fi

"$@"
RC=$?
record "$RC" false
if [ "$RC" -eq 0 ]; then
    echo "ok:cycle-fired:rc=0"
else
    echo "fail:cycle-driver:rc=$RC"
fi
exit "$RC"
