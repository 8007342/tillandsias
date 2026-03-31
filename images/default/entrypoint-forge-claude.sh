#!/usr/bin/env bash
# entrypoint-forge-claude.sh — Claude Code forge entrypoint.
#
# Lifecycle: source common -> install/update Claude Code -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec claude
#
# Secrets: gh credentials, git config, claude dir (~/.claude/ mounted from host), cache.

source /usr/local/lib/tillandsias/lib-common.sh

trace_lifecycle "entrypoint" "claude-code starting"

# ── Claude Code (npm installer, cached) ─────────────────────
CC_PREFIX="$CACHE/claude"
CC_BIN="$CC_PREFIX/bin/claude"

install_claude() {
    mkdir -p "$CC_PREFIX" 2>/dev/null || true
    if [ ! -x "$CC_BIN" ]; then
        trace_lifecycle "install" "claude-code: fresh install starting"
        if npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            trace_lifecycle "install" "claude-code: npm install succeeded"
        else
            trace_lifecycle "install" "claude-code: npm install FAILED"
        fi
        if [ -x "$CC_BIN" ]; then
            local cc_ver
            cc_ver="$("$CC_BIN" --version 2>&1 || true)"
            trace_lifecycle "install" "claude-code: ready ($cc_ver)"
        else
            trace_lifecycle "install" "claude-code: binary NOT FOUND after install at $CC_BIN"
        fi
    else
        trace_lifecycle "install" "claude-code: cached ($("$CC_BIN" --version 2>/dev/null || echo "unknown"))"
    fi
    export PATH="$CC_PREFIX/bin:$PATH"
}

update_claude() {
    local stamp_file="$CC_PREFIX/.last-update-check"
    if ! needs_update_check "$stamp_file"; then
        trace_lifecycle "update" "claude-code: skipped (checked <24h ago)"
        return 0
    fi
    if [ ! -x "$CC_BIN" ]; then
        trace_lifecycle "update" "claude-code: skipped (not installed)"
        return 0
    fi
    trace_lifecycle "update" "claude-code: checking for updates..."
    local current_ver latest_ver
    current_ver="$("$CC_BIN" --version 2>/dev/null || echo "unknown")"
    latest_ver="$(timeout 10 npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
    if [ -z "$latest_ver" ]; then
        trace_lifecycle "update" "claude-code: skipped (offline)"
        record_update_check "$stamp_file"
        return 0
    fi
    if [ "$current_ver" != "$latest_ver" ]; then
        trace_lifecycle "update" "claude-code: updating $current_ver -> $latest_ver"
        if npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            trace_lifecycle "update" "claude-code: updated to $("$CC_BIN" --version 2>/dev/null || echo "$latest_ver")"
        else
            trace_lifecycle "update" "claude-code: update FAILED, keeping $current_ver"
        fi
    else
        trace_lifecycle "update" "claude-code: up to date ($current_ver)"
    fi
    record_update_check "$stamp_file"
}

# ── OpenSpec (npm to user prefix, cached) ────────────────────
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"
mkdir -p "$OS_PREFIX" 2>/dev/null || true

if [ ! -x "$OS_BIN" ]; then
    trace_lifecycle "install" "openspec: fresh install starting"
    set +e
    npm install -g --prefix "$OS_PREFIX" @anthropic-ai/openspec 2>&1 || \
        npm install -g --prefix "$OS_PREFIX" openspec 2>&1 || true
    set -e
    if [ -x "$OS_BIN" ]; then
        trace_lifecycle "install" "openspec: installed"
    else
        trace_lifecycle "install" "openspec: not available (non-fatal)"
    fi
else
    trace_lifecycle "install" "openspec: cached"
fi

# ── Install and update Claude Code ──────────────────────────
install_claude
update_claude

# ── Credential check ────────────────────────────────────────
if [ -d "$HOME/.claude" ]; then
    local_files="$(ls -1 "$HOME/.claude/" 2>/dev/null | wc -l | tr -d ' ')"
    trace_lifecycle "credentials" "claude: ~/.claude/ mounted ($local_files files)"
else
    trace_lifecycle "credentials" "claude: ~/.claude/ NOT FOUND (first auth will prompt)"
fi

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    trace_lifecycle "openspec-init" "initializing for claude..."
    "$OS_BIN" init --tools claude && trace_lifecycle "openspec-init" "done" || trace_lifecycle "openspec-init" "skipped"
else
    trace_lifecycle "openspec-init" "skipped (binary=$([ -x "$OS_BIN" ] && echo "yes" || echo "no"), project=$([ -n "$PROJECT_DIR" ] && echo "yes" || echo "no"), existing=$([ -d "${PROJECT_DIR:-/nonexistent}/openspec" ] && echo "yes" || echo "no"))"
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "claude"

# ── Launch Claude Code ──────────────────────────────────────
if [ -x "$CC_BIN" ]; then
    trace_lifecycle "exec" "launching claude-code ($CC_BIN)"
    exec "$CC_BIN" "$@"
else
    trace_lifecycle "exec" "FAILED — claude-code not found at $CC_BIN"
    echo ""
    echo "ERROR: Claude Code failed to install."
    echo ""
    echo "To retry: restart the container"
    echo "To clear cache: rm -rf ~/.cache/tillandsias/claude/"
    echo ""
    exec bash
fi
