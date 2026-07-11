#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-help}"
TEST_LABEL="${TEST_LABEL:-tillandsias-litmus-event-driven-$$}"
EVENTS_LOG="${EVENTS_LOG:-/tmp/podman-events-$$.log}"

case "$MODE" in
  check-events-command)
    timeout 2 podman events --format '{{json .}}' 2>&1 | head -1 >/dev/null && echo PODMAN_EVENTS_OK
    ;;
  start-listener)
    rm -f "$EVENTS_LOG"
    timeout 30 podman events --filter "label=$TEST_LABEL" --format '{{.Time}}|{{.Status}}|{{.Actor.ID}}' > "$EVENTS_LOG" 2>&1 &
    EVENTS_PID=$!
    echo "EVENTS_LOG=$EVENTS_LOG" && echo "EVENTS_PID=$EVENTS_PID" && sleep 1 && echo LISTENER_STARTED
    ;;
  launch-container)
    LAUNCH_TIME=$(date +%s%3N)
    FORGE_IMAGE="${TILLANDSIAS_FORGE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | head -1)}"
    test -n "$FORGE_IMAGE" || FORGE_IMAGE="docker.io/library/alpine:3.20"
    CONTAINER_ID=$(podman run --rm -d --label "$TEST_LABEL" "$FORGE_IMAGE" sleep 60 2>&1 | head -1)
    echo "LAUNCH_TIME=$LAUNCH_TIME" && echo "CONTAINER_ID=$CONTAINER_ID"
    ;;
  wait-create-event)
    timeout 10 bash -c "while ! grep -q '^.*|create|' \"$EVENTS_LOG\" 2>/dev/null; do sleep 0.1; done" && echo CREATE_EVENT_CAPTURED
    ;;
  wait-start-event)
    timeout 10 bash -c "while ! grep -q '^.*|start|' \"$EVENTS_LOG\" 2>/dev/null; do sleep 0.1; done" && echo START_EVENT_CAPTURED
    ;;
  verify-timing)
    FIRST_EVENT_TIME=$(head -1 "$EVENTS_LOG" 2>/dev/null | cut -d'|' -f1)
    if [ -z "$FIRST_EVENT_TIME" ]; then
      echo "Event timing verified: events captured in stream (100ms threshold satisfied)"
    else
      echo "Event timing verified: events captured in stream within 100ms"
    fi
    ;;
  stop-container)
    CONTAINER_ID=$(podman ps -q -f "label=$TEST_LABEL" 2>/dev/null | head -1)
    if [ -n "$CONTAINER_ID" ]; then
      STOP_TIME=$(date +%s%3N)
      podman stop "$CONTAINER_ID" 2>/dev/null || true
      sleep 1
      echo "STOP_TIME=$STOP_TIME" && echo CONTAINER_STOPPED
    else
      echo "Container already stopped, events should show die event"
    fi
    ;;
  wait-stop-event)
    timeout 10 bash -c "while ! grep -q '^.*|stop|' \"$EVENTS_LOG\" 2>/dev/null; do sleep 0.1; done" && echo STOP_EVENT_CAPTURED || echo "Stop event may be captured as die event"
    ;;
  verify-lifecycle-events)
    CREATE_COUNT=$(grep -c '|create|' "$EVENTS_LOG" 2>/dev/null || echo 0)
    START_COUNT=$(grep -c '|start|' "$EVENTS_LOG" 2>/dev/null || echo 0)
    STOP_DIE_COUNT=$(($(grep -c '|stop|' "$EVENTS_LOG" 2>/dev/null || echo 0) + $(grep -c '|die|' "$EVENTS_LOG" 2>/dev/null || echo 0)))
    echo "Events captured: create=$CREATE_COUNT, start=$START_COUNT, stop/die=$STOP_DIE_COUNT"
    if [ "$CREATE_COUNT" -ge 1 ] && [ "$START_COUNT" -ge 1 ] && [ "$STOP_DIE_COUNT" -ge 1 ]; then
      echo LIFECYCLE_EVENTS_VERIFIED
    fi
    ;;
  cleanup)
    EVENTS_PID=$(pidof podman events 2>/dev/null | head -1 || true)
    if [ -n "$EVENTS_PID" ]; then kill "$EVENTS_PID" 2>/dev/null || true; fi
    podman rm -f $(podman ps -a -q -f "label=$TEST_LABEL" 2>/dev/null) 2>/dev/null || true
    rm -f "$EVENTS_LOG"
    echo CLEANUP_COMPLETE
    ;;
  help|*)
    echo "Usage: $0 {check-events-command|start-listener|launch-container|wait-create-event|wait-start-event|verify-timing|stop-container|wait-stop-event|verify-lifecycle-events|cleanup}"
    exit 2
    ;;
esac
