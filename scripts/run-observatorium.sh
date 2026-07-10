#!/usr/bin/env bash
# @trace spec:clickable-trace-index
set -euo pipefail

RECREATE=0
PORT_OVERRIDE="${OBSERVATORIUM_PORT:-}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: scripts/run-observatorium.sh [--project PATH] [--recreate] [--port PORT]

Launch a small local observatorium container serving a project checkout and
open it in Chromium-first mode, with a host browser fallback. This script is
the dev/litmus wrapper; the main CLI uses the router-gated enclave path.

Options:
  --project PATH  Project checkout to serve read-only (default: repo root)
  --recreate   Remove any existing observatorium container before starting
  --port PORT  Explicit host port escape hatch when 80 and 8080 are occupied

Environment:
  OBSERVATORIUM_BROWSER=auto|chromium|host|none
  OBSERVATORIUM_PORT=8787
  OBSERVATORIUM_BROWSER_URL=http://127.0.0.1:<port>/observatorium/
EOF
    exit 0
fi

PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "error: --project requires a path" >&2
                exit 2
            fi
            PROJECT_PATH="$1"
            ;;
        --recreate)
            RECREATE=1
            ;;
        --port)
            shift
            if [[ -z "${1:-}" || ! "$1" =~ ^[0-9]+$ ]]; then
                echo "error: --port requires a numeric value" >&2
                exit 2
            fi
            PORT_OVERRIDE="$1"
            ;;
        --*)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
        *)
            if [[ -n "$PROJECT_PATH" ]]; then
                echo "error: unexpected argument: $1" >&2
                exit 2
            fi
            PROJECT_PATH="$1"
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT}"
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "error: project path not found or not a directory: $PROJECT_PATH" >&2
    exit 2
fi
PROJECT_ROOT="$(cd "$PROJECT_PATH" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
PROJECT_LABEL="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')"
PODMAN_CLI="$ROOT/scripts/tillandsias-podman"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="${OBSERVATORIUM_CONTAINER_NAME:-tillandsias-observatorium-${PROJECT_LABEL}}"
SERVICE_PORT="${OBSERVATORIUM_SERVICE_PORT:-8080}"
BROWSER_URL="${OBSERVATORIUM_BROWSER_URL:-}"
BROWSER_MODE="${OBSERVATORIUM_BROWSER:-auto}"
# Image resolution (order 267 strict-default finding): the name must be
# localhost/-QUALIFIED — unqualified short names fail on hosts whose
# registries.conf defines no unqualified-search registries — and the exact
# v${VERSION} tag does not exist in the window between a version bump and
# the next image build (every --ci-full pre-build phase). Prefer the exact
# current-version image, fall back to the newest available web image.
IMAGE="${OBSERVATORIUM_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
    IMAGE="localhost/tillandsias-web:v${VERSION}"
    if ! podman image exists "$IMAGE" 2>/dev/null; then
        FALLBACK="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '(^|/)tillandsias-web:v' | head -1)"
        if [[ -n "$FALLBACK" ]]; then
            echo "[run-observatorium] NOTE: $IMAGE not built yet; using $FALLBACK"
            IMAGE="$FALLBACK"
        fi
    fi
fi
HOST_PORT=""
CREATE_NEEDS_HOST_FALLBACK=0
CONTAINER_STARTED_BY_CREATE=0

podman_cli() {
    "$PODMAN_CLI" "$@"
}

container_host_port() {
    local mapping
    mapping="$(podman_cli container host-port "$NAME" "$SERVICE_PORT" 2>/dev/null | head -n1 || true)"
    if [[ -z "$mapping" ]]; then
        return 1
    fi

    echo "${mapping##*:}"
}

create_container_with_userns() {
    local userns_mode="$1"
    local candidate
    local create_error_file
    create_error_file="$(mktemp /tmp/run-observatorium-create.XXXXXX)"

    local candidates=()
    if [[ -n "$PORT_OVERRIDE" ]]; then
        candidates=("$PORT_OVERRIDE")
    else
        candidates=(80 8080)
    fi

    for candidate in "${candidates[@]}"; do
        if podman_cli container run \
            --detach \
            --rm \
            --name "$NAME" \
            --label "app=tillandsias" \
            --label "role=observatorium" \
            --userns="$userns_mode" \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            --security-opt=label=disable \
            --read-only \
            --tmpfs /tmp:rw,size=64m \
            --tmpfs /var/cache:rw,size=16m \
            --publish "127.0.0.1:${candidate}:8080" \
            --volume "${ROOT}/observatorium:/var/www/observatorium:ro" \
            --volume "${PROJECT_ROOT}:/var/www/source:ro" \
            "$IMAGE" >/dev/null 2>"$create_error_file"; then
            HOST_PORT="$candidate"
            CONTAINER_STARTED_BY_CREATE=1
            echo "[run-observatorium] Bound host port: $HOST_PORT"
            rm -f "$create_error_file"
            return 0
        fi

        if grep -Eqi 'newuidmap|cannot set up namespace|uid_map|read-only file system' "$create_error_file"; then
            CREATE_NEEDS_HOST_FALLBACK=1
            cat "$create_error_file" >&2
            rm -f "$create_error_file"
            return 1
        fi
    done

    cat "$create_error_file" >&2
    rm -f "$create_error_file"
    return 1
}

