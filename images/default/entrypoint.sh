#!/usr/bin/env bash
set -euo pipefail

# Graceful shutdown on SIGTERM/SIGINT
cleanup() {
    echo ""
    echo "Shutting down..."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Create cache directories if missing
mkdir -p ~/.cache/tillandsias/nix
mkdir -p ~/.cache/tillandsias/opencode

# Deferred OpenSpec install if not found
if ! command -v openspec &>/dev/null; then
    npm install -g @fission-ai/openspec 2>/dev/null || true
fi

# Welcome banner
PROJECT_NAME="$(basename "$(pwd)")"
echo "========================================"
echo "  tillandsias forge"
echo "  project: ${PROJECT_NAME}"
echo "========================================"
echo ""

# Launch opencode as the foreground process, fall back to bash
if command -v opencode &>/dev/null; then
    exec opencode "$@"
else
    echo "opencode not found, falling back to bash"
    exec bash "$@"
fi
