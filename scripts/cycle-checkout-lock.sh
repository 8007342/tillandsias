#!/usr/bin/env bash
# @trace spec:meta-orchestration
# cycle-checkout-lock.sh — the CHECKOUT lock, acquirable from EVERY lane.
#
# ORDER 873-zcim. The no-stacking lock existed and was held — by the driver
# lane only. scripts/tillandsias-cycle-driver.sh takes a non-blocking flock on
# <git-dir>/tillandsias-cycle.lock around its whole cycle, so the DRIVER never
# stacks on itself. But a cycle started any other way — an operator prompt, a
# Claude Code /loop cron, a cloud schedule, a human typing the sentence —
# acquired NOTHING. On 2026-08-24 a 4-hourly /loop fired on yoga 21 minutes
# into a running driver cycle in the same worktree; the newcomer could see the
# driver's lock but had no way to take one of its own, and the driver cannot
# refuse a stacker it cannot see. Four hours earlier on the same host, one
# process's disposal of a worktree destroyed another's uncommitted work
# (872-c9nd). The lock guarded the driver lane; the thing two agents actually
# contend for is the CHECKOUT.
#
# WHY THE PROMPT LANES CANNOT USE THE FLOCK ARM. flock guards an open file
# descriptor and releases when the holding process exits. The driver IS one
# process wrapping its whole cycle, so that works. A skill-driven cycle is a
# CHAIN of short-lived shells — no single process spans it, so there is no fd
# to hold. These lanes use the mkdir arm (atomic, survives process exit) with
# the AGENT HARNESS pid as the liveness anchor: the parent of the tool shells
# (e.g. the `claude` process) lives for the whole session and `kill -0` on it
# answers "is that cycle still possibly running".
#
# CROSS-ARM VISIBILITY, both directions, or the gap just moves:
#   - acquire here takes the mkdir dir FIRST (the atomic claim among prompt
#     lanes), then PROBES the driver's flock; if the driver holds it, we
#     release our dir and skip.
#   - the driver, after winning its flock, now ALSO checks this dir
#     (liveness-aware) and skips if a prompt-lane cycle holds it.
#   A simultaneous grab can make BOTH back off for one tick; both fire again
#   on their own clocks, and a skipped tick is the designed outcome (the
#   driver's own words). Livelock resolves at the next uncontended fire.
#
# EXIT CRITERION 3: a cycle refused for overlap must be distinguishable from a
# cycle that ran and found nothing. The refusing cycle must NOT write into the
# contended checkout — that is the hazard being refused — so the durable
# record goes OUTSIDE it: one JSONL line per refusal in
# ${TILLANDSIAS_CYCLE_STATE_DIR:-~/.cache/tillandsias}/overlap-refusals.jsonl,
# carrying who was refused and who held. The coordinator can sweep that file.
#
# EXIT CRITERION 4, DECIDED: a second agent NEVER works in a locked checkout.
# The sanctioned path for concurrent work on one host is a separate worktree
# or a clean temp clone (the technique yoga used for both its wedge record and
# the 873-zcim filing itself). This script therefore has no "join" mode on
# purpose; asking for one is asking to be the 872-c9nd incident.
#
# Grammar (last line on stdout):
#   ok:checkout-lock:acquired:<lane>:<pid>
#   ok:checkout-lock:released
#   ok:checkout-lock:free            (status mode)
#   skip:overlap-lock-held:<holder-description>
#   fail:checkout-lock:<reason>
#
# Usage:
#   scripts/cycle-checkout-lock.sh acquire [--lane <name>] [--source <text>]
#   scripts/cycle-checkout-lock.sh release
#   scripts/cycle-checkout-lock.sh status
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "fail:checkout-lock:not-a-repo"; exit 2; }
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "fail:checkout-lock:no-git-dir"; exit 2; }
LOCK="$GIT_DIR/tillandsias-cycle.lock"
LOCKD="$LOCK.d"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"
# The liveness anchor: the agent-harness process that spans the whole cycle.
#
# CALLERS MUST PASS TILLANDSIAS_CYCLE_HOLDER_PID=$PPID FROM THEIR OWN SHELL.
# The default below — this script's $PPID — is one level too deep for an
# agent-tool invocation: it resolves to the tool-call wrapper shell, which
# dies the moment the call returns, so the lock's holder is dead within
# seconds and the next acquire stale-reclaims it. Measured live during
# 873-zcim's own bring-up: the first acquire recorded pid 1695105 (the
# wrapper), dead one tool-call later. Evaluated in the CALLER's shell, $PPID
# is the harness process (e.g. `claude`, alive for the whole session), which
# is the identity that actually spans the cycle.
HOLDER_PID="${TILLANDSIAS_CYCLE_HOLDER_PID:-$PPID}"
# Staleness bound: same 10800s (2x the 90m cycle cap) the driver uses.
STALE_S=10800

