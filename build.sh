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

# On Windows (Git Bash / MSYS), transparently re-exec inside the dedicated
# tillandsias-build WSL2 distro — the WSL2 sibling of the toolbox re-exec
# above (operator directive 2026-07-15). Non-Windows hosts skip with zero
# overhead. PLEASE REVIEW: linux — shared-scope hook added from the
# windows lane.
source "$_BUILDER_DIR/scripts/with-wsl2-builder.sh"
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

# ---------------------------------------------------------------------------
# Git hooks: install them, do not merely ship them
# ---------------------------------------------------------------------------
# scripts/install-hooks.sh has existed for months and .git/hooks/ was EMPTY on
# this checkout — every hook the repo ships was inert because installing them
# was a manual step nobody performed. That is the exact shape of enforcement the
# operator ruled out: "we should not be asking agents each time to follow git
# methodology by chance."
#
# Since push CI was removed (2026-08-03) the pre-push gate is the trunk's only
# automated protection, so shipping it uninstalled is indistinguishable from not
# having it. Every build.sh invocation now ensures it is wired.
#
# Silent when already correct; never fatal — a hook-install failure must not
# block a build, only report itself.
_ensure_git_hooks_installed() {
    [[ -d "$SCRIPT_DIR/.git" || -f "$SCRIPT_DIR/.git" ]] || return 0
    [[ -f "$SCRIPT_DIR/scripts/install-hooks.sh" ]] || return 0
    # Forge containers quarantine core.hooksPath deliberately; do not fight it.
    [[ "${TILLANDSIAS_HOST_KIND:-}" == "forge" ]] && return 0

    local hooks_dir out
    hooks_dir="$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null)/hooks"
    if [[ -f "$hooks_dir/pre-push" ]] \
        && grep -qF "tillandsias-pre-push-v3" "$hooks_dir/pre-push" 2>/dev/null; then
        return 0
    fi
    if out="$(bash "$SCRIPT_DIR/scripts/install-hooks.sh" 2>&1)"; then
        _info "Git hooks installed (pre-push gate is now active)"
    else
        _warn "Git hook install did not complete; pushes are UNGATED until it does"
        _warn "  run: scripts/install-hooks.sh"
    fi
    return 0
}
_ensure_git_hooks_installed

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
# Shared build helpers
# ---------------------------------------------------------------------------
# These live ABOVE the standalone dispatches below on purpose: a function
# definition only takes effect once the interpreter reaches it, so a helper
# defined after a dispatch that calls it is plain "command not found" at run
# time. That is exactly how `./build.sh --observatorium` used to die
# (_require_host_build_tools was defined ~45 lines below its only caller).

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

