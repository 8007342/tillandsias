#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Loop Success Probe
#
# Used by the autonomous fix-loop to determine whether
# `tillandsias --tray --opencode-web <project> --debug` has come up cleanly
# end-to-end without needing a TTY or a GTK display.
#
# Reads the structured event log Tillandsias writes at
# $XDG_RUNTIME_DIR/tillandsias/logs/opencode-web/<project>.jsonl (see
# `emit_opencode_web_event` in crates/tillandsias-headless/src/main.rs).
# Each line is JSON: {"ts":..., "project":..., "stage":..., "state":...,
# "detail":...}. The stages are: stack, proxy, git, inference, forge, browser.
#
# Success: every stack/proxy/git/inference/forge event has reached "started"
# AND the browser stage has reached "route_ready" AND "launched".
#
# Failure: any "launch_failed" or "route_unhealthy" event, or timeout.
#
# Emits one JSON line on stdout: {"status":"ok"|"timeout"|"failed",
# "stage":"<last>","details":"<gist>"}. Exit 0 on ok, 1 otherwise.
#
# Usage:
#   loop-success-probe.sh <project> <timeout-seconds> [json-output-path]
# =============================================================================

set -uo pipefail

PROJECT="${1:-}"
TIMEOUT_SECS="${2:-90}"
OUTPUT_PATH="${3:-}"

if [[ -z "$PROJECT" ]]; then
    echo "usage: $0 <project> <timeout-seconds> [json-output-path]" >&2
    exit 2
fi

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    EVENT_LOG="$XDG_RUNTIME_DIR/tillandsias/logs/opencode-web/$PROJECT.jsonl"
else
    EVENT_LOG="/tmp/tillandsias/logs/opencode-web/$PROJECT.jsonl"
fi

REQUIRED_START_STAGES=(stack proxy git inference forge)
deadline=$(( $(date +%s) + TIMEOUT_SECS ))

emit_result() {
    local status="$1" stage="$2" details="$3"
    # shellcheck disable=SC2059
    local line
    line=$(printf '{"status":"%s","stage":"%s","details":"%s"}' \
        "$status" "$stage" "${details//\"/\\\"}")
    printf '%s\n' "$line"
    if [[ -n "$OUTPUT_PATH" ]]; then
        mkdir -p "$(dirname "$OUTPUT_PATH")"
        printf '%s\n' "$line" >"$OUTPUT_PATH"
    fi
}

# Wait for the event log file to appear.
while [[ ! -f "$EVENT_LOG" ]]; do
    if (( $(date +%s) >= deadline )); then
        emit_result "timeout" "init" "event log never appeared at $EVENT_LOG"
        exit 1
    fi
    sleep 1
done

declare -A SEEN_STARTED=()
ROUTE_READY=false
LAUNCHED=false
LAST_STAGE="init"
LAST_DETAIL=""

while (( $(date +%s) < deadline )); do
    # Read every line currently in the file (idempotent re-scan).
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        stage=$(printf '%s' "$line" | jq -r '.stage // empty' 2>/dev/null || true)
        state=$(printf '%s' "$line" | jq -r '.state // empty' 2>/dev/null || true)
        detail=$(printf '%s' "$line" | jq -r '.detail // empty' 2>/dev/null || true)
        [[ -z "$stage" || -z "$state" ]] && continue
        LAST_STAGE="$stage"
        LAST_DETAIL="$detail"
        case "$state" in
            started)
                SEEN_STARTED["$stage"]=1
                ;;
            route_ready)
                ROUTE_READY=true
                ;;
            route_unhealthy)
                emit_result "failed" "$stage" "route_unhealthy: $detail"
                exit 1
                ;;
            launched)
                LAUNCHED=true
                ;;
            launch_failed)
                emit_result "failed" "$stage" "launch_failed: $detail"
                exit 1
                ;;
        esac
    done < "$EVENT_LOG"

    # Have all required start stages been seen, plus browser route+launch?
    all_started=true
    for s in "${REQUIRED_START_STAGES[@]}"; do
        if [[ -z "${SEEN_STARTED[$s]:-}" ]]; then
            all_started=false
            break
        fi
    done
    if [[ "$all_started" == true && "$ROUTE_READY" == true && "$LAUNCHED" == true ]]; then
        emit_result "ok" "browser" "all stages reached terminal state"
        exit 0
    fi

    sleep 1
done

# Build a gist of which stages we did/didn't see.
missing=()
for s in "${REQUIRED_START_STAGES[@]}"; do
    [[ -z "${SEEN_STARTED[$s]:-}" ]] && missing+=("$s")
done
[[ "$ROUTE_READY" != true ]] && missing+=("browser:route_ready")
[[ "$LAUNCHED" != true ]] && missing+=("browser:launched")
gist="missing: ${missing[*]:-none}; last_seen: ${LAST_STAGE}/${LAST_DETAIL}"

emit_result "timeout" "$LAST_STAGE" "$gist"
exit 1
