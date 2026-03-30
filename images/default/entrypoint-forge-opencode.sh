#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: gh credentials, git config, cache. No Claude secrets.

source /usr/local/lib/tillandsias/lib-common.sh

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
            return 0
        fi
        if ! tar xzf /tmp/opencode.tar.gz -C "$OC_DIR/bin/" --strip-components=1; then
            echo "  ERROR: Failed to extract OpenCode archive."
            rm -f /tmp/opencode.tar.gz
            return 0
        fi
        chmod +x "$OC_BIN" 2>/dev/null || true
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
    latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/anomalyco/opencode/releases/latest" 2>/dev/null || true)"
    if [ -z "$latest_url" ]; then
        echo "  Update check skipped (offline)."
        record_update_check "$stamp_file"
        return 0
    fi
    local latest_tag
    latest_tag="$(basename "$latest_url" 2>/dev/null || true)"
    if [ -n "$latest_tag" ] && ! echo "$current_ver" | grep -q "$latest_tag"; then
        echo "  Updating OpenCode ($current_ver -> $latest_tag)..."
        if curl -fsSL -o /tmp/opencode.tar.gz \
            "https://github.com/anomalyco/opencode/releases/latest/download/opencode-${VARIANT}.tar.gz" \
            && tar xzf /tmp/opencode.tar.gz -C "$OC_DIR/bin/" --strip-components=1; then
            chmod +x "$OC_BIN" 2>/dev/null || true
            rm -f /tmp/opencode.tar.gz
            echo "  Updated to $("$OC_BIN" --version 2>/dev/null || echo "$latest_tag")"
        else
            rm -f /tmp/opencode.tar.gz
            echo "  Update failed, continuing with current version."
        fi
    else
        echo "  OpenCode is up to date ($current_ver)."
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

# ── Install and update OpenCode ─────────────────────────────
install_opencode
update_opencode

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── OpenSpec init (first launch only) ────────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR/openspec" ]; then
    "$OS_BIN" init --tools opencode && echo "  ✓ OpenSpec initialized" || echo "  OpenSpec init skipped"
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Launch OpenCode ─────────────────────────────────────────
export PATH="$OC_DIR/bin:$PATH"
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
