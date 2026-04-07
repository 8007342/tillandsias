#!/usr/bin/env bash
# entrypoint-forge-claude.sh — Claude Code forge entrypoint.
#
# Lifecycle: source common -> install/update Claude Code -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec claude
#
# Secrets: gh credentials, git config, claude dir (~/.claude/ mounted from host), cache.

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
CA_CHAIN="/run/tillandsias/ca-chain.crt"
if [ -f "$CA_CHAIN" ]; then
    if command -v update-ca-trust &>/dev/null; then
        if ! cp "$CA_CHAIN" /etc/pki/ca-trust/source/anchors/tillandsias-ca.crt 2>/dev/null; then
            echo "[entrypoint] WARNING: Failed to install CA certificate — proxy HTTPS caching may not work" >&2
        fi
        if ! update-ca-trust 2>/dev/null; then
            echo "[entrypoint] WARNING: Failed to update CA trust store" >&2
        fi
    elif command -v update-ca-certificates &>/dev/null; then
        if ! cp "$CA_CHAIN" /usr/local/share/ca-certificates/tillandsias-ca.crt 2>/dev/null; then
            echo "[entrypoint] WARNING: Failed to install CA certificate — proxy HTTPS caching may not work" >&2
        fi
        if ! update-ca-certificates 2>/dev/null; then
            echo "[entrypoint] WARNING: Failed to update CA trust store" >&2
        fi
    fi
fi

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "claude-code starting"

# @trace spec:git-mirror-service, spec:forge-offline
# Clone project from git mirror (Phase 3: mirror-only, no direct mount)
if [[ -n "${TILLANDSIAS_GIT_SERVICE:-}" ]] && [[ -n "${TILLANDSIAS_PROJECT:-}" ]]; then
    trace_lifecycle "git-mirror" "cloning from ${TILLANDSIAS_GIT_SERVICE}"
    MAX_RETRIES=5
    CLONE_SUCCESS=false
    CLONE_DIR="/home/forge/src/${TILLANDSIAS_PROJECT}"
    for i in $(seq 1 $MAX_RETRIES); do
        if git clone "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" "$CLONE_DIR" 2>&1; then
            trace_lifecycle "git-mirror" "clone successful"
            CLONE_SUCCESS=true
            cd "$CLONE_DIR"
            # Configure push back to mirror
            # @trace spec:git-mirror-service
            if ! git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" 2>/dev/null; then
                echo "[entrypoint] WARNING: Failed to set push URL — git push may not work" >&2
            fi
            # Set git identity from host config
            # @trace spec:forge-offline
            if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
                git config user.name "$GIT_AUTHOR_NAME"
            fi
            if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
                git config user.email "$GIT_AUTHOR_EMAIL"
            fi
            break
        fi
        if [[ $i -lt $MAX_RETRIES ]]; then
            trace_lifecycle "git-mirror" "git service not ready, retrying ($i/$MAX_RETRIES)..."
            sleep 1
        else
            trace_lifecycle "git-mirror" "clone failed after $MAX_RETRIES attempts"
        fi
    done
    if [[ "$CLONE_SUCCESS" != "true" ]]; then
        echo "[forge] ERROR: Could not clone project from git service."
        echo "[forge] The git service may not be running. Dropping to shell."
        exec bash
    fi
    echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
fi

# ── Capture and scrub API key ────────────────────────────────
# Only the agent process that needs it will receive it via exec env.
_CLAUDE_KEY="${ANTHROPIC_API_KEY:-}"
unset ANTHROPIC_API_KEY

# ── Claude Code (npm installer, cached) ─────────────────────
# @trace spec:layered-tools-overlay
# Check for pre-installed tools overlay before falling back to inline install.
TOOLS_DIR="/home/forge/.tools"
TOOLS_CC_BIN="$TOOLS_DIR/claude/bin/claude"
_CLAUDE_FROM_OVERLAY=false

if [ -x "$TOOLS_CC_BIN" ]; then
    # Tools overlay present — use pre-installed binary
    export PATH="$TOOLS_DIR/claude/bin:$PATH"
    CC_PREFIX="$TOOLS_DIR/claude"
    CC_BIN="$TOOLS_CC_BIN"
    _CLAUDE_FROM_OVERLAY=true
    trace_lifecycle "install" "claude-code: using tools overlay ($TOOLS_CC_BIN)"
