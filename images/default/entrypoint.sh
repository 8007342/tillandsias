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

# Detect if we have a terminal (TTY)
if [ -t 0 ] && [ -t 1 ]; then
    # Interactive mode (CLI: tillandsias <path>)
    # Launch opencode TUI or fall back to bash
    if command -v opencode &>/dev/null; then
        set +e
        opencode "$@"
        OPENCODE_EXIT=$?
        set -e

        if [ "$OPENCODE_EXIT" -ne 0 ]; then
            echo ""
            echo "opencode exited with status ${OPENCODE_EXIT}."
            echo "Falling back to interactive bash."
            echo ""
            exec bash
        fi
    else
        echo "opencode not found in PATH."
        echo "Falling back to interactive bash."
        echo ""
        exec bash
    fi
else
    # Detached mode (Tray: Attach Here)
    # Keep container alive. User connects via: podman exec -it <name> bash
    echo "Running in background mode."
    echo "Connect with: podman exec -it ${HOSTNAME:-container} bash"
    echo "Or use: tillandsias ${PROJECT_NAME}"
    echo ""

    # Sleep forever, waiting for SIGTERM
    exec sleep infinity
fi
