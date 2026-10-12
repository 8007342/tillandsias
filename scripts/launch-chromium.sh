#!/usr/bin/env bash
# @trace spec:browser-isolation-core, spec:chromium-safe-variant, spec:chromium-debug-variant
# Launch a Chromium container with security hardening, GUI display forwarding,
# and GPU support detection.
# Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]
# Example: launch-chromium.sh my-project "http://localhost:3000" 9222 open_safe_window "0.1.160"

set -euo pipefail

PROJECT="${1:?'Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]'}"
URL="${2:?'Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]'}"
PORT="${3:-9222}"
WINDOW_TYPE="${4:-open_safe_window}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
VERSION="${5:-$DEFAULT_VERSION}"

# Detect GPU availability
detect_gpu() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        echo "nvidia"
    elif [[ -c /dev/dri/renderD128 ]]; then
        echo "amd_intel"
    else
        echo "none"
    fi
}

GPU_TIER=$(detect_gpu)
if [[ -n "${XDG_RUNTIME_DIR:-}" && -w "${XDG_RUNTIME_DIR:-/dev/null}" ]]; then
    PROFILE_ROOT="${XDG_RUNTIME_DIR}/tillandsias/browser"
else
    PROFILE_ROOT="${TMPDIR:-/tmp}/tillandsias/browser"
fi
mkdir -p "$PROFILE_ROOT"
PROFILE_DIR="$(mktemp -d "$PROFILE_ROOT/${PROJECT}-XXXXXX")"
CHROMIUM_CONFIG_DIR="${PROFILE_ROOT}/chromium-config"
CHROMIUM_CACHE_DIR="${PROFILE_ROOT}/chromium-cache"
mkdir -p "$CHROMIUM_CONFIG_DIR" "$CHROMIUM_CACHE_DIR"

cleanup() {
    rm -rf "$PROFILE_DIR"
}

trap cleanup EXIT INT TERM

# ORDER 1641-xbvq (p0): WAYLAND ONLY, and ONLY the socket file. This used to
# mount the host's whole $XDG_RUNTIME_DIR read-write on Wayland (podman.sock,
# the tray and lane MCP sockets, the D-Bus bus and the keyring dir) and all of
# /tmp/.X11-unix on X11, and X11 won whenever DISPLAY was set (every XWayland
# session). The socket goes into a private tmpfs runtime dir, without a
# relabel option, which would rewrite the live compositor socket's label.
# label=disable stays (below) because a confined container_t is denied
# connecting to the compositor socket ("Failed to connect to Wayland display:
# Permission denied", measured 2026-10-12).
BROWSER_RUNTIME_DIR=/run/user/browser
configure_display_forwarding() {
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo "ERROR: launch-chromium.sh opens the browser on Wayland only, and this session has no WAYLAND_DISPLAY. It never hands a container an X11 display (that reaches every X client on it). Log in to a Wayland session and retry." >&2
        return 1
    fi
    local wayland_socket
    case "$WAYLAND_DISPLAY" in
        /*) wayland_socket="$WAYLAND_DISPLAY" ;;
        */*) echo "ERROR: launch-chromium.sh: WAYLAND_DISPLAY=${WAYLAND_DISPLAY} is not a socket name. Log in to a Wayland session and retry." >&2; return 1 ;;
        .) echo "ERROR: launch-chromium.sh: WAYLAND_DISPLAY=. is not a socket name. Log in to a Wayland session and retry." >&2; return 1 ;;
        ..) echo "ERROR: launch-chromium.sh: WAYLAND_DISPLAY=.. is not a socket name. Log in to a Wayland session and retry." >&2; return 1 ;;
        *)
            if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
                echo "ERROR: launch-chromium.sh opens the browser on Wayland only, and XDG_RUNTIME_DIR is not set, so the Wayland socket cannot be found. Log in to a Wayland session and retry." >&2
                return 1
            fi
            wayland_socket="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ;;
    esac
    if [[ ! -S "$wayland_socket" ]]; then
        echo "ERROR: launch-chromium.sh opens the browser on Wayland only, and the Wayland socket ${wayland_socket} does not exist. Log in to a Wayland session and retry." >&2
        return 1
    fi
    local socket_name="${wayland_socket##*/}"
    PODMAN_ARGS+=(
        "--tmpfs=${BROWSER_RUNTIME_DIR}:size=1m,mode=0755"
        "--volume=${wayland_socket}:${BROWSER_RUNTIME_DIR}/${socket_name}:rw"
        "--env=XDG_RUNTIME_DIR=${BROWSER_RUNTIME_DIR}"
        "--env=WAYLAND_DISPLAY=${socket_name}"
    )
    BROWSER_ARGS+=("--ozone-platform=wayland")
    return 0
}

