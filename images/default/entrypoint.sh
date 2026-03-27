#!/usr/bin/env bash
set -euo pipefail

# Ensure all files created by this script and any process it execs (OpenCode,
# npm, openspec, bash) are user-writable. Without this, tools that run inside
# the container may create files on the bind-mounted project directory with
# mode 0444 or 0555, which the host user cannot modify or delete without sudo.
umask 0022

trap 'exit 0' SIGTERM SIGINT

# Ensure secrets directories exist
mkdir -p ~/.config/gh 2>/dev/null || true
touch ~/.gitconfig 2>/dev/null || true

# Bridge gh auth → git push: register gh as git credential helper.
# Without this, git doesn't know about gh's OAuth token and prompts for
# username/password. Non-interactive, fails silently if gh not installed yet.
command -v gh &>/dev/null && gh auth setup-git 2>/dev/null || true

# Deploy shell configs if not present
for f in .bashrc .zshrc; do
    [ -f "$HOME/$f" ] || cp "/etc/skel/$f" "$HOME/$f" 2>/dev/null || true
done
mkdir -p "$HOME/.config/fish"
[ -f "$HOME/.config/fish/config.fish" ] || cp "/etc/skel/.config/fish/config.fish" "$HOME/.config/fish/config.fish" 2>/dev/null || true

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

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    "$OS_BIN" init --tools opencode && echo "  ✓ OpenSpec initialized" || echo "  ⚠ OpenSpec init skipped"
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
