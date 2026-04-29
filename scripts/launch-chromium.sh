#!/usr/bin/env bash
# @trace spec:browser-isolation-launcher
# Launch a Chromium container with security hardening and GPU support detection.
# Usage: launch-chromium.sh <project> <url> [port]
# Example: launch-chromium.sh my-project "http://localhost:3000" 9222

set -euo pipefail

PROJECT="${1:?'Usage: launch-chromium.sh <project> <url> [port]'}"
URL="${2:?'Usage: launch-chromium.sh <project> <url> [port]'}"
PORT="${3:-9222}"

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
    "--tmpfs=/dev/shm:size=256m"
    "--tmpfs=/home/chromium/.cache:size=512m"
    "--read-only"
    "--remote-debugging-port=9222"
    "--remote-debugging-address=127.0.0.1"
)

# Add GPU devices if available
if [[ "$GPU_TIER" == "nvidia" ]]; then
    CMD+=("--device=nvidia.com/gpu=all")
elif [[ "$GPU_TIER" == "amd_intel" ]]; then
    CMD+=("--device=/dev/dri/renderD128")
fi

# Add image and URL
CMD+=("tillandsias-chromium-core:latest" "$URL")

# Spawn container and output container ID
output=$(exec "${CMD[@]}")
echo "$output"
