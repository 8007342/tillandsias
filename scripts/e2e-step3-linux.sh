#!/bin/bash
set -e
LOG_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TILLANDSIAS_SMOKE_LOCK_LOG="$LOG_DIR/00-smoke-lock.log" \
  "$SCRIPT_DIR/with-smoke-lock.sh" --name build-install-smoke-e2e -- \
  "$SCRIPT_DIR/with-tillandsias-process-cleanup.sh" --log "$LOG_DIR/00-process-cleanup.log" -- \
  tillandsias --init --debug 2>&1 | tee "$LOG_DIR/03-init.log"
INIT_RC=${PIPESTATUS[0]}; printf 'init_exit=%s\n' "$INIT_RC" | tee "$LOG_DIR/03-init-exit.txt"
test "$INIT_RC" -eq 0
