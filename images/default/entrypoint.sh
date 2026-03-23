#!/usr/bin/env bash
set -euo pipefail

trap 'exit 0' SIGTERM SIGINT

CACHE="$HOME/.cache/tillandsias"
OC_BIN="$CACHE/opencode/opencode"

mkdir -p "$CACHE/opencode" "$CACHE/nix" 2>/dev/null || true
export PATH="$CACHE/opencode:$PATH"

# Install OpenCode binary directly into the cache (persisted via mount)
if [ ! -x "$OC_BIN" ]; then
    echo "Installing OpenCode (first run)..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  VARIANT="linux-x64" ;;
        aarch64) VARIANT="linux-arm64" ;;
        *)       VARIANT="linux-x64" ;;
    esac
    curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${VARIANT}.tar.gz"
    tar xzf /tmp/opencode.tar.gz -C "$CACHE/opencode/"
    chmod +x "$OC_BIN"
    rm -f /tmp/opencode.tar.gz
    echo "OpenCode installed: $("$OC_BIN" --version 2>/dev/null || echo 'ok')"
fi

# Deferred OpenSpec install
command -v openspec &>/dev/null || npm install -g @fission-ai/openspec 2>/dev/null || true

# Banner
echo ""
echo "========================================"
echo "  tillandsias forge"
echo "  project: $(basename "$(pwd)")"
echo "========================================"
echo ""

# Launch OpenCode
if [ -x "$OC_BIN" ]; then
    exec "$OC_BIN" "$@"
else
    echo "OpenCode not available. Starting bash."
    exec bash
fi
