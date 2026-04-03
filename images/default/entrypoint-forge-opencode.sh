#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "opencode starting"

# ── OpenCode (official curl installer) ─────────────────────
# On Fedora (default): pre-built binary executes directly (standard glibc).
# On Nix: binary needs the Nix dynamic linker — a wrapper is created.
OC_DIR="$CACHE/opencode"
OC_BIN="$OC_DIR/bin/opencode"
OC_NATIVE="$HOME/.opencode/bin/opencode"

_make_opencode_wrapper() {
    # The curl installer puts the binary at ~/.opencode/bin/opencode.
    # We need it at $OC_BIN (persistent cache). On Nix images, the binary
    # can't execute directly, so we create a wrapper with the Nix linker.
    local native="$OC_NATIVE"
    [ -f "$native" ] || return 1

    local nix_ld
    nix_ld="$(find /nix/store -name 'ld-linux-*.so.*' -path '*/lib/ld-linux-*' 2>/dev/null | head -1)"

    if [ -n "$nix_ld" ]; then
        trace_lifecycle "install" "opencode: Nix image detected, creating linker wrapper"
        local nix_lib_dir
        nix_lib_dir="$(dirname "$nix_ld")"
        cat > "$OC_BIN" <<WRAPPER
#!/usr/bin/env bash
exec "$nix_ld" --library-path "$nix_lib_dir" "$native" "\$@"
WRAPPER
        chmod +x "$OC_BIN"
    else
        # Standard FHS (Fedora) — binary executes directly
        cp "$native" "$OC_BIN"
        chmod +x "$OC_BIN"
    fi
}

ensure_opencode() {
    local stamp_file="$OC_DIR/.last-update-check"
    mkdir -p "$OC_DIR/bin" 2>/dev/null || true

    if [ ! -x "$OC_BIN" ]; then
        trace_lifecycle "install" "opencode: fresh install via curl"
        set +e
        export OPENCODE_INSTALL_DIR="$OC_DIR"
        curl -fsSL https://opencode.ai/install | bash 2>&1
        set -e

        # If installer ignored OPENCODE_INSTALL_DIR (common), relocate binary
        if [ ! -x "$OC_BIN" ] && [ -f "$OC_NATIVE" ]; then
            _make_opencode_wrapper
        fi

        if [ -x "$OC_BIN" ]; then
            trace_lifecycle "install" "opencode: ready ($("$OC_BIN" --version 2>/dev/null || echo "unknown"))"
            record_update_check "$stamp_file"
        else
            trace_lifecycle "install" "opencode: FAILED (binary not found)"
        fi
        return 0
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
    # Refresh wrapper/copy if updated
    if [ -f "$OC_NATIVE" ]; then
        _make_opencode_wrapper
    fi
    trace_lifecycle "update" "opencode: $("$OC_BIN" --version 2>/dev/null || echo "ready")"
    record_update_check "$stamp_file"
}

# ── OpenSpec (shared function from lib-common.sh) ────────────
# @trace spec:forge-shell-tools
install_openspec
OS_BIN="$CACHE/openspec/bin/openspec"

# ── Install and update OpenCode ─────────────────────────────
ensure_opencode || true

echo "[lifecycle] entrypoint | opencode installed" >&2

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
# Always run to ensure /opsx commands are available, even if the project
# was cloned without openspec config. Idempotent — no-ops if already set up.
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    "$OS_BIN" init --tools opencode >/dev/null 2>&1 || true
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Launch OpenCode ─────────────────────────────────────────
echo "[lifecycle] entrypoint | opencode launching" >&2
export PATH="$OC_DIR/bin:$PATH"
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
