#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Development Build Script
#
# Single entry point for the entire dev lifecycle. Runs everything inside
# the `tillandsias` toolbox, creating it automatically if needed.
#
# @tombstone superseded:linux-native-portable-executable
# Tauri WebKit wrapper and AppImage bundling removed 2026-05-05.
# Replaced with native headless launcher and future platform-native tray wrappers.
# Kept through release 0.1.271 (three releases) for traceability.
#
# Usage:
#   ./build.sh                      # Debug build (musl binary)
#   ./build.sh --release            # Release build (musl binary, optimized)
#   ./build.sh --test               # Run tests
#   ./build.sh --check              # Type-check only
#   ./build.sh --clean              # Clean before building
#   ./build.sh --install            # Build + install binary to ~/.local/bin/
#   ./build.sh --remove             # Remove installed binary and symlink
#   ./build.sh --wipe               # Remove target/, caches, temp files
#   ./build.sh --toolbox-reset      # Destroy and recreate toolbox
#   ./build.sh --clean --release    # Flags combine
# =============================================================================

set -euo pipefail

# @trace spec:linux-native-portable-executable, spec:dev-build, spec:build-script-architecture, spec:windows-cross-build

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
        --init)           FLAG_INIT=true ;;
        --ci)             FLAG_CI=true ;;
        --ci-full)        FLAG_CI_FULL=true ;;
        --help|-h)
            cat <<'EOF'
Tillandsias Development Build Script

Usage: ./build.sh [flags]

Build flags:
  (none)            Debug build (cargo build --workspace)
  --release         Release build (native launcher, optimized)
  --test            Run test suite (cargo test --workspace)
  --check           Type-check only (cargo check --workspace)
  --clean           Clean build artifacts before building
  --ci              Run local CI/CD validation (quick: spec binding, drift, version, fmt, clippy, tests)
  --ci-full         Run full CI/CD validation (includes litmus tests — required for releases)

Install flags:
  --install         Build release + install binary to ~/.local/bin/

Maintenance flags:
  --wipe            Remove target/, ~/.cache/tillandsias/, temp files
  --toolbox-reset   Destroy and recreate the tillandsias toolbox
  --init            Build all container images with versioned tags (runs on host)
  --help            Show this message

Flags combine: ./build.sh --clean --release --install

The tillandsias toolbox is auto-created on first run with all
build dependencies. No manual setup needed.
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

    # Use standard squid image for dev proxy (not tillandsias-proxy, which may be under build)
    # @trace spec:proxy-container, spec:default-image
    local proxy_image="docker.io/library/squid:6.1"

    _step "Using standard squid image for dev caching: $proxy_image"

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

    # Export proxy env vars for toolbox
    export HTTP_PROXY="http://127.0.0.1:3129"
    export HTTPS_PROXY="http://127.0.0.1:3129"
    export http_proxy="http://127.0.0.1:3129"
    export https_proxy="http://127.0.0.1:3129"
    export CARGO_HTTP_PROXY="http://127.0.0.1:3129"
    export CARGO_HTTP_CAINFO="$ca_cert"

    _info "Dev proxy active: $HTTP_PROXY"
}

# Setup podman registries configuration ONLY for dev builds, not portable installs
# Portable binaries must not depend on host configuration (@trace spec:portable-linux-executable)
# @trace spec:podman-registries-config
if [[ "$FLAG_INSTALL" != true ]]; then
    "$SCRIPT_DIR/scripts/setup-podman-registries.sh" || {
        _warn "Failed to setup podman registries (non-fatal, build may continue)"
    }
else
    _info "Skipping registries config for portable install (binary is self-contained)"
fi

# Dev cache (squid proxy) is optional and skipped for portable installs
# @trace spec:dev-build
if [[ "$FLAG_INSTALL" != true ]]; then
    ensure_dev_cache
else
    _info "Skipping dev cache for portable install"
fi

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
        if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_TOOLBOX_RESET$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
            exit 0
        fi
    else
        _error "CI/CD validation failed — fix issues and retry"
        exit 1
    fi
fi

if [[ "$FLAG_REMOVE" == true ]]; then
    # Remove binary symlink
    rm -f "$INSTALL_BIN"
    _info "Removed $INSTALL_BIN"
    # If --remove is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_TOOLBOX_RESET$FLAG_CI$FLAG_CI_FULL" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Wipe cache and target directories
