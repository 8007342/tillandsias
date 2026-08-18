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

# PODMAN MODE IS THE CALLER'S TO DECLARE — the gate does not guess it.
#
# Order 797-r6tc. What used to be here inferred remote podman mode from a FILE
# EXISTING: if ${XDG_RUNTIME_DIR}/podman/podman.sock was a socket, build.sh
# exported TILLANDSIAS_PODMAN_REMOTE_URL. That socket is present on any host
# with podman.socket enabled, which is the ordinary Fedora state, so the
# inference fired unconditionally and ONLY inside the gate.
#
# Sourcing common.sh with that variable set takes its remote branch, which does
# three things beyond choosing a URL: it generates a wrapper, puts the wrapper
# directory FIRST on PATH, and pins TILLANDSIAS_PODMAN_BIN to it. That pin wins
# over PATH in resolve_podman_bin() (crates/tillandsias-podman/src/lib.rs), and
# it is exported, so it outlives this process into every litmus child. Litmus
# tests declaring `backend: fake` inject their podman by PATH; an inherited pin
# silently overrode it and they exercised real podman against a fake-podman
# contract. Measured on macuahuitl 2026-08-17, same commit, same 302-test set:
# 302/302 pass from a bare `scripts/run-litmus-test.sh --phase pre-build
# --size quick`, 295/302 through `./build.sh --ci-full`. A gate that tests a
# different substrate than every other caller is not a stricter gate, it is a
# gate whose subject is unknown.
#
# PROVENANCE: the export arrived in 4650c8f9f (2026-05-14, "checkpoint(codex):
# split quiet quit and repeat modes"), incidental to that change, with no
# rationale and no packet. WHO ACTUALLY WANTS REMOTE MODE, checked before
# removing it: exactly one caller, and it sets the variable itself —
# packaging/systemd/user/tillandsias.service, whose ExecStart is
# `tillandsias --headless` and whose lane require_headless_service_account()
# hard-requires a unix:// URL for. That lane is unaffected by this deletion
# because it never routed through build.sh. No macOS or Windows/WSL2 lane sets
# it (order 309's WSL2 delegation design is filed but unimplemented).
#
# So the rule is 793-a62g's, one level up: the podman wrapper is CONFIGURATION,
# never inference. A caller that wants the gate to reach podman through a
# socket exports TILLANDSIAS_PODMAN_REMOTE_URL (or CONTAINER_HOST) and says so;
# common.sh honours it exactly as before. Absent that, the gate uses podman as
# the operating system provides it — the same podman a bare litmus run uses, so
# the two agree about what they tested.
#
# Pinned by litmus:gate-podman-mode-is-configuration-not-inference.

source "$SCRIPT_DIR/scripts/common.sh"

