#!/usr/bin/env bash
# @trace spec:browser-isolation-launcher, spec:browser-isolation-core, spec:chromium-debug-variant
# Launch a Chromium container with security hardening and GPU support detection.
# Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]
# Example: launch-chromium.sh my-project "http://localhost:3000" 9222 open_safe_window "0.1.160"

set -euo pipefail

PROJECT="${1:?'Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]'}"
URL="${2:?'Usage: launch-chromium.sh <project> <url> [port] [window_type] [version]'}"
PORT="${3:-9222}"
WINDOW_TYPE="${4:-open_safe_window}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Build base podman command with security flags
CMD=(
    "podman" "run" "--rm"
    "--userns=keep-id"
    "--cap-drop=ALL"
    "--cap-add=SYS_CHROOT"
    "--network=enclave-bridge"
    "--security-opt=seccomp=/etc/seccomp.json"
    "--tmpfs=/tmp:size=256m"
    "--tmpfs=/home/chromium/.cache:size=512m"
    "--tmpfs=/dev/shm:size=256m"
    "--read-only"
)

# Add window-type specific flags
if [[ "$WINDOW_TYPE" == "open_safe_window" ]]; then
    # Safe window: headless mode, no dev tools
    CMD+=("--headless=new")
elif [[ "$WINDOW_TYPE" == "open_debug_window" ]]; then
    # Debug window: remote debugging enabled
    CMD+=("--remote-debugging-port=${PORT}")
    CMD+=("--remote-debugging-address=127.0.0.1")
else
    # Default: safe window
    CMD+=("--headless=new")
fi

# Add GPU devices if available
if [[ "$GPU_TIER" == "nvidia" ]]; then
    CMD+=("--device=nvidia.com/gpu=all")
elif [[ "$GPU_TIER" == "amd_intel" ]]; then
    CMD+=("--device=/dev/dri/renderD128")
fi

# Add image and URL — use versioned image tags for reproducibility
# @trace spec:browser-isolation-core
if [[ "$VERSION" == "latest" ]]; then
    echo "ERROR: chromium launcher requires a concrete version, not 'latest'" >&2
    exit 2
fi

# Use versioned tags: tillandsias-chromium-core:v0.1.160
# @trace spec:browser-isolation-core
if [[ "$WINDOW_TYPE" == "open_debug_window" ]]; then
    CMD+=("tillandsias-chromium-framework:v${VERSION}" "$URL")
else
    CMD+=("tillandsias-chromium-core:v${VERSION}" "$URL")
fi

# Spawn container and output container ID
output=$(exec "${CMD[@]}")
echo "$output"
