#!/bin/bash
set -e
LOG_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TILLANDSIAS_SMOKE_LOCK_LOG="$LOG_DIR/00-smoke-lock.log" \
  "$SCRIPT_DIR/with-smoke-lock.sh" --name build-install-smoke-e2e -- \
  podman system reset --force 2>&1 | tee "$LOG_DIR/02-reset.log"
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee "$LOG_DIR/02-reset-exit.txt"
test "$RESET_RC" -eq 0
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee "$LOG_DIR/02-empty-store.txt"
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"
# Order 386: the full stack teardown above must leave zero straggling host
# processes — no tray-parented zombies, no orphaned terminal launchers. The
# probe exits nonzero on any straggler and fails the lane loud.
"$SCRIPT_DIR/container-teardown-straggler-probe.sh" 2>&1 | tee "$LOG_DIR/02-straggler-probe.log"
test "${PIPESTATUS[0]}" -eq 0