# Build/test DURATION telemetry (packet 682-emvg). Best-effort side-channel:
# times the pre-push gate so a cycle can see where its wall-clock goes. A timing
# failure must NEVER change build.sh's exit code or output, so the source and its
# no-op fallback are both `|| true`-guarded.
. "$SCRIPT_DIR/scripts/timing-log.sh" 2>/dev/null || true
command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
# 765-uti9 quick win (velocity audit F2/F10): anchor for the build-preamble
# record — everything between here and the --check timer (git hooks, podman
# registries, dev-proxy ensure, sidecar staging) was invisible to timing:,
# hiding the post-VERSION-bump sidecar rebuild that can dwarf the timed block.
_PREAMBLE_T0="$(timing_now_ms)"

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
# ── Per-phase timing (order 758-jw6v) ────────────────────────────────────────
#
# WHY THIS EXISTS. `./build.sh --check` is the largest fixed cost in a
# meta-orchestration cycle — ~130s, run three or four times per cycle — and
# until now the only way to find out WHERE that went was to pipe the gate's
# output through a timestamper and diff the gaps. I did that, attributed a 58s
# gap to trace-coverage.sh, fixed trace-coverage.sh from 455s to 20s, and the
# gate moved 146s -> 130s. The win was real; the attribution was wrong by a
# factor of three, and wrong in the direction that would have justified more
# work on the thing already fixed.
#
# A number nobody can see is a number nobody checks. So the gate now measures
# itself: every `_step` closes the previous phase, and the end of the run
# prints the total plus any phase that took longer than the threshold.
#
# QUIET BY DEFAULT, because 45 phases of timing on every commit is the kind of
# noise that gets a signal ignored (734-sjb3). Only phases over
# TILLANDSIAS_GATE_SLOW_MS (default 5s) are named; TILLANDSIAS_GATE_PROFILE=1
# prints all of them.
_PHASE_NAME=""
_PHASE_T0=""
_PHASE_LOG=""
# Order 785-ibu9. `_PHASE_T0` measures BANNER TO BANNER, which is the phase's
# wall clock but NOT necessarily the named step's own cost: any work between a
# step's command and the next banner lands on the previous step's record. That
# inflated a real reading (783-xyk5 was filed on a step number that bundled
# work the guard did not do), so the emitted telemetry now carries the step's
# OWN measured work — the time spent inside `_run`, accumulated here — and
# falls back to the span only for phases that run no `_run` at all. The
# fallback is labelled in the record's `phase` field rather than silently
# mixed in, because an unattributable number that looks attributable is the
# defect this packet closes.
_PHASE_WORK_MS=0
_PHASE_RAN_WORK=0
# date '+%s%3N' is GNU-only. BSD/macOS date SUCCEEDS while passing %3N
# through literally ("<secs>3N"), so an exit-code guard never fires and the
# phase arithmetic explodes ("value too great for base" — first hit: macOS
# 2026-08-16, 766-class dialect skew). Validate digits; degrade to whole
# seconds — the report only names phases over TILLANDSIAS_GATE_SLOW_MS
# (default 5s), so second granularity keeps every consumer meaningful.
_now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null || true)" # gnu-date: ok (digit-validated below; degrades to seconds)
    case "$t" in
        ''|*[!0-9]*)
            t="$(date +%s 2>/dev/null || true)"
            case "$t" in
                ''|*[!0-9]*) t=0 ;;
                *) t=$((t * 1000)) ;;
            esac
            ;;
    esac
    printf '%s' "$t"
}

_phase_close() {
    [[ -n "$_PHASE_NAME" ]] || return 0
    local now elapsed work
    now="$(_now_ms)"
    elapsed=$(( now - _PHASE_T0 ))
    [[ "$elapsed" -ge 0 ]] || elapsed=0
    work="$_PHASE_WORK_MS"
    [[ "$work" -ge 0 ]] || work=0
    # span<TAB>work<TAB>name — `work` is -1 when the phase measured no `_run`,
    # so a consumer can tell "measured zero work" from "nothing to measure".
    [[ "$_PHASE_RAN_WORK" == 1 ]] || work=-1
    _PHASE_LOG="${_PHASE_LOG}${elapsed}	${work}	${_PHASE_NAME}
"
    _PHASE_NAME=""
}

_step()  {
    _phase_close
    _PHASE_NAME="$*"
    _PHASE_T0="$(_now_ms)"
    _PHASE_WORK_MS=0
    _PHASE_RAN_WORK=0
    [[ "${FLAG_GRAPHS:-false}" == true ]] || echo -e "${CYAN}[build]${NC} $*"
}

# Print the gate's own cost. Called once, at the end of --check.
_phase_report() {
    _phase_close
    [[ -n "$_PHASE_LOG" ]] || return 0
    local total slow_ms
    slow_ms="${TILLANDSIAS_GATE_SLOW_MS:-5000}"
    total="$(printf '%s' "$_PHASE_LOG" | awk -F'\t' '{s+=$1} END {printf "%d", s}')"
    # 785-ibu9: the report is a WALL-CLOCK view, so it keeps ranking on span —
    # but when a phase's span materially exceeds the work measured inside it,
    # the difference is time the named step did not spend, and printing it is
    # how the unattributed gap stops hiding inside a step's number.
    if [[ "${TILLANDSIAS_GATE_PROFILE:-0}" == "1" ]]; then
        printf '%s' "$_PHASE_LOG" | sort -rn | awk -F'\t' \
            '{ gap = ($2 >= 0 && $1 - $2 > 250) ? sprintf("   (+%.1fs unattributed)", ($1-$2)/1000) : ""
               printf "  %6.1fs  %s%s\n", $1/1000, $3, gap }' >&2
    else
        printf '%s' "$_PHASE_LOG" | sort -rn \
            | awk -F'\t' -v lim="$slow_ms" \
            '$1 > lim { gap = ($2 >= 0 && $1 - $2 > 250) ? sprintf("   (+%.1fs unattributed)", ($1-$2)/1000) : ""
                        printf "  %6.1fs  %s%s\n", $1/1000, $3, gap }' >&2
    fi
    _info "Gate phases totalled $(( total / 1000 ))s (set TILLANDSIAS_GATE_PROFILE=1 for every phase)"
}

