#!/bin/bash
set -e
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="target/build-install-smoke-e2e/$RUN_ID"
mkdir -p "$LOG_DIR"
OS="$(uname -s)"
case "$OS" in
  Linux)  HOST_BRANCH=linux-next  ; HOST_KIND=linux   ;;
  Darwin) HOST_BRANCH=osx-next    ; HOST_KIND=macos   ;;
  *)      HOST_BRANCH=windows-next; HOST_KIND=windows ;;
esac
echo "host_kind=$HOST_KIND host_branch=$HOST_BRANCH" | tee "$LOG_DIR/00-host.txt"
git rev-parse HEAD       | tee "$LOG_DIR/00-commit.txt"
git status --short       | tee "$LOG_DIR/00-status.txt"
cat VERSION 2>/dev/null  | tee "$LOG_DIR/00-version.txt"
test -x ./build.sh
echo "$LOG_DIR"
