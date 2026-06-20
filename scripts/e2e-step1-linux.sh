#!/bin/bash
set -e
LOG_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TILLANDSIAS_SMOKE_LOCK_LOG="$LOG_DIR/00-smoke-lock.log" \
  "$SCRIPT_DIR/with-smoke-lock.sh" --name build-install-smoke-e2e -- \
  "$SCRIPT_DIR/with-tillandsias-process-cleanup.sh" --log "$LOG_DIR/00-process-cleanup.log" -- \
  ./build.sh --ci-full --install 2>&1 | tee "$LOG_DIR/01-build-install.log"
BUILD_RC=${PIPESTATUS[0]}
printf 'build_install_exit=%s\n' "$BUILD_RC" | tee "$LOG_DIR/01-build-install-exit.txt"
test "$BUILD_RC" -eq 0
hash -r
INSTALLED_PATH="$(command -v tillandsias)"
EXPECTED_PATH="${HOME}/.local/bin/tillandsias"
printf '%s\n' "$INSTALLED_PATH" | tee "$LOG_DIR/01-installed-path.txt"
printf '%s\n' "$EXPECTED_PATH" | tee "$LOG_DIR/01-expected-path.txt"
test "$INSTALLED_PATH" = "$EXPECTED_PATH"
EXPECTED_VERSION="$(tr -d '[:space:]' < VERSION)"
INSTALLED_VERSION="$(tillandsias --version)"
EXPECTED_VERSION_LINE="Tillandsias v${EXPECTED_VERSION}"
printf '%s\n' "$INSTALLED_VERSION" | tee "$LOG_DIR/01-installed-version.txt"
printf '%s\n' "$EXPECTED_VERSION_LINE" | tee "$LOG_DIR/01-expected-version.txt"
test "$INSTALLED_VERSION" = "$EXPECTED_VERSION_LINE"
