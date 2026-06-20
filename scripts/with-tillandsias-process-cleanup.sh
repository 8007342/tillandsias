#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/with-tillandsias-process-cleanup.sh [--log PATH] -- COMMAND [ARG...]

Run a smoke/e2e command and clean up any new host-side `tillandsias` launcher
processes it leaves behind. Existing user processes are left untouched.
EOF
}

LOG_FILE="${TILLANDSIAS_PROCESS_CLEANUP_LOG:-}"
GRACE_SECS="${TILLANDSIAS_PROCESS_CLEANUP_GRACE_SECS:-5}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            LOG_FILE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ $# -gt 0 ]] || { usage; exit 64; }
[[ "$GRACE_SECS" =~ ^[0-9]+$ ]] || { echo "cleanup grace must be an integer: $GRACE_SECS" >&2; exit 64; }

log_line() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) process_cleanup $*"
    echo "$line" >&2
    if [[ -n "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

snapshot_pids() {
    pgrep -u "$(id -u)" -x tillandsias 2>/dev/null | sort -n || true
}

describe_pids() {
    local pid
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        ps -fp "$pid" 2>/dev/null || true
    done
}

before="$(mktemp)"
after="$(mktemp)"
leaked="$(mktemp)"
remaining="$(mktemp)"
trap 'rm -f "$before" "$after" "$leaked" "$remaining"' EXIT

snapshot_pids > "$before"

set +e
"$@"
command_rc=$?
set -e

snapshot_pids > "$after"
comm -13 "$before" "$after" > "$leaked"

if [[ ! -s "$leaked" ]]; then
    log_line "no new tillandsias host processes leaked"
    exit "$command_rc"
fi

log_line "detected leaked tillandsias pid(s): $(tr '\n' ' ' < "$leaked")"
describe_pids < "$leaked" >> "${LOG_FILE:-/dev/stderr}" 2>/dev/null || true

while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
done < "$leaked"

sleep "$GRACE_SECS"

: > "$remaining"
while read -r pid; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$pid" >> "$remaining"
    fi
done < "$leaked"

if [[ -s "$remaining" ]]; then
    log_line "forcing leaked tillandsias pid(s): $(tr '\n' ' ' < "$remaining")"
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done < "$remaining"
fi

if [[ "$command_rc" -eq 0 ]]; then
    log_line "failing successful command because it leaked tillandsias process(es)"
    exit 70
fi

exit "$command_rc"
