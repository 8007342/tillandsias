#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Development Build Script
#
# Single entry point for the entire dev lifecycle. Runs everything inside
# the `tillandsias` toolbox, creating it automatically if needed.
#
# Usage:
#   ./build.sh                      # Debug build
#   ./build.sh --release            # Release build (Tauri bundle)
#   ./build.sh --test               # Run tests
#   ./build.sh --check              # Type-check only
#   ./build.sh --clean              # Clean before building
#   ./build.sh --install            # Build AppImage + install to ~/Applications/
#   ./build.sh --remove             # Remove installed AppImage + symlink
#   ./build.sh --wipe               # Remove target/, caches, temp files
#   ./build.sh --toolbox-reset      # Destroy and recreate toolbox
#   ./build.sh --appimage           # Build AppImage in Ubuntu podman container
#   ./build.sh --clean --release    # Flags combine
# =============================================================================

set -euo pipefail

# @trace spec:dev-build, spec:appimage-build-pipeline, spec:windows-cross-build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBOX_NAME="$(basename "$SCRIPT_DIR")"

# Get the actual user's home directory (works with sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    ACTUAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    ACTUAL_HOME="$HOME"
fi

INSTALL_DIR="$ACTUAL_HOME/.local/bin"
INSTALL_BIN="$INSTALL_DIR/tillandsias"
CACHE_DIR="$ACTUAL_HOME/.cache/tillandsias"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[build]${NC} $*"; }
_error() { echo -e "${RED}[build]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[build]${NC} $*"; }

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
FLAG_RELEASE=false
FLAG_TEST=false
FLAG_CHECK=false
FLAG_CLEAN=false
FLAG_INSTALL=false
FLAG_REMOVE=false
FLAG_WIPE=false
FLAG_TOOLBOX_RESET=false
FLAG_APPIMAGE=false
FLAG_INIT=false
FLAG_CI=false
FLAG_CI_FULL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        FLAG_RELEASE=true ;;
        --test)           FLAG_TEST=true ;;
        --check)          FLAG_CHECK=true ;;
        --clean)          FLAG_CLEAN=true ;;
        --install)        FLAG_INSTALL=true ;;
        --remove)         FLAG_REMOVE=true ;;
        --wipe)           FLAG_WIPE=true ;;
        --toolbox-reset)  FLAG_TOOLBOX_RESET=true ;;
        --appimage)       FLAG_APPIMAGE=true ;;
        --init)           FLAG_INIT=true ;;
        --ci)             FLAG_CI=true ;;
        --ci-full)        FLAG_CI_FULL=true ;;
        --help|-h)
            cat <<'EOF'
Tillandsias Development Build Script

Usage: ./build.sh [flags]

Build flags:
  (none)            Debug build (cargo build --workspace)
  --release         Release build (cargo tauri build — validates CI first)
  --test            Run test suite (cargo test --workspace)
  --check           Type-check only (cargo check --workspace)
  --clean           Clean build artifacts before building
  --appimage        Build AppImage in Ubuntu podman container (FUSE-capable)
  --ci              Run local CI/CD validation (quick: spec binding, drift, version, fmt, clippy, tests)
  --ci-full         Run full CI/CD validation (includes litmus tests — required for releases)

Install flags:
  --install         Build AppImage + install to ~/Applications/ + symlink to ~/.local/bin/
  --remove          Remove installed AppImage, symlink, and desktop integration

Maintenance flags:
  --wipe            Remove target/, ~/.cache/tillandsias/, temp files
  --toolbox-reset   Destroy and recreate the tillandsias toolbox
  --init            Build all container images with versioned tags (runs on host)
  --help            Show this message

Flags combine: ./build.sh --clean --release --install

The tillandsias toolbox is auto-created on first run with all
build dependencies (GTK, WebKit, Tauri CLI). No manual setup needed.
EOF
            exit 0
            ;;
        *) _error "Unknown flag: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Transparent HTTPS caching setup (dev proxy)
