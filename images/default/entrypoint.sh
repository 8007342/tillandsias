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

# ── Maintenance mode ────────────────────────────────────────
# When TILLANDSIAS_MAINTENANCE=1 the container was launched for a
# maintenance terminal. We set up PATH and env, then drop to fish/bash
# instead of launching an AI agent.
MAINTENANCE="${TILLANDSIAS_MAINTENANCE:-0}"

# ── Update-check rate-limiting ──────────────────────────────
# Returns 0 (true) if the last check was more than 24 hours ago or never ran.
needs_update_check() {
    local stamp_file="$1"
    if [ ! -f "$stamp_file" ]; then
        return 0
    fi
    local now last_check age
    now="$(date +%s)"
    last_check="$(cat "$stamp_file" 2>/dev/null || echo 0)"
    age=$(( now - last_check ))
    # 86400 seconds = 24 hours
    [ "$age" -ge 86400 ]
}

record_update_check() {
    local stamp_file="$1"
    mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
    date +%s > "$stamp_file"
}

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
        if ! curl -fsSL -o /tmp/opencode.tar.gz \
            "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${VARIANT}.tar.gz"; then
            echo "  ERROR: Failed to download OpenCode. Check network connection."
            return 1
        fi
        tar xzf /tmp/opencode.tar.gz -C "$OC_DIR/bin/" --strip-components=1
        chmod +x "$OC_BIN"
        rm -f /tmp/opencode.tar.gz
    fi
    # Verify binary actually works
    if [ -x "$OC_BIN" ]; then
        local oc_ver
        oc_ver="$("$OC_BIN" --version 2>&1 || true)"
        if [ -n "$oc_ver" ]; then
            echo "  OpenCode ready: $oc_ver"
        else
            echo "  WARNING: OpenCode binary exists but --version returned nothing."
        fi
    fi
}

update_opencode() {
    local stamp_file="$OC_DIR/.last-update-check"
    if ! needs_update_check "$stamp_file"; then
        return 0
    fi
    if [ ! -x "$OC_BIN" ]; then
        return 0
    fi
    echo "Checking for OpenCode updates..."
    local current_ver latest_url
    current_ver="$("$OC_BIN" --version 2>/dev/null || echo "unknown")"
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  VARIANT="linux-x64" ;;
        aarch64) VARIANT="linux-arm64" ;;
        *)       VARIANT="linux-x64" ;;
    esac
    # Check if the latest release redirects to a different URL than what we have.
    # GitHub releases/latest always redirects to the actual version URL.
    latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/anomalyco/opencode/releases/latest" 2>/dev/null || true)"
    if [ -z "$latest_url" ]; then
        echo "  Update check skipped (offline)."
        record_update_check "$stamp_file"
        return 0
    fi
    # Extract version tag from redirect URL (e.g., .../releases/tag/v0.1.2 -> v0.1.2)
    local latest_tag
    latest_tag="$(basename "$latest_url" 2>/dev/null || true)"
    if [ -n "$latest_tag" ] && ! echo "$current_ver" | grep -q "$latest_tag"; then
        echo "  Updating OpenCode ($current_ver -> $latest_tag)..."
        if curl -fsSL -o /tmp/opencode.tar.gz \
            "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${VARIANT}.tar.gz"; then
            tar xzf /tmp/opencode.tar.gz -C "$OC_DIR/bin/" --strip-components=1
            chmod +x "$OC_BIN"
            rm -f /tmp/opencode.tar.gz
            echo "  Updated to $("$OC_BIN" --version 2>/dev/null || echo "$latest_tag")"
        else
            echo "  Update failed, continuing with current version."
        fi
    else
        echo "  OpenCode is up to date ($current_ver)."
    fi
    record_update_check "$stamp_file"
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
        # Show output so failures are diagnosable (no 2>/dev/null).
        if npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            echo "  npm install succeeded."
        else
            echo "  ERROR: npm install failed. See output above for details."
        fi
        # Verify the binary
        if [ -x "$CC_BIN" ]; then
            local cc_ver
            cc_ver="$("$CC_BIN" --version 2>&1 || true)"
            if [ -n "$cc_ver" ]; then
                echo "  Claude Code ready: $cc_ver"
            else
                echo "  WARNING: Claude Code binary exists but --version returned nothing."
                echo "  The binary may be corrupt. Try clearing the cache:"
                echo "    rm -rf $CC_PREFIX && restart the container"
            fi
        else
            echo "  Claude Code binary not found after install."
            echo "  Expected at: $CC_BIN"
        fi
    fi
    export PATH="$CC_PREFIX/bin:$PATH"
}

