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

# ── no-stacking lock (held for the whole cycle) ──────────────────────────────
# TWO ARMS (856-s56y, found by the macOS launchd verifier 2026-08-23): the
# original unconditional `flock -n 9` assumed util-linux flock(1), which stock
# macOS does not ship — the invocation failed command-not-found, `if !` read
# that as "lock held", and EVERY fire on a Darwin host skipped with exit 0,
# indistinguishable from the designed skip. The silent cadence death this
# driver exists to prevent, produced by the driver itself.
#
# flock arm: locks fd 9's open file description; auto-releases on process
# death. mkdir arm (POSIX; runtime_language_policy forbids reaching for
# another interpreter here): atomic mkdir plus liveness-checked staleness —
# a lock whose recorded PID is dead, or older than 10800s (2x the default
# 90m cycle cap, covering PID reuse), is reclaimed; the reclaim's mkdir race
# elects exactly one winner. The trap approximates flock's auto-release; a
# SIGKILLed cycle is covered by the liveness check on the next fire.
exec 9>"$LOCK" || { echo "fail:cycle-driver:rc=3"; exit 3; }
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        record 0 true
        echo "skip:overlap-lock-held"
        exit 0
    fi
    # ORDER 873-zcim — CROSS-ARM CHECK. Prompt-launched cycles (an operator
    # sentence, a /loop cron, a cloud schedule) cannot hold a flock: they span
    # many short-lived shells with no fd that survives between them. They hold
    # the mkdir dir via scripts/cycle-checkout-lock.sh instead. Winning the
    # flock therefore proves only that no OTHER DRIVER runs; a prompt-lane
    # cycle in this same checkout is invisible to fd 9 — which is exactly how
    # a /loop fire stacked on a running driver on yoga, 2026-08-24, holding
    # claims the driver then duplicated. Check the dir, liveness-aware, with
    # the same staleness bound as the dir arm below.
    LOCKD="$LOCK.d"
    if [ -d "$LOCKD" ]; then
        _xa_pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
        _xa_born="$(cat "$LOCKD/epoch" 2>/dev/null || echo 0)"
        case "$_xa_born" in *[!0-9]*|"") _xa_born=0 ;; esac
        _xa_age=$(( $(date +%s) - _xa_born ))
        if [ -n "$_xa_pid" ] && kill -0 "$_xa_pid" 2>/dev/null && [ "$_xa_age" -le 10800 ]; then
            record 0 true
            echo "skip:overlap-lock-held"
            exit 0
        fi
        # Stale prompt-lane lock (dead holder / beyond bound): reclaim it so a
        # crashed /loop cannot silence the cadence forever.
        rm -rf "$LOCKD" 2>/dev/null || true
    fi
else
    LOCKD="$LOCK.d"
    if ! mkdir "$LOCKD" 2>/dev/null; then
        _holder="$(cat "$LOCKD/pid" 2>/dev/null || true)"
        _born="$(cat "$LOCKD/epoch" 2>/dev/null || echo 0)"
        case "$_born" in *[!0-9]*|"") _born=0 ;; esac
        _age=$(( $(date +%s) - _born ))
        if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null && [ "$_age" -le 10800 ]; then
            record 0 true
            echo "skip:overlap-lock-held"
            exit 0
        fi
        rm -rf "$LOCKD" 2>/dev/null || true
        if ! mkdir "$LOCKD" 2>/dev/null; then
            record 0 true
            echo "skip:overlap-lock-held"
            exit 0
        fi
    fi
    printf '%s\n' "$$" > "$LOCKD/pid"
    date +%s > "$LOCKD/epoch"
    trap 'rm -rf "$LOCKD" 2>/dev/null || true' EXIT
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
