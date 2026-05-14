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

configure_display_forwarding() {
    if [[ -n "${DISPLAY:-}" ]]; then
        PODMAN_ARGS+=(
            "--env=DISPLAY=${DISPLAY}"
            "--volume=/tmp/.X11-unix:/tmp/.X11-unix:rw"
        )
        if [[ -n "${XAUTHORITY:-}" && -f "${XAUTHORITY}" ]]; then
            PODMAN_ARGS+=(
                "--env=XAUTHORITY=/home/chromium/.Xauthority"
                "--volume=${XAUTHORITY}:/home/chromium/.Xauthority:ro"
            )
        fi
        BROWSER_ARGS+=("--ozone-platform=x11")
        return 0
    fi

    if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
        local wayland_socket="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
        if [[ -S "$wayland_socket" ]]; then
            PODMAN_ARGS+=(
                "--env=XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
                "--env=WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
                "--volume=${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}:rw"
            )
            BROWSER_ARGS+=("--ozone-platform=wayland")
            return 0
        fi
    fi

    echo "ERROR: launch-chromium.sh requires a graphical session (DISPLAY or WAYLAND_DISPLAY)." >&2
    return 1
}

# Build base podman command with security flags
PODMAN_ARGS=(
    "$PODMAN" "run" "--rm"
    "--pull=never"
    "--userns=keep-id"
    "--cap-drop=ALL"
    "--cap-add=SYS_CHROOT"
    "--network=${TILLANDSIAS_BROWSER_NETWORK:-host}"
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
