#!/usr/bin/env bash
# forge-liveness-probe.sh — Host-side forge agent liveness probe
# Order 265: forge-agent-liveness-signals
#
# Polls three signals (container state, heartbeat file mtime, git HEAD)
# and classifies the forge agent into one of five liveness states.
#
# Usage:
#   forge-liveness-probe.sh status [options]   — print current state
#   forge-liveness-probe.sh wait [options]     — poll until dead, exit non-zero
#   forge-liveness-probe.sh deadline [options] — print wall-clock deadline
#
# Exit codes:
#   0 — alive (progressing or quiet)
#   1 — dead (air, crashed, or killed)
#   2 — usage error
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_DIR="${PWD}"
HEARTBEAT_FILE=".forge-heartbeat"
HEARTBEAT_DEADLINE_SECS=120
POLL_INTERVAL_SECS=10
BUDGET_SECS=5400
START_EPOCH=""
BEFORE_HEAD=""
FORGE_CONTAINER_PATTERN="tillandsias-forge"
SKIP_CONTAINER_CHECK=false
MODE=""

# ── Parse args ────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: forge-liveness-probe.sh <mode> [options]

Modes:
  status    — print one of: alive_progressing, alive_quiet, dead_air,
              dead_crashed, dead_killed
  wait      — poll until state changes from alive_* to dead_*,
              exit non-zero on dead
  deadline  — print the wall-clock deadline given a start time and budget

Options:
  --project-dir <path>        project directory (default: $PWD)
  --heartbeat-file <path>     heartbeat file (default: .forge-heartbeat)
  --heartbeat-deadline <s>    stale threshold in seconds (default: 120)
  --poll-interval <s>         polling interval in seconds (default: 10)
  --budget <s>                total budget in seconds (default: 5400)
  --start-time <epoch>        cycle start time as epoch seconds (default: now)
  --container <pattern>       podman container name pattern (default: tillandsias-forge)
  --no-container              skip container check (assume running; for testing)
  --before-head <sha>         git HEAD before the cycle started (for git-changed probe)
EOF
    exit 2
}

[[ $# -lt 1 ]] && usage
MODE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)      PROJECT_DIR="$2"; shift 2 ;;
        --heartbeat-file)   HEARTBEAT_FILE="$2"; shift 2 ;;
        --heartbeat-deadline) HEARTBEAT_DEADLINE_SECS="$2"; shift 2 ;;
        --poll-interval)    POLL_INTERVAL_SECS="$2"; shift 2 ;;
        --budget)           BUDGET_SECS="$2"; shift 2 ;;
        --start-time)       START_EPOCH="$2"; shift 2 ;;
        --container)        FORGE_CONTAINER_PATTERN="$2"; shift 2 ;;
        --no-container)     SKIP_CONTAINER_CHECK=true; shift ;;
        --before-head)      BEFORE_HEAD="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -z "$START_EPOCH" ]] && START_EPOCH=$(date +%s)

HEARTBEAT_PATH="${PROJECT_DIR}/${HEARTBEAT_FILE}"

# ── Signal probes ─────────────────────────────────────────────────────────────

# Probe 1: Is the forge container running?
probe_container_running() {
    if [[ "$SKIP_CONTAINER_CHECK" == true ]]; then
        return 0  # Assume running for test mode
    fi
    local status
    status=$(podman inspect --format '{{.State.Status}}' "$FORGE_CONTAINER_PATTERN" 2>/dev/null || echo "missing")
    [[ "$status" == "running" ]]
}

# Probe 2: Is the heartbeat file fresh?
probe_heartbeat_fresh() {
    [[ -f "$HEARTBEAT_PATH" ]] || return 1
    local mtime now age
    mtime=$(stat --format='%Y' "$HEARTBEAT_PATH" 2>/dev/null) || return 1
    now=$(date +%s)
    age=$(( now - mtime ))
    [[ $age -le $HEARTBEAT_DEADLINE_SECS ]]
}

# Probe 3: Has git HEAD advanced since start?
probe_git_head_changed() {
    local current_head before_head
    current_head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    before_head="${BEFORE_HEAD:-${LIVENESS_GIT_BEFORE_HEAD:-}}"
    if [[ -n "$before_head" ]]; then
        [[ "$current_head" != "$before_head" ]]
    else
        # Fallback: check if any commit in the repo is newer than START_EPOCH
        local recent_count
        recent_count=$(git -C "$PROJECT_DIR" rev-list --count --since="@${START_EPOCH}" HEAD 2>/dev/null || echo "0")
        [[ "$recent_count" -gt 0 ]]
    fi
}

# ── State classifier ─────────────────────────────────────────────────────────

classify_state() {
    local container_running=false heartbeat_fresh=false git_changed=false

    probe_container_running && container_running=true
    probe_heartbeat_fresh && heartbeat_fresh=true
    probe_git_head_changed && git_changed=true

    if [[ "$container_running" == false ]]; then
        echo "dead_crashed"
        return 1
    fi

    if [[ "$heartbeat_fresh" == true ]]; then
        if [[ "$git_changed" == true ]]; then
            echo "alive_progressing"
            return 0
        else
            echo "alive_quiet"
            return 0
        fi
    fi

    # Heartbeat stale — agent is dead air (container alive but no heartbeat)
    echo "dead_air"
    return 1
}

# ── Deadline calculator ───────────────────────────────────────────────────────

calc_deadline() {
    local deadline=$(( START_EPOCH + BUDGET_SECS ))
    date -u -d "@${deadline}" '+%Y-%m-%dT%H:%M:%SZ'
}

# ── Wait loop ─────────────────────────────────────────────────────────────────

wait_for_death() {
    local deadline_epoch=$(( START_EPOCH + BUDGET_SECS ))

    while true; do
        local state
        state=$(classify_state) || true

        case "$state" in
            alive_progressing|alive_quiet)
                # Check budget
                local now
                now=$(date +%s)
                if [[ $now -ge $deadline_epoch ]]; then
                    echo "dead_killed" >&2
                    echo "Budget exhausted (dead_killed)" >&2
                    return 1
                fi
                sleep "$POLL_INTERVAL_SECS"
                ;;
            dead_air|dead_crashed)
                echo "$state" >&2
                echo "Forge agent detected as $state" >&2
                return 1
                ;;
        esac
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "$MODE" in
    status)
        classify_state
        ;;
    wait)
        wait_for_death
        ;;
    deadline)
        calc_deadline
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        usage
        ;;
esac