if [[ "$FLAG_WIPE" == true ]]; then
    _step "Wiping build artifacts and caches..."
    rm -rf \
        "$SCRIPT_DIR/target" \
        "$SCRIPT_DIR/target-musl" \
        "$SCRIPT_DIR/.nix-output" \
        "$CACHE_DIR" \
        "$ACTUAL_HOME/.cache/tillandsias/build-hashes" \
        "$ACTUAL_HOME/.cache/tillandsias/packages" \
        /tmp/tillandsias-* \
        2>/dev/null || true
    _info "Wipe complete"
    # If --wipe is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_TOOLBOX_RESET$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Clean before building
if [[ "$FLAG_CLEAN" == true ]]; then
    _step "Cleaning build artifacts..."
    rm -rf "$SCRIPT_DIR/target" "$SCRIPT_DIR/target-musl" "$SCRIPT_DIR/.nix-output"
    _info "Build artifacts cleaned"
fi

# ---------------------------------------------------------------------------
# Toolbox management
# ---------------------------------------------------------------------------

_toolbox_exists() {
    toolbox list --containers 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -Fxq "$TOOLBOX_NAME"
}

_toolbox_ensure() {
    if _toolbox_exists; then
        return 0
    fi

    _step "Creating toolbox '${TOOLBOX_NAME}'..."
    _warn "First-time setup creates the toolbox container (~30 seconds)"

    if ! toolbox create -c "$TOOLBOX_NAME" 2>&1 | tail -5; then
        _error "Failed to create toolbox"
        exit 1
    fi
    _info "Toolbox created"
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
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Install binary — build release and copy to ~/.local/bin/
# ---------------------------------------------------------------------------

if [[ "$FLAG_INSTALL" == true ]]; then
    _step "Building portable headless launcher (musl-static) for install..."
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true

    _toolbox_ensure
    _run cargo build --workspace --release --target x86_64-unknown-linux-musl --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1

    # Validate musl-static headless launcher
    RELEASE_BIN="$SCRIPT_DIR/target/x86_64-unknown-linux-musl/release/tillandsias"
    if [[ ! -f "$RELEASE_BIN" ]]; then
        _error "Portable headless launcher not found at $RELEASE_BIN"
        exit 1
    fi

    _step "Validating portable headless launcher..."
    # Test 1: Verify musl-static launcher (no external libc dependency)
    if file "$RELEASE_BIN" | grep -q "statically linked"; then
        _info "✓ Headless launcher is musl-static (portable)"
    else
        _error "✗ Binary is NOT statically linked (has glibc dependency)"
        exit 1
    fi

    # Test 2: Verify headless mode starts
    HEADLESS_OUTPUT="$(timeout 5 "$RELEASE_BIN" --headless /tmp/test-install-validation 2>&1 || true)"
    if grep -q '"event":"app.started"' <<<"$HEADLESS_OUTPUT" && grep -q '"event":"app.stopped"' <<<"$HEADLESS_OUTPUT"; then
        _info "✓ Headless mode works"
    else
        _error "✗ Headless mode failed to start"
        exit 1
    fi

    # Copy binary to install location
    mkdir -p "$INSTALL_DIR"
    cp "$RELEASE_BIN" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    _info "Portable headless launcher installed: $INSTALL_BIN ($(du -h "$INSTALL_BIN" | cut -f1))"
    _info "Launcher is self-contained; native tray/wrapper surfaces may use platform libraries"

    # If --install is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Ensure toolbox exists before running cargo commands
_toolbox_ensure

# Test build
if [[ "$FLAG_TEST" == true ]]; then
    _step "Running tests..."
    _run cargo test --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Tests passed"

    # Prune dangling images accumulated during the test
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # If --test is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Type-check only
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Type-checking workspace..."
    _run cargo check --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Type-check passed"

    # If --check is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Release build
if [[ "$FLAG_RELEASE" == true ]]; then
    if ! bash "$SCRIPT_DIR/scripts/local-ci.sh" --fast; then
        _error "CI/CD validation failed — fix issues before releasing"
        exit 1
    fi
    _info "CI/CD validation passed — proceeding with release build"

    _step "Building release (native launcher)..."

    # Clean old binaries to avoid confusion
    rm -rf "$SCRIPT_DIR/target/release/tillandsias"

    # Build optimized release binary
    _run cargo build --workspace --release --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Release build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias"
    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias ($(du -h "$RELEASE_BIN" | cut -f1))"
    fi

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true
fi
