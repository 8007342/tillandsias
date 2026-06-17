#!/bin/bash
set -e
LOG_DIR="$1"
tillandsias --init --debug 2>&1 | tee "$LOG_DIR/03-init.log"
INIT_RC=${PIPESTATUS[0]}; printf 'init_exit=%s\n' "$INIT_RC" | tee "$LOG_DIR/03-init-exit.txt"
test "$INIT_RC" -eq 0