ensure_container() {
    if podman_cli container inspect "$NAME" >/dev/null 2>&1; then
        if [[ "$RECREATE" -eq 1 ]]; then
            echo "[run-observatorium] Recreating existing container: $NAME"
            podman_cli container rm -f "$NAME" >/dev/null 2>&1 || true
        else
            echo "[run-observatorium] Reusing existing container: $NAME"
        fi
    fi

    if ! podman_cli container inspect "$NAME" >/dev/null 2>&1; then
        echo "[run-observatorium] Creating container: $NAME"
        if ! create_container_with_userns keep-id; then
            if [[ "$CREATE_NEEDS_HOST_FALLBACK" -eq 1 ]]; then
                echo "[run-observatorium] Retrying container create with --userns=host after namespace failure"
                podman_cli system migrate >/dev/null 2>&1 || true
                if ! create_container_with_userns host; then
                    :
                fi
            fi
        fi

        if [[ -z "$HOST_PORT" ]]; then
            echo "[run-observatorium] ERROR: podman could not create the observatorium container." >&2
            echo "[run-observatorium] HINT: re-run with --port <free-port> when 80 and 8080 are occupied." >&2
            echo "[run-observatorium] HINT: if podman reports newuidmap/namespace errors, repair the rootless runtime with 'podman system migrate' or reboot." >&2
            return 1
        fi

        if [[ "$CONTAINER_STARTED_BY_CREATE" -eq 1 ]]; then
            echo "[run-observatorium] Starting container: $NAME"
        fi
    fi

    if [[ -z "$HOST_PORT" ]]; then
        HOST_PORT="$(container_host_port)" || true
    fi
}

start_container() {
    if [[ "$CONTAINER_STARTED_BY_CREATE" -eq 1 ]]; then
        return 0
    fi

    local running
    running="$(podman_cli container inspect "$NAME" 2>/dev/null || true)"
    if [[ "$running" == *'"state":"running"'* ]]; then
        echo "[run-observatorium] Container already running: $NAME"
    else
        echo "[run-observatorium] Starting container: $NAME"
        podman_cli container start "$NAME" >/dev/null
    fi
}

resolve_host_port() {
    local mapping
    local i
    for i in $(seq 1 20); do
        mapping="$(podman_cli container host-port "$NAME" "$SERVICE_PORT" 2>/dev/null | head -n1 || true)"
        if [[ -n "$mapping" ]]; then
            echo "${mapping##*:}"
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_http() {
    local i
    for i in $(seq 1 30); do
        if command -v curl >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:${HOST_PORT}/observatorium/" >/dev/null 2>&1; then
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
        "$ROOT/scripts/launch-chromium.sh" observatorium "$BROWSER_URL" 9222 open_debug_window "$VERSION"
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
            "$browser_cmd" --app="$BROWSER_URL" --new-window >/dev/null 2>&1 &
            disown >/dev/null 2>&1 || true
            return 0
        fi
    done

    if command -v xdg-open >/dev/null 2>&1; then
        echo "[run-observatorium] Falling back to xdg-open"
        xdg-open "$BROWSER_URL" >/dev/null 2>&1 &
        disown >/dev/null 2>&1 || true
        return 0
    fi

    echo "[run-observatorium] WARNING: no host browser command found" >&2
    return 1
}

echo "[run-observatorium] Launching observatorium for VERSION=$VERSION"
echo "[run-observatorium] Project: $PROJECT_ROOT"
ensure_container
start_container
if [[ -z "$HOST_PORT" ]]; then
    HOST_PORT="$(resolve_host_port)" || true
fi
if [[ -z "$BROWSER_URL" ]]; then
    BROWSER_URL="http://127.0.0.1:${HOST_PORT}/observatorium/"
fi

if ! wait_for_http; then
    echo "[run-observatorium] ERROR: observatorium did not become ready at http://127.0.0.1:${HOST_PORT}/observatorium/" >&2
    echo "[run-observatorium] --- podman logs: $NAME ---" >&2
    podman_cli container logs --tail 100 "$NAME" >&2 || true
    echo "[run-observatorium] --- podman inspect: $NAME ---" >&2
    podman_cli container inspect "$NAME" >&2 || true
    exit 1
fi

if launch_private_chromium; then
    exit 0
fi

launch_host_browser
