#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Development Build Script
#
# Single entry point for the entire dev lifecycle. Runs builds directly on the
# host workstation.
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
#   ./build.sh --clean --release    # Flags combine
# =============================================================================

set -euo pipefail
export TILLANDSIAS_NO_SINGLETON=1

# On Fedora Silverblue (immutable), transparently re-exec inside the
# tillandsias-builder toolbox where Rust/gcc/ruby/etc are available.
# Non-Silverblue hosts skip with zero overhead.
_BUILDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_BUILDER_DIR/scripts/with-tillandsias-builder.sh"
unset _BUILDER_DIR

# @trace spec:linux-native-portable-executable, spec:dev-build, spec:build-script-architecture, spec:windows-cross-build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer a rustup-managed toolchain when present so optional targets such as
# x86_64-unknown-linux-musl are visible to host-native builds.
if [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

if [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-}" ]]; then
    _build_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    _build_remote_socket="${_build_runtime_dir}/podman/podman.sock"
    if [[ -S "$_build_remote_socket" ]]; then
        export TILLANDSIAS_PODMAN_REMOTE_URL="unix://${_build_remote_socket}"
    fi
fi

source "$SCRIPT_DIR/scripts/common.sh"

# Get the actual user's home directory (works with sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    ACTUAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    ACTUAL_HOME="$HOME"
fi

INSTALL_DIR="$ACTUAL_HOME/.local/bin"
INSTALL_BIN="$INSTALL_DIR/tillandsias"
CACHE_DIR="$ACTUAL_HOME/.cache/tillandsias"

# NOTE: no unconditional `require_podman` gate here. Sourcing common.sh
# above already primed the Podman wrapper selection/generation (needed on
# immutable hosts where the default runtime dir is read-only); that setup
# is independent of whether Podman is actually reachable right now. Most
# flags below (--check, --test, plain debug builds, --install alone,
# --clean/--wipe/--remove) never touch Podman at all — every Podman call in
# this script already degrades gracefully (warn + continue) except the
# explicit guard before --init, and --ci/--ci-full/--release already
# self-guard via scripts/local-ci.sh's own require_podman calls at the
# specific points that need it. A blanket gate here would hard-block those
# Podman-independent flags on any host with a stopped/misconfigured Podman
# daemon for no reason. See
# plan/issues/build-sh-unconditional-podman-gate-2026-07-07.md.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { [[ "${FLAG_GRAPHS:-false}" == true ]] || echo -e "${GREEN}[build]${NC} $*"; }
_warn()  { [[ "${FLAG_GRAPHS:-false}" == true ]] || echo -e "${YELLOW}[build]${NC} $*"; }
_error() { echo -e "${RED}[build]${NC} $*" >&2; }
_step()  { [[ "${FLAG_GRAPHS:-false}" == true ]] || echo -e "${CYAN}[build]${NC} $*"; }

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
FLAG_INIT=false
FLAG_CI=false
FLAG_CI_FULL=false
FLAG_GRAPHS=false
FLAG_STRICT_ALL=false
FLAG_SPEC=false
CI_FILTER_SPEC_LIST=""
CI_STRICT_SPEC_LIST=""
CI_IGNORE_SPEC_LIST=""
CI_SPEC_LIST=""
CI_ARG_LIST=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        FLAG_RELEASE=true ;;
        --test)           FLAG_TEST=true ;;
        --check)          FLAG_CHECK=true ;;
        --clean)          FLAG_CLEAN=true ;;
        --install)        FLAG_INSTALL=true ;;
        --remove)         FLAG_REMOVE=true ;;
        --wipe)           FLAG_WIPE=true ;;
        --init)           FLAG_INIT=true ;;
        --ci)             FLAG_CI=true ;;
        --ci-full)        FLAG_CI_FULL=true ;;
        --graphs)         FLAG_GRAPHS=true ;;
        --strict-all)     FLAG_STRICT_ALL=true ;;
        --observatorium)
            FLAG_OBSERVATORIUM=true
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                OBSERVATORIUM_PROJECT="${2}"
                shift 2
            else
                OBSERVATORIUM_PROJECT="."
                shift
            fi
            continue
            ;;
        --spec)
            FLAG_SPEC=true
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_SPEC_LIST="${2}"
                shift 2
            else
                CI_SPEC_LIST=""
                shift
            fi
            continue
            ;;
        --spec=*)
            FLAG_SPEC=true
            CI_SPEC_LIST="${1#*=}"
            shift
            continue
            ;;
        --filter)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_FILTER_SPEC_LIST="${2}"
                shift 2
            else
                CI_FILTER_SPEC_LIST=""
                shift
            fi
            continue
            ;;
        --filter=*)
            CI_FILTER_SPEC_LIST="${1#*=}"
            shift
            continue
            ;;
        --strict)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_STRICT_SPEC_LIST="${2}"
                shift 2
            else
                CI_STRICT_SPEC_LIST=""
                shift
            fi
            continue
            ;;
        --strict=*)
            CI_STRICT_SPEC_LIST="${1#*=}"
            shift
            continue
            ;;
        --ignore)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                CI_IGNORE_SPEC_LIST="${2}"
                shift 2
            else
                CI_IGNORE_SPEC_LIST=""
                shift
            fi
            continue
            ;;
        --ignore=*)
            CI_IGNORE_SPEC_LIST="${1#*=}"
            shift
            continue
            ;;
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
  --ci-full         Run phased CI/CD validation (pre-build gate, post-build smoke, runtime residual litmus)
  --graphs          Prefer graph-summary output for ci-full runs
  --strict-all      Run CI phases in strict mode across the full active spec set
  --spec SPEC       Convenience shorthand for a scoped spec ladder (fills filter+strict when omitted)
  --filter SPECLIST  Limit litmus execution to colon/comma-separated spec IDs
  --strict SPECLIST  Fail fast on the selected specs (or the filtered specs if omitted)
  --ignore SPECLIST  Exclude colon/comma-separated spec IDs from strict-all frontier scans

