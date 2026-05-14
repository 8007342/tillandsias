#!/usr/bin/env bash
# @trace spec:clickable-trace-index
set -euo pipefail

RECREATE=0
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: scripts/run-observatorium.sh [--recreate]

Launch a small local observatorium container serving the current checkout and
open it in Chromium-first mode, with a host browser fallback.

Options:
  --recreate   Remove any existing observatorium container before starting

Environment:
  OBSERVATORIUM_BROWSER=auto|chromium|host|none
  OBSERVATORIUM_PORT=8787
EOF
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recreate)
            RECREATE=1
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="${OBSERVATORIUM_CONTAINER_NAME:-tillandsias-observatorium}"
PORT="${OBSERVATORIUM_PORT:-8787}"
URL="http://127.0.0.1:${PORT}/observatorium/"
BROWSER_MODE="${OBSERVATORIUM_BROWSER:-auto}"
IMAGE="${OBSERVATORIUM_IMAGE:-docker.io/library/alpine:3.20}"

ensure_container() {
    if "$PODMAN" container exists "$NAME" >/dev/null 2>&1; then
        if [[ "$RECREATE" -eq 1 ]]; then
            echo "[run-observatorium] Recreating existing container: $NAME"
            "$PODMAN" rm -f "$NAME" >/dev/null 2>&1 || true
        else
            echo "[run-observatorium] Reusing existing container: $NAME"
        fi
    fi

    if ! "$PODMAN" container exists "$NAME" >/dev/null 2>&1; then
        echo "[run-observatorium] Creating container: $NAME"
        if ! "$PODMAN" create \
            --name "$NAME" \
            --label "app=tillandsias" \
            --label "role=observatorium" \
            --userns=keep-id \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            --security-opt=label=disable \
            --read-only \
            --tmpfs /tmp:rw,size=64m \
            --tmpfs /var/cache:rw,size=16m \
            --publish "127.0.0.1:${PORT}:8080" \
            --volume "${ROOT}:/repo:ro" \
            --workdir /repo \
            "$IMAGE" \
            /bin/sh -lc 'busybox httpd -f -p 8080 -h /repo'
        then
            echo "[run-observatorium] ERROR: podman could not create the observatorium container." >&2
            echo "[run-observatorium] HINT: run from the normal host shell with a working rootless podman socket, or set TILLANDSIAS_PODMAN_REMOTE_URL to a reachable user socket." >&2
            return 1
        fi
    fi
}

start_container() {
    local running
    running="$("$PODMAN" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
    if [[ "$running" != "true" ]]; then
        echo "[run-observatorium] Starting container: $NAME"
        "$PODMAN" start "$NAME" >/dev/null
    else
        echo "[run-observatorium] Container already running: $NAME"
    fi
}

wait_for_http() {
    local i
    for i in $(seq 1 30); do
        if command -v curl >/dev/null 2>&1 && curl -fsS "$URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

launch_private_chromium() {
    if [[ "$BROWSER_MODE" == "host" || "$BROWSER_MODE" == "none" ]]; then
        return 1
    fi
    if [[ -x "$ROOT/scripts/launch-chromium.sh" ]]; then
        echo "[run-observatorium] Trying private Chromium sandbox"
        "$ROOT/scripts/launch-chromium.sh" observatorium "$URL" 9222 open_debug_window "$VERSION"
        return 0
    fi
    return 1
}

launch_host_browser() {
    if [[ "$BROWSER_MODE" == "none" ]]; then
        echo "[run-observatorium] Browser launch disabled (OBSERVATORIUM_BROWSER=none)"
        return 0
    fi

    local browser_cmd
    for browser_cmd in google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$browser_cmd" >/dev/null 2>&1; then
            echo "[run-observatorium] Falling back to host browser: $browser_cmd"
            "$browser_cmd" --app="$URL" --new-window >/dev/null 2>&1 &
            disown >/dev/null 2>&1 || true
            return 0
        fi
    done

    if command -v xdg-open >/dev/null 2>&1; then
        echo "[run-observatorium] Falling back to xdg-open"
        xdg-open "$URL" >/dev/null 2>&1 &
        disown >/dev/null 2>&1 || true
        return 0
    fi

    echo "[run-observatorium] WARNING: no host browser command found" >&2
    return 1
}

echo "[run-observatorium] Launching observatorium for VERSION=$VERSION"
ensure_container
start_container

if ! wait_for_http; then
    echo "[run-observatorium] ERROR: observatorium did not become ready at $URL" >&2
    exit 1
fi

if launch_private_chromium; then
    exit 0
fi

launch_host_browser