# Trace coverage. Until 2026-08-09 this was clickable-trace-index REGENERATION:
# build.sh rewrote 171 tracked TRACES.md files on every build-producing dispatch,
# and the ordering rule below existed entirely to stop that write from landing
# between a gate that passed clean and the forge's dirty-start guard.
#
# The write is gone, so the hazard is gone with it. scripts/trace-coverage.sh
# only reads: it computes the trace_coverage_summary the evidence bundle has
# always required and enforces the ghost-trace ratchet. Order 495's constraint is
# satisfied vacuously now — a function that cannot dirty the worktree cannot hand
# dirt to the forge gate — but the call site is kept in the same place so the
# ordering property stays true by construction rather than by luck.
#
# TILLANDSIAS_SKIP_TRACE_INDEX=1 still suppresses it, kept under its old name so
# existing callers (post-build and runtime litmus phases, which can launch a real
# forge) keep working unchanged.
# Local build counter. methodology/versioning.yaml declares this and has since
# the scheme was designed:
#
#   Build:
#     meaning: "Local monotonic build counter — increments on every local build"
#     monotonic: "Globally monotonic across all machines and branches"
#     increment_rule: "Automatic on every local build (./build.sh), manual bump at merge"
#
# It was never automatic. scripts/bump-version.sh --bump-build existed,
# scripts/verify-version-monotonic.sh existed, and build.sh called NEITHER — so
# VERSION sat at 0.4.260728.1 through days of local builds while the published
# tag moved to v0.4.260728.2, and the version-monotonicity gate was red the whole
# time. The gate was not miscategorised; it was correctly reporting a real,
# ongoing defect that nothing else surfaced.
#
# Bumped from the same dispatch set as the trace indexes — the build-PRODUCING
# ones. `--check` and `--test` produce no artifact, so they are not builds and
# must not move the counter (that distinction is already load-bearing for the
# trace indexes; reuse it rather than invent a second rule).
#
# The bump is fail-soft on the script's own errors but LOUD: it dirties a tracked
# file, and an agent that does not know that ships an unbumped VERSION.
_BUILD_VERSION_BUMPED=false
_bump_build_version() {
    [[ "$_BUILD_VERSION_BUMPED" == false ]] || return 0
    _BUILD_VERSION_BUMPED=true
    if [[ "${TILLANDSIAS_SKIP_VERSION_BUMP:-0}" == "1" ]]; then
        _info "Skipping build-counter bump (TILLANDSIAS_SKIP_VERSION_BUMP=1)"
        return 0
    fi
    local before after
    before="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)"
    if ! "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build; then
        _warn "Build-counter bump FAILED. VERSION is unchanged at ${before}; methodology/versioning.yaml requires it to increment on every local build. Run scripts/bump-version.sh --bump-build by hand and read its errors."
        return 0
    fi
    after="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || echo unknown)"
    if [[ "$before" != "$after" ]]; then
        # NEVER INSTRUCT AN ACTION THE PRE-PUSH GUARD WILL REFUSE (order 643-64bx,
        # partial reduction — windows host 2026-08-10).
        #
        # This used to say, unconditionally, "Commit them with your change".
        # On any branch except main that is advice toward a wall: the pre-push
        # VERSION guard refuses a push whose commits change VERSION unless the
        # result equals main's (a sync-forward catch-up) or the branch is the
        # release bump branch. Following the advice therefore ends at one of
        #   * `git push --no-verify`, which disables the ONLY remaining gate
        #     (push CI was removed, 599-w5jd) in order to push the very file that
        #     gate protects — the worst available exit; or
        #   * a local-only commit, which the meta-orchestration exit contract
        #     forbids outright.
        #
        # The deadlock itself is NOT fixed here and 643-64bx stays open: a local
        # build still writes to a tracked file, so `./build.sh --install` followed
        # by a normal push still needs a manual revert. Fixing that means deciding
        # whether the local build counter should touch tracked files at all, which
        # has release-path consequences and is the packet's own first exit
        # criterion. What is fixed is the packet's second criterion — the
        # instruction that actively steers toward --no-verify.
        local branch main_version
        branch="$(git -C "$SCRIPT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")"
        main_version="$(git -C "$SCRIPT_DIR" show origin/main:VERSION 2>/dev/null \
            || git -C "$SCRIPT_DIR" show main:VERSION 2>/dev/null || echo "")"
        main_version="$(printf '%s' "$main_version" | tr -d '[:space:]')"

        _warn "VERSION bumped ${before} -> ${after} (local build counter). This dirties tracked files."
        if [[ -z "$branch" || "$branch" == "main" ]]; then
            _warn "  Commit them with your change: git add VERSION Cargo.toml crates/*/Cargo.toml"
            _warn "  Verify monotonicity before pushing: scripts/verify-version-monotonic.sh"
        elif [[ -n "$main_version" && "$after" == "$main_version" ]]; then
            # Sync-forward: the bump landed exactly on main's VERSION, which the
            # guard permits as a catch-up rather than a divergent bump.
            _warn "  This matches origin/main (${main_version}) — a sync-forward, which the pre-push guard allows."
            _warn "  Commit them with your change: git add VERSION Cargo.toml crates/*/Cargo.toml"
        else
            _warn "  Do NOT commit VERSION on '${branch}': the pre-push guard refuses it (main's is ${main_version:-unknown})."
            _warn "  Revert the bump to keep the tree clean:"
            _warn "    git checkout -- VERSION Cargo.toml Cargo.lock crates/*/Cargo.toml"
            _warn "  Or skip it next time: TILLANDSIAS_SKIP_VERSION_BUMP=1 ./build.sh …"
            _warn "  Do NOT reach for 'git push --no-verify' — it disables the only remaining gate (643-64bx)."
        fi
    fi
}