# Build base podman command with security flags
PODMAN_ARGS=(
    "$PODMAN" "run" "--rm"
    "--pull=never"
    "--userns=keep-id"
    "--cap-drop=ALL"
    "--cap-add=SYS_CHROOT"
    # ORDER 1118-dwgx. DEFAULT TO THE ENCLAVE, NOT THE HOST. `--network=host`
    # gave Chromium direct host network access with no proxy filtering — every
    # other flag in this array is a confinement (cap-drop=ALL, no-new-privileges,
    # read-only, tmpfs everything) and the network line undid them by default.
    # The fallback chain honours TILLANDSIAS_ENCLAVE_NET so this agrees with
    # check-enclave-network-internal.sh rather than hardcoding a second spelling
    # of the same network; an operator who has renamed the enclave renames it
    # once. TILLANDSIAS_BROWSER_NETWORK still wins for a deliberate override.
    "--network=${TILLANDSIAS_BROWSER_NETWORK:-${TILLANDSIAS_ENCLAVE_NET:-tillandsias-enclave}}"
    "--security-opt=no-new-privileges"
    "--security-opt=label=disable"
    "--tmpfs=/tmp:size=256m"
    "--tmpfs=/tmp/chromium-config:size=128m"
    "--tmpfs=/tmp/chromium-cache:size=512m"
    "--tmpfs=/dev/shm:size=256m"
    "--read-only"
    "--volume=${PROFILE_DIR}:${PROFILE_DIR}"
)

# Add Chromium command flags after the image name.
BROWSER_ARGS=(
    "--incognito"
    "--no-first-run"
    "--no-default-browser-check"
    "--user-data-dir=${PROFILE_DIR}"
)

PODMAN_ARGS+=(
    "--env=XDG_CONFIG_HOME=/tmp/chromium-config"
    "--env=XDG_CACHE_HOME=/tmp/chromium-cache"
)

# Add window-type specific flags
if [[ "$WINDOW_TYPE" == "open_debug_window" ]]; then
    # Debug window: remote debugging enabled, still GUI app-mode.
    BROWSER_ARGS+=("--remote-debugging-port=${PORT}")
    BROWSER_ARGS+=("--remote-debugging-address=127.0.0.1")
fi

configure_display_forwarding

# Add GPU devices if available (optional — skip if not accessible)
# CDI devices may not be configured in all environments
if [[ "$GPU_TIER" == "amd_intel" && -e /dev/dri/renderD128 ]]; then
    PODMAN_ARGS+=("--device=/dev/dri/renderD128")
fi

# Add image and URL — use versioned image tags for reproducibility
# @trace spec:browser-isolation-core
if [[ "$VERSION" == "latest" ]]; then
    echo "ERROR: chromium launcher requires a concrete version, not 'latest'" >&2
    exit 2
fi

# Use versioned tags from the local wrapper storage.
# @trace spec:browser-isolation-core
PODMAN_ARGS+=("tillandsias-chromium-framework:v${VERSION}")

# Chromium app-mode URL argument follows the image and browser flags.
BROWSER_ARGS+=("--app=${URL}")

# Spawn container and output container ID
output=$(exec "${PODMAN_ARGS[@]}" "${BROWSER_ARGS[@]}")
echo "$output"