# 765-dfry: flush every closed phase into the 682-emvg timing side-channel, in
# ONE spawn (per-record emission costs ~15ms x ~45 phases per gate — the
# audit's empty-suite-floor lesson applied to the telemetry itself). Step name
# is a stable slug of the phase description, prefixed `step:` so consumers can
# select the family; per-phase exit is 0 by definition (phase records carry
# WHERE the time went; the gate's verdict lives on the build-check record).
# Best-effort like every 682-emvg emission: never alters output or exit codes,
# and never double-emits (the log is consumed on flush).
_phase_emit_timing() {
    _phase_close
    [[ -n "$_PHASE_LOG" ]] || return 0
    {
        printf '%s' "$_PHASE_LOG" | awk -F'\t' \
            -v host="${TILLANDSIAS_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}" '
            NF == 3 {
                name = tolower($3)
                gsub(/[^a-z0-9]+/, "-", name)
                gsub(/^-+|-+$/, "", name)
                if (length(name) > 64) name = substr(name, 1, 64)
                if (name == "") next
                # 785-ibu9: prefer the step OWN WORK (measured inside _run) over
                # the banner-to-banner span. `phase` carries the provenance so a
                # reader never has to guess which one a number is: `build` means
                # attributable to the named step, `build-span` means the phase
                # ran no measurable command and the number is wall clock between
                # banners. Same `step:` family either way, so the finest-grain
                # slowest= preference keeps seeing every phase.
                if ($2 >= 0) { dur = $2; prov = "build" } else { dur = $1; prov = "build-span" }
                printf "step:%s\t%s\t%s\t0\t%s\n", name, prov, dur, host
            }' | bash "$SCRIPT_DIR/scripts/cycle-metrics.sh" --emit-timing-batch
    } 2>/dev/null || true
    # Consume on flush: combined dispatches (--ci-full --install) flush once
    # per stage, so a later flush emits only the phases closed since this one.
    _PHASE_LOG=""
    return 0
}

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
# 723-whrx: --install has no macOS meaning, so say so instead of half-doing it
# ---------------------------------------------------------------------------
# Before this, `grep -niE 'darwin|uname|OSTYPE'` over this whole file matched
# nothing: build.sh had no host branch at all. On macOS `--install` therefore
# built an x86_64 Linux musl launcher and tried to EXECUTE it, while the
# readiness guard reported the host as ready. `--ci-full --install` is the
# phased gate the release and meta-orchestration runbooks treat as the strong
# evidence path, so on macOS that path was not merely unsupported — it was
# unsupported SILENTLY, which is the part that lets a "builds from scratch on
# macOS" claim get made.
#
# PLACEMENT IS THE POINT, and it is why this sits here rather than beside the
# install block. Three things downstream mutate state before the install work
# begins: `_bump_build_version` and `_check_trace_coverage` (the FLAG_INSTALL
# pre-gate), `_prepare_ci_full_install_inputs` on the --ci-full --install path,
# and the main install block. Refusing at any of those still dirties VERSION
# first, and build.sh then tells the operator not to commit the dirt it just
# made. Refusing HERE — flags parsed, nothing done — is the only position where
# "no Linux binary was built" and "the tree is clean" are both true.
#
# Deliberately NOT gated on --check/--test: those are the paths that DO work on
# macOS and this must not touch them.
if [[ "$(uname -s)" == "Darwin" ]] && [[ "$FLAG_INSTALL" == true ]]; then
    cat >&2 <<'DARWIN_INSTALL_REFUSAL'
Error: --install is not supported on macOS.

  It builds an x86_64 Linux musl launcher and then tries to run it, which
  cannot work on this host. (--ci-full --install is the same path.)

  The macOS build is a signed .app bundle, not a musl binary:

      scripts/build-macos-tray.sh

  What DOES work here: ./build.sh --check and ./build.sh --test.
DARWIN_INSTALL_REFUSAL
    exit 2
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

