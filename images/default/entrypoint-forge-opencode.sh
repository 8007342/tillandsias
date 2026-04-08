#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

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
trace_lifecycle "entrypoint" "opencode starting"

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

# ── Config overlay (ramdisk symlinks) ──────────────────────
# @trace spec:layered-tools-overlay
# Symlink tool configs to ramdisk overlay (zero disk I/O reads)
OVERLAY="/home/forge/.config-overlay"
if [ -d "$OVERLAY/opencode" ]; then
    mkdir -p ~/.config
    ln -sfn "$OVERLAY/opencode" ~/.config/opencode
    trace_lifecycle "config" "opencode: symlinked to ramdisk overlay"
fi

# ── OpenCode (official curl installer) ─────────────────────
# On Fedora (default): pre-built binary executes directly (standard glibc).
# On Nix: binary needs the Nix dynamic linker — a wrapper is created.
# @trace spec:layered-tools-overlay
# Check for pre-installed tools overlay before falling back to inline install.
TOOLS_DIR="/home/forge/.tools"
TOOLS_OC_BIN="$TOOLS_DIR/opencode/bin/opencode"
_OPENCODE_FROM_OVERLAY=false

if [ -x "$TOOLS_OC_BIN" ]; then
    # Tools overlay present — use pre-installed binary
    export PATH="$TOOLS_DIR/opencode/bin:$PATH"
    OC_DIR="$TOOLS_DIR/opencode"
    OC_BIN="$TOOLS_OC_BIN"
    _OPENCODE_FROM_OVERLAY=true
    trace_lifecycle "install" "opencode: using tools overlay ($TOOLS_OC_BIN)"
else
    # Fallback: install inline (first launch or overlay not ready)
    OC_DIR="$CACHE/opencode"
    OC_BIN="$OC_DIR/bin/opencode"
fi
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
    # @trace spec:layered-tools-overlay
    if [ "$_OPENCODE_FROM_OVERLAY" = true ]; then
        trace_lifecycle "install" "opencode: skipped (overlay)"
        return 0
    fi
    local stamp_file="$OC_DIR/.last-update-check"
    mkdir -p "$OC_DIR/bin" 2>/dev/null || true

    if [ ! -x "$OC_BIN" ]; then
        trace_lifecycle "install" "opencode: fresh install via curl"
        set +e
        export OPENCODE_INSTALL_DIR="$OC_DIR"
        OC_OUTPUT=$(spin "${L_INSTALLING_OPENCODE:-Installing OpenCode...}" bash -c 'curl -fsSL https://opencode.ai/install | bash' 2>&1)
        OC_EXIT=$?
        set -e
        if [ $OC_EXIT -ne 0 ]; then
            echo "[entrypoint] WARNING: OpenCode installer exited with code $OC_EXIT" >&2
            echo "[entrypoint] $OC_OUTPUT" >&2
        fi

        # If installer ignored OPENCODE_INSTALL_DIR (common), relocate binary
        if [ ! -x "$OC_BIN" ] && [ -f "$OC_NATIVE" ]; then
            _make_opencode_wrapper
        fi

        if [ -x "$OC_BIN" ]; then
            trace_lifecycle "install" "opencode: ready ($("$OC_BIN" --version 2>/dev/null || echo "unknown"))"
            printf "  ${L_INSTALLED_OPENCODE:-OpenCode ready: %s}\n" "$("$OC_BIN" --version 2>/dev/null || echo "")" >&2
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
    OC_OUTPUT=$(spin "${L_INSTALLING_OPENCODE:-Installing OpenCode...}" bash -c 'curl -fsSL https://opencode.ai/install | bash' 2>&1)
    OC_EXIT=$?
    set -e
    if [ $OC_EXIT -ne 0 ]; then
        echo "[entrypoint] WARNING: OpenCode update exited with code $OC_EXIT" >&2
        echo "[entrypoint] $OC_OUTPUT" >&2
    fi
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

trace_lifecycle "entrypoint" "opencode installed"

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
# Always run to ensure /opsx commands are available, even if the project
# was cloned without openspec config. Idempotent — no-ops if already set up.
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools opencode </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Launch OpenCode ─────────────────────────────────────────
trace_lifecycle "entrypoint" "opencode launching"
export PATH="$OC_DIR/bin:$PATH"
if [ -x "$OC_BIN" ]; then
    trace_lifecycle "exec" "launching opencode ($OC_BIN)"
    exec "$OC_BIN" "$@"
else
    trace_lifecycle "exec" "FAILED — opencode not found at $OC_BIN"
    echo ""
    echo "${L_OPENCODE_INSTALL_FAILED:-ERROR: OpenCode failed to install.}"
    echo ""
    echo "${L_RETRY_HINT:-To retry: restart the container}"
    echo "${L_CLEAR_CACHE_OPENCODE:-To clear cache: rm -rf ~/.cache/tillandsias/opencode/}"
    echo ""
    exec bash
fi