update_claude() {
    local stamp_file="$CC_PREFIX/.last-update-check"
    if ! needs_update_check "$stamp_file"; then
        return 0
    fi
    if [ ! -x "$CC_BIN" ]; then
        return 0
    fi
    echo "Checking for Claude Code updates..."
    local current_ver latest_ver
    current_ver="$("$CC_BIN" --version 2>/dev/null || echo "unknown")"
    # npm view returns the latest published version — timeout after 10 seconds
    latest_ver="$(timeout 10 npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
    if [ -z "$latest_ver" ]; then
        echo "  Update check skipped (offline or npm registry unreachable)."
        record_update_check "$stamp_file"
        return 0
    fi
    if [ "$current_ver" != "$latest_ver" ]; then
        echo "  Updating Claude Code ($current_ver -> $latest_ver)..."
        if npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            echo "  Updated to $("$CC_BIN" --version 2>/dev/null || echo "$latest_ver")"
        else
            echo "  Update failed, continuing with current version ($current_ver)."
        fi
    else
        echo "  Claude Code is up to date ($current_ver)."
    fi
    record_update_check "$stamp_file"
}

# ── OpenSpec (npm to user prefix, cached) ────────────────────
if [ ! -x "$OS_BIN" ]; then
    echo "Installing OpenSpec..."
    if npm install -g --prefix "$OS_PREFIX" @fission-ai/openspec; then
        [ -x "$OS_BIN" ] && echo "  ✓ OpenSpec installed" || echo "  ✗ OpenSpec binary not found after install"
    else
        echo "  OpenSpec install failed (non-fatal, continuing)"
    fi
fi

# Install and update the selected agent
if [ "$AGENT" = "opencode" ]; then
    install_opencode
    update_opencode
fi
if [ "$AGENT" = "claude" ]; then
    install_claude
    update_claude
fi

# ── Find project directory ───────────────────────────────────
PROJECT_DIR=""
for dir in "$HOME/src"/*/; do
    [ -d "$dir" ] && PROJECT_DIR="$dir" && break
done
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    "$OS_BIN" init --tools claude && echo "  ✓ OpenSpec initialized" || echo "  OpenSpec init skipped"
fi

# ── Banner ───────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  tillandsias forge"
echo "  project: $(basename "$(pwd)")"
echo "  agent:   $AGENT"
[ "$MAINTENANCE" = "1" ] && echo "  mode:    maintenance"
echo "========================================"
echo ""

# ── Maintenance mode: drop to interactive shell ──────────────
if [ "$MAINTENANCE" = "1" ]; then
    # Ensure agent bin dirs are on PATH for maintenance shells too
    export PATH="$CC_PREFIX/bin:$OC_DIR/bin:$PATH"
    if command -v fish &>/dev/null; then
        exec fish
    else
        exec bash
    fi
fi

# ── Launch selected agent ────────────────────────────────────
case "$AGENT" in
    claude)
        if [ -x "$CC_BIN" ]; then
            # Re-inject API key at exec time. The key was captured and scrubbed
            # above — this ensures it only exists in Claude Code's process env.
            if [ -n "$_CLAUDE_KEY" ]; then
                exec env ANTHROPIC_API_KEY="$_CLAUDE_KEY" "$CC_BIN" "$@"
            else
                exec "$CC_BIN" "$@"
            fi
        else
            echo ""
            echo "ERROR: Claude Code failed to install."
            echo ""
            echo "Possible causes:"
            echo "  - Network issue during npm install"
            echo "  - npm cache corruption"
            echo "  - Insufficient disk space"
            echo ""
            echo "To retry: restart the container (Tillandsias will re-attempt install)"
            echo "To clear cache: rm -rf ~/.cache/tillandsias/claude/"
            echo ""
            echo "Starting bash for debugging..."
            exec bash
        fi
        ;;
    opencode)
        if [ -x "$OC_BIN" ]; then
            exec "$OC_BIN" "$@"
        else
            echo ""
            echo "ERROR: OpenCode failed to install."
            echo ""
            echo "Possible causes:"
            echo "  - Network issue during download"
            echo "  - GitHub release URL changed"
            echo "  - Unsupported architecture: $(uname -m)"
            echo ""
            echo "To retry: restart the container (Tillandsias will re-attempt install)"
            echo "To clear cache: rm -rf ~/.cache/tillandsias/opencode/"
            echo ""
            echo "Starting bash for debugging..."
            exec bash
        fi
        ;;
    *)
        echo "Unknown agent '$AGENT'. Starting bash."
        exec bash
        ;;
esac
