#!/usr/bin/env bash
set -euo pipefail

trap 'exit 0' SIGTERM SIGINT

CACHE="$HOME/.cache/tillandsias"

# ── Idempotent tool init ──────────────────────────────────────
# Tools install to the persistent cache volume (mounted from host).
# First run: ~15s. Subsequent runs: instant.

mkdir -p "$CACHE/opencode" "$CACHE/openspec" "$CACHE/nix" 2>/dev/null || true
export PATH="$CACHE/opencode:$CACHE/openspec/node_modules/.bin:$PATH"

# OpenCode — direct binary download, cached
if [ ! -x "$CACHE/opencode/opencode" ]; then
    echo "Installing OpenCode..."
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  VARIANT="linux-x64" ;;
        aarch64) VARIANT="linux-arm64" ;;
        *)       VARIANT="linux-x64" ;;
    esac
    curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${VARIANT}.tar.gz"
    tar xzf /tmp/opencode.tar.gz -C "$CACHE/opencode/"
    chmod +x "$CACHE/opencode/opencode"
    rm -f /tmp/opencode.tar.gz
    echo "  ✓ OpenCode $($CACHE/opencode/opencode --version 2>/dev/null || echo 'installed')"
fi

# OpenSpec — npm prefix install, cached
if [ ! -x "$CACHE/openspec/node_modules/.bin/openspec" ]; then
    echo "Installing OpenSpec..."
    npm install --prefix "$CACHE/openspec" @anthropic-ai/openspec 2>/dev/null \
        || npm install --prefix "$CACHE/openspec" openspec 2>/dev/null \
        || echo "  OpenSpec install deferred"
    if [ -x "$CACHE/openspec/node_modules/.bin/openspec" ]; then
        echo "  ✓ OpenSpec installed"
    fi
fi

# ── Find project directory ────────────────────────────────────
# The project is mounted at /home/forge/src/<project-name>/
# Find the first real directory under src/
PROJECT_DIR=""
for dir in "$HOME/src"/*/; do
    if [ -d "$dir" ]; then
        PROJECT_DIR="$dir"
        break
    fi
done

if [ -n "$PROJECT_DIR" ]; then
    cd "$PROJECT_DIR"
fi

# ── Banner ────────────────────────────────────────────────────
PROJECT_NAME="$(basename "$(pwd)")"
echo ""
echo "========================================"
echo "  tillandsias forge"
echo "  project: ${PROJECT_NAME}"
echo "========================================"
echo ""

# ── Launch OpenCode ───────────────────────────────────────────
if [ -x "$CACHE/opencode/opencode" ]; then
    exec "$CACHE/opencode/opencode" "$@"
else
    echo "OpenCode not available. Starting bash."
    exec bash
fi
