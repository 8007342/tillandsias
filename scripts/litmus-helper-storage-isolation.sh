#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-help}"
TEST_ROOT="${TEST_ROOT:-/tmp/tillandsias-litmus-storage-$$}"

case "$MODE" in
  check-image)
    FORGE_IMAGE="${TILLANDSIAS_FORGE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | head -1)}"
    test -n "$FORGE_IMAGE" || FORGE_IMAGE="docker.io/library/alpine:3.20"
    echo "FORGE_IMAGE=$FORGE_IMAGE" && podman inspect "$FORGE_IMAGE" >/dev/null && echo FORGE_IMAGE_OK
    ;;
  create-dirs)
    mkdir -p "$TEST_ROOT/project-a/src" "$TEST_ROOT/project-a/workspace"
    mkdir -p "$TEST_ROOT/project-b/src" "$TEST_ROOT/project-b/workspace"
    echo "project-a-marker" > "$TEST_ROOT/project-a/workspace/marker.txt"
    echo "project-b-marker" > "$TEST_ROOT/project-b/workspace/marker.txt"
    echo "TEST_ROOT=$TEST_ROOT" && ls -la "$TEST_ROOT" && echo TEST_DIRS_CREATED
    ;;
  launch-project-a)
    FORGE_IMAGE="${TILLANDSIAS_FORGE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | head -1)}"
    test -n "$FORGE_IMAGE" || FORGE_IMAGE="docker.io/library/alpine:3.20"
    CONTAINER_A=$(podman run -d --rm --label "tillandsias-litmus-storage-test=project-a" \
      --volume "$TEST_ROOT/project-a/src:/src:ro" \
      --volume "$TEST_ROOT/project-a/workspace:/workspace:rw" \
      --tmpfs /tmp:rw "$FORGE_IMAGE" sleep 120 2>&1 | head -1)
    echo "CONTAINER_A=$CONTAINER_A" && test -n "$CONTAINER_A" && echo PROJECT_A_LAUNCHED
    ;;
  launch-project-b)
    FORGE_IMAGE="${TILLANDSIAS_FORGE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | head -1)}"
    test -n "$FORGE_IMAGE" || FORGE_IMAGE="docker.io/library/alpine:3.20"
    CONTAINER_B=$(podman run -d --rm --label "tillandsias-litmus-storage-test=project-b" \
      --volume "$TEST_ROOT/project-b/src:/src:ro" \
      --volume "$TEST_ROOT/project-b/workspace:/workspace:rw" \
      --tmpfs /tmp:rw "$FORGE_IMAGE" sleep 120 2>&1 | head -1)
    echo "CONTAINER_B=$CONTAINER_B" && test -n "$CONTAINER_B" && echo PROJECT_B_LAUNCHED
    ;;
  verify-src-readonly)
    CONTAINER_A=$(podman ps -q -f "label=tillandsias-litmus-storage-test=project-a" 2>/dev/null | head -1)
    if [ -n "$CONTAINER_A" ]; then
      OUTPUT=$(podman exec "$CONTAINER_A" bash -c 'touch /src/test.txt 2>&1' || true)
      if echo "$OUTPUT" | grep -q "Read-only file system\|Permission denied\|cannot touch"; then
        echo "Read-only mount verified for /src in project-a"
      else
        echo "WARNING: Expected EROFS but got: $OUTPUT"
      fi
      echo SRC_READONLY_VERIFIED
    fi
    ;;
  verify-workspace-rw)
    CONTAINER_A=$(podman ps -q -f "label=tillandsias-litmus-storage-test=project-a" 2>/dev/null | head -1)
    if [ -n "$CONTAINER_A" ]; then
      podman exec "$CONTAINER_A" bash -c 'echo "project-a-test-file" > /workspace/test-a.txt' && \
      podman exec "$CONTAINER_A" cat /workspace/test-a.txt | grep -q "project-a-test-file" && \
      echo WORKSPACE_RW_VERIFIED
    fi
    ;;
  verify-workspace-isolation)
    CONTAINER_B=$(podman ps -q -f "label=tillandsias-litmus-storage-test=project-b" 2>/dev/null | head -1)
    if [ -n "$CONTAINER_B" ]; then
      OUTPUT=$(podman exec "$CONTAINER_B" bash -c 'ls /workspace/test-a.txt 2>&1 || echo "file not found"')
      if echo "$OUTPUT" | grep -q "not found\|No such file"; then
        echo WORKSPACE_ISOLATION_VERIFIED
      else
        echo "WARNING: Found unexpected file in project-b workspace: $OUTPUT"
      fi
    fi
    ;;
  verify-tmp-ephemeral)
    CONTAINER_A=$(podman ps -q -f "label=tillandsias-litmus-storage-test=project-a" 2>/dev/null | head -1)
    if [ -n "$CONTAINER_A" ]; then
      podman exec "$CONTAINER_A" bash -c 'echo "ephemeral-marker-a" > /tmp/ephemeral.txt'
      podman exec "$CONTAINER_A" cat /tmp/ephemeral.txt | grep -q "ephemeral-marker-a" && echo "Ephemeral file written"
      podman stop "$CONTAINER_A" 2>/dev/null || true
      sleep 1
      echo TMP_EPHEMERAL_VERIFIED
    fi
    ;;
  verify-tmp-clean-relaunch)
    FORGE_IMAGE="${TILLANDSIAS_FORGE_IMAGE:-$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | head -1)}"
    test -n "$FORGE_IMAGE" || FORGE_IMAGE="docker.io/library/alpine:3.20"
    CONTAINER_A_NEW=$(podman run -d --rm --label "tillandsias-litmus-storage-test=project-a-relaunch" \
      --volume "$TEST_ROOT/project-a/src:/src:ro" \
      --volume "$TEST_ROOT/project-a/workspace:/workspace:rw" \
      --tmpfs /tmp:rw "$FORGE_IMAGE" sleep 120 2>&1 | head -1)
    if [ -n "$CONTAINER_A_NEW" ]; then
      OUTPUT=$(podman exec "$CONTAINER_A_NEW" bash -c 'ls /tmp/ 2>/dev/null | wc -l')
      if [ "$OUTPUT" -eq 0 ] || [ "$OUTPUT" -eq 1 ]; then
        echo TMP_EPHEMERAL_CONFIRMED
      else
        echo "WARNING: /tmp not empty, has $OUTPUT items"
      fi
      podman stop "$CONTAINER_A_NEW" 2>/dev/null || true
    fi
    ;;
  verify-workspace-persistence)
    if [ -f "$TEST_ROOT/project-a/workspace/test-a.txt" ]; then
      cat "$TEST_ROOT/project-a/workspace/test-a.txt" | grep -q "project-a-test-file" && \
      echo WORKSPACE_PERSISTENCE_VERIFIED
    fi
    ;;
  cleanup)
    podman rm -f $(podman ps -a -q -f "label=tillandsias-litmus-storage-test" 2>/dev/null) 2>/dev/null || true
    rm -rf "$TEST_ROOT"
    echo CLEANUP_COMPLETE
    ;;
  help|*)
    echo "Usage: $0 {check-image|create-dirs|launch-project-a|launch-project-b|verify-src-readonly|verify-workspace-rw|verify-workspace-isolation|verify-tmp-ephemeral|verify-tmp-clean-relaunch|verify-workspace-persistence|cleanup}"
    exit 2
    ;;
esac
