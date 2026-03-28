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

# Bridge gh auth -> git push: register gh as git credential helper.
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
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"

mkdir -p "$OS_PREFIX" "$CACHE/nix" 2>/dev/null || true
export PATH="$OS_PREFIX/bin:$PATH"

# ── Agent selection ──────────────────────────────────────────
AGENT="${TILLANDSIAS_AGENT:-claude}"

# Capture API key then scrub from environment to limit exposure.
# Only the agent process that needs it will receive it via exec env.
_CLAUDE_KEY="${ANTHROPIC_API_KEY:-}"
unset ANTHROPIC_API_KEY

# ── OpenCode (direct binary, cached) ────────────────────────
OC_DIR="$CACHE/opencode"
OC_BIN="$OC_DIR/bin/opencode"

install_opencode() {
    mkdir -p "$OC_DIR/bin" 2>/dev/null || true
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
        tar xzf /tmp/opencode.tar.gz -C "$OC_DIR/bin/" --strip-components=1
        chmod +x "$OC_BIN"
        rm -f /tmp/opencode.tar.gz
        echo "  done OpenCode $("$OC_BIN" --version 2>/dev/null || echo 'installed')"
    fi
}

# ── Claude Code (npm installer, cached) ─────────────────────
CC_PREFIX="$CACHE/claude"
CC_BIN="$CC_PREFIX/bin/claude"

install_claude() {
    mkdir -p "$CC_PREFIX" 2>/dev/null || true
    if [ ! -x "$CC_BIN" ]; then
        echo "Installing Claude Code..."
        # Claude Code installs via npm — use a local prefix so it persists
        # across container restarts via the cache bind mount.
        npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code 2>/dev/null || true
        if [ -x "$CC_BIN" ]; then
            echo "  done Claude Code installed"
        else
            echo "  Claude Code install failed"
        fi
    fi
    export PATH="$CC_PREFIX/bin:$PATH"
}

# ── OpenSpec (npm to user prefix, cached) ────────────────────
if [ ! -x "$OS_BIN" ]; then
    echo "Installing OpenSpec..."
    npm install -g --prefix "$OS_PREFIX" @fission-ai/openspec 2>/dev/null || true
    [ -x "$OS_BIN" ] && echo "  done OpenSpec installed" || echo "  OpenSpec deferred"
fi

# Install the selected agent
if [ "$AGENT" = "opencode" ]; then
    install_opencode
fi
if [ "$AGENT" = "claude" ]; then
    install_claude
fi

# ── Find project directory ───────────────────────────────────
PROJECT_DIR=""
for dir in "$HOME/src"/*/; do
    [ -d "$dir" ] && PROJECT_DIR="$dir" && break
done
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    "$OS_BIN" init --tools claude && echo "  done OpenSpec initialized" || echo "  OpenSpec init skipped"
fi

# ── Banner ───────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  tillandsias forge"
echo "  project: $(basename "$(pwd)")"
echo "  agent:   $AGENT"
echo "========================================"
echo ""

# ── Launch selected agent ────────────────────────────────────
case "$AGENT" in
    claude)
        if [ -x "$CC_BIN" ]; then
            exec "$CC_BIN" "$@"
        else
            echo "Claude Code not available. Starting bash."
            exec bash
        fi
        ;;
    opencode)
        if [ -x "$OC_BIN" ]; then
            exec "$OC_BIN" "$@"
        else
            echo "OpenCode not available. Starting bash."
            exec bash
        fi
        ;;
    *)
        echo "Unknown agent '$AGENT'. Starting bash."
        exec bash
        ;;
esac
