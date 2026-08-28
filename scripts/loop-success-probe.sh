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

# TOOL RESOLUTION, ONCE, OUTSIDE EVERY LOOP (order 914-ahsy).
#
# This probe is the archetype the packet was filed about, and it is worse than
# a plain loop: an OUTER poll loop re-scans the whole event log until the
# deadline, and the inner loop ran THREE jq invocations per line. Under the
# 799-tb7q per-call toolbox dispatch that is 3 x 265 ms = 795 ms PER LINE PER
# PASS on a jq-less host — a probe with a 90 s timeout would spend its entire
# budget in container round trips and report `timeout` for a stack that came up
# fine. A false failure verdict, from the tool meant to detect failure.
#
# fast_tool resolves ONCE here: host jq if present; else the toolbox's jq
# materialized onto the host (~1.0 s once, then 2 ms/call — identical to host
# jq, because it is the same binary); else the per-call toolbox prefix; else
# empty. Resolving inside the loop would defeat the entire point.
#
# The libs are sourced by WALKING UP (order 914-ahsy hazard 4): a fixed-depth
# `dirname "${BASH_SOURCE[0]}"/lib/...` silently resolves to nothing from a
# caller one directory down, the `|| true` swallows it, and JQ falls back to
# the bare name — a conversion that passes review and changes nothing.
_lsp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_lsp_dir" ] && [ "$_lsp_dir" != "/" ] && [ ! -f "$_lsp_dir/lib/tool-dispatch.sh" ]; do
    _lsp_dir="$(dirname "$_lsp_dir")"
done
if [ -f "$_lsp_dir/lib/tool-dispatch.sh" ]; then
    . "$_lsp_dir/lib/tool-dispatch.sh" 2>/dev/null || true
    . "$_lsp_dir/lib/tool-materialize.sh" 2>/dev/null || true
fi
if command -v fast_tool >/dev/null 2>&1; then
    JQ="$(fast_tool jq || printf 'jq')"
else
    JQ="jq"   # libs unavailable: preserve the previous behaviour exactly
fi

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    EVENT_LOG="$XDG_RUNTIME_DIR/tillandsias/logs/opencode-web/$PROJECT.jsonl"
else
    EVENT_LOG="/tmp/tillandsias/logs/opencode-web/$PROJECT.jsonl"
fi

# `stack` only emits state=starting (it's the parent meta-stage); the per-
# container stages are the ones that go to state=started.
REQUIRED_START_STAGES=(proxy git inference forge)
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

# Space-delimited string set instead of `declare -A` (761-g36m burndown:
# associative arrays don't exist on Apple's bash 3.2, and this probe must at
# minimum refuse legibly there). Stage tokens are identifiers — no spaces.
SEEN_STARTED=" "
seen_started() {
    case "$SEEN_STARTED" in
        *" $1 "*) return 0 ;;
    esac
    return 1
}
ROUTE_READY=false
LAUNCHED=false
LAST_STAGE="init"
LAST_DETAIL=""

while (( $(date +%s) < deadline )); do
    # Read every line currently in the file (idempotent re-scan).
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # ONE invocation per line, not three (order 914-ahsy). The three
        # fields come from the SAME object, so three parses of one line was
        # pure waste even with host jq — and under any toolbox dispatch it is
        # three container round trips where one would do. Tab-separated
        # because `detail` is free text that may contain spaces; @tsv would
        # also escape it, but these are single-line values and read -r with
        # IFS=$'\t' is the bash-3.2-clean reader (761-g36m).
        IFS="$(printf '\t')" read -r stage state detail < <(
            printf '%s' "$line" | $JQ -r '[.stage // "", .state // "", .detail // ""] | @tsv' 2>/dev/null || true
        )
        [[ -z "$stage" || -z "$state" ]] && continue
        LAST_STAGE="$stage"
        LAST_DETAIL="$detail"
        case "$state" in
            started)
                seen_started "$stage" || SEEN_STARTED="${SEEN_STARTED}${stage} "
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
        if ! seen_started "$s"; then
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
    seen_started "$s" || missing+=("$s")
done
[[ "$ROUTE_READY" != true ]] && missing+=("browser:route_ready")
[[ "$LAUNCHED" != true ]] && missing+=("browser:launched")
gist="missing: ${missing[*]:-none}; last_seen: ${LAST_STAGE}/${LAST_DETAIL}"

emit_result "timeout" "$LAST_STAGE" "$gist"
exit 1
