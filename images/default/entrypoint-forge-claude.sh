#!/usr/bin/env bash
# entrypoint-forge-claude.sh — Claude Code forge entrypoint.
#
# Lifecycle: source common -> install/update Claude Code -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec claude
#
# Secrets: gh credentials, git config, claude dir, API key, cache.

source /usr/local/lib/tillandsias/lib-common.sh

# ── Capture and scrub API key ────────────────────────────────
# Only the agent process that needs it will receive it via exec env.
_CLAUDE_KEY="${ANTHROPIC_API_KEY:-}"
unset ANTHROPIC_API_KEY

# ── Claude Code (npm installer, cached) ─────────────────────
CC_PREFIX="$CACHE/claude"
CC_BIN="$CC_PREFIX/bin/claude"

install_claude() {
    mkdir -p "$CC_PREFIX" 2>/dev/null || true
    if [ ! -x "$CC_BIN" ]; then
        echo "Installing Claude Code..."
        if npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            echo "  npm install succeeded."
        else
            echo "  ERROR: npm install failed. See output above for details."
        fi
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
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"
mkdir -p "$OS_PREFIX" 2>/dev/null || true

if [ ! -x "$OS_BIN" ]; then
    echo "Installing OpenSpec..."
    if npm install -g --prefix "$OS_PREFIX" @fission-ai/openspec; then
        [ -x "$OS_BIN" ] && echo "  ✓ OpenSpec installed" || echo "  ✗ OpenSpec binary not found after install"
    else
        echo "  OpenSpec install failed (non-fatal, continuing)"
    fi
fi

# ── Install and update Claude Code ──────────────────────────
install_claude
update_claude

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    "$OS_BIN" init --tools claude && echo "  ✓ OpenSpec initialized" || echo "  OpenSpec init skipped"
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "claude"

# ── Launch Claude Code ──────────────────────────────────────
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