Install flags:
  --install         Build release + install binary to ~/.local/bin/

Maintenance flags:
  --wipe            Remove target/, ~/.cache/tillandsias/, temp files
  --init            Build all container images with versioned tags (runs on host)
  --help            Show this message

Flags combine: ./build.sh --clean --release --install

Rust builds run directly on the host workstation. No Toolbox or Nix build layer
is used by this script.
EOF
            exit 0
            ;;
        *) _error "Unknown flag: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

if [[ -n "$CI_SPEC_LIST" ]]; then
    if [[ -z "$CI_FILTER_SPEC_LIST" ]]; then
        CI_FILTER_SPEC_LIST="$CI_SPEC_LIST"
    fi
    if [[ -z "$CI_STRICT_SPEC_LIST" ]]; then
        CI_STRICT_SPEC_LIST="$CI_SPEC_LIST"
    fi
fi

_forge_check_only_without_host_podman_setup() {
    [[ "${TILLANDSIAS_HOST_KIND:-}" == "forge" ]] || return 1
    [[ "$FLAG_CHECK" == true ]] || return 1
    [[ "$FLAG_RELEASE" == false ]] || return 1
    [[ "$FLAG_TEST" == false ]] || return 1
    [[ "$FLAG_INSTALL" == false ]] || return 1
    [[ "$FLAG_INIT" == false ]] || return 1
    [[ "$FLAG_CI" == false ]] || return 1
    [[ "$FLAG_CI_FULL" == false ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Transparent HTTPS caching setup (dev proxy)
# ---------------------------------------------------------------------------
# @trace spec:dev-build, spec:transparent-https-caching
PODMAN_CTL="$SCRIPT_DIR/scripts/tillandsias-podman"
ensure_dev_cache() {
    # Skip if explicitly disabled
    [[ "${TILLANDSIAS_NO_PROXY:-}" == "1" ]] && return 0

    # Ensure CA cert exists
    local ca_cert="$CACHE_DIR/ca-cert.pem"
    local ca_key="$CACHE_DIR/ca-key.pem"
    if [[ ! -f "$ca_cert" || ! -f "$ca_key" ]]; then
        mkdir -p "$CACHE_DIR"
        local ca_lock="$CACHE_DIR/ca-generation.lock"
        local lock_acquired=false
        for _ in {1..50}; do
            if mkdir "$ca_lock" 2>/dev/null; then
                lock_acquired=true
                break
            fi
            sleep 0.1
        done
        if [[ "$lock_acquired" != true ]]; then
            _warn "Timed out waiting for dev proxy CA generation lock"
            return 0
        fi
        trap 'rmdir "$ca_lock" 2>/dev/null || true' RETURN
        if [[ ! -f "$ca_cert" || ! -f "$ca_key" ]]; then
            local tmp_cert tmp_key
            tmp_cert="$(mktemp "$CACHE_DIR/ca-cert.XXXXXX")"
            tmp_key="$(mktemp "$CACHE_DIR/ca-key.XXXXXX")"
            if openssl req -x509 -newkey rsa:2048 -keyout "$tmp_key" -out "$tmp_cert" \
                -days 3650 -nodes -subj "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA" 2>/dev/null; then
                chmod 600 "$tmp_key" 2>/dev/null || true
                chmod 644 "$tmp_cert" 2>/dev/null || true
                mv -f "$tmp_key" "$ca_key"
                mv -f "$tmp_cert" "$ca_cert"
            else
                rm -f "$tmp_cert" "$tmp_key"
                _warn "Failed to generate CA cert for dev proxy"
                return 0
            fi
        fi
        rmdir "$ca_lock" 2>/dev/null || true
        trap - RETURN
    fi

    # Ensure dev proxy cache dir exists
    mkdir -p "$CACHE_DIR/dev-proxy-cache"

    # Use standard squid image for dev proxy (not tillandsias-proxy, which may be under build)
    # @trace spec:proxy-container, spec:default-image
    local proxy_image="docker.io/library/squid:6.1"

    _step "Using standard squid image for dev caching: $proxy_image"

    # Start dev proxy if not already running
    if ! "$PODMAN_CTL" container inspect tillandsias-dev-proxy &>/dev/null 2>&1; then
        _step "Starting dev proxy container..."

        # Start proxy with all interface binding so containers can reach it
        if ! "$PODMAN_CTL" container run \
            --detach \
            --rm \
            --name tillandsias-dev-proxy \
            --publish "3129:3129" \
            --userns=keep-id \
            --volume "$CACHE_DIR/dev-proxy-cache:/var/spool/squid:rw,Z" \
            --volume "$ca_cert:/etc/squid/certs/intermediate.crt:ro,Z" \
            --volume "$ca_key:/etc/squid/certs/intermediate.key:ro,Z" \
            "$proxy_image" >/dev/null 2>&1; then
            _info "Dev proxy unavailable (container builds will be uncached — normal in CI/VMs)"
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
                "$PODMAN_CTL" container logs tillandsias-dev-proxy 20 2>&1 | tail -20
                "$PODMAN_CTL" container rm tillandsias-dev-proxy 2>/dev/null || true
                return 0
            fi
            sleep 1
        done
    fi

    # Export proxy env vars for host-side build tooling
    export HTTP_PROXY="http://127.0.0.1:3129"
    export HTTPS_PROXY="http://127.0.0.1:3129"
    export http_proxy="http://127.0.0.1:3129"
    export https_proxy="http://127.0.0.1:3129"
    export CARGO_HTTP_PROXY="http://127.0.0.1:3129"
    export CARGO_HTTP_CAINFO="$ca_cert"

    _info "Dev proxy active: $HTTP_PROXY"
}

# Setup podman registries configuration ONLY for dev builds, not portable installs
# Portable binaries must not depend on host configuration (@trace spec:linux-native-portable-executable)
# @trace spec:podman-registries-config
if _forge_check_only_without_host_podman_setup; then
    _info "Skipping host Podman registry setup for forge check-only build"
elif [[ "$FLAG_INSTALL" != true ]]; then
    "$SCRIPT_DIR/scripts/setup-podman-registries.sh" || {
        _warn "Failed to setup podman registries (non-fatal, build may continue)"
    }
else
    _info "Skipping registries config for portable install (binary is self-contained)"
fi

# Dev cache (squid proxy) is optional and skipped for portable installs
# @trace spec:dev-build
if _forge_check_only_without_host_podman_setup; then
    _info "Skipping host dev cache setup for forge check-only build"
elif [[ "$FLAG_INSTALL" != true ]]; then
    ensure_dev_cache
else
    _info "Skipping dev cache for portable install"
fi

# ---------------------------------------------------------------------------
# Standalone operations
# ---------------------------------------------------------------------------

if [[ "$FLAG_INIT" == true ]]; then
    # The only build.sh flag with a genuine, unconditional Podman need
    # (it builds every container image). Fail fast with a clear message
    # here rather than a possibly-confusing downstream Rust error.
    require_podman || exit 1
    _step "Running tillandsias --init (builds all images with versioned tags)..."
    # Runs on the host where podman works.
    "$SCRIPT_DIR/target/debug/tillandsias" --init 2>&1
    # Also prune old images
    _step "Pruning old images..."
    "$PODMAN_CTL" image prune -f 2>/dev/null || true
    exit 0
fi

if [[ "${FLAG_OBSERVATORIUM:-false}" == true ]]; then
    _step "Building workspace (debug)..."
    _require_host_build_tools
    (cd "$SCRIPT_DIR" && cargo build --workspace)
    _step "Running tillandsias --observatorium ${OBSERVATORIUM_PROJECT}..."
    "$SCRIPT_DIR/target/debug/tillandsias" --observatorium "$OBSERVATORIUM_PROJECT"
    exit 0
fi

if [[ "$FLAG_REMOVE" == true ]]; then
    # Remove binary symlink
    rm -f "$INSTALL_BIN"
    _info "Removed $INSTALL_BIN"
    # If --remove is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_CI$FLAG_CI_FULL" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
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
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
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
# Host build execution
# ---------------------------------------------------------------------------

_require_host_build_tools() {
    local missing=()
    local tool
    for tool in cargo rustc rustfmt clippy-driver gcc pkg-config; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if [[ "$FLAG_INSTALL" == true ]] && ! command -v file >/dev/null 2>&1; then
        missing+=(file)
    fi
    if [[ "${#missing[@]}" -gt 0 ]]; then
        _error "Missing host build tools: ${missing[*]}"
        _error "Install the Fedora build dependencies, then rerun this command."
        exit 1
    fi

    if [[ "$FLAG_INSTALL" == true ]]; then
        if ! command -v rustup >/dev/null 2>&1; then
            _error "Portable installs require a rustup-managed toolchain with the musl target."
            _error "Install rustup, initialize it, then add x86_64-unknown-linux-musl."
            exit 1
        fi
        if ! rustup target list --installed | grep -qx 'x86_64-unknown-linux-musl'; then
            _error "Missing Rust target: x86_64-unknown-linux-musl"
            _error "Run: rustup target add x86_64-unknown-linux-musl"
            exit 1
        fi
    fi
}

_run() {
    _require_host_build_tools
    (cd "$SCRIPT_DIR" && "$@")
}

_run_litmus_phase() {
    local phase="$1"
    local size="$2"
    local log_file="$3"
    shift 3
    local -a phase_args=()
    local arg
    for arg in "${CI_ARG_LIST[@]}"; do
        # run-litmus-test runs the full selected phase by default; strict-all is
        # a local-ci frontier-expansion flag and is not part of its CLI.
        [[ "$arg" == "--strict-all" ]] || phase_args+=("$arg")
    done

    bash "$SCRIPT_DIR/scripts/run-litmus-test.sh" \
        --phase "$phase" \
        --size "$size" \
        --compact \
        "${phase_args[@]}" \
        "$@" 2>&1 | tee "$log_file"
}

_run_local_ci_gate() {
    local -a command=(bash "$SCRIPT_DIR/scripts/local-ci.sh" "$@")
    if [[ "$FLAG_GRAPHS" == true ]]; then
        "${command[@]}" >/tmp/tillandsias-ci-graphs.log 2>&1
    else
        "${command[@]}"
    fi
}

_prepare_ci_full_install_inputs() {
    [[ "$FLAG_CI_FULL" == true ]] || return 0
    [[ "$FLAG_INSTALL" == true ]] || return 0

    _step "Preparing version and staged guest binaries for full install CI..."
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true

    if [[ ! -x "$SCRIPT_DIR/scripts/build-guest-binaries.sh" ]]; then
        _error "Missing executable guest binary builder: scripts/build-guest-binaries.sh"
        exit 1
    fi

    "$SCRIPT_DIR/scripts/build-guest-binaries.sh"
}

# CI validation
if [[ "$FLAG_CI" == true ]] || [[ "$FLAG_CI_FULL" == true ]]; then
    CI_ARG_LIST=()
    if [[ -n "$CI_IGNORE_SPEC_LIST" ]]; then
        CI_ARG_LIST+=(--ignore "$CI_IGNORE_SPEC_LIST")
    fi
    if [[ -n "$CI_FILTER_SPEC_LIST" ]]; then
        CI_ARG_LIST+=(--filter "$CI_FILTER_SPEC_LIST")
    fi
    if [[ -n "$CI_STRICT_SPEC_LIST" ]]; then
        CI_ARG_LIST+=(--strict "$CI_STRICT_SPEC_LIST")
    fi
    if [[ "$FLAG_STRICT_ALL" == true ]]; then
        CI_ARG_LIST+=(--strict-all)
    fi
    if [[ "$FLAG_CI_FULL" == true ]]; then
        _step "Running full CI/CD validation (pre-build gate)..."
        _prepare_ci_full_install_inputs
        CI_ARGS=(--phase pre-build)
    else
        _step "Running quick CI/CD validation (pre-build gate, fast mode)..."
        CI_ARGS=(--phase pre-build --fast)
    fi

    if _run_local_ci_gate "${CI_ARGS[@]}" "${CI_ARG_LIST[@]}"; then
        :
    else
        if [[ "$FLAG_GRAPHS" == true ]]; then
            cat /tmp/tillandsias-ci-graphs.log >&2 || true
        fi
        _error "CI/CD validation failed — fix issues and retry"
        exit 1
    fi
    if [[ "$FLAG_CI_FULL" == true ]]; then
        _info "Pre-build CI/CD validation passed — continuing to install"
    else
        _info "Quick CI/CD validation passed — ready for development"
    fi
    # If --ci is the only flag, exit with success
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalse" ]]; then
        if [[ "$FLAG_GRAPHS" == true ]]; then
            "$SCRIPT_DIR/scripts/update-convergence-dashboard.sh" >/dev/null 2>&1 || true
            if [[ -f "$SCRIPT_DIR/docs/convergence/centicolon-dashboard.md" ]]; then
                cat "$SCRIPT_DIR/docs/convergence/centicolon-dashboard.md"
            fi
        fi
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Install binary — build release and copy to ~/.local/bin/
# ---------------------------------------------------------------------------

if [[ "$FLAG_INSTALL" == true ]]; then
    _step "Building portable launcher (musl-static) with tray support for install..."
    if [[ "$FLAG_CI_FULL" == false ]]; then
        "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
        "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true
    fi

    # Build only the Linux launcher here. macOS and Windows tray binaries share
    # the `tillandsias-tray` bin name and have platform-specific release paths.
    _run cargo build --package tillandsias-headless --bin tillandsias --release --target x86_64-unknown-linux-musl --features tray --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1

    # Validate musl-static headless launcher
    RELEASE_BIN="$SCRIPT_DIR/target/x86_64-unknown-linux-musl/release/tillandsias"
    if [[ ! -f "$RELEASE_BIN" ]]; then
        _error "Portable headless launcher not found at $RELEASE_BIN"
        exit 1
    fi

    _step "Validating portable launcher..."
    # Test 1: Verify musl-static launcher (no external libc dependency)
    if file "$RELEASE_BIN" | grep -q "statically linked"; then
        _info "✓ Launcher is musl-static (portable)"
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
    rm -f "$INSTALL_BIN"
    cp "$RELEASE_BIN" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    _info "Portable launcher installed: $INSTALL_BIN ($(du -h "$INSTALL_BIN" | cut -f1))"
    _info "Launcher is self-contained; native tray/wrapper surfaces may use platform libraries"

    # Ensure container images exist for the newly installed version so post-build
    # E2E litmus tests (which use the versioned images) can pass.
    if [[ "$FLAG_CI_FULL" == true ]]; then
        _step "Ensuring container images exist for version $(cat "$SCRIPT_DIR/VERSION")..."
        "$INSTALL_BIN" --init 2>&1 || _warn "Failed to build images (non-fatal, post-build CI may fail)"
    fi

    if [[ "$FLAG_CI_FULL" == true ]]; then
        _step "Running post-build status smoke..."
        if TILLANDSIAS_STATUS_CHECK_BIN="$INSTALL_BIN" \
            _run_litmus_phase post-build e2e /tmp/litmus-post-build.log; then
            _info "Post-build status smoke passed"
        else
            _error "Post-build status smoke failed"
            exit 1
        fi

        _step "Running runtime residual litmus..."
        RUNTIME_STATUS_FILE="$SCRIPT_DIR/target/convergence/runtime-phase.status"
        mkdir -p "$(dirname "$RUNTIME_STATUS_FILE")"
        rm -f /tmp/litmus-runtime.log
        if podman_runtime_health_probe; then
            if _run_litmus_phase runtime e2e /tmp/litmus-runtime.log; then
                printf 'PASS\n' >"$RUNTIME_STATUS_FILE"
                _info "Runtime residual litmus passed"
            else
                printf 'FAIL\n' >"$RUNTIME_STATUS_FILE"
                _error "Runtime residual litmus failed"
                exit 1
            fi
        else
            printf 'SKIP\n' >"$RUNTIME_STATUS_FILE"
            if [[ -f "$RUNTIME_STATUS_FILE" ]] && grep -q '^SKIP$' "$RUNTIME_STATUS_FILE"; then
                _warn "Runtime residual litmus skipped (host Podman runtime unhealthy)"
            fi
        fi

        _step "Generating evidence bundle..."
        if bash "$SCRIPT_DIR/scripts/generate-evidence-bundle.sh" --reuse-ci-results; then
            _info "Evidence bundle generated for convergence validation"
        else
            _warn "Evidence bundle generation failed (non-fatal)"
        fi
    fi

    # If --install is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Test build
if [[ "$FLAG_TEST" == true ]]; then
    _step "Running tests..."
    _run cargo test --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Tests passed"

    # Prune dangling images accumulated during the test
    _step "Pruning dangling podman images..."
    "$PODMAN_CTL" image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # If --test is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Type-check only
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Checking Rust formatting..."
    if ! _run cargo fmt --check --all --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1; then
        _error "Rust code not formatted: run 'cargo fmt --all'"
        exit 1
    fi
    _info "Formatting check passed"

    _step "Type-checking workspace..."
    _run cargo check --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Type-check passed"

    _step "Running clippy (strict)..."
    _run cargo clippy --all-targets --manifest-path "$SCRIPT_DIR/Cargo.toml" -- -D warnings 2>&1
    _info "Clippy passed"

    # If --check is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Release build
if [[ "$FLAG_RELEASE" == true ]]; then
    if ! bash "$SCRIPT_DIR/scripts/local-ci.sh" --fast "${CI_ARG_LIST[@]}"; then
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
    "$PODMAN_CTL" image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias"
    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias ($(du -h "$RELEASE_BIN" | cut -f1))"
    fi

# Default: debug build (only if no other build or CI action was requested)
elif [[ "$FLAG_TEST$FLAG_CHECK$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL" == "falsefalsefalsefalsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    "$PODMAN_CTL" image prune -f 2>/dev/null && _info "Dangling images pruned" || true
fi