_TRACE_INDEXES_REGENERATED=false
# Trace coverage + ghost-trace ratchet. Replaces the 171 committed TRACES.md
# rendering files that scripts/generate-traces.sh used to emit and that this
# function used to regenerate on every build (operator directive 2026-08-09).
#
# The rendering was pure cost. It was ~4000 lines of generated markdown, tracked
# in git, rewritten on every build, and its only real consumers were a
# dead-trace detector exercised solely by its own tests, a handful of litmus
# greps, and the on-hold Observatorium. It dirtied worktrees, tripped
# litmus:local-ci-self-clean-evidence, and forced agents into extra commits
# whose whole content was regenerated evidence — the exact velocity tax the
# comment this replaces spent 20 lines apologising for.
#
# Crucially it was NOT what carried the convergence guarantee. That is carried
# by the @trace annotations themselves (still in source, untouched), by
# validate_spec_existence, by litmus-to-spec binding, and by the CentiColon
# signature. And `trace_coverage_summary` — a REQUIRED evidence-bundle field in
# methodology/convergence.yaml and verification.yaml — was never produced by
# anything at all. scripts/trace-coverage.sh now produces it, and enforces the
# ghost ratchet, so this change closes an open obligation rather than dropping
# one. Nothing writes to the worktree here: the summary is computed on demand.
_check_trace_coverage() {
    [[ "$_TRACE_INDEXES_REGENERATED" == false ]] || return 0
    _TRACE_INDEXES_REGENERATED=true
    if [[ "${TILLANDSIAS_SKIP_TRACE_INDEX:-0}" == "1" ]]; then
        _info "Skipping trace coverage check (TILLANDSIAS_SKIP_TRACE_INDEX=1)"
        return 0
    fi
    _step "Computing trace coverage + ghost-trace ratchet..."
    local summary
    summary="$("$SCRIPT_DIR/scripts/trace-coverage.sh" 2>/dev/null)"
    if [[ -n "$summary" ]]; then
        _info "$summary"
    fi

    # The ratchet fails in BOTH directions: a new ghost, or a baseline entry
    # that is no longer a ghost and must be pruned. The baseline may only
    # shrink, which is what makes this monotonic instead of a mute button.
    local gate_out
    if ! gate_out="$("$SCRIPT_DIR/scripts/trace-coverage.sh" --gate 2>&1)"; then
        _error "Ghost-trace ratchet FAILED"
        printf '%s\n' "$gate_out" >&2
        return 1
    fi
    _info "${gate_out}"
    return 0
}

# ---------------------------------------------------------------------------
# Standalone operations
# ---------------------------------------------------------------------------

if [[ "$FLAG_INIT" == true ]]; then
    # The only build.sh flag with a genuine, unconditional Podman need
    # (it builds every container image). Fail fast with a clear message
    # here rather than a possibly-confusing downstream Rust error.
    require_podman || exit 1
    _bump_build_version
    _check_trace_coverage
    _step "Running tillandsias --init (builds all images with versioned tags)..."
    # Runs on the host where podman works.
    "$SCRIPT_DIR/target/debug/tillandsias" --init 2>&1
    # Also prune old images
    _step "Pruning old images..."
    "$PODMAN_CTL" image prune -f 2>/dev/null || true
    exit 0
fi