# ---------------------------------------------------------------------------
# @trace spec:dev-build, spec:transparent-https-caching
ensure_dev_cache() {
    # Skip if explicitly disabled
    [[ "${TILLANDSIAS_NO_PROXY:-}" == "1" ]] && return 0

    # Ensure CA cert exists
    local ca_cert="$CACHE_DIR/ca-cert.pem"
    local ca_key="$CACHE_DIR/ca-key.pem"
    if [[ ! -f "$ca_cert" ]]; then
        mkdir -p "$CACHE_DIR"
        openssl req -x509 -newkey rsa:2048 -keyout "$ca_key" -out "$ca_cert" \
            -days 3650 -nodes -subj "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA" 2>/dev/null || {
            _warn "Failed to generate CA cert for dev proxy"
            return 0
        }
    fi

    # Ensure dev proxy cache dir exists
    mkdir -p "$CACHE_DIR/dev-proxy-cache"

    # Find or rebuild the tillandsias-proxy image
    local proxy_image
    proxy_image=$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "tillandsias-proxy" | head -1)

    if [[ -z "$proxy_image" ]]; then
        _step "No tillandsias-proxy image found — rebuilding..."
        if [[ ! -x "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
            _warn "scripts/build-image.sh not found — dev caching disabled"
            return 0
        fi
        if ! "$SCRIPT_DIR/scripts/build-image.sh" proxy 2>&1 | tail -5; then
            _warn "Failed to build tillandsias-proxy image — dev caching disabled"
            return 0
        fi
        # Re-fetch image after building
        proxy_image=$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "tillandsias-proxy" | head -1)
        if [[ -z "$proxy_image" ]]; then
            _warn "tillandsias-proxy image still not found after build — dev caching disabled"
            return 0
        fi
        _info "Proxy image built: $proxy_image"
    fi

    # Start dev proxy if not already running
    if ! podman inspect tillandsias-dev-proxy &>/dev/null 2>&1; then
        _step "Starting dev proxy container..."

        # Start proxy with all interface binding so containers can reach it
        if ! podman run \
            --detach \
            --rm \
            --name tillandsias-dev-proxy \
            --publish "3129:3129" \
            --userns=keep-id \
            --volume "$CACHE_DIR/dev-proxy-cache:/var/spool/squid:rw,Z" \
            --volume "$ca_cert:/etc/squid/certs/intermediate.crt:ro,Z" \
            --volume "$ca_key:/etc/squid/certs/intermediate.key:ro,Z" \
            "$proxy_image" >/dev/null 2>&1; then
            _warn "Failed to start dev proxy container"
            return 0
        fi

        # Wait for proxy to be healthy (listening on 3129)
        local max_retries=15
        local retry=0
        while [[ $retry -lt $max_retries ]]; do
            if nc -z 127.0.0.1 3129 &>/dev/null 2>&1; then
                _info "Dev proxy healthy on :3129"
                break
            fi
            retry=$((retry + 1))
            if [[ $retry -eq $max_retries ]]; then
                _error "Proxy health check failed after $max_retries seconds"
                podman logs tillandsias-dev-proxy 2>&1 | tail -20
                podman rm -f tillandsias-dev-proxy 2>/dev/null || true
                return 0
            fi
            sleep 1
        done
    fi

    # Export proxy env vars for toolbox and AppImage builder
    export HTTP_PROXY="http://127.0.0.1:3129"
    export HTTPS_PROXY="http://127.0.0.1:3129"
    export http_proxy="http://127.0.0.1:3129"
    export https_proxy="http://127.0.0.1:3129"
    export CARGO_HTTP_PROXY="http://127.0.0.1:3129"
    export CARGO_HTTP_CAINFO="$ca_cert"

    _info "Dev proxy active: $HTTP_PROXY"
}

