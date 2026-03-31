#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

source /usr/local/lib/tillandsias/lib-common.sh

trace_lifecycle "entrypoint" "opencode starting"

# ── OpenCode (official installer, cached) ───────────────────
# Install to persistent cache so the binary survives container restarts.
# The env var must be exported so the piped bash subprocess inherits it.
export OPENCODE_INSTALL_DIR="$CACHE/opencode"
OC_BIN="$OPENCODE_INSTALL_DIR/bin/opencode"

ensure_opencode() {
    local stamp_file="$OPENCODE_INSTALL_DIR/.last-update-check"
    mkdir -p "$OPENCODE_INSTALL_DIR/bin" 2>/dev/null || true

    # First install: run the official installer
    if [ ! -x "$OC_BIN" ]; then
        trace_lifecycle "install" "opencode: fresh install to $OPENCODE_INSTALL_DIR"
        # Disable set -e for the installer — it may return non-zero or trigger
        # pipefail even on success (installer writes to stderr for progress).
        set +e
        curl -fsSL https://opencode.ai/install | bash 2>&1
        local install_exit=$?
        set -e

        # The installer might ignore OPENCODE_INSTALL_DIR and install to ~/.opencode.
        # If so, move the binary to our cache dir so it persists.
        if [ ! -x "$OC_BIN" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then
            trace_lifecycle "install" "opencode: installer used ~/.opencode, relocating to cache"
            cp "$HOME/.opencode/bin/opencode" "$OC_BIN"
            chmod +x "$OC_BIN"
        fi

        if [ -x "$OC_BIN" ]; then
            trace_lifecycle "install" "opencode: ready ($("$OC_BIN" --version 2>/dev/null || echo "unknown"))"
            record_update_check "$stamp_file"
        else
            trace_lifecycle "install" "opencode: FAILED (exit=$install_exit, binary not at $OC_BIN)"
        fi
        return 0  # Always non-fatal — script continues to error handler at bottom
    fi

    # Subsequent launches: only update if stamp is stale (daily throttle)
    if ! needs_update_check "$stamp_file"; then
        trace_lifecycle "update" "opencode: skipped (checked <24h ago)"
        return 0
    fi
    trace_lifecycle "update" "opencode: checking for updates..."
    set +e
    curl -fsSL https://opencode.ai/install | bash 2>&1
    set -e
    # Relocate if installer ignored OPENCODE_INSTALL_DIR
    if [ ! -x "$OC_BIN" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then
        cp "$HOME/.opencode/bin/opencode" "$OC_BIN"
        chmod +x "$OC_BIN"
    fi
    if [ -x "$OC_BIN" ]; then
        trace_lifecycle "update" "opencode: $("$OC_BIN" --version 2>/dev/null || echo "ready")"
    fi
    record_update_check "$stamp_file"
}

# ── OpenSpec (npm to user prefix, cached) ────────────────────
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"
mkdir -p "$OS_PREFIX" 2>/dev/null || true

if [ ! -x "$OS_BIN" ]; then
    trace_lifecycle "install" "openspec: fresh install starting"
    # npm install can fail for many reasons — never fatal
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

# ── Install and update OpenCode ─────────────────────────────
ensure_opencode || true  # Never fatal — error handler at bottom provides fallback

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    trace_lifecycle "openspec-init" "initializing for opencode..."
    "$OS_BIN" init --tools opencode && trace_lifecycle "openspec-init" "done" || trace_lifecycle "openspec-init" "skipped"
else
    trace_lifecycle "openspec-init" "skipped (binary=$([ -x "$OS_BIN" ] && echo "yes" || echo "no"), project=$([ -n "$PROJECT_DIR" ] && echo "yes" || echo "no"), existing=$([ -d "${PROJECT_DIR:-/nonexistent}/openspec" ] && echo "yes" || echo "no"))"
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Launch OpenCode ─────────────────────────────────────────
export PATH="$OPENCODE_INSTALL_DIR/bin:$PATH"
if [ -x "$OC_BIN" ]; then
    trace_lifecycle "exec" "launching opencode ($OC_BIN)"
    exec "$OC_BIN" "$@"
else
    trace_lifecycle "exec" "FAILED — opencode not found at $OC_BIN"
    echo ""
    echo "ERROR: OpenCode failed to install."
    echo ""
    echo "To retry: restart the container"
    echo "To clear cache: rm -rf ~/.cache/tillandsias/opencode/"
    echo ""
    exec bash
fi
