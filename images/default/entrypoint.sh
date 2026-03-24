#!/usr/bin/env bash
set -euo pipefail

trap 'exit 0' SIGTERM SIGINT

# Ensure secrets directories exist
mkdir -p ~/.config/gh 2>/dev/null || true
touch ~/.gitconfig 2>/dev/null || true

CACHE="$HOME/.cache/tillandsias"
OC_BIN="$CACHE/opencode/opencode"
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"

mkdir -p "$CACHE/opencode" "$OS_PREFIX" "$CACHE/nix" 2>/dev/null || true
export PATH="$CACHE/opencode:$OS_PREFIX/bin:$PATH"

# ── OpenCode (direct binary, cached) ──────────────────────────
if [ ! -x "$OC_BIN" ]; then
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
    chmod +x "$OC_BIN"
    rm -f /tmp/opencode.tar.gz
    echo "  ✓ OpenCode $("$OC_BIN" --version 2>/dev/null || echo 'installed')"
fi

# ── OpenSpec (npm to user prefix, cached) ─────────────────────
if [ ! -x "$OS_BIN" ]; then
    echo "Installing OpenSpec..."
    npm install -g --prefix "$OS_PREFIX" @fission-ai/openspec 2>/dev/null || true
    [ -x "$OS_BIN" ] && echo "  ✓ OpenSpec installed" || echo "  OpenSpec deferred"
fi

# ── Find project directory ────────────────────────────────────
PROJECT_DIR=""
for dir in "$HOME/src"/*/; do
    [ -d "$dir" ] && PROJECT_DIR="$dir" && break
done
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── Deploy OpenCode skills ───────────────────────────────────
# Skills are bundled into the image at /usr/local/share/tillandsias/opencode/.
# ~/src/ is a volume mount so build-time files are hidden — copy at runtime.
SKILLS_SRC="/usr/local/share/tillandsias/opencode"
if [ -d "$SKILLS_SRC" ] && [ -n "$PROJECT_DIR" ]; then
    mkdir -p "$PROJECT_DIR/.opencode"
    cp -r "$SKILLS_SRC"/* "$PROJECT_DIR/.opencode/" 2>/dev/null || true
fi

# ── Banner ────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  tillandsias forge"
echo "  project: $(basename "$(pwd)")"
echo "========================================"
echo ""

# ── Launch OpenCode ───────────────────────────────────────────
if [ -x "$OC_BIN" ]; then
    exec "$OC_BIN" "$@"
else
    echo "OpenCode not available. Starting bash."
    exec bash
fi
