#!/usr/bin/env bash
set -euo pipefail

trap 'exit 0' SIGTERM SIGINT

# Cache dirs
mkdir -p ~/.cache/tillandsias/{nix,opencode} 2>/dev/null || true

# Deferred OpenSpec install
command -v openspec &>/dev/null || npm install -g @fission-ai/openspec 2>/dev/null || true

# Banner
PROJECT_NAME="$(basename "$(pwd)")"
echo "========================================"
echo "  tillandsias forge"
echo "  project: ${PROJECT_NAME}"
echo "========================================"
echo ""

# Launch OpenCode or fall back to bash
if command -v opencode &>/dev/null; then
    exec opencode "$@"
else
    echo "opencode not found. Starting bash."
    exec bash
fi