ensure_dev_cache

# ---------------------------------------------------------------------------
# Standalone operations (don't need toolbox)
# ---------------------------------------------------------------------------

if [[ "$FLAG_INIT" == true ]]; then
    _step "Running tillandsias --init (builds all images with versioned tags)..."
    # Runs on HOST where podman works (not nested in toolbox)
    "$SCRIPT_DIR/target/debug/tillandsias" --init 2>&1
    # Also prune old images
    _step "Pruning old images..."
    podman image prune -f 2>/dev/null || true
    exit 0
fi

# CI validation (standalone — runs locally without toolbox)
if [[ "$FLAG_CI" == true ]] || [[ "$FLAG_CI_FULL" == true ]]; then
    if [[ "$FLAG_CI_FULL" == true ]]; then
        _step "Running full CI/CD validation (including litmus tests)..."
        CI_ARGS=""
    else
        _step "Running quick CI/CD validation (skipping litmus tests)..."
        CI_ARGS="--fast"
    fi

    if bash "$SCRIPT_DIR/scripts/local-ci.sh" $CI_ARGS; then
        if [[ "$FLAG_CI_FULL" == true ]]; then
            _info "Full CI/CD validation passed — ready for release"
        else
            _info "Quick CI/CD validation passed — ready for development"
        fi
        # If --ci or --ci-full is the only flag, exit with success
        if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_APPIMAGE$FLAG_WIPE$FLAG_TOOLBOX_RESET$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
            exit 0
        fi
    else
        _error "CI/CD validation failed — fix issues and retry"
        exit 1
    fi
fi

if [[ "$FLAG_REMOVE" == true ]]; then
    # Remove AppImage (new install layout)
    rm -f "$ACTUAL_HOME/Applications/Tillandsias.AppImage"
    # Remove CLI symlink
    rm -f "$INSTALL_BIN"
    # Remove legacy layout artifacts (old install format)
    rm -f "$INSTALL_DIR/.tillandsias-bin"
    rm -rf "$ACTUAL_HOME/.local/lib/tillandsias"
    rm -rf "$ACTUAL_HOME/.local/share/tillandsias"

    # Remove desktop launcher and XDG icons
    rm -f "$ACTUAL_HOME/.local/share/applications/tillandsias.desktop"
    for size in 32x32 128x128 256x256; do
        rm -f "$ACTUAL_HOME/.local/share/icons/hicolor/$size/apps/tillandsias.png"
    done
    update-desktop-database "$ACTUAL_HOME/.local/share/applications" 2>/dev/null || true
    gtk-update-icon-cache "$ACTUAL_HOME/.local/share/icons/hicolor" 2>/dev/null || true

    _info "Removed tillandsias (AppImage, symlink, desktop integration)"
    # If --remove is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_TOOLBOX_RESET$FLAG_APPIMAGE$FLAG_CI$FLAG_CI_FULL" == "falsefalsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

if [[ "$FLAG_WIPE" == true ]]; then
    _step "Wiping build artifacts and caches..."
    rm -rf "$SCRIPT_DIR/target"
    rm -rf "$CACHE_DIR"
    # Cargo registry cache inside toolbox is in the host home (shared)
    _info "Removed target/ and $CACHE_DIR"
    # If --wipe is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_TOOLBOX_RESET$FLAG_APPIMAGE$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# AppImage build (standalone — uses podman Ubuntu container, not toolbox)
# ---------------------------------------------------------------------------