if [[ "${FLAG_OBSERVATORIUM:-false}" == true ]]; then
    _bump_build_version
    _check_trace_coverage
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

    # Order 495 (litmus:local-ci-self-clean-evidence): these phases run after
    # the pre-build gate and can launch a real forge whose dirty-start guard
    # inspects the tracked checkout. A nested build.sh must not regenerate the
    # tracked trace indexes inside that window, so suppress it for the phase.
    TILLANDSIAS_SKIP_TRACE_INDEX=1 \
        bash "$SCRIPT_DIR/scripts/run-litmus-test.sh" \
        --phase "$phase" \
        --size "$size" \
        --compact \
        "${phase_args[@]}" \
        "$@" 2>&1 | tee "$log_file"
}

# Record that a gate passed against THIS tree, for the pre-push hook to verify.
# Called from EVERY passing gate. It was originally only in the --check path,
# which meant `--ci-full` — the STRONGER gate, and the one the release skill
# requires — left the stamp stale, so a release run had to go back and run the
# lesser gate just to be allowed to push. Found by the gate refusing its own
# release push on 2026-08-04.
_write_gate_stamp() {
    [[ -f "$SCRIPT_DIR/scripts/gate-stamp.sh" ]] || return 0

    # Order 584-2qq2: a stamp is authority for the pre-push hook, so it must
    # cover trace evidence as well as Rust/ledger checks. What it covered until
    # 2026-08-09 was the FRESHNESS of 171 generated TRACES.md files — a property
    # of a rendering, satisfiable only by committing regenerated markdown, and
    # the reason a passing gate routinely demanded an extra commit before it
    # would let you push.
    #
    # The stamp now covers the property that actually matters and that a
    # rendering could never express: no annotation references a spec that does
    # not exist. Non-mutating, as before — nothing is written to the worktree,
    # so a stamp can no longer be blocked by evidence the build itself dirtied.
    local ghost_status
    if ! ghost_status="$("$SCRIPT_DIR/scripts/trace-coverage.sh" --gate 2>&1)"; then
        _error "Ghost-trace ratchet failed — gate stamp NOT recorded"
        printf '%s\n' "$ghost_status" >&2
        return 1
    fi

    if bash "$SCRIPT_DIR/scripts/gate-stamp.sh" write >/dev/null 2>&1; then
        _info "Gate stamp recorded (pre-push will accept this tree)"
    else
        _warn "Could not record gate stamp — pre-push may ask you to re-run the gate"
    fi
    return 0
}

_run_local_ci_gate() {
    local -a command=(bash "$SCRIPT_DIR/scripts/local-ci.sh" "$@")
    if [[ "$FLAG_GRAPHS" == true ]]; then
        MD_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.md" \
            JSON_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json" \
            SUMMARY_OUT="$SCRIPT_DIR/target/convergence/summary.md" \
            "${command[@]}" >/tmp/tillandsias-ci-graphs.log 2>&1
    else
        MD_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.md" \
            JSON_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json" \
            SUMMARY_OUT="$SCRIPT_DIR/target/convergence/summary.md" \
            "${command[@]}"
    fi
}

_prepare_ci_full_install_inputs() {
    [[ "$FLAG_CI_FULL" == true ]] || return 0
    [[ "$FLAG_INSTALL" == true ]] || return 0

    _step "Preparing trace indexes and staged guest binaries for full install CI..."
    # DELIBERATELY NO _bump_build_version here. This is the meta-orchestration
    # cycle's own build path, and litmus:meta-orchestration-dirty-tree-safety
    # (order 495) requires it to leave tracked RELEASE state untouched: a cycle
    # must exit with a clean worktree, and a monotonically-increasing counter
    # never converges to a value a second cycle would agree on the way a
    # regenerated trace index does. Developer dispatches still bump — that is
    # methodology/versioning.yaml's increment_rule — but the cycle's internal
    # build must not.
    _check_trace_coverage

    if [[ ! -x "$SCRIPT_DIR/scripts/build-guest-binaries.sh" ]]; then
        _error "Missing executable guest binary builder: scripts/build-guest-binaries.sh"
        exit 1
    fi

    "$SCRIPT_DIR/scripts/build-guest-binaries.sh"
}

