#!/bin/bash
set -e
LOG_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TILLANDSIAS_SMOKE_LOCK_LOG="$LOG_DIR/00-smoke-lock.log" \
  "$SCRIPT_DIR/with-smoke-lock.sh" --name build-install-smoke-e2e -- \
  ./build.sh --ci-full --install 2>&1 | tee "$LOG_DIR/01-build-install.log"
BUILD_RC=${PIPESTATUS[0]}
printf 'build_install_exit=%s\n' "$BUILD_RC" | tee "$LOG_DIR/01-build-install-exit.txt"
test "$BUILD_RC" -eq 0
hash -r
command -v tillandsias        | tee "$LOG_DIR/01-installed-path.txt"
tillandsias --version         | tee "$LOG_DIR/01-installed-version.txt"
