#!/usr/bin/env bash
# @trace order:1275-ngrc
#
# smoke-agent-watch.sh — detect the smoke forge lane's central failure mode:
# the in-forge agent hits a TERMINAL error, opencode idles instead of exiting,
# `opencode_exit` is never written, and every §4a instrument reports health.
#
# MEASURED on pirria 2026-09-19 (v56.9.19.1): the agent died at 17:19:38Z
# (`AI_RetryError: Failed after 3 attempts. Last error: Rate limit exceeded.`)
# and the lane ran on for 2h19m. Containers up, no oom-kill, supervisor alive,
# and even a CPU-delta probe said ALIVE (an idle event loop plus an hourly
# `cleanup prune=7.days` timer). A frozen process is detectable; a live process
# idling after its agent died was not, by anything the runbook prescribed.
#
# THE SIGNAL IS THE AGENT'S STATE, NEVER THE CLOCK. A lane budget cannot tell a
# long healthy run from a death at minute 2 (the row's negative control). The
# verdict needs BOTH: the agent's last non-housekeeping log line is a TERMINAL
# error, AND no agent activity follows it for --grace seconds. Any agent line
# after the error (a retry that worked, a new tool call) is activity and resets
# the watch; the grace is a quiet window on the agent's own log, not a budget.
#
# USAGE
#   smoke-agent-watch.sh classify <opencode-log>
#       -> state:no-log | state:working | state:agent-error-idle<TAB><error line>
#   smoke-agent-watch.sh watch [--container NAME] [--log PATH] [--grace S]
#                              [--poll S] [--out DIR]
#       Runs until the lane ends (killed by its caller) or it issues the
#       verdict: writes <out>/04-agent-watch.txt
#       (refused:smoke-forge-lane:agent-dead-process-idling + the error line),
#       copies the agent log to <out>/04-opencode-agent.log (HOST-SIDE evidence;
#       the log lives in the forge at a path the runbook never named), then
#       `podman stop`s the forge container so the lane returns and §4 records
#       its exit. --log reads a host path instead of the container (fixtures).
#
# NAMED LIMITS: the terminal-error and housekeeping patterns below are the
# measured ones plus the provider failures that cannot retry into success;
# a new terminal shape is a one-line addition here, found by reading the
# copied log. A log format change that drops the ERROR level word makes this
# answer state:working — the old behaviour, never a false kill.
set -uo pipefail

# ERROR-level lines whose error cannot resolve by waiting.
TERMINAL_RE='AI_RetryError|Failed after [0-9]+ attempts|AI_LoadAPIKeyError|AI_NoSuchModelError|ProviderInitError|ProviderModelNotFoundError'
# Timer lines that are not agent activity (measured: `cleanup prune=7.days`).
HOUSEKEEPING_RE='(^|[[:space:]])cleanup([[:space:]]|$)|prune='
ERROR_LEVEL_RE='(^|[[:space:]])ERROR([[:space:]]|$)|level=error'
AGENT_LOG_DIR='/home/forge/.local/share/opencode/log'

classify() {
    local log="$1" last
    if [[ ! -s "$log" ]]; then
        echo "state:no-log"
        return 0
    fi
    # The last line that is not housekeeping decides; one pass, no fork per line.
    last="$(awk -v hk="$HOUSEKEEPING_RE" 'NF && $0 !~ hk { l = $0 } END { print l }' "$log")"
    if [[ -n "$last" ]] && grep -qE "$ERROR_LEVEL_RE" <<<"$last" && grep -qE "$TERMINAL_RE" <<<"$last"; then
        printf 'state:agent-error-idle\t%s\n' "$last"
    else
        echo "state:working"
    fi
}

# The forge container of the running lane: exactly one name ending in -forge.
find_forge() {
    local names
    names="$(podman ps --format '{{.Names}}' 2>/dev/null | grep -E -- '-forge$')"
    [[ "$(grep -c . <<<"$names")" == 1 ]] && printf '%s\n' "$names"
}

# Copy the newest agent log out of the container (or from --log) to $1. Two
# argv calls, no shell string: list the log directory newest-first, then cat.
fetch_log() {
    local dest="$1" newest
    if [[ -n "$LOG" ]]; then
        cp "$LOG" "$dest" 2>/dev/null || : >"$dest"
        return 0
    fi
    newest="$(podman exec "$CONTAINER" ls -t "$AGENT_LOG_DIR" 2>/dev/null | awk '/\.log$/ { print; exit }')"
    if [[ -z "$newest" ]]; then
        : >"$dest"
        return 0
    fi
    podman exec "$CONTAINER" cat "$AGENT_LOG_DIR/$newest" >"$dest" 2>/dev/null || : >"$dest"
}

watch() {
    local snap state err="" since=0 now
    mkdir -p "$OUT"
    snap="$(mktemp "${TMPDIR:-/tmp}/smoke-agent-watch.XXXXXX")"
    trap 'rm -f "$snap"' EXIT
    while :; do
        if [[ -z "$LOG" && -z "$CONTAINER" ]]; then
            CONTAINER="$(find_forge)"
        fi
        if [[ -n "$LOG" || -n "$CONTAINER" ]]; then
            fetch_log "$snap"
            state="$(classify "$snap")"
            now="$(date +%s)"
            case "$state" in
                state:agent-error-idle*)
                    # The SAME error must stay the last agent line for --grace.
                    if [[ "${state#*$'\t'}" != "$err" ]]; then
                        err="${state#*$'\t'}"
                        since="$now"
                    elif [[ $((now - since)) -ge "$GRACE" ]]; then
                        cp "$snap" "$OUT/04-opencode-agent.log"
                        {
                            echo "refused:smoke-forge-lane:agent-dead-process-idling"
                            echo "  why: the agent's last non-housekeeping log line is a terminal error and no agent activity followed it for ${GRACE}s; opencode idles instead of exiting, so the lane would run forever"
                            echo "  error: $err"
                            echo "  evidence: $OUT/04-opencode-agent.log (copied from ${LOG:-$CONTAINER:$AGENT_LOG_DIR})"
                            echo "  action: podman stop ${CONTAINER:-<none: --log mode>} so the lane returns and §4 records its exit"
                        } >"$OUT/04-agent-watch.txt"
                        cat "$OUT/04-agent-watch.txt" >&2
                        [[ -n "$CONTAINER" ]] && podman stop "$CONTAINER" >/dev/null 2>&1
                        return 3
                    fi
                    ;;
                *)
                    err=""
                    since=0
                    ;;
            esac
        fi
        sleep "$POLL"
    done
}

CONTAINER=""
LOG=""
GRACE=300
POLL=30
OUT="target/smoke-e2e"
verb="${1:-}"
shift || true
case "$verb" in
    classify)
        [[ $# -eq 1 ]] || { echo "usage: $0 classify <opencode-log>" >&2; exit 2; }
        classify "$1"
        ;;
    watch)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --container) CONTAINER="$2"; shift 2 ;;
                --log) LOG="$2"; shift 2 ;;
                --grace) GRACE="$2"; shift 2 ;;
                --poll) POLL="$2"; shift 2 ;;
                --out) OUT="$2"; shift 2 ;;
                *) echo "usage: $0 watch [--container NAME] [--log PATH] [--grace S] [--poll S] [--out DIR]" >&2; exit 2 ;;
            esac
        done
        watch
        ;;
    *)
        echo "usage: $0 classify <opencode-log> | watch [--container NAME] [--log PATH] [--grace S] [--poll S] [--out DIR]" >&2
        exit 2
        ;;
esac