lane="prompt"
source_desc="unspecified"

now() { date +%s; }

dir_holder_desc() {
    printf 'lane=%s pid=%s since=%s source=%s' \
        "$(cat "$LOCKD/lane" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/pid" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/epoch" 2>/dev/null || echo '?')" \
        "$(cat "$LOCKD/source" 2>/dev/null || echo '?')"
}

dir_lock_live() {
    [ -d "$LOCKD" ] || return 1
    local pid born age
    pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
    born="$(cat "$LOCKD/epoch" 2>/dev/null || echo 0)"
    case "$born" in *[!0-9]*|"") born=0 ;; esac
    age=$(( $(now) - born ))
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$age" -le "$STALE_S" ]
}

# Is the DRIVER's flock held? Probe without keeping it: if we can take it, the
# driver is not running, and closing the fd releases our probe instantly.
driver_flock_held() {
    command -v flock >/dev/null 2>&1 || return 1
    ( exec 9>>"$LOCK"; flock -n 9 ) 2>/dev/null && return 1
    return 0
}

record_refusal() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '{"ts":"%s","event":"overlap-refused","refused_lane":"%s","refused_source":"%s","holder":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lane" "$source_desc" "$1" \
        >> "$STATE_DIR/overlap-refusals.jsonl" 2>/dev/null || true
}

cmd="${1:-status}"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --lane)   shift; lane="${1:-prompt}" ;;
        --source) shift; source_desc="${1:-unspecified}" ;;
        *) echo "fail:checkout-lock:unknown-arg:$1"; exit 2 ;;
    esac
    shift || true
done

case "$cmd" in
    acquire)
        # 1. The atomic claim among prompt lanes.
        if ! mkdir "$LOCKD" 2>/dev/null; then
            if dir_lock_live; then
                h="$(dir_holder_desc)"
                record_refusal "$h"
                echo "skip:overlap-lock-held:$h"
                exit 0
            fi
            # Stale (dead holder or beyond the bound): reclaim; the mkdir race
            # after rm elects exactly one winner, as in the driver.
            rm -rf "$LOCKD" 2>/dev/null || true
            if ! mkdir "$LOCKD" 2>/dev/null; then
                h="$(dir_holder_desc)"
                record_refusal "$h"
                echo "skip:overlap-lock-held:$h"
                exit 0
            fi
        fi
        printf '%s\n' "$HOLDER_PID" > "$LOCKD/pid"
        now > "$LOCKD/epoch"
        printf '%s\n' "$lane" > "$LOCKD/lane"
        printf '%s\n' "$source_desc" > "$LOCKD/source"
        # 2. Back off if the DRIVER holds its flock — it cannot see our dir
        #    mid-cycle (it checks only at start), so we yield to it.
        if driver_flock_held; then
            rm -rf "$LOCKD" 2>/dev/null || true
            record_refusal "driver-flock (tillandsias-cycle-driver.sh mid-cycle)"
            echo "skip:overlap-lock-held:driver-flock"
            exit 0
        fi
        echo "ok:checkout-lock:acquired:$lane:$HOLDER_PID"
        ;;
    release)
        # Only the holder (or a cleanup after its death) should release; a
        # mismatched pid refuses rather than silently freeing someone else's
        # cycle — the failure mode this lock exists to prevent.
        if [ -d "$LOCKD" ]; then
            held_pid="$(cat "$LOCKD/pid" 2>/dev/null || true)"
            if [ -n "$held_pid" ] && [ "$held_pid" != "$HOLDER_PID" ] && kill -0 "$held_pid" 2>/dev/null; then
                echo "fail:checkout-lock:held-by-other:$(dir_holder_desc)"
                exit 1
            fi
            rm -rf "$LOCKD" 2>/dev/null || true
        fi
        echo "ok:checkout-lock:released"
        ;;
    status)
        if dir_lock_live; then
            echo "skip:overlap-lock-held:$(dir_holder_desc)"
        elif driver_flock_held; then
            echo "skip:overlap-lock-held:driver-flock"
        else
            echo "ok:checkout-lock:free"
        fi
        ;;
    *)
        echo "fail:checkout-lock:unknown-command:$cmd"
        exit 2
        ;;
esac
