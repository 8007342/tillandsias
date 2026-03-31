#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

source /usr/local/lib/tillandsias/lib-common.sh

trace_lifecycle "entrypoint" "opencode starting"

# ── OpenCode (npm installer, cached) ────────────────────────
# The Nix-built container lacks standard glibc paths (/lib/ld-linux-*.so),
# so pre-built binaries from the curl installer can't execute ("required
# file not found"). npm install uses Node.js which is Nix-patched, so it
# works correctly — same pattern as Claude Code.
OC_PREFIX="$CACHE/opencode"
OC_BIN="$OC_PREFIX/bin/opencode"

ensure_opencode() {
    local stamp_file="$OC_PREFIX/.last-update-check"
    mkdir -p "$OC_PREFIX" 2>/dev/null || true

    # First install
    if [ ! -x "$OC_BIN" ]; then
        trace_lifecycle "install" "opencode: fresh install via npm"
        set +e
        npm install -g --prefix "$OC_PREFIX" opencode-ai@latest 2>&1
        set -e
        if [ -x "$OC_BIN" ]; then
            trace_lifecycle "install" "opencode: ready ($("$OC_BIN" --version 2>/dev/null || echo "unknown"))"
            record_update_check "$stamp_file"
        else
            trace_lifecycle "install" "opencode: FAILED (binary not at $OC_BIN)"
        fi
        return 0
    fi

    # Subsequent launches: only update if stamp is stale (daily throttle)
    if ! needs_update_check "$stamp_file"; then
        trace_lifecycle "update" "opencode: skipped (checked <24h ago)"
        return 0
    fi
    trace_lifecycle "update" "opencode: checking for updates..."
    local current_ver latest_ver
    current_ver="$("$OC_BIN" --version 2>/dev/null || echo "unknown")"
    latest_ver="$(timeout 10 npm view opencode-ai version 2>/dev/null || true)"
    if [ -z "$latest_ver" ]; then
        trace_lifecycle "update" "opencode: skipped (offline)"
        record_update_check "$stamp_file"
        return 0
    fi
    if [ "$current_ver" != "$latest_ver" ]; then
        trace_lifecycle "update" "opencode: updating $current_ver -> $latest_ver"
        set +e
        npm install -g --prefix "$OC_PREFIX" opencode-ai@latest 2>&1
        set -e
        trace_lifecycle "update" "opencode: $("$OC_BIN" --version 2>/dev/null || echo "ready")"
    else
        trace_lifecycle "update" "opencode: up to date ($current_ver)"
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
export PATH="$OC_PREFIX/bin:$PATH"
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