build_appimage() {
    local output_dir="$SCRIPT_DIR/target/release/bundle/appimage"
    local cache_base="$ACTUAL_HOME/.cache/tillandsias/appimage-builder"
    local container_pid=""

    # Trap SIGINT to kill child podman process on Ctrl+C
    trap 'if [[ -n "$container_pid" ]]; then kill "$container_pid" 2>/dev/null || true; fi; exit 130' INT TERM

    _step "Preparing AppImage build directories..."
    mkdir -p "$output_dir"
    mkdir -p "$cache_base"/{cargo-registry,cargo-bin,rustup,apt}

    # Clean stale apt locks from previous interrupted builds
    # @trace spec:appimage-build-pipeline
    rm -f "$cache_base/apt/archives/lock" "$cache_base/apt/lists/lock" 2>/dev/null || true
    rm -rf "$cache_base/apt/partial" "$cache_base/apt/lists/partial" 2>/dev/null || true
    # Also clean any stray apt processes that might be holding locks
    pkill -9 -f "apt-get|dpkg" 2>/dev/null || true
    # Wait for process cleanup
    sleep 1

    # Remove old AppImages — avoids "Text file busy" if one is still running.
    # On Linux, rm unlinks the file but running processes keep their fd.
    rm -f "$output_dir"/*.AppImage 2>/dev/null || true

    _info "Output dir:  $output_dir"
    _info "Cache dir:   $cache_base"
    _step "Starting Ubuntu 22.04 podman container for AppImage build..."
    if [[ -f "$cache_base/rustup/settings.toml" ]]; then
        _info "Cached toolchain found — skipping install (~1-2 min build)"
    else
        _warn "First build installs Rust + tauri-cli — expect 10-20 minutes"
    fi

    # Create apt lists cache directory
    mkdir -p "$cache_base"/apt-lists

    # Run podman in background so we can capture PID for signal handling
    local podman_args=(
        --rm
        --device /dev/fuse
        --cap-add SYS_ADMIN
        -v "$SCRIPT_DIR:/src:ro,Z"
        -v "$cache_base/cargo-registry:/root/.cargo/registry:rw,Z"
        -v "$cache_base/cargo-bin:/root/.cargo/bin:rw,Z"
        -v "$cache_base/rustup:/root/.rustup:rw,Z"
        -v "$cache_base/apt:/var/cache/apt:rw,Z"
        -v "$cache_base/apt-lists:/var/lib/apt/lists:rw,Z"
        -v "$output_dir:/output:rw,Z"
    )

    # Add proxy and CA cert if dev proxy is running
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        local ca_cert="$CACHE_DIR/ca-cert.pem"
        podman_args+=(
            --env "HTTP_PROXY=http://host.containers.internal:3129"
            --env "HTTPS_PROXY=http://host.containers.internal:3129"
            --env "http_proxy=http://host.containers.internal:3129"
            --env "https_proxy=http://host.containers.internal:3129"
            --env "CARGO_HTTP_PROXY=http://host.containers.internal:3129"
            --env "CARGO_HTTP_CAINFO=/tmp/tillandsias-ca.crt"
            -v "$ca_cert:/tmp/tillandsias-ca.crt:ro,Z"
        )
    fi

    podman run "${podman_args[@]}" \
        ubuntu:22.04 \
        bash -euo pipefail -c '
set -euo pipefail

# ── Certificate Authority injection ──────────────────────────
# @trace spec:transparent-https-caching
if [ -f /tmp/tillandsias-ca.crt ]; then
    mkdir -p /usr/local/share/ca-certificates
    cp /tmp/tillandsias-ca.crt /usr/local/share/ca-certificates/tillandsias.crt
    update-ca-certificates --fresh 2>/dev/null || true
fi

# System deps — apt cache and lists are persistent across builds (RW mounts)
# apt-get update will be skipped if real package metadata exists and is recent
echo "[appimage] Installing system dependencies..."
should_update=true
# Check for actual package metadata files (not just empty directory)
if [[ -f /var/lib/apt/lists/lock ]] && [[ -n "$(find /var/lib/apt/lists -name '*.gz' -o -name 'Release' 2>/dev/null | head -1)" ]]; then
    # Real package metadata exists — check age of lock file
    lock_mtime="$(stat -c %Y /var/lib/apt/lists/lock 2>/dev/null || echo 0)"
    current_time="$(date +%s)"
    age_seconds=$((current_time - lock_mtime))
    if [[ $age_seconds -lt 86400 ]]; then
        echo "[appimage] Apt lists cached ($(( age_seconds / 3600 ))h old) — skipping update"
        should_update=false
    else
        echo "[appimage] Apt lists stale (>24h) — refreshing"
    fi
else
    echo "[appimage] No cached apt lists found — will update"
fi
if [[ "$should_update" == "true" ]]; then
    echo "[appimage] Running apt-get update (this may take 30-60s)..."
    timeout 120 apt-get update -qq || apt-get update  # Retry without -qq, with timeout
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libappindicator3-dev \
    librsvg2-dev \
    libssl-dev \
    fuse \
    libfuse2 \
    curl \
    file \
    ca-certificates \
    2>&1 | tail -3

# Rust — skip install if rustup already cached
if [[ -f /root/.cargo/bin/rustup ]]; then
    echo "[appimage] Rust toolchain cached — skipping install"
    export PATH="/root/.cargo/bin:$PATH"
else
    echo "[appimage] Installing Rust toolchain..."
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    export PATH="/root/.cargo/bin:$PATH"
fi

# tauri-cli — skip if already installed
if command -v cargo-tauri &>/dev/null; then
    echo "[appimage] tauri-cli cached — skipping install"
else
    echo "[appimage] Installing tauri-cli..."
    cargo install tauri-cli --version "^2" --locked 2>&1 | tail -3
fi

echo "[appimage] Copying source to writable build directory..."
cp -r /src /build
cd /build

echo "[appimage] Running cargo tauri build (AppImage target)..."
# APPIMAGE_EXTRACT_AND_RUN lets linuxdeploy (itself an AppImage) extract
# to a temp dir instead of requiring FUSE mount — critical for containers.
export APPIMAGE_EXTRACT_AND_RUN=1
# Prefer IPv4 — IPv6 connections to raw.githubusercontent.com hang in containers
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
# Allow non-zero exit — signing key is only available in CI, the AppImage
# itself is produced before the signing step fails.
cargo tauri build --bundles appimage 2>&1 || true

echo "[appimage] Locating AppImage artifact..."
appimage_file="$(find /build/target/release/bundle/appimage -name "*.AppImage" -type f 2>/dev/null | head -1)"
if [[ -z "$appimage_file" ]]; then
    echo "[appimage] ERROR: No AppImage found in target/release/bundle/appimage/" >&2
    exit 1
fi

echo "[appimage] Copying $(basename "$appimage_file") to output mount..."
rm -f /output/*.AppImage 2>/dev/null || true
cp "$appimage_file" /output/
echo "[appimage] Done: /output/$(basename "$appimage_file")"
' &
    container_pid=$!

    # Wait for container, properly handling signals
    wait "$container_pid"
    local build_status=$?

    # Clean up trap
    trap - INT TERM

    if [[ $build_status -ne 0 ]]; then
        _error "AppImage build failed with status $build_status"
        return $build_status
    fi

    # Find the produced AppImage and report it
    local appimage_path
    appimage_path="$(find "$output_dir" -name "*.AppImage" -type f 2>/dev/null | head -1)"
    if [[ -z "$appimage_path" ]]; then
        _error "AppImage build failed — no .AppImage found in $output_dir"
        exit 1
    fi

    chmod +x "$appimage_path"
    _info "AppImage ready: $appimage_path ($(du -h "$appimage_path" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Install AppImage — same layout as the curl installer
# ---------------------------------------------------------------------------

# @trace spec:dev-build
install_appimage() {
    _step "Building AppImage for install..."
    build_appimage

    # Locate the built AppImage
    local appimage_output_dir="$SCRIPT_DIR/target/release/bundle/appimage"
    local appimage_src
    appimage_src="$(find "$appimage_output_dir" -name "*.AppImage" -type f 2>/dev/null | head -1)"
    if [[ -z "$appimage_src" ]]; then
        _error "AppImage build failed — no .AppImage found"
        return 1
    fi

    # Install to ~/Applications/ (same location as curl installer and self-updater)
    local app_dir="$ACTUAL_HOME/Applications"
    local app_path="$app_dir/Tillandsias.AppImage"
    mkdir -p "$app_dir"
    cp "$appimage_src" "$app_path"
    chmod +x "$app_path"
    _info "AppImage installed: $app_path ($(du -h "$app_path" | cut -f1))"

    # Create symlink in ~/.local/bin/ for CLI access
    mkdir -p "$INSTALL_DIR"
    ln -sf "$app_path" "$INSTALL_BIN"
    _info "Symlink: $INSTALL_BIN -> $app_path"

    # Build the forge container image with versioned tag (handles staleness detection)
    if [[ -x "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
        local full_version
        full_version="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
        _step "Building forge container image..."
        if ! "$SCRIPT_DIR/scripts/build-image.sh" forge --tag "tillandsias-forge:v${full_version}"; then
            _error "ERROR: forge image build failed — install aborted"
            return 1
        fi
        _info "Forge image built and loaded"
    else
        _warn "scripts/build-image.sh not found, skipping image build"
    fi

    _info "[build] SUCCESS: tillandsias installed and forge image ready"
    _info "Installed. Run 'tillandsias' or launch from your desktop."
    _info "Desktop integration (icons, launcher) is set up on first run."
}

# ---------------------------------------------------------------------------
# Toolbox management
# ---------------------------------------------------------------------------

_toolbox_exists() {
    toolbox list --containers 2>/dev/null | grep -q "^[[:space:]]*[a-f0-9].*${TOOLBOX_NAME}\b"
}

_toolbox_ensure() {
    if _toolbox_exists; then
        return 0
    fi

    _step "Creating toolbox '${TOOLBOX_NAME}'..."
    toolbox create --assumeyes "$TOOLBOX_NAME" 2>&1

    _step "Installing build dependencies..."
    # podman-compose is included so tests under crates/tillandsias-compose/
    # can shell out to it. The tray itself runs on the host and needs a
    # host-side podman-compose (>= 1.5.0) — see preflight.rs and the
    # `rpm-ostree install podman-compose` note in the project README.
    # @trace spec:enclave-compose-migration
    toolbox run -c "$TOOLBOX_NAME" sudo dnf install -y \
        gcc \
        gtk3-devel \
        webkit2gtk4.1-devel \
        libappindicator-gtk3-devel \
        librsvg2-devel \
        openssl-devel \
        pkg-config \
        patchelf \
        podman-compose \
        2>&1 | tail -3

    _info "Toolbox '${TOOLBOX_NAME}' ready"
}

_toolbox_ensure_tauri_cli() {
    if toolbox run -c "$TOOLBOX_NAME" cargo tauri --version &>/dev/null; then
        return 0
    fi

    _step "Installing tauri-cli (first time, may take a minute)..."
    toolbox run -c "$TOOLBOX_NAME" cargo install tauri-cli --version "^2" 2>&1 | tail -3
    _info "tauri-cli installed"
}

_run() {
    toolbox run -c "$TOOLBOX_NAME" "$@"
}

# Toolbox reset
if [[ "$FLAG_TOOLBOX_RESET" == true ]]; then
    _step "Resetting toolbox '${TOOLBOX_NAME}'..."
    if _toolbox_exists; then
        toolbox rm -f "$TOOLBOX_NAME" 2>&1
        _info "Removed existing toolbox"
    fi
    _toolbox_ensure
    # If --toolbox-reset is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_APPIMAGE$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# AppImage build (standalone — bypasses toolbox entirely)
if [[ "$FLAG_APPIMAGE" == true ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    build_appimage
    # If --appimage is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Install (builds AppImage via podman, then installs to ~/Applications/)
if [[ "$FLAG_INSTALL" == true ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true
    if ! install_appimage; then
        _error "[build] ERROR: install failed — check output above for which step failed"
        exit 1
    fi
    exit 0
fi

# Ensure toolbox exists for any build operation
_toolbox_ensure

# ---------------------------------------------------------------------------
# Auto-increment build number on every build (not test/check/clean-only)
# ---------------------------------------------------------------------------
if [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Build operations
# ---------------------------------------------------------------------------

# Clean
if [[ "$FLAG_CLEAN" == true ]]; then
    _step "Cleaning build artifacts..."
    _run cargo clean --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Clean complete"
fi

# Test
if [[ "$FLAG_TEST" == true ]]; then
    # Static lints on the Compose YAMLs + per-service spec READMEs run on
    # the host (no toolbox dependency). They are cheap and fail fast.
    # @trace spec:enclave-compose-migration
    _step "Linting compose.yaml + overlays..."
    bash "$SCRIPT_DIR/scripts/lint-compose.sh"
    _info "compose lint passed"

    _step "Checking per-service spec READMEs..."
    bash "$SCRIPT_DIR/scripts/check-containerfile-docs.sh"
    _info "spec READMEs passed"

    _step "Running tests..."
    _run cargo test --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Tests complete"
fi

# Check
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Type-checking workspace..."
    _run cargo check --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Check complete"
fi

# Release build (via tauri)
if [[ "$FLAG_RELEASE" == true ]]; then
    # Always run CI checks before release — fail if any check doesn't pass
    # (Cloud minutes are expensive; validate locally first)
    _step "Running CI/CD validation before release..."
    if ! bash "$SCRIPT_DIR/scripts/local-ci.sh" --fast; then
        _error "CI/CD validation failed — fix issues before retrying"
        exit 1
    fi
    _info "CI/CD validation passed — proceeding with release build"

    _toolbox_ensure_tauri_cli

    # Skip AppImage in toolbox — linuxdeploy needs FUSE which isn't available.
    # AppImage bundling works in CI (ubuntu with FUSE) and via --appimage.
    # Linux only distributes via AppImage; no deb/rpm bundles.
    BUNDLES=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        BUNDLES="dmg"
    fi

    _step "Building release (bundles: ${BUNDLES})..."

    # Clean old bundles to avoid listing stale versions
    rm -rf "$SCRIPT_DIR/target/release/bundle"

    # Single build: --bundles skips AppImage (needs FUSE, CI handles it).
    # The updater error is expected in toolbox — ignore it.
    tauri_build="cd '$SCRIPT_DIR' && cargo tauri build"
    if [[ -n "$BUNDLES" ]]; then
        tauri_build="$tauri_build --bundles $BUNDLES"
    fi
    _run bash -c "$tauri_build" 2>&1 || {
        # Check if the binary was built despite the bundle error
        if [[ -f "$SCRIPT_DIR/target/release/tillandsias" ]]; then
            _warn "Some bundles failed (updater needs AppImage — CI handles that)"
        else
            _error "Build failed"
            exit 1
        fi
    }
    _info "Release build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias"
    BUNDLE_DIR="$SCRIPT_DIR/target/release/bundle"
    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias ($(du -h "$RELEASE_BIN" | cut -f1))"
    fi
    if [[ -d "$BUNDLE_DIR" ]]; then
        find "$BUNDLE_DIR" -type f \( -name "*.AppImage" -o -name "*.dmg" -o -name "*.exe" -o -name "*.msi" \) 2>/dev/null | while read -r f; do
            _info "Bundle: $(basename "$f") ($(du -h "$f" | cut -f1))"
        done
    fi

    # Note: --install is handled as a standalone operation above (before
    # toolbox setup), using build_appimage() + install_appimage().

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true
fi
