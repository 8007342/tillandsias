#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/with-smoke-lock.sh [--name NAME] [--timeout SECONDS] -- COMMAND [ARG...]

Serialize destructive or shared-resource smoke/e2e work across concurrent
agents on the same host. The lock path defaults to
${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks/NAME.lock.
EOF
}

LOCK_NAME="${TILLANDSIAS_SMOKE_LOCK_NAME:-smoke-e2e}"
LOCK_ROOT="${TILLANDSIAS_SMOKE_LOCK_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks}"
LOCK_TIMEOUT="${TILLANDSIAS_SMOKE_LOCK_TIMEOUT_SECS:-7200}"
LOG_FILE="${TILLANDSIAS_SMOKE_LOCK_LOG:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            LOCK_NAME="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            LOCK_TIMEOUT="$2"
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
[[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || { echo "lock timeout must be an integer: $LOCK_TIMEOUT" >&2; exit 64; }
[[ "$LOCK_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "lock name contains unsupported characters: $LOCK_NAME" >&2; exit 64; }

mkdir -p "$LOCK_ROOT"

log_line() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) smoke_lock[$LOCK_NAME] $*"
    echo "$line" >&2
    if [[ -n "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

write_holder() {
    local destination="$1"
    shift
    {
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$(hostname 2>/dev/null || printf unknown)"
        printf 'cwd=%s\n' "$(pwd -P)"
        printf 'command='
        printf '%q ' "$@"
        printf '\n'
        printf 'acquired_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$destination"
}

run_with_flock() {
    local lock_file="$LOCK_ROOT/$LOCK_NAME.lock"
    exec 9>"$lock_file"
    log_line "waiting path=$lock_file timeout=${LOCK_TIMEOUT}s"
    if ! flock -w "$LOCK_TIMEOUT" 9; then
        log_line "timeout path=$lock_file"
        return 75
    fi
    write_holder "$lock_file" "$@"
    log_line "acquired path=$lock_file"
    set +e
    # 9>&- : the payload (and every descendant, e.g. a launched forge
    # agent session) must NOT inherit the lock fd. An orphaned descendant
    # that outlived the wrapper kept the flock held for up to its own
    # 90-minute cap and deadlocked the next gate 16 minutes (plan order
    # 283). Only this wrapper's shell lifetime holds the lease.
    "$@" 9>&-
    local rc=$?
    set -e
    log_line "released path=$lock_file exit=$rc"
    return "$rc"
}

run_with_lockdir() {
    local lock_dir="$LOCK_ROOT/$LOCK_NAME.lockdir"
    local start now
    start="$(date +%s)"
    log_line "waiting path=$lock_dir timeout=${LOCK_TIMEOUT}s fallback=mkdir"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        now="$(date +%s)"
        if (( now - start >= LOCK_TIMEOUT )); then
            log_line "timeout path=$lock_dir fallback=mkdir"
            return 75
        fi
        sleep 2
    done
    trap 'rm -rf "$lock_dir"' EXIT
    write_holder "$lock_dir/holder" "$@"
    log_line "acquired path=$lock_dir fallback=mkdir"
    set +e
    "$@"
    local rc=$?
    set -e
    log_line "released path=$lock_dir exit=$rc fallback=mkdir"
    return "$rc"
}

if command -v flock >/dev/null 2>&1; then
    run_with_flock "$@"
else
    run_with_lockdir "$@"
fi
