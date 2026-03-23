#!/usr/bin/env bash
set -euo pipefail

trap 'exit 0' SIGTERM SIGINT

# Cache dirs
mkdir -p ~/.cache/tillandsias/{nix,opencode} 2>/dev/null || true

# OpenCode lives at ~/.opencode/bin/ (persisted via cache mount)
export PATH="$HOME/.opencode/bin:$PATH"

# Install OpenCode on first run (official installer, cached across runs)
if ! command -v opencode &>/dev/null; then
    echo "Installing OpenCode (first run, ~10s)..."
    curl -fsSL https://opencode.ai/install | bash 2>&1
fi

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
    echo "OpenCode not available. Starting bash."
    exec bash
fi
