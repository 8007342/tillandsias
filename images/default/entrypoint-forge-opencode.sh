#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

source /usr/local/lib/tillandsias/lib-common.sh

trace_lifecycle "entrypoint" "opencode starting"

# ── Nix dynamic linker ─────────────────────────────────────
# The Nix-built container lacks standard glibc paths (/lib/ld-linux-*.so).
# Pre-built binaries (curl installer, npm-bundled natives) fail with
# "required file not found" or ENOENT. We find the Nix dynamic linker
# and use it to invoke unpatched binaries.
NIX_LD="$(find /nix/store -name 'ld-linux-*.so.*' -path '*/lib/ld-linux-*' 2>/dev/null | head -1)"
NIX_LIB_DIR="$(dirname "$NIX_LD" 2>/dev/null || true)"
if [ -n "$NIX_LD" ]; then
    trace_lifecycle "nix" "dynamic linker: $NIX_LD"
else
    trace_lifecycle "nix" "WARNING: dynamic linker not found in /nix/store"
fi

# ── OpenCode (curl installer + Nix linker wrapper) ─────────
OC_DIR="$CACHE/opencode"
OC_NATIVE="$HOME/.opencode/bin/opencode"
OC_BIN="$OC_DIR/bin/opencode"

ensure_opencode() {
    local stamp_file="$OC_DIR/.last-update-check"
    mkdir -p "$OC_DIR/bin" 2>/dev/null || true

    # First install: download via official curl installer
    if [ ! -x "$OC_BIN" ]; then
        trace_lifecycle "install" "opencode: fresh install via curl"
        set +e
        curl -fsSL https://opencode.ai/install | bash 2>&1
        set -e

        # The installer puts the native binary at ~/.opencode/bin/opencode.
        # It can't execute directly in Nix (wrong ELF interpreter), so we
        # create a wrapper script that invokes it through the Nix linker.
        local native_bin="$OC_NATIVE"
        if [ ! -f "$native_bin" ]; then
            trace_lifecycle "install" "opencode: FAILED (binary not at $native_bin)"
            return 0
        fi

        if [ -n "$NIX_LD" ]; then
            trace_lifecycle "install" "opencode: creating Nix linker wrapper"
            cat > "$OC_BIN" <<WRAPPER
#!/usr/bin/env bash
exec "$NIX_LD" --library-path "$NIX_LIB_DIR" "$native_bin" "\$@"
WRAPPER
            chmod +x "$OC_BIN"
        else
            # No Nix linker found — try direct execution (non-Nix image)
            cp "$native_bin" "$OC_BIN"
            chmod +x "$OC_BIN"
        fi

        if [ -x "$OC_BIN" ]; then
            local oc_ver
            oc_ver="$("$OC_BIN" --version 2>/dev/null || echo "unknown")"
            trace_lifecycle "install" "opencode: ready ($oc_ver)"
            record_update_check "$stamp_file"
        else
            trace_lifecycle "install" "opencode: wrapper created but execution failed"
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
    # Recreate wrapper if native binary was updated
    if [ -f "$OC_NATIVE" ] && [ -n "$NIX_LD" ]; then
        cat > "$OC_BIN" <<WRAPPER
#!/usr/bin/env bash
exec "$NIX_LD" --library-path "$NIX_LIB_DIR" "$OC_NATIVE" "\$@"
WRAPPER
        chmod +x "$OC_BIN"
    fi
    trace_lifecycle "update" "opencode: $("$OC_BIN" --version 2>/dev/null || echo "ready")"
    record_update_check "$stamp_file"
}

# ── OpenSpec ────────────────────────────────────────────────
# OpenSpec is a Node.js CLI — npm install works in Nix (uses patched Node).
# Package name: @fission-ai/openspec (primary), fallback: openspec
OS_PREFIX="$CACHE/openspec"
OS_BIN="$OS_PREFIX/bin/openspec"
mkdir -p "$OS_PREFIX" 2>/dev/null || true

if [ ! -x "$OS_BIN" ]; then
    trace_lifecycle "install" "openspec: fresh install starting"
    set +e
    npm install -g --prefix "$OS_PREFIX" @fission-ai/openspec 2>&1 || \
        npm install -g --prefix "$OS_PREFIX" openspec-cli 2>&1 || true
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
ensure_opencode || true

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    trace_lifecycle "openspec-init" "initializing for opencode..."
    "$OS_BIN" init --tools opencode && trace_lifecycle "openspec-init" "done" || trace_lifecycle "openspec-init" "skipped"
else
    trace_lifecycle "openspec-init" "skipped (binary=$([ -x "$OS_BIN" ] && echo "yes" || echo "no"))"
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Launch OpenCode ─────────────────────────────────────────
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