else
    # Fallback: install inline (first launch or overlay not ready)
    CC_PREFIX="$CACHE/claude"
    CC_BIN="$CC_PREFIX/bin/claude"
fi

install_claude() {
    # @trace spec:layered-tools-overlay
    if [ "$_CLAUDE_FROM_OVERLAY" = true ]; then
        trace_lifecycle "install" "claude-code: skipped (overlay)"
        return 0
    fi
    mkdir -p "$CC_PREFIX" 2>/dev/null || true
    if [ ! -x "$CC_BIN" ]; then
        trace_lifecycle "install" "claude-code: fresh install starting"
        if spin "${L_INSTALLING_CLAUDE:-Installing Claude Code...}" npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            trace_lifecycle "install" "claude-code: npm install succeeded"
        else
            trace_lifecycle "install" "claude-code: npm install FAILED"
        fi
        if [ -x "$CC_BIN" ]; then
            local cc_ver
            cc_ver="$("$CC_BIN" --version 2>&1 || true)"
            trace_lifecycle "install" "claude-code: ready ($cc_ver)"
            printf "  ${L_INSTALLED_CLAUDE:-Claude Code ready: %s}\n" "$cc_ver" >&2
        else
            trace_lifecycle "install" "claude-code: binary NOT FOUND after install at $CC_BIN"
            echo "  ${L_CLAUDE_NOT_FOUND:-Claude Code binary not found after install.}" >&2
        fi
    else
        trace_lifecycle "install" "claude-code: cached ($("$CC_BIN" --version 2>/dev/null || echo "unknown"))"
    fi
    export PATH="$CC_PREFIX/bin:$PATH"
}

update_claude() {
    # @trace spec:layered-tools-overlay
    if [ "$_CLAUDE_FROM_OVERLAY" = true ]; then
        trace_lifecycle "update" "claude-code: skipped (overlay)"
        return 0
    fi
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
    latest_ver="$(timeout 10 npm view @anthropic-ai/claude-code version </dev/null 2>/dev/null || true)"
    if [ -z "$latest_ver" ]; then
        trace_lifecycle "update" "claude-code: skipped (offline)"
        record_update_check "$stamp_file"
        return 0
    fi
    if [ "$current_ver" != "$latest_ver" ]; then
        trace_lifecycle "update" "claude-code: updating $current_ver -> $latest_ver"
        if spin "${L_INSTALLING_CLAUDE:-Installing Claude Code...}" npm install -g --prefix "$CC_PREFIX" @anthropic-ai/claude-code; then
            trace_lifecycle "update" "claude-code: updated to $("$CC_BIN" --version 2>/dev/null || echo "$latest_ver")"
        else
            trace_lifecycle "update" "claude-code: update FAILED, keeping $current_ver"
        fi
    else
        trace_lifecycle "update" "claude-code: up to date ($current_ver)"
    fi
    record_update_check "$stamp_file"
}

# ── OpenSpec (shared function from lib-common.sh) ────────────
# @trace spec:forge-shell-tools
install_openspec
OS_BIN="$CACHE/openspec/bin/openspec"

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

# ── OpenSpec init (every launch, silent) ────────────────────
# Always run to ensure /opsx commands are available, even if the project
# was cloned without openspec config. Idempotent — no-ops if already set up.
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools claude </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "claude"

# ── Launch Claude Code ──────────────────────────────────────
trace_lifecycle "entrypoint" "claude launching"
if [ -x "$CC_BIN" ]; then
    trace_lifecycle "exec" "launching claude-code ($CC_BIN)"
    exec "$CC_BIN" "$@"
else
    trace_lifecycle "exec" "FAILED — claude-code not found at $CC_BIN"
    echo ""
    echo "${L_INSTALL_FAILED_CLAUDE:-ERROR: Claude Code failed to install.}"
    echo ""
    echo "${L_RETRY_HINT:-To retry: restart the container}"
    echo "${L_CLEAR_CACHE_CLAUDE:-To clear cache: rm -rf ~/.cache/tillandsias/claude/}"
    echo ""
    exec bash
fi
