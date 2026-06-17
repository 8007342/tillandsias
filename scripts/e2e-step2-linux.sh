#!/bin/bash
set -e
LOG_DIR="$1"
podman system reset --force 2>&1 | tee "$LOG_DIR/02-reset.log"
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee "$LOG_DIR/02-reset-exit.txt"
test "$RESET_RC" -eq 0
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee "$LOG_DIR/02-empty-store.txt"
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"