# 765-uti9 quick win (velocity audit F2): a check-only dispatch builds no
# containers and pulls nothing through the dev proxy, so host podman registry
# setup and the dev-proxy ensure (15x1s health-wait worst case) are pure
# preamble tax there — on ANY host kind, not only in-forge. Same flag predicate
# as above minus the host-kind gate; any other flag reinstates the full
# preamble. Worst case: a --check with a changed lockfile loses proxy caching
# for one cargo fetch — slower, never wrong.
_check_only_dispatch() {
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
elif _check_only_dispatch; then
    _info "Skipping host Podman registry setup for check-only dispatch (765-uti9)"
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
elif _check_only_dispatch; then
    _info "Skipping host dev cache setup for check-only dispatch (765-uti9)"
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
# Router sidecar staging (order 710-w9kc). The tillandsias-headless build.rs
# include_bytes!()s images/router/tillandsias-router-sidecar as a REQUIRED
# runtime asset, and the router Containerfile COPYs it into the image. It is a
# BUILD ARTIFACT and is gitignored — NEVER committed to the repo. Stage a
# freshly-compiled sidecar before any cargo invocation so cargo build/check/test
# finds it. build-sidecar.sh is a cheap no-op when already up to date, and a
# build-number bump (VERSION touch) forces a fresh, version-matched recompile.
# ---------------------------------------------------------------------------
_stage_router_sidecar() {
    [[ -f "$SCRIPT_DIR/scripts/build-sidecar.sh" ]] || return 0
    _step "Staging router sidecar (build artifact — not committed)..."
    bash "$SCRIPT_DIR/scripts/build-sidecar.sh"
}

# Stage before every dispatch that compiles Rust. Pure teardown flags
# (--remove/--wipe/--clean-alone/--init) never invoke cargo, so they skip it and
# stay usable without a rustup/musl toolchain.
_stage_router_sidecar_if_compiling() {
    local f
    for f in FLAG_INSTALL FLAG_CI FLAG_CI_FULL FLAG_RELEASE FLAG_CHECK FLAG_TEST FLAG_OBSERVATORIUM; do
        if [[ "${!f:-false}" == true ]]; then _stage_router_sidecar; return; fi
    done
    if [[ "$FLAG_REMOVE" != true && "$FLAG_WIPE" != true \
       && "$FLAG_CLEAN" != true && "$FLAG_INIT" != true ]]; then
        _stage_router_sidecar   # bare debug build (no standalone flag)
    fi
}
_stage_router_sidecar_if_compiling

# ---------------------------------------------------------------------------
# Standalone operations
# ---------------------------------------------------------------------------

if [[ "$FLAG_INIT" == true ]]; then
    # 723-whrx: build the binary BEFORE the podman gate and the VERSION bump.
    #
    # This block used to execute target/debug/tillandsias without ever building
    # it, so from a clean tree --init failed on ANY platform — but only AFTER
    # require_podman had run and _bump_build_version had dirtied VERSION, and
    # build.sh then tells the operator not to commit that dirt. The failure was
    # therefore both avoidable and expensive: a missing artifact reported as a
    # podman problem or a bare "no such file", with a dirty tree left behind.
    #
    # Ordering is the property being fixed, not the message. Everything that
    # mutates state or gates on external services now happens only once the
    # thing we are about to run is known to exist.
    if [[ ! -x "$SCRIPT_DIR/target/debug/tillandsias" ]]; then
        _step "target/debug/tillandsias is absent — building it first (723-whrx)..."
        if ! cargo build -p tillandsias-headless 2>&1; then
            _error "--init needs target/debug/tillandsias and the build failed."
            _error "Nothing was changed: no VERSION bump, no podman calls."
            exit 1
        fi
    fi
    if [[ ! -x "$SCRIPT_DIR/target/debug/tillandsias" ]]; then
        # Built without error yet still absent: refuse rather than fall through
        # to a confusing exec failure three steps later.
        _error "--init: target/debug/tillandsias is still absent after a successful build."
        _error "Nothing was changed: no VERSION bump, no podman calls."
        exit 1
    fi

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

# Order 785-ibu9: `_run` is the seam where a step's REAL work happens, so it is
# where the step's own cost can be measured without annotating ~40 call sites
# (765-dfry's zero-per-site-edit property is the reason its telemetry exists at
# all, and a fix that required per-step edits would rot). Accumulates rather
# than assigns: a phase may run several commands, and their sum is the phase's
# work. `|| _rc=$?` keeps the command "tested" so errexit does not abort before
# the accounting, and the original status is then returned unchanged — the
# 682-emvg contract (never alter exit codes or output) is preserved by
# construction, and a broken clock can only mis-add, never fail the step.
_run() {
    _require_host_build_tools
    local _run_t0 _run_rc=0 _run_dt
    _run_t0="$(_now_ms)"
    (cd "$SCRIPT_DIR" && "$@") || _run_rc=$?
    _run_dt=$(( $(_now_ms) - _run_t0 ))
    [[ "$_run_dt" -ge 0 ]] || _run_dt=0
    _PHASE_WORK_MS=$(( _PHASE_WORK_MS + _run_dt ))
    _PHASE_RAN_WORK=1
    return "$_run_rc"
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
    # Order 765-mza8 makes the `scope full` paragraph below enforceable rather
    # than aspirational. run-litmus-test.sh drops this sentinel when it actually
    # skipped tests under --diff-scope; if it is present, this dispatch did NOT
    # validate the whole tree and must not say it did.
    #
    # Refusing to write ANY stamp is the fail-closed choice, and it is the right
    # one: no stamp means pre-push asks for a full gate, which is exactly what a
    # partially-verified tree needs. Downgrading to a scoped stamp would be
    # worse — this function cannot know WHICH classes the scoped litmus run
    # actually covered, and inventing a class list is how a stamp starts lying.
    #
    # FIRST, before the ghost ratchet and before the gate-stamp.sh existence
    # check. Both can fail or return early, and either would leave the sentinel
    # on disk to veto every LATER, legitimately-full run. The sentinel is
    # one-shot: consuming it here is what bounds the veto to the run that
    # earned it.
    local _scoped_sentinel
    _scoped_sentinel="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-litmus-diff-scoped"
    if [[ -f "$_scoped_sentinel" ]]; then
        local _scoped_detail
        _scoped_detail="$(cat "$_scoped_sentinel" 2>/dev/null || echo 'diff-scope')"
        rm -f "$_scoped_sentinel" 2>/dev/null || true
        _warn "NOT writing a gate stamp: this run's litmus lane was diff-scoped (${_scoped_detail})"
        _warn "  A scoped run cannot vouch for the whole tree. Re-run the gate without --diff-scope before pushing."
        return 0
    fi

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
    # Announced so it is attributable. This ran silently, and the pause it
    # produced was read as "trace-coverage is slow" when measurement later put
    # most of the time elsewhere (758-jw6v). A phase with no name cannot be
    # blamed correctly OR exonerated.
    _step "Ratcheting ghost traces for the gate stamp (584-2qq2)..."
    local ghost_status
    if ! ghost_status="$("$SCRIPT_DIR/scripts/trace-coverage.sh" --gate 2>&1)"; then
        _error "Ghost-trace ratchet failed — gate stamp NOT recorded"
        printf '%s\n' "$ghost_status" >&2
        return 1
    fi

    # Order 765-dt8h: the stamp records WHICH gate wrote it and WHAT it
    # validated. Every dispatch here validates the whole tree, so all of them
    # write `scope full` — the field exists so that a future scoped run (the
    # diff-scoped litmus / change-class selector packets, all of which depend
    # on this one) physically cannot write a stamp that overstates its
    # coverage. `dispatch` is provenance only: --check and --ci-full both
    # cover everything, but they do not cover it equally, and a reader of a
    # refused push deserves to know which one ran.
    local _stamp_dispatch="check"
    if [[ "$FLAG_CI_FULL" == true ]]; then
        _stamp_dispatch="ci-full"
    elif [[ "$FLAG_CI" == true ]]; then
        _stamp_dispatch="ci"
    fi

    _step "Writing the gate stamp..."
    if bash "$SCRIPT_DIR/scripts/gate-stamp.sh" write --scope full --dispatch "$_stamp_dispatch" >/dev/null 2>&1; then
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

    # 765-dfry: flush install-stage phase records (portable-launcher build,
    # image ensure, status smoke, evidence bundle) so a --ci-full --install
    # run's wall clock is attributable from the timing records alone.
    _phase_emit_timing

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
    # Time the WHOLE --check (the pre-push gate, run every cycle) as a telemetry
    # side-channel (packet 682-emvg). The trap fires on any exit while set —
    # including a set -e abort when a sub-step fails — recording the real exit
    # code; it is cancelled at normal completion so a single record is emitted
    # and combined-flag runs do not over-count. NEVER alters the gate's exit.
    # 765-uti9: emit the preamble duration first — best-effort per the
    # 682-emvg contract, never alters the gate's exit.
    timing_emit build-preamble check "${_PREAMBLE_T0:-$(timing_now_ms)}" 0 || true
    _CHECK_T0="$(timing_now_ms)"
    trap 'timing_emit build-check check "$_CHECK_T0" $?' EXIT
    _step "Checking Rust formatting..."
    if ! _run cargo fmt --check --all --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1; then
        _error "Rust code not formatted: run 'cargo fmt --all'"
        exit 1
    fi
    _info "Formatting check passed"

    # 765-uti9 quick win (velocity audit F3): the dedicated `cargo check
    # --workspace` step was fully subsumed by the clippy pass below — same
    # virtual-manifest workspace, a strict SUPERSET of targets (--all-targets),
    # -D warnings failing on every diagnostic check would report, and
    # _require_host_build_tools hard-requires clippy-driver so no host can run
    # check but not clippy. The two also share no fingerprints (clippy drives
    # its own compiler), so the removed step was a full second frontend pass.
    # Type errors now surface under the clippy banner.
    _step "Running clippy (strict; includes the workspace type-check)..."
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
    # Order 721-nyev. Every script that RUNS tillandsias-plan must resolve it
    # through the shared probe, never a hardcoded target/ path. 704-zcgi
    # centralised that probe on the reasoning that fixing instances is not
    # enough, and four more instances appeared afterwards anyway — each written
    # by someone with no reason to know the probe existed. This makes the rule
    # enforceable rather than remembered.
    _step "Checking plan-binary resolution goes through the shared probe (721-nyev)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-plan-binary-probe-usage.sh" 2>&1; then
        _error "a script runs tillandsias-plan from a hardcoded target/ path — an executable bit is a claim, running the binary is evidence"
        exit 1
    fi
    _info "Plan-binary probe usage check passed"

    _step "Checking for fragment status transitions the fold discards..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-status-loss.sh" 2>&1; then
        _error "a fragment declares a status the fold does not apply — write a status: LWW entry instead (plan/index.d/README.md)"
        exit 1
    fi
    _info "Fragment status-loss check passed"

    # Order 698-7n6q. The sibling of the check above: that one catches a
    # fragment whose declared status the fold DISCARDS; this one catches a
    # fragment the fold cannot READ AT ALL. `tillandsias-plan check` warns about
    # the latter and exits 0, so until now an unparseable fragment could be
    # committed, gated green, and pushed — carrying packets that exist in git
    # and in no answer. Packet 697-s3by reached origin in exactly that state on
    # 2026-08-12. Diff-scoped like 634-39ik's enforcement, so a fragment
    # inherited from a sibling only warns and can never red-gate this host.
    _step "Checking that fragments added by this change parse..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-added-fragments-parse.sh" 2>&1; then
        _error "this change adds a ledger fragment the fold cannot read — its packets would be invisible to every host (plan/index.d/README.md)"
        exit 1
    fi
    _info "Added-fragment parse check passed"

    # Order 634-39ik (Tlatoāni-approved bar raise 2026-08-11). Refuse any NEWLY
    # ADDED litmus step that pins a literal source expression without a negative
    # control. Diff-scoped by construction — it can only flag steps added on
    # this branch, never the existing corpus (624-cf9f backlog), so raising the
    # bar accepts standing debt rather than redding it (the operator's
    # CRDT/Erlang posture: keep the line running, file improvement packets).
    _step "Checking for newly-added expression-pinned litmus steps (634-39ik)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-expression-pinning-added.sh" 2>&1; then
        _error "a newly-added litmus step pins a literal source expression without a negative control (634-39ik)"
        exit 1
    fi
    _info "Expression-pinning enforcement passed"

    # Order 686-7qcm criterion 3. Refuse a NEWLY ADDED fragment that records a
    # closure rung (completed/verified/done) with no evidence-bearing event —
    # the gate-time backstop to set-field's write-time --evidence requirement,
    # catching hand-authored fragments that bypass set-field. Diff-scoped, so
    # the base ledger's historical closures are never re-judged.
    _step "Checking that added fragment closures carry evidence (686-7qcm)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-closure-evidence-added.sh" 2>&1; then
        _error "this change adds a fragment recording a closure (completed/verified/done) with no evidence-bearing event (686-7qcm)"
        exit 1
    fi
    _info "Closure-evidence enforcement passed"

    # Order 614-2gqx / 651-2x5s. The durable MO-FULL attestation ledger
    # (plan/mo-full-attestations.d/) must never carry a tampered, fabricated,
    # or unreachable marker — the terminal marker is only as strong as the
    # record that outlives the transcript it was emitted into.
    _step "Checking the durable MO-FULL attestation ledger (614-2gqx)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-mo-full-attestations.sh" 2>&1; then
        _error "the MO-FULL attestation ledger records a marker that is fabricated, tampered, or unreachable (plan/mo-full-attestations.d/)"
        exit 1
    fi
    _info "MO-FULL attestation ledger check passed"

    # Order 680-zphp. Fail loud if an expert-groundtruth case pins `status:` on a
    # packet whose LIVE status is non-terminal — such a pin reds the 4-verifier
    # ratification harness on the next legitimate ledger update (it fired 3x:
    # 394d twice, 394e). Terminal pins and frozen-fixture pins are exempt.
    _step "Checking groundtruth cases for mutable-status pins (680-zphp)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-groundtruth-mutable-status-pins.sh" 2>&1; then
        _error "an expert-groundtruth case pins status on a live non-terminal packet — it will red the harness on the next ledger update (680-zphp)"
        exit 1
    fi
    _info "Groundtruth status-pin guard passed"

    # Order 440 / 599-4wzr: the status vocabulary in plan/index.yaml
    # (default_status_values) and plan/schema.yaml (statuses) must not diverge —
    # a silent divergence would let the 650-dq6u ladder and the schema disagree.
    # This guard shipped (order 440) but was ORPHANED (invoked by nothing) until
    # the guard-activation audit (599-4wzr) surfaced it; wiring it here activates
    # it as a real --check gate.
    # Order 761-g36m: a bash-4-only construct in a shared script fails on
    # Apple's bash 3.2 as a silent bad substitution or an empty verdict —
    # the class that blocked every macOS push on 2026-08-16
    # (agent-identity.sh) and emptied the windows sources verdict on
    # 2026-08-14 (723-b9cn). Scripts must be 3.2-clean, refuse loudly, or
    # carry the probed-fallback dual marker; the allowlist inside the
    # checker is a burndown list, never an escape hatch.
    # Order 309: the guest headless unit forks podman, and order 308 proved a
    # cap-stripped uid-0 podman selects ROOTLESS mode and wedges every ensure.
    # Re-adding confinement without the listener/orchestrator split reproduces
    # that outage, so the absence of those directives is now enforced rather
    # than merely true.
    _step "Checking guest headless unit hardening (309)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-guest-unit-hardening.sh" 2>&1; then
        _error "the guest headless unit carries confinement directives that wedge podman — see the verdict above (309)"
        exit 1
    fi
    _info "Guest unit hardening guard passed"

    _step "Checking scripts/ bash dialect (761-g36m)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-bash-dialect.sh" 2>&1; then
        _error "a shared script carries an unguarded bash-4-only construct — see the verdict line above (761-g36m)"
        exit 1
    fi
    _info "Bash dialect gate passed"

    _step "Checking plan/schema status-vocab divergence (440)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-plan-schema-divergence.sh" 2>&1; then
        # Do NOT restate the cause here: the script emits one of three verdicts
        # (diverges / index-load-failed / unreadable) and this wrapper used to
        # assert "vocabularies diverge" for all of them, which sent a reader to
        # diff two identical lists while the real fault was an unloadable index
        # (order 720-24u6). The verdict line above is the cause.
        _error "plan/schema status-vocab gate refused (440) — see the verdict line above"
        exit 1
    fi
    _info "Plan/schema status-vocab check passed"

    # Order 702-eusw criterion 3: a build-number VERSION bump must never be swept
    # into an unrelated commit. dd8fd63f bundled a VERSION bump into a security
    # fix via `git add -A`; the mandated linux-next merge then imported a
    # divergent VERSION the mandated pre-push gate refused, blocking the whole
    # fleet. This guard refuses any NON-MERGE outgoing commit that changes VERSION
    # alongside non-companion files (a merge inheriting VERSION is exempt — that
    # is a legitimate catch-up, order 643-64bx). A clean release-bump commit
    # (VERSION + Cargo files only) still passes.
    _step "Checking VERSION-bump isolation on outgoing commits (702-eusw)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-version-bump-isolation.sh" 2>&1; then
        _error "an outgoing commit sweeps a VERSION bump in with unrelated files — bump alone via a release/version-bump-* branch (702-eusw)"
        exit 1
    fi
    _info "VERSION-bump isolation check passed"

    # Order 714-4r6w. `SyncPodmanCommand` makes an unbounded synchronous podman
    # call a COMPILE error, which is the real guarantee; this guards the two ways
    # around the type — building a podman std::process::Command directly, and
    # growing the caller-owned-spawn escape hatch past its reviewed count.
    _step "Checking the synchronous podman surface stays bounded (714-4r6w)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-podman-sync-budgets.sh" 2>&1; then
        _error "a synchronous podman call can wait forever — route it through podman_cmd_sync()'s bounded methods (714-4r6w)"
        exit 1
    fi
    _info "Podman sync-budget check passed"

    # Order 631-wpkd. Canonical skills/ is the single source of truth and every
    # runtime reaches a skill by symlink. The layout section CLAIMED that while
    # thirteen skills lived only under .claude/skills/ — including a macOS build
    # skill invisible to every non-Claude harness. What a host can do must not
    # depend on which harness launched it, and prose could not notice it had
    # stopped being true.
    _step "Checking skills have exactly one source of truth (631-wpkd)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-skills-single-source.sh" 2>&1; then
        _error "a skill has drifted out of canonical skills/ — declare it in skills/HARNESS-SCOPED.txt or link it (631-wpkd)"
        exit 1
    fi
    _info "Skills single-source check passed"

    # Order 721-77yu. A script that says "Pinned by litmus:<name>" is making a
    # verification claim, and until this gate existed nothing checked it: the
    # fragment-parse gate carried such a line for weeks against a test that had
    # never been written. Both empty shapes fail here — a name no test declares,
    # and a test no spec binds (execution is binding-driven, so an unbound test
    # runs in no suite and is as inert as a missing one).
    _step "Checking litmus pin claims resolve and execute (721-77yu)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-pin-claims.sh" 2>&1; then
        _error "a script claims a litmus pin that cannot execute (721-77yu) — see the verdict line above"
        exit 1
    fi
    _info "Litmus pin-claim check passed"

    # Order 731-d89b. A script a caller RUNS by path must be tracked executable.
    # resolve-release-run.sh reached linux-next at mode 100644 from the Windows
    # host, so the release runbook's direct invocation of it was a permission
    # error rather than the verdict it exists to produce. Narrow by design: a
    # `bash scripts/x.sh` caller works at any mode, and sourced libraries here
    # are correctly non-executable.
    _step "Checking scripts invoked by path are executable (731-d89b)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-script-exec-bits.sh" 2>&1; then
        _error "a script is invoked by path but tracked non-executable (731-d89b) — see the verdict line above"
        exit 1
    fi
    _info "Script exec-bit check passed"

    # Order 716-f5kc. REPORT, not refusal. A Linux build of the Windows tray
    # compiles src/stubs/ and goes green without ever parsing the edited file,
    # which produced two unverified changes on 2026-08-13 alone. Refusing here
    # would strand finished work on a host whose native toolchain is blocked —
    # which the exit contract forbids more strongly than it forbids an
    # unverified commit — so the cycle is TOLD, and carries the verdict into its
    # handoff. Promotion to a refusal is an operator decision, and the moment
    # for it is when dev binaries are signed and SAC stops being a coin flip.
    _step "Reporting Windows-only source verification state (716-f5kc)..."
    _windows_only_verdict="$(bash "$SCRIPT_DIR/scripts/check-windows-only-sources-verified.sh" 2>/dev/null || echo "stale:windows-sources-check-failed")"
    case "$_windows_only_verdict" in
        ok:* | skip:*)
            _info "Windows-only sources: $_windows_only_verdict"
            ;;
        *)
            _warn "Windows-only sources: $_windows_only_verdict"
            _warn "  A Linux build compiles src/stubs/ for these — this gate did NOT read them."
            _warn "  Verify natively (cargo test -p tillandsias-windows-tray), then:"
            _warn "    scripts/check-windows-only-sources-verified.sh stamp"
            ;;
    esac

    # Record that the gate passed against THIS exact tree. The pre-push hook
    # verifies this stamp instead of re-running the whole gate: a multi-minute
    # hook gets --no-verify'd on its second use and then enforces nothing, while
    # hashing the diff costs milliseconds for the same guarantee. Push CI was
    # removed 2026-08-03, so this is the trunk's only remaining protection.
    _write_gate_stamp

    # Normal completion: cancel the abort-trap and emit exactly one success
    # record for the whole gate. (packet 682-emvg)
    trap - EXIT
    _phase_report
    # 765-dfry: flush per-phase records AFTER the printed report (report reads
    # the same log; the flush consumes it).
    _phase_emit_timing
    timing_emit build-check check "$_CHECK_T0" 0

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