# The install dispatch owns the only path with a post-build forge phase, and its
# CI gate runs below — ahead of the install block itself. Regenerate here so the
# order 495 rule holds for every install variant (--install, --ci --install,
# --ci-full --install): trace indexes are refreshed BEFORE the gate, never
# between the gate and the forge dirty-start guard. The call inside the install
# block is latched to a no-op by this one. The release dispatch owns its own
# gate and regenerates at the top of its own block.
if [[ "$FLAG_INSTALL" == true ]]; then
    _bump_build_version
    _check_trace_coverage
fi

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
    _write_gate_stamp
    # If --ci is the only flag, exit with success
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_REMOVE" == "falsefalsefalsefalsefalsefalsefalse" ]]; then
        if [[ "$FLAG_GRAPHS" == true ]]; then
            if [[ -f "$SCRIPT_DIR/target/convergence/centicolon-dashboard.md" ]]; then
                cat "$SCRIPT_DIR/target/convergence/centicolon-dashboard.md"
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
    _bump_build_version
    _check_trace_coverage

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
        if DASHBOARD_FILE="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json" \
            bash "$SCRIPT_DIR/scripts/generate-evidence-bundle.sh" --reuse-ci-results; then
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

    _step "Running clippy (strict + listen-vsock)..."
    _run cargo clippy --all-targets --manifest-path "$SCRIPT_DIR/Cargo.toml" -p tillandsias-headless --features listen-vsock -- -D warnings 2>&1
    _info "Clippy (listen-vsock) passed"

    _step "Checking plan ledger integrity (tillandsias-plan check)..."
    if ! _run cargo run -q --manifest-path "$SCRIPT_DIR/Cargo.toml" -p tillandsias-plan -- check 2>&1; then
        _error "plan/index.yaml failed integrity check: run 'cargo run -p tillandsias-plan -- check' for details"
        exit 1
    fi
    _info "Plan ledger check passed"

    _step "Checking plan order uniqueness (tillandsias-policy plan-orders)..."
    if ! _run cargo run -q --manifest-path "$SCRIPT_DIR/Cargo.toml" -p tillandsias-policy -- plan-orders 2>&1; then
        _error "plan/index.yaml has open duplicate order tokens: run 'cargo run -p tillandsias-policy -- plan-orders' for details"
        exit 1
    fi
    _info "Plan order uniqueness passed"

    # Order 635-i6vm. `tillandsias-plan check` validates the ledger's SCHEMA and
    # references; it cannot see a status transition the fold discarded, because
    # the discarded result is itself perfectly valid. Re-declaring a packet under
    # `packets:` with a new status parses, validates, reviews correctly — and is
    # a no-op, because `packets:` is a G-Set. 11 of 21 fragment-recorded
    # completions were being thrown away when this was found, and the batch
    # selector was handing already-completed packets back out as next work.
    _step "Checking for fragment status transitions the fold discards..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-status-loss.sh" 2>&1; then
        _error "a fragment declares a status the fold does not apply — write a status: LWW entry instead (plan/index.d/README.md)"
        exit 1
    fi
    _info "Fragment status-loss check passed"

    # Record that the gate passed against THIS exact tree. The pre-push hook
    # verifies this stamp instead of re-running the whole gate: a multi-minute
    # hook gets --no-verify'd on its second use and then enforces nothing, while
    # hashing the diff costs milliseconds for the same guarantee. Push CI was
    # removed 2026-08-03, so this is the trunk's only remaining protection.
    _write_gate_stamp

    # If --check is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Release build
if [[ "$FLAG_RELEASE" == true ]]; then
    _bump_build_version
    _check_trace_coverage
    if ! _run_local_ci_gate --fast "${CI_ARG_LIST[@]}"; then
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
    _bump_build_version
    _check_trace_coverage
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    "$PODMAN_CTL" image prune -f 2>/dev/null && _info "Dangling images pruned" || true
fi
