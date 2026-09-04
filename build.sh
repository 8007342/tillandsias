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

# ORDER 936-kdev. A SIGTERM used to kill this script SILENTLY: two ci-full
# runs died rc=143 with every check green, and even naming the phase that was
# live took forensic log reading — the sender is still unidentified. This
# trap converts the event into one loud line (phase, pid, UTC), then
# re-raises with default disposition so rc stays 143 and process-group
# semantics are untouched. It is attribution, not protection.
trap '{
    echo "[build] SIGTERM received (pid $$) during phase: ${_PHASE_NAME:-<pre-phase>} at $(date -u +%Y-%m-%dT%H:%M:%SZ) — exiting 143 (936-kdev)" >&2
    trap - TERM
    kill -TERM $$
}' TERM

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

# When TILLANDSIAS_BUILD_LANE=container is set, route nix invocations through
# the tillandsias-builder container (images/builder/Containerfile — the one
# lineage; distro nix): /nix on a named volume so a relaunch lands warm, the
# per-host cache chroot store mounted at /host-store, and a post-build
# populate + pin (openspec/changes/nix-cache-build-lane/design.md, 790-6n2k).
# The wrapper injects per-host substituter flags when nix-cache-service.sh
# answers; a cache that is down degrades to cold, never to failure. When
# unset, byte-identical current behaviour (873-b1nx exit criterion 3).
source "$_BUILDER_DIR/scripts/with-nix-builder.sh"

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
  --test            Run test suite (cargo test --workspace --no-fail-fast,
                    plus the tray/listen-vsock feature pass)
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

# spec:dev-build "Build churn directories opt out of copy-on-write on btrfs".
# Idempotent and best-effort: `chattr +C` affects only files created after it
# is set, so this is safe on a live tree and needs no wipe; on non-btrfs the
# chattr simply fails and we stay silent. The churn these trees hold is
# rebuildable, and CoW+zstd+checksum amplification on it is what saturated
# macuahuitl's NVMe during parallel builds (2026-08-30, io full 21.6% PSI).
_ensure_nodatacow_churn_dirs() {
    local d
    for d in "$SCRIPT_DIR/target" "$HOME/.local/share/containers/storage/overlay"; do
        [[ -d "$d" ]] || continue
        [[ "$(lsattr -d "$d" 2>/dev/null | awk '{print $1}')" == *C* ]] && continue
        chattr +C "$d" 2>/dev/null || true
    done
}

_require_host_build_tools() {
    _ensure_nodatacow_churn_dirs
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
        # Remediation must name THIS host's package path (order 851-gpb5): the
        # Fedora line on a Mac strands the operator at the first --check.
        if [[ "$(uname -s)" == "Darwin" ]]; then
            _error "macOS: install the Xcode Command Line Tools for gcc (xcode-select --install),"
            _error "pkg-config via Homebrew (brew install pkg-config), and the Rust tools via"
            _error "rustup (https://rustup.rs; rustup component add rustfmt clippy). Then rerun."
        else
            _error "Install the Fedora build dependencies, then rerun this command."
        fi
        exit 1
    fi

    if [[ "$FLAG_INSTALL" == true ]]; then
        if ! command -v rustup >/dev/null 2>&1; then
            _error "Portable installs require a rustup-managed toolchain with the musl target."
            _error "Install rustup, initialize it, then add x86_64-unknown-linux-musl."
            exit 1
        fi
        # PIPESTATUS[1] (grep's verdict), not the pipeline's: with pipefail, a
        # SIGPIPE'd rustup would red this guard even when grep matched (795-imz3).
        _musl_target_rc=0
        rustup target list --installed | grep -qx 'x86_64-unknown-linux-musl' || _musl_target_rc="${PIPESTATUS[1]}"
        if [[ "$_musl_target_rc" -ne 0 ]]; then
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
    for arg in ${CI_ARG_LIST[@]+"${CI_ARG_LIST[@]}"}; do
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

    # ORDER 940-f77j — issue the PASS TOKEN that authorises the stamp.
    #
    # This function is reached only after every check passed, so reaching it IS
    # the gate's verdict. Until now that invariant lived only in this control
    # flow, while `gate-stamp.sh write` stayed callable by anyone — so a caller
    # could assert a pass the gate never granted, and on 2026-08-29 one did
    # (`./build.sh --check; scripts/gate-stamp.sh write; git push`, semicolons
    # rather than `&&`: red gate, stamped anyway, pushed).
    #
    # Emitting the token here moves the invariant out of build.sh's shell and
    # into an artifact only a green run produces. The token names the TREE it
    # covers, so it cannot vouch for a tree edited after the gate ran, and
    # gate-stamp.sh consumes it, so it cannot vouch twice.
    local _pass_token _token_digest
    _pass_token="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-gate-pass-token"
    if _token_digest="$(bash "$SCRIPT_DIR/scripts/gate-stamp.sh" compute 2>/dev/null)" \
       && [[ -n "$_token_digest" ]]; then
        {
            printf 'version 1\n'
            printf 'digest %s\n' "$_token_digest"
            printf 'dispatch %s\n' "$_stamp_dispatch"
            printf 'issued %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$_pass_token" 2>/dev/null || true
    fi

    _step "Writing the gate stamp..."
    if bash "$SCRIPT_DIR/scripts/gate-stamp.sh" write --scope full --dispatch "$_stamp_dispatch" >/dev/null 2>&1; then
        _info "Gate stamp recorded (pre-push will accept this tree)"
    else
        _warn "Could not record gate stamp — pre-push may ask you to re-run the gate"
        # Never leave a live token behind: an unconsumed token is a standing
        # authorisation to stamp this tree later, which is the thing 940-f77j
        # removes. If the stamp could not be written, the remedy is to re-run
        # the gate, not to hold a credit note for it.
        rm -f "$_pass_token" 2>/dev/null || true
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
    # 765-evbt: a staged artifact must never carry false provenance. Refuse
    # loudly if a non-artifact lane's fingerprint overrides leaked into the
    # environment.
    if [[ -n "${TILLANDSIAS_GIT_SHA_OVERRIDE:-}" ]] || [[ -n "${BUILD_COMMIT_SHA_OVERRIDE:-}" ]]; then
        _error "Fingerprint overrides must not be set during --install (TILLANDSIAS_GIT_SHA_OVERRIDE=${TILLANDSIAS_GIT_SHA_OVERRIDE:-}, BUILD_COMMIT_SHA_OVERRIDE=${BUILD_COMMIT_SHA_OVERRIDE:-})"
        _error "A staged artifact must carry real provenance. Unset the overrides and retry."
        exit 1
    fi

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
    # --no-fail-fast (order 829-g4xf) and the feature pass (order 831-wmn4).
    # Both exist because the count this prints did not mean what it said. BOTH
    # FIGURES BELOW WERE MEASURED ON MACOS (2026-08-19) and neither is this
    # host's:
    #
    #   cargo test --workspace                 -> 801 passed,  1 failed   [macOS]
    #   cargo test --workspace --no-fail-fast  -> 1911 passed, 8 failed   [macOS]
    #
    # Cargo runs test binaries sequentially and STOPS at the first one that
    # fails, so more than half the workspace never ran and seven failures were
    # invisible behind the first. A truncated run and a complete one look
    # identical except for totals nobody knows in advance.
    #
    # LINUX'S FAILURE SET IS 1, NOT 8 — and that 8 sat here unattributed until
    # 2026-08-21. Measured on THIS host at f9ee195a9, same command, complete
    # run:
    #
    #   cargo test --workspace --no-fail-fast  -> 1894 passed, 1 failed,
    #                                             10 ignored              [Linux]
    #
    # The one failure is proxy_cache_policy's
    # bumped_origin_tls_and_signed_url_logs_fail_closed (also measured red on
    # 2026-08-20 at 81d2315f5, so it predates this cycle). The other seven were
    # macOS's and arrived with that host's merge. An unattributed count in a
    # shared file is how a real Linux regression gets waved through as a
    # known-bad baseline, so every figure here names the host it came from.
    #
    # THE VERDICT IS A RATCHET, NOT CARGO'S EXIT CODE. cargo exits non-zero for
    # that one standing failure, so this dispatch was red on a clean tree and
    # its exit code carried no information about THIS change. What carries
    # information is whether the failure SET moved: a failure not named in
    # scripts/test-known-red.txt is a new regression, and a listed test that
    # PASSED is a stale entry that must be deleted. Both are red.
    #
    # PIPESTATUS, not `$?`: `cmd | tee f` returns TEE's status, and tee happily
    # succeeds while cargo is failing. The pipe costs `_run`'s phase accounting
    # for this step (the function body runs in a subshell); --test emits no
    # phase report, and a live-streamed transcript is worth more here than a
    # timing record nothing prints.
    _TEST_TRANSCRIPT="$SCRIPT_DIR/target/test-transcript-workspace.log"
    mkdir -p "$(dirname "$_TEST_TRANSCRIPT")"
    _step "Running tests..."
    _test_rc=0
    _run cargo test --workspace --no-fail-fast --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1 |
        tee "$_TEST_TRANSCRIPT" || _test_rc="${PIPESTATUS[0]}"
    if ! _test_baseline_verdict="$(bash "$SCRIPT_DIR/scripts/check-test-baseline.sh" --from "$_TEST_TRANSCRIPT")"; then
        _error "$_test_baseline_verdict"
        _error "the workspace failure set moved (cargo rc=$_test_rc) — see the named tests above; transcript: $_TEST_TRANSCRIPT"
        _error "if a failure is genuinely pre-existing, file its issue and add its key to scripts/test-known-red.txt"
        exit 1
    fi
    _info "$_test_baseline_verdict"

    # `tray` and `listen-vsock` are NOT default features, so the plain pass
    # above compiles neither `mod tray` nor `mod vsock_server` — 139 of that
    # binary's 522 tests. They are not peripheral: one is the Linux tray's
    # control socket, the other the in-VM control wire's server half. A test
    # added there runs nowhere and the suite still counts it as coverage
    # (measured 2026-08-19: two new bound tests reported "0 passed; 383
    # filtered out", indistinguishable from a filter typo).
    #
    # local-ci.sh already runs the `tray` half for exactly this reason and
    # documents it at length; it does not run `listen-vsock`, which is why
    # this pass names both.
    #
    # Deliberately NOT routed through the baseline ratchet: no known-red entry
    # lives in this pass today, so strict is both correct and stricter. If one
    # ever does, wrap it the same way rather than deleting the entry.
    _step "Running feature-gated tests (tray, listen-vsock)..."
    _run cargo test -p tillandsias-headless --bin tillandsias \
        --features tray,listen-vsock --no-fail-fast \
        --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Feature-gated tests passed"

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

    # ── Stamp memoization (order 765-tkq2) ────────────────────────────────
    #
    # `--check` runs 2-5x per cycle and the 2nd..5th are usually against an
    # identical tree: a cycle re-runs the gate after a ledger-only commit,
    # after the attestation commit, after a rebase. The gate is a pure
    # function of (tree bytes, toolchain), and the stamp already records
    # exactly that pair — so when both match a PASSING run, re-running cannot
    # produce a different verdict.
    #
    # WHY THE WHOLE GATE AND NOT THE EXPENSIVE STEPS. Memoizing individual
    # steps (clippy is ~17s of a ~20s gate) needs each step's INPUT SET —
    # which files that step's verdict depends on. The stamp makes no such
    # claim and cannot: it vouches for the tree as a whole. Inventing
    # per-step input sets here would duplicate the change-class taxonomy
    # 765-xpct is building and would be a scope claim with no verification
    # behind it. So this memo asserts exactly what the stamp already proves,
    # and nothing more; partial credit on a CHANGED tree stays with 765-xpct.
    #
    # This is the same trust pre-push already places in the stamp — it skips
    # the entire gate on a fresh one. Extending that trust to the gate's own
    # entry point is consistency, not a new assumption.
    #
    # SAFETY, in the order the failure modes matter:
    #   * only a GREEN run writes a stamp (_write_gate_stamp is reached only
    #     after every check passes), so a red gate can never be memoized;
    #   * memo-check is fail-closed on every unknown — legacy stamp, absent
    #     toolchain, scoped stamp, different dispatch, any digest drift;
    #   * combined dispatches never memoize: the guard below is the SAME
    #     "only flag" condition this block uses to decide whether to exit, so
    #     `--check --install` still runs the full gate and still installs;
    #   * TILLANDSIAS_FORCE_CHECK=1 bypasses unconditionally.
    #
    # The record is emitted as `build-check-memoized`, NOT `build-check`:
    # folding sub-second skips into the build-check series would drag
    # build_check_ms_avg down and misreport the gate's real cost, which is
    # the metric the velocity work steers by.
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CLEAN$FLAG_INSTALL$FLAG_CI$FLAG_CI_FULL$FLAG_REMOVE$FLAG_WIPE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]] &&
        [[ "${TILLANDSIAS_FORCE_CHECK:-0}" != "1" ]] &&
        [[ -f "$SCRIPT_DIR/scripts/gate-stamp.sh" ]]; then
        _memo_verdict="$(bash "$SCRIPT_DIR/scripts/gate-stamp.sh" memo-check check 2>/dev/null)" || _memo_verdict=""
        case "$_memo_verdict" in
            "ok:gate-fresh "*)
                _info "ok:gate-fresh (stamped ${_memo_verdict#ok:gate-fresh }; TILLANDSIAS_FORCE_CHECK=1 to re-run)"
                _info "  Tree bytes and toolchain are unchanged since that passing gate; nothing re-run."
                trap - EXIT
                timing_emit build-check-memoized check "$_CHECK_T0" 0 || true
                exit 0
                ;;
        esac
    fi

    # 765-evbt: export tray-crate build fingerprint overrides for non-artifact
    # lanes. These stabilize the build fingerprint across git activity during
    # --check, preventing unnecessary recompilations of downstream crates.
    # NEVER export in --install or --release — a staged artifact must carry
    # real provenance (guarded below).
    export TILLANDSIAS_GIT_SHA_OVERRIDE="non-artifact"
    export BUILD_COMMIT_SHA_OVERRIDE="non-artifact"

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

    # ── The test baseline (2026-08-20 archive-sweep regression) ───────────
    #
    # An archive sweep moved 550 packets out of plan/index.yaml. `--check` was
    # green every run, so were archive-plan-packets.sh --check (both
    # invariants), check-fragment-status-loss.sh, and two hand-written
    # acceptance assertions. Seven tests in `-p tillandsias-plan --lib` were
    # red the whole time: the expert system could no longer ANSWER about an
    # archived packet, and a real query returned `unsupported: no packet in
    # the ledger matches any token`. NONE of those gates runs cargo test — it
    # lived only in the --test dispatch, which the pre-push gate never calls.
    # It was caught by accident, taking an unrelated baseline for a pending
    # merge.
    #
    # A ledger SHAPE gate cannot see a CAPABILITY loss. So the smallest suite
    # that can is now part of the gate that runs every cycle.
    #
    # SCOPE IS DELIBERATE: `-p tillandsias-plan --lib` only, 10.4s measured in
    # this gate on 2026-08-21 (203 tests), and it is exactly where the
    # regression was — the same suite went 180/0 pre-sweep, 173/7 post-sweep
    # and 180/0 after the revert, at the 180 tests it held on 2026-08-20. The
    # FULL workspace suite stays in --test: it is minutes long and --check runs
    # 2-5x per cycle, which is how a gate gets bypassed.
    #
    # The fixture runs first (0.1s, hermetic). A ratchet that cannot go red is
    # indistinguishable from a passing one — the whole failure class this
    # block exists for — and the fixture is what proves both directions still
    # fail. Its own non-vacuity is proven by mutation, in its header.
    # Host identity seeds work selection on every host in the fleet, and its
    # two vendor-detection traps ("VGA compatible controller" contains `ati`;
    # "Non-VGA unclassified device" contains `vga`) are invisible on any single
    # box — they only misfire on hardware that machine does not have. The
    # fixture is hermetic for exactly that reason.
    # set-field writes the ledger's LWW channel, and it has now emitted
    # unparseable YAML twice from two different value shapes (832-698m's
    # colon-space, then a multi-line block scalar indented under its own key).
    # Both times it printed `ok:` and the pre-push gate was the only thing that
    # noticed. A writer that reports success while corrupting an append-only
    # record needs a fixture, not a third incident.
    # WHOLE-OVERLAY, not diff-scoped. check-added-fragments-parse.sh refuses a
    # push that ADDS an unreadable fragment, and check-fragment-status-loss.sh
    # already wrote the caveat down: a fragment damaged by MERGE is outside it.
    # On 2026-08-23 git rename detection paired two hosts' set-field fragments
    # after concurrent compactions and wrote conflict markers into both; they
    # presented as renames, so the diff-scoped gate could not see them.
    # A typo'd packet_id does not corrupt anything and does not fail anything —
    # the fold refuses the fragment, the file survives, and the record is
    # invisible. One sat here for fourteen hours being reported on every
    # compaction while three cycle reports called it a benign refusal.
    _step "Checking every fragment event lands on a real packet..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-events-land.sh" 2>&1; then
        _error "an event is attached to no packet — invisible, not merely unfolded"
        exit 1
    fi
    _info "All fragment events land"

    _step "Checking every ledger fragment is intact (whole overlay)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-all-fragments-intact.sh" 2>&1; then
        _error "a ledger fragment is damaged — append-only files are restored, not merged"
        exit 1
    fi
    _info "All fragments intact"

    _step "Checking the whole-overlay fragment guard's negative controls..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-all-fragments-intact.sh" 2>&1; then
        _error "the fragment-integrity guard cannot distinguish valid YAML, parse damage, and conflict markers"
        exit 1
    fi
    _info "Fragment-integrity fixture passed"
    _step "Checking the sanctioned YAML reader is present here (746-htj9)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-yaml-reader-availability.sh" 2>&1; then
        _error "no sanctioned YAML reader in this environment, or the load-failure verdict collapsed into the divergence verdict (720-24u6)"
        exit 1
    fi
    _info "YAML reader available and its verdicts stay distinct"


    _step "Checking set-field emits valid YAML for every value shape..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-set-field-yaml-shapes.sh" 2>&1; then
        _error "set-field can write an unparseable ledger fragment — the ledger is append-only"
        exit 1
    fi
    _info "set-field YAML-shape fixture passed"

    # ORDER 877-mynm's fixture, wired 2026-08-25. It shipped INVOKED BY NOTHING:
    # named only in a comment inside the hook it guards and in plan prose, so
    # `grep -Rl` saw the name and nothing ever ran the file. A negative control
    # nobody executes cannot protect the hole it names (calmecacpilli).
    #
    # scripts/audit-guard-activation.sh did not catch it for two reasons, both
    # worth knowing: its population is the 76 `check-*` guards, so `test-*`
    # fixtures are not audited at all; and its own source (line ~74) records that
    # it decides activation by `grep -Rl <basename>`, which cannot tell an
    # invocation from a mention. 6.2s, and it guards the plan-only fast lane —
    # the path a widening is about to make busier (889-twhe).
    # RE-WIRED 2026-08-26 after the fixture was made parity-independent
    # (d678058ea). Verified here before restoring the call, in BOTH parities:
    # ambient stamp PRESENT 11/11, ambient stamp ABSENT 11/11, stamp restored
    # afterwards. The history below is kept because the failure mode is subtle
    # and the next author should not have to rediscover it.
    #
    # WAS UNWIRED BRIEFLY, by the same host that wired it in at b5f6399cc, because
    # the fixture was NOT HERMETIC and wiring it exposed that to the trunk's only
    # gate.
    #
    # MEASURED on macuahuitl: with a valid .git/tillandsias-gate-stamp present the
    # fixture reports 8 passed / 2 failed; with the stamp removed, 10 passed / 0
    # failed. Arm 7 pipes a synthetic outgoing ref through the REAL
    # pre-push-local-gate.sh against a scratch bare repo and asserts a refusal —
    # but the hook resolves the stamp from the AMBIENT repository, finds this
    # checkout's valid stamp, and correctly accepts. The arm then reports "a real
    # outgoing ref was accepted without gating" while observing nothing but its
    # own contamination. Independently found and isolated by yoga.
    #
    # WHY THIS MATTERS MORE THAN A FLAKY TEST: the gate WRITES its stamp at the
    # END of a run, so a tree whose last gate was RED runs green and a tree whose
    # last gate was GREEN runs red. A gate that alternates on an unchanged tree
    # makes "re-run it and see" return whichever answer the parity lands on, and
    # a single green stops being evidence of anything.
    #
    # THE DEFECT IS LATENT AND PREDATES ME — the fixture landed 292ff7607
    # (877-mynm, pirria) on 2026-08-25 and was orphaned, invoked by nothing.
    # calmecacpilli was right that a negative control nobody executes cannot
    # protect the hole it names, and I was right to wire it; I was wrong not to
    # check that it was safe to EXERCISE first. Making an unexercised thing
    # exercised without verifying it is hermetic is its own instance of tonight's
    # class.
    #
    # AND THE OBVIOUS FIX WAS WRONG — recorded because it nearly shipped. Both
    # yoga and I proposed isolating the guard into the scratch repo via
    # GIT_DIR/GIT_WORK_TREE. yoga implemented it and found it makes arms 7 and 8
    # pass VACUOUSLY: in a hermetic scratch repo the guard finds no gate
    # machinery, takes its nothing-to-gate path, and accepts everything, so the
    # arms assert nothing at all. The gate would have gone green with two arms
    # measuring nothing. They reverted it.
    #
    # The arms invoke a real checkout DELIBERATELY — that is what makes them mean
    # anything. The contamination was never the real checkout; it was that the
    # STAMP's presence varies with what the host last did. So the landed fix makes
    # that variable a constant rather than hiding from it: hold the ambient stamp
    # aside for the arms that need its absence, and restore it on every exit path
    # including INT/TERM. Arm 9 (pirria's design) asserts arm 7's verdict is
    # IDENTICAL whichever way the stamp happens to be, so a future leak fails
    # loudly instead of flipping silently.
    _step "Checking the pre-push empty-ref-list fixture (877-mynm)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-pre-push-empty-ref-list.sh" 2>&1; then
        _error "the empty-ref-list lane fixture regressed — the plan-only fast lane's acceptance path is unproven"
        exit 1
    fi
    _info "pre-push empty-ref-list fixture passed"

    # TWO GUARDS THAT EXISTED, WERE BROKEN, AND WERE INVOKED BY NOTHING.
    #
    # Found by pirria 2026-09-03 by sweeping every fixture that inits a repo
    # AND drives git: 20 such fixtures, 5 of which also reference hooks, of
    # which these two FAILED. Both failed for the core.hooksPath reason — a
    # forge sets it globally, git then replaces .git/hooks outright, and a
    # fixture that installs its own hook silently measures nothing. Fourth
    # and fifth instances of that class in one day.
    #
    # THE PART THAT MATTERS MORE THAN THE FIX: neither was wired here, so a
    # forge whose gate had just gone green stayed green with two of its own
    # guards broken. A gate cannot report on a check it never invokes. This
    # is the uninvoked-guard shape audit-guard-activation exists to catch,
    # reached from the other side — not a guard an audit noticed nobody had
    # wired, but one discovered because it was ALSO broken and nothing said
    # so. An unwired guard does not merely fail to protect: it ROTS, and the
    # longer it sits the likelier it is already broken when someone wires it.
    #
    # COST, measured before deciding rather than asserted: 435 ms and 631 ms,
    # 1.07 s combined against a 109 s gate — 0.98%. pirria declined to wire
    # them because gate time is a real cost on the floor and this was a scope
    # decision rather than a side effect of their bug fix; that was right, and
    # with the number in hand it is not a close call. Note the second one pins
    # the gate STAMP scope (887-bz88) — the guard whose weakening was refused
    # hours earlier the same day, sitting unwired and broken the whole time.
    _step "Checking the credential-channel fixture (860-g798)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-check-credential-channel.sh" 2>&1; then
        _error "the credential-channel fixture regressed — the push-path guard every cycle depends on is unproven"
        exit 1
    fi
    _info "credential-channel fixture passed"

    _step "Checking the gate-stamp scope fixture (887-bz88)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-gate-stamp-scope.sh" 2>&1; then
        _error "the gate-stamp scope fixture regressed — what the stamp covers is unproven, and a too-narrow stamp once let a lost exec bit reach the trunk"
        exit 1
    fi
    _info "gate-stamp scope fixture passed"

    # The brew autoinstall shim must not re-enter itself (966-rq7f). `brew` is a
    # Ruby program and `ruby` is a shimmed tool, so an unguarded shim recurses:
    # measured at 3663 live processes on a floor forge — 89.4% of its pid
    # ceiling — from an ordinary check that merely probed for ruby, installing
    # nothing. The fixture is hermetic (a fake brew, no network, its own depth
    # stop) because a test for a fork bomb must not be one.
    _step "Checking the brew shim re-entrancy guard (966-rq7f)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-brew-shim-reentrancy.sh" 2>&1; then
        _error "the brew shim re-entrancy guard regressed — a tool probe can fork until it hits the pid ceiling"
        exit 1
    fi
    _info "brew shim re-entrancy fixture passed"

    # A cycle that attests must not refuse the checkout to its own successor
    # (899-q9di). Wired here rather than left standing because an uninvoked
    # guard is the shape audit-guard-activation exists to catch — and because
    # the defect it pins was MEASURED on this host: the hourly fire was refused
    # by pid 2393229, its own $PPID, a live harness that had already emitted a
    # valid MO-FULL. The fixture's negative controls (cases 2 and 4) are the
    # load-bearing half: they fail if the fix ever widens into "reclaim a lock",
    # which would retire 873-zcim while every positive case stayed green.
    # append-event must not write into the ARCHIVE (896-f8ti). Arms 3 and 4 are
    # the load-bearing pair: the naive fix ("refuse anything not in the base")
    # passes the refusal arms and breaks 699-usxc, the case that lets a packet
    # filed THIS cycle receive events. Falsified against the pre-fix binary —
    # arm 1 catches the acceptance, arm 3 catches the fragment it wrote.
    _step "Checking the append-event archived-refusal fixture (896-f8ti)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-append-event-archived-refusal.sh" 2>&1; then
        _error "append-event's archive guard regressed — either events are landing on completed work again, or legitimate writes to fragment-only packets are being refused"
        exit 1
    fi
    _info "append-event archived-refusal fixture passed"

    _step "Checking the checkout-lock attested-release fixture (899-q9di)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-cycle-lock-attested-release.sh" 2>&1; then
        _error "the checkout-lock attested-release fixture regressed — either a finished cycle strands its lock again, or the lock stopped refusing concurrent agents"
        exit 1
    fi
    _info "checkout-lock attested-release fixture passed"

    # The release runbook must not prescribe pushing the tag before the
    # back-merge (898-zhf3). That order is UNEXECUTABLE with the pre-push hook
    # installed — creating the tag locally is enough for the monotonicity guard
    # to resolve it as "latest release" and refuse the branch's pre-release
    # VERSION, and the back-merge that fixes it was prescribed afterwards.
    # Measured during the v0.4.260826.1 cut. The pressure at that point is
    # toward --no-verify, on the one ref where bypassing the gate ships.
    # Evidence capture must not be truncated by its own display (899-6pwv).
    # Arms 1 and 2 reproduce the two original incidents with the original
    # idioms, so if `tee|head` ever stops truncating — or the pipe-status rule
    # changes — this fails and tells us the helper's premise moved.
    _step "Checking the evidence capture helper (899-6pwv)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-capture-helper.sh" 2>&1; then
        _error "capture.sh regressed — evidence files can be silently truncated by the excerpt that displays them"
        exit 1
    fi
    _info "capture helper fixture passed"

    # `expire-claims --list-live` must NAME every in_progress packet it counts
    # (905-wjfj). The count and the rows had different sources: the summary
    # counted all in_progress, the rows came from a claim-event filter, and a
    # packet that was fresh but unclaimed fell through every bucket — observed
    # on two hosts an hour apart as `in_progress=1` with zero rows. The arm that
    # matters is the fresh-unclaimed one; it fails against the pre-fix binary.
    _step "Checking expire-claims --list-live names what it counts (905-wjfj)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-expire-claims-list-live-rows.sh" 2>&1; then
        _error "--list-live is counting in_progress packets it will not name — the sibling-overlap step built on it is blind again"
        exit 1
    fi
    _info "expire-claims --list-live rows fixture passed"

    _step "Checking the release runbook's tag/back-merge order (898-zhf3)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-release-runbook-tag-order.sh" 2>&1; then
        _error "the release runbook prescribes an order the pre-push hook refuses — the next cut deadlocks at the tag push"
        exit 1
    fi
    _info "release runbook tag-order fixture passed"

    _step "Checking the promote-stable evidence gate and dry-run..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-promote-stable-evidence-gate.sh" 2>&1; then
        _error "promote-stable's gate or its --dry-run regressed — this script flips an outward-facing release channel"
        exit 1
    fi
    _info "promote-stable gate + dry-run fixture passed"

    _step "Checking host-identity derivation..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-derive-host-identity.sh" 2>&1; then
        _error "host identity derivation is wrong — every host's work seed depends on it"
        exit 1
    fi
    _info "Host-identity fixture passed"

    _step "Checking the test-baseline ratchet's own fixture..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-check-test-baseline.sh" 2>&1; then
        _error "the test-baseline ratchet's fixture failed — the gate below cannot be trusted to go red"
        exit 1
    fi
    _info "Test-baseline fixture passed"

    # Order 843-624y. Compaction is the ONE ledger operation that can destroy:
    # everything else here is append-only. Both compaction paths used to report
    # every LOADED fragment as consumed and the caller deleted exactly that
    # list, so a fragment the fold could not absorb was removed having
    # contributed nothing. A v0.4 release-gate closure went that way
    # (9d12276ca^, order 735-6iki) and 1,144 fragment files have been deleted
    # across history with nothing distinguishing folded from eaten.
    #
    # Hermetic — the fixture builds its own ledger under mktemp and never
    # touches plan/, which matters more than usual for a test of a deleter.
    _step "Checking compaction deletes only what it folded (843-624y)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-compaction-coverage.sh" 2>&1; then
        _error "compaction would delete fragments it never folded — that is silent data loss"
        exit 1
    fi
    _info "Compaction coverage fixture passed"

    # Order 851-cduu. The instrument gate for every ledger check in this file:
    # a stale tillandsias-plan does not fail, it answers wrong (measured twice
    # on 2026-08-23 — yolanda's WSL gate cache, macuahuitl's mid-cycle pull).
    # ensure_fresh_plan_binary's point-of-use contract is what stands between
    # those checks and a binary built for another checkout; this fixture pins
    # the contract hermetically.
    _step "Checking point-of-use instrument freshness (851-cduu)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-plan-binary-freshness.sh" 2>&1; then
        _error "ensure_fresh_plan_binary broke its contract — a stale instrument could pass for HEAD"
        exit 1
    fi
    _info "Instrument freshness fixture passed"

    # Order 628-r2vk. The NEW-surface railguard: a user-visible tray surface
    # (menu id, notification, status chip, tooltip) cannot land without a
    # parity-matrix claim. The hermetic fixture pins both directions; the
    # LIVE check over the real tree is litmus:tray-new-surface-parity-gate
    # (post-build phase). Ruby-free: the check is the Rust policy binary.
    _step "Checking the new-surface parity railguard fixture (628-r2vk)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-tray-surface-parity-gate.sh" 2>&1; then
        _error "the new-surface parity railguard broke — surfaces could land rowless again"
        exit 1
    fi
    _info "New-surface parity railguard fixture passed"

    # Order 859-b2zc. Host identity must resolve WITHOUT a `hostname` binary —
    # no Fedora image this project runs ships one, so five scripts that
    # re-derived the chain inline were blind in the forge and in both WSL
    # distros. The forge case is the one that hid: `unavailable:` is the single
    # verdict that asks nobody to do anything, so the capability gate never
    # once prompted it.
    _step "Checking capability-row host resolution (859-b2zc)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-capability-row-check.sh" 2>&1; then
        _error "check-capability-row.sh cannot resolve a host without \`hostname\` — the forge goes silent again"
        exit 1
    fi
    _info "Capability-row host-resolution fixture passed"

    # Order 889-ewvt. The guard above proves the host can NAME itself. This one
    # proves the row it publishes is still TRUE: check-capability-row.sh printed
    # `ok:capability-row-reported:yoga` all night over a row advertising an
    # ollama engine the host did not have, and that false row routed the
    # authoritative release gate to a host that could not run it. A missing row
    # routes nothing; a false row routes confidently and wrongly.
    _step "Checking capability-row truth dimension (889-ewvt)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-capability-row.sh" fixture 2>&1; then
        _error "the capability-row truth fixture broke — a stale row can be consumed as a current fact again"
        exit 1
    fi
    _info "Capability-row truth fixture passed"

    # Order 823-u3k9. check-mcp-expert-health.sh launches its OWN server from
    # the registration, so it validates the FILE and reads green by construction
    # over a long-lived process running pre-fix code — measured on macuahuitl
    # 2026-08-18, where 799-j4xd's fix was in the file and not in the server the
    # session actually reached. This fixture pins the join that can see it.
    _step "Checking the live MCP server build join (823-u3k9)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-mcp-live-build.sh" fixture 2>&1; then
        _error "the live-build join broke — a stale MCP server can read healthy again"
        exit 1
    fi
    _info "Live MCP server build fixture passed"

    # Order 965-hz3f. The forge lifecycle warms the tier's SELECTED model
    # before expert-serve reports ready, so a cold VRAM load is not charged
    # against a tier budget that only ever promised inference latency
    # (measured on an RTX A5000: 7b 23353ms cold vs 938ms warm, 14b 9996ms vs
    # 1474ms — both warm figures inside Quick's 3000ms). The SELECTION is the
    # part that can be wrong silently: warming a 14b on the CPU floor would
    # recreate the very stall it removes on a GPU. Wired here so the policy
    # cannot ship as a guard nobody invokes (the 865-n8vq shape).
    _step "Checking the tier-model warm selection (965-hz3f)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-warm-tier-model.sh" 2>&1; then
        _error "the tier-model warm selection regressed — the CPU floor could be handed a model it cannot serve in-budget"
        exit 1
    fi
    _info "Tier-model warm selection fixture passed"

    # Order 448. images/default/cheatsheets/ is a TRACKED copy derived from the
    # authored tree, so an authoring commit that omits it leaves every OTHER
    # host unable to push (the v5 pre-push hook refuses) while the author's own
    # commit succeeds — three measured instances, the latest 2026-09-02. The
    # commit-time guard re-syncs into the same commit; this pins it, including
    # the mutation arm that proves the drift is real without it.
    _step "Checking the commit-time cheatsheet image sync (448)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-sync-image-cheatsheets-for-commit.sh" 2>&1; then
        _error "the commit-time cheatsheet sync regressed — an authored cheatsheet can again strand every other host's push"
        exit 1
    fi
    _info "Commit-time cheatsheet sync fixture passed"

    # Order 969-nhh7. The forge installs the pre-commit/pre-push guards into
    # the PROJECT checkout, repo-local. This fixture cannot prove a hook fires
    # (the live negative control on the packet does that); it pins the property
    # whose regression silently undoes the fix — that the guards go repo-local
    # and the GLOBAL hooks dir is left alone. A global guard fires in every
    # repo on the box, which cost six litmus suites and a red gate on
    # 2026-09-01, so the obvious implementation is the known-bad one.
    _step "Checking the forge project guard-hook install (969-nhh7)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-forge-project-guard-hooks.sh" 2>&1; then
        _error "the forge guard-hook install regressed — a forge may ship with no pre-push gate, or with a GLOBAL one that breaks every other repo"
        exit 1
    fi
    _info "Forge project guard-hook fixture passed"

    # Order 748-tkjx. ./build.sh --check runs NO litmus (deliberate — the suite
    # is minutes and a gate that slow gets bypassed with --no-verify), so a
    # green gate plus the spec you happened to run can both pass over another
    # spec's broken pin. Measured twice: an edit to images/default/lib-common.sh
    # left litmus:startup-context-addendum-shape red through both on 2026-08-15,
    # and 921-vtf4 found three tests red back to af745f3fd on 2026-08-28. This
    # fixture pins the reverse map that lets an editor ask what to re-run.
    _step "Checking the file -> covering-litmus-specs query (748-tkjx)..."
    if ! _run bash "$SCRIPT_DIR/scripts/litmus-covering-specs.sh" fixture 2>&1; then
        _error "the litmus coverage query broke — an editor of a shared file cannot learn which specs cover it"
        exit 1
    fi
    _info "Litmus coverage query fixture passed"

    # Order 925-erjs. A litmus step that asserts through `grep -A<N>` measures
    # FORMATTING: a comment inserted above the anchor reddens correct code, and
    # a window too narrow to reach the real arm greens a broken one. 25 such
    # windows across 15 tests were converted to structural ranges; the seven
    # that remain are argued in
    # openspec/litmus-tests/LINE-WINDOW-DISPOSITIONS.txt. ADVISORY, per
    # 634-39ik's recorded scope — enforcement never halts the line — but the
    # count must not silently grow back: it went from 21 to 23 in the one day
    # between filing the packet and starting it.
    _step "Reporting litmus line-window pins (925-erjs, advisory)..."
    _run bash "$SCRIPT_DIR/scripts/check-litmus-line-windows.sh" 2>&1 || true
    _info "Litmus line-window report emitted"

    # Order 928-qm8k. A groundtruth case that asserts on ANSWER PROSE has a
    # verdict that belongs to the HOST, not to the answer: measured on yoga, the
    # same query yields a synthesised sentence with inference up and the raw
    # pasted section with it down. `answer_contains: "## Direction"` therefore
    # passed on retrieval-only hosts and failed on synthesising ones — three
    # hosts, three rounds, 24 hours. This grades the whole corpus under both
    # regimes and names any case whose verdict moves. ~4s; the deterministic
    # engines never touch the network.
    _step "Checking groundtruth cases grade the same with inference up or down (928-qm8k)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-groundtruth-regime-invariance.sh" --strict 2>&1; then
        _error "a groundtruth case grades differently by inference regime — its verdict is a property of the host (928-qm8k)"
        exit 1
    fi
    _info "Groundtruth regime-invariance check passed"

    # Order 923-rmtw. containers.conf's [engine] env proxy block was written by
    # an init that could only CREATE it (its guard was a presence test), so
    # every host provisioned before 801-kqme kept a no_proxy list without
    # nix-cache — four days of phantom 883-ncrs "cache RSTs" and a broken e2e,
    # repaired BY HAND on two hosts. This fixture pins the converger that
    # removes the block and the check that would have caught the drift.
    _step "Checking the containers.conf proxy-env converger (923-rmtw)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-containers-conf-proxy-env.sh" fixture 2>&1; then
        _error "the containers.conf proxy-env check broke — a stale enclave proxy can strand fleet hosts again"
        exit 1
    fi
    _info "containers.conf proxy-env fixture passed"

    # Order 972-a8vh. --internal is what makes the enclave an enclave: without
    # it podman attaches a gateway and every member gets NAT egress, so the
    # proxy stops being the only way out. Three Rust paths passed the flag and
    # scripts/orchestrate-enclave.sh did not, so WHICH BINARY created the
    # network decided whether the isolation existed. The check covers the
    # deployed half too, because adding the flag reaches no host that already
    # has a network — creation is skipped for an existing one, so an unisolated
    # network survives every future launch (the same installed-base gap as the
    # containers.conf block above).
    _step "Checking the enclave network is internal (972-a8vh)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-enclave-network-internal.sh" source 2>&1; then
        _error "a launcher creates the enclave network without --internal — the proxy would not be the only way out"
        exit 1
    fi
    _info "Enclave network internal check passed"

    # Order 971-7muc. A ledger write that silently deletes the words it is
    # quoting, while producing valid YAML and plausible prose, is invisible to
    # every other check here — validate-yaml, the ledger check and the
    # fragment-keys guard all pass the corrupted text. Only byte-identity sees
    # it, so this asserts it directly, and its negative control reproduces the
    # shell mangling that started the order.
    _step "Checking ledger prose round-trips byte-identically (971-7muc)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-ledger-prose-roundtrip.sh" 2>&1; then
        _error "a ledger write alters the prose it was given — the record cannot be trusted to say what its author wrote"
        exit 1
    fi
    _info "Ledger prose round-trip passed"

    # The DEPLOYED half is host state, so it is REPORTED and never fatal: a
    # network created before this fix reds no build, because the repair is
    # `podman network rm`, not a code change, and failing here would make one
    # host's stale network every host's red build (699-dycj). The launcher
    # refuses to reuse it at the point where reuse would happen.
    _run bash "$SCRIPT_DIR/scripts/check-enclave-network-internal.sh" check 2>&1 || true

    # Order 923-rmtw, shell half. A pasted copy of a Rust constant stops
    # tracking its source: run-forge-project.sh and orchestrate-enclave.sh each
    # carried their own no_proxy list, both frozen at pre-801-kqme values for
    # eleven days — naming git-service after the constant dropped it, missing
    # nix-cache after it gained it. One definition now, and this gate parses
    # main.rs rather than restating the value, so the next change to
    # ENCLAVE_NO_PROXY_BASE breaks the build instead of stranding the fleet.
    _step "Checking the enclave proxy list has one definition (923-rmtw)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-enclave-proxy-lib.sh" 2>&1; then
        _error "the shell enclave proxy list drifted from ENCLAVE_NO_PROXY_BASE, or a script re-pasted it"
        exit 1
    fi
    _info "Enclave proxy list single-source check passed"

    # Order 858-ihcb. A benchmark that measures a warm prompt cache reports a
    # number that is wrong by 10x and looks plausible. This fixture inspects
    # the payloads the harness's REAL call sites put on the wire, because the
    # defect's second incarnation — a nonce counter incremented inside `$( )`,
    # which never advances in the parent — is invisible to any test that calls
    # the helper directly.
    _step "Checking bench prompt uniqueness (858-ihcb)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-bench-prompt-uniqueness.sh" 2>&1; then
        _error "bench-inference-floor.sh can reach a measured call with a reused prompt — prefill numbers would be cache hits"
        exit 1
    fi
    _info "Bench prompt-uniqueness fixture passed"

    # PIPESTATUS, not `$?` — `cmd | tee f` returns TEE's status. The verdict is
    # the ratchet's, not cargo's: a failure not in scripts/test-known-red.txt
    # is a regression, a listed test that PASSED is a stale entry, and a listed
    # test this run never built is neither (the workspace's one known-red entry
    # lives in a different binary and is simply absent here).
    # `--lib` WAS HERE UNTIL 2026-08-22, and it made this ratchet blind to the
    # binary's own tests. Two of them — the pair asserting every dispatch arm
    # and every declared capability appears in the usage text — sat RED for
    # several cycles while `--check` reported green, because a subcommand added
    # earlier in the campaign was never documented. The ratchet's whole premise
    # is that no gate ran `cargo test`; scoping it to one target recreated that
    # blind spot inside the fix. Dropping `--lib` covers the bin and integration
    # targets too, and cost ~0.0s: the bin suite is 23 assertions of pure text.
    # ORDER 1003-444f. THE GATE NOW RUNS EVERY WORKSPACE CRATE'S SUITE, and
    # names the crates whose suites produced nothing.
    #
    # It used to run exactly ONE: `-p tillandsias-plan`. Measured on yoga
    # 2026-09-04 by appending a deliberately-failing test to
    # crates/tillandsias-core/src/ca_path.rs — the crate went red
    # (`test result: FAILED. 201 passed; 1 failed`) and a forced
    # `./build.sh --check` still returned rc=0. The same log printed
    # `Checking tillandsias-core` twice: the gate COMPILED the crate and
    # stopped one step short of running its suite. The coverage gap was one
    # flag wide, not an architectural absence.
    #
    # WHY --workspace RATHER THAN A LIST OF CRATES. The comment above records
    # that scoping the ratchet to one target recreated the blind spot inside
    # the fix; a hand-maintained crate list is that mistake with more entries,
    # and it goes stale silently the day someone adds a crate. `--workspace`
    # IS the derivation: cargo enumerates the members, so a new crate is
    # covered the day it lands rather than the day someone remembers it.
    #
    # WHAT IT COST, measured before it was written rather than defended after:
    # `cargo test --workspace --no-fail-fast` is 61s on this host against a
    # warm cache, versus a 103s gate. The crates were already being COMPILED by
    # the gate, so the marginal cost is running assertions, and most of these
    # suites are pure-assertion.
    #
    # --no-fail-fast is not optional here (829-g4xf). A suite that stops at its
    # first failure hides its own tail: yolanda's windows-tray crate concealed
    # TWO stale pins that way, the second invisible because the first aborted
    # the run. Running every crate is not enough if each one stops early.
    #
    # WHAT THIS TURNED UP THE FIRST TIME IT RAN, which is the packet's own
    # argument: two red targets in tillandsias-headless, invisible to every
    # gate for as long as they had been red.
    #   proxy_cache_policy::bumped_origin_tls_and_signed_url_logs_fail_closed
    #     — already in test-known-red.txt (845-7a88), so it becomes `tolerated`
    #       rather than a surprise; it had simply never been EXERCISED.
    #   tests::foreground_git_mirror_lanes_revoke_issued_approle_accessors_on_return
    #     — a stale COUNT pin, fixed in this commit. It asserted exactly 5 CLI
    #       dispatches wrap themselves in the vault-credential cleanup; the
    #       --ensure-enclave dispatch made it 6, and the assertion's own message
    #       says "a new dispatch that wraps itself in the cleanup is compliance,
    #       not drift". Same cause as the tray-contract pin fixed at ae85ee471
    #       (1022-y7kc cause 1) — one change, two stale pins, and this one sat
    #       in a target no gate ran.
    _step "Running workspace tests (cargo test --workspace, all targets)..."
    _WS_TEST_TRANSCRIPT="$SCRIPT_DIR/target/test-transcript-workspace-gate.log"
    mkdir -p "$(dirname "$_WS_TEST_TRANSCRIPT")"
    _ws_test_rc=0
    # SERIAL, and it is not a tax. A ratchet compares FAILURE SETS, so it needs
    # the set to be a function of the tree and nothing else. Measured on yoga
    # 2026-09-04, clean tree, tillandsias-headless's bin target:
    #   parallel run 1 -> 1 failure    (the stale count pin)
    #   parallel run 2 -> 1 failure    (forge_credential_quarantine_mounts_present)
    #   parallel run 3 -> 2 failures   (count pin + forge_agent_run_args_export_debug)
    #   --test-threads=1 -> 1 failure, the count pin, every time
    # Three runs, three different sets. Those tests share process-global state
    # (the ca_path HOME race macbookair fixed in tillandsias-core is the same
    # family), so under threads the loser of the race is whichever test got
    # there second. A ratchet fed a non-deterministic set reports new-red on a
    # coin flip, and a gate that fails at random is a gate that gets switched
    # off.
    #
    # It is also FASTER here: 51.6s serial against 61s parallel, because the
    # contention these suites create costs more than the threads win. So this
    # buys determinism at negative cost on this host, and the interference is
    # filed separately — serial execution is a mitigation, not a cure, and the
    # shared state is still there for anyone who runs the suite by hand.
    _run cargo test --workspace --no-fail-fast --manifest-path "$SCRIPT_DIR/Cargo.toml" \
        -- --test-threads=1 2>&1 |
        tee "$_WS_TEST_TRANSCRIPT" || _ws_test_rc="${PIPESTATUS[0]}"
    if ! _ws_baseline_verdict="$(bash "$SCRIPT_DIR/scripts/check-test-baseline.sh" --from "$_WS_TEST_TRANSCRIPT")"; then
        _error "$_ws_baseline_verdict"
        _error "the workspace suite's failure set moved (cargo rc=$_ws_test_rc) — transcript: $_WS_TEST_TRANSCRIPT"
        _error "a ledger change every shape gate calls clean can still break what the expert system can ANSWER"
        exit 1
    fi
    _info "$_ws_baseline_verdict"

    # CRITERION 3 (1003-444f) IS SATISFIED BY --workspace, NOT BY A SECOND
    # CHECK, and the check I wrote first is deleted rather than shipped.
    #
    # I built scripts/check-workspace-test-coverage.sh to name crates whose
    # suites produced nothing. It read the transcript's `Running …
    # (target/debug/deps/<stem>-<hash>)` lines and matched <stem> against the
    # workspace member names. That premise is false: the stem is a TARGET name,
    # and target names have no reliable relation to package names.
    # tillandsias-headless declares `name = "tillandsias"`; macos-tray and
    # windows-tray BOTH declare `name = "tillandsias-tray"`; integration
    # targets are named after their file in tests/. The check duly reported
    # tillandsias-headless as silent in a run where its suite had just caught a
    # red. A check that misreports is the defect this order is about, so it is
    # gone.
    #
    # What replaces it is the structural fact, which needs no parsing: cargo
    # enumerates the workspace members itself, so with --workspace there is no
    # subset to name — every member is included by construction, and a member
    # added tomorrow is included the day it lands. A crate whose tests are
    # cfg'd out on this platform contributes `running 0 tests`, which is
    # visible in the transcript and honest: there is nothing to run here, and
    # the ratchet's ran= total (2199, from 331) is the figure that moves if
    # that stops being true.

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

    # Order 831-ezea. The sibling of the check above, on the other axis: that
    # one asks whether a fragment's CLOSURE reached the fold; this one asks
    # whether a fragment that did NOT close a packet left it resumable. The
    # loop's only blocking exit condition today is FILING A NEW ROW, so arrival
    # scales with service — every cycle adds rows and carries none forward.
    # `next_action` is the carry-forward artifact and it has had a reader since
    # 606-xu52 (answer.rs next_action_snippet -> the `next:` line of every
    # `plan next` row); without it the row hands the next agent the packet's own
    # TITLE as its next step.
    #
    # ADVISORY, NOT A GATE, AND `_run` IS DELIBERATE HERE: the script exits 0
    # even when it names fragments. Measured 2026-08-19, next_action adoption is
    # 4.6% of ready rows (17/367), so a refusal would reject essentially every
    # fragment the fleet writes tonight and would be switched off within a day —
    # and 699-dycj forbids making one host's habit every host's red build. The
    # promotion bar (>= 40% adoption) and the command that measures it are
    # recorded in the script's header; promoting it means flipping its `exit 0`
    # and adding an `_error` branch here. Its own non-zero exits (a broken
    # checkout) still red the build through the `if !` below, which is why this
    # is wired as a gate whose guard is currently unarmed rather than as a bare
    # invocation nobody would notice breaking.
    _step "Checking that open packets carry a next_action (831-ezea, advisory)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-carry-forward.sh" 2>&1; then
        _error "the carry-forward advisory could not run — that is a broken checkout, not a clean ledger"
        exit 1
    fi
    _info "Carry-forward advisory reported"

    # ORDER 751-i9mb. The closure-event pass applied to the BASE ledger, where
    # compaction puts every fragment's events. The sibling gate above scans
    # plan/index.d only, so the moment a ledger is compacted its closure events
    # move out of that gate's reach — packet 532 sat claimable with its exit
    # criterion already green while --check printed
    # ok:no-fragment-status-loss:16 checked.
    #
    # ADVISORY, on the same terms as the carry-forward line above and for the
    # same reason: a terminal event beside a non-terminal status is a QUESTION
    # for a cycle, not a fact to apply. Auto-promoting a status from an event is
    # how a false completion becomes permanent, and 532 was only closable
    # because its litmus was re-run and passed. The `if !` guards that the
    # advisory can RUN — a broken checkout is a build break; a ledger finding is
    # not.
    _step "Checking the base ledger for completions the fold hides (751-i9mb, advisory)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-base-ledger-status-loss.sh" 2>&1; then
        _error "the base-ledger status-loss advisory could not run — that is a broken checkout, not a clean ledger"
        exit 1
    fi
    _info "Base-ledger status-loss advisory reported"

    # Order 941-trcf. The fragment-overlay cost is linear in the index.d
    # backlog (~40ms of gate time per fragment per gate run, measured), so the
    # gate NAMES the backlog before it regrows to the 338 that doubled it.
    # ADVISORY on the 751-i9mb terms: a grown backlog is news for the next
    # coordination cycle, never a build break.
    _step "Checking the plan fragment backlog against the compaction cadence (941-trcf, advisory)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-backlog.sh" 2>&1; then
        _error "the fragment-backlog advisory could not run — that is a broken checkout, not a clean backlog"
        exit 1
    fi
    _info "Fragment-backlog advisory reported"

    # Order 810-k8jy. Which file classes under a corpus root the RAG indexer
    # indexes, declines, or has never been told about. ADVISORY like the
    # carry-forward line above, and for the same reason: a new file class in the
    # tree is news, not a build break, and redding the gate the first time
    # someone adds a .lock is how a check gets switched off.
    #
    # The packet's complaint was not that HCL, PowerShell and SELinux policy
    # were unindexed — it was that their absence was INVISIBLE. walk_files
    # returns "no files matched" for a class deliberately declined and for a
    # class nobody has considered, and those two silences are identical.
    # UNCLASSIFIED is the difference.
    # `cargo run -q` like the ledger-integrity step above, not a target/ path:
    # check-plan-binary-probe-usage.sh reds the build for a hardcoded
    # target/release path, and it is right to (704-zcgi). The subcommand lives
    # on the LEDGER-FREE dispatch path, so this costs a walk, not a fold.
    _step "Reporting RAG corpus coverage (810-k8jy, advisory)..."
    if ! _run cargo run -q --manifest-path "$SCRIPT_DIR/Cargo.toml" -p tillandsias-plan -- corpus-coverage >/dev/null 2>&1; then
        _error "the corpus-coverage report could not run — a broken checkout, not an unclassified tree"
        exit 1
    fi
    # Printed separately from the run above so the verdict is not swallowed by
    # a pipeline whose exit status belongs to `tail` (727-kmks, hit twice today).
    _info "$(cargo run -q --manifest-path "$SCRIPT_DIR/Cargo.toml" -p tillandsias-plan -- corpus-coverage 2>/dev/null | tail -1)"

    # Order 831-ezea, the OTHER half of the same arithmetic. Carry-forward above
    # is about SERVICE — did the cycle leave the rows it touched resumable. This
    # one is about ARRIVAL — should the rows the cycle FILED have been rows at
    # all. Arrivals measured at lambda = 2.2 + 1.80*mu, so dL/dt = a + (b-1)*mu
    # and the sign flips at b = 1: at b = 1.80 the ready queue drains at NO
    # service rate and adding hosts diverges faster. Every budget in the
    # methodology caps service; new_row_only_if_independently_schedulable is the
    # only rule that touches arrival, and until this line it was prose with no
    # checker — written by the host measured as the largest single filer.
    #
    # ADVISORY, AND ONLY HALF THE RULE — the script's header says so in its own
    # words. It checks the owned_files disjunct (reusing answer.rs
    # `owned_file_owners`, the same fold the selector uses for claim exclusion)
    # plus a normalized-equality heuristic on deliverable/title. It does NOT
    # decide the pickup_role disjunct and does not judge whether two rows are
    # really the same work; it prints both roles and leaves the call to the
    # filer. Diff-scoped to fragments this change ADDS, so an inherited row can
    # never shout at a host that did not file it (699-dycj).
    #
    # `_run` with `if !` is deliberate, exactly as above: the advisory itself
    # exits 0, so only a pass that CANNOT RUN reds the build. Promotion bar —
    # open rows carrying owned_files at >= 40%, today 0.6% (3/490) — is recorded
    # in the script header along with the clause that must never be promoted.
    _step "Checking that newly filed rows are independently schedulable (831-ezea, advisory)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-arrival-routing.sh" 2>&1; then
        _error "the arrival-routing advisory could not run — that is a broken checkout, not a clean ledger"
        exit 1
    fi
    _info "Arrival-routing advisory reported"

    # Order 831-ezea. The archiver is the ONLY bulk drain the ledger has, and
    # until this line it had ZERO call sites — so its correctness was never
    # exercised by anything. When it was finally dry-run on 2026-08-19 it
    # archived two READY rows (424, 437) into a file where they answer `no
    # packet matches`, while its own `--check` printed "script is idempotent"
    # and its freshness header cited that as evidence of soundness.
    #
    # --check now asserts the actual invariant — archiving moves TERMINAL rows,
    # so the ready set must be byte-identical across a run — and this wires it
    # to a caller. 2.0s. Gating a tool nobody invokes yet is deliberate: the
    # sweep gets its call site under R3, and the gate must predate the sweep
    # rather than be added after the first bad run.
    # ORDER 923-ws3r. The two outcomes are now separate exit codes, because the
    # merged message ("would change the ready set, OR its check could not run")
    # named both and pointed at neither — and the check spent days red on clean
    # checkouts for the second reason while its wording invited the first
    # reading. A violation means STOP. A could-not-run means the INSTRUMENT is
    # broken and this step has learned nothing about the ledger.
    _step "Checking the plan archiver preserves the ready set (831-ezea)..."
    _archiver_rc=0
    # ORDER 911-m7js. The check is LEDGER-BOUND (16-20s here, 105s on a slow
    # host, proportional to the ledger) and its inputs are exactly the ledger
    # plus the archiver itself, so its verdict is memoised on a digest of those
    # inputs (scripts/archiver-check-memo.sh). A hit repeats a verdict the same
    # bytes earned; any change to plan/index.yaml, plan/archive, a fragment,
    # the archiver, its checker or the plan binary is a miss and runs it.
    # 965-sxec: the output is TEED rather than swallowed, because the exit-3
    # branch below has to read one token out of it while the operator still
    # needs to see the whole thing. `_run` stays in the path — it carries the
    # phase timing and the cd into SCRIPT_DIR, and a capture that dropped it
    # would silently stop this step being profiled.
    _archiver_log="$(mktemp "${TMPDIR:-/tmp}/tillandsias-archiver.XXXXXX")"
    if _archiver_memo="$(bash "$SCRIPT_DIR/scripts/archiver-check-memo.sh" check 2>/dev/null)"; then
        _info "$_archiver_memo — ledger and archiver unchanged since the last pass; check not re-run"
    else
        _run bash "$SCRIPT_DIR/scripts/archive-plan-packets.sh" --check 2>&1             | tee "$_archiver_log" || true
        _archiver_rc="${PIPESTATUS[0]}"
        [ "$_archiver_rc" -eq 0 ] && bash "$SCRIPT_DIR/scripts/archiver-check-memo.sh" record >/dev/null 2>&1 || true
    fi
    if [ "$_archiver_rc" -eq 3 ]; then
        # ORDER 965-sxec. A forge ships NO ruby by design, so the archiver's
        # worker cannot run there and the whole forge lane could not reach a
        # verdict on ./build.sh --check at all — a p0 blocker, filed by an agent
        # it stopped. Named as a SKIP here rather than a failure, and the skip is
        # narrow twice over: only inside a forge, and only for the one cause the
        # script tokenises. A stale plan binary or an unreadable fragment also
        # exit 3 and still stop the gate, because those are repairable in the
        # locus that hit them and waving them through would trade a false
        # substantive verdict for a false green.
        #
        # It is LOUD on purpose. The ready set went unverified on this run; a
        # reader has to be able to see that in the log, which is the 796-4ydb
        # posture — say what was not checked rather than make one environment's
        # missing package every host's red build.
        if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]            && grep -q 'could-not-run:no-usable-ruby' "$_archiver_log" 2>/dev/null; then
            _warn "SKIPPED the plan archiver check: no usable ruby in this forge (965-sxec). The ready set was NOT verified on this run — the archiver's ruby worker never executed. This is not a statement about the ledger."
        else
            _error "the plan archiver's check COULD NOT RUN (exit 3) — this says nothing about the ready set; the instrument is what needs repair (923-ws3r)"
            exit 1
        fi
    elif [ "$_archiver_rc" -ne 0 ]; then
        _error "the plan archiver would CHANGE THE READY SET, orphan events, or leave archived rows unanswerable — do not sweep"
        exit 1
    fi
    rm -f "$_archiver_log"
    _info "Plan archiver check passed"

    # Order 965-sxec. The fixture for the branch just above. It pins the VERDICT
    # TEXT, not the exit code alone: build.sh failed either way before this, and
    # what was wrong was what it SAID — "the plan archiver would CHANGE THE READY
    # SET" on a run where the check never executed. A test that checked only the
    # code would have stayed green through the whole incident.
    _step "Checking a check that could not run never claims what it would have found (965-sxec)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-archiver-could-not-run-verdict.sh" 2>&1; then
        _error "the archiver's could-not-run path regressed (965-sxec) — a gate that cannot RUN a check must never assert what the check would have FOUND"
        exit 1
    fi
    _info "Archiver could-not-run verdict fixture passed"

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

    # Order 792-ksr8. Refuse a NEWLY ADDED pipeline whose verdict SIGPIPE can
    # decide: an unbounded producer into an early-exiting consumer, under
    # pipefail, in an if/while condition. A match then surfaces as a failure
    # whenever the producer is still writing — which is how a push-blocking
    # gate returned 1/2/3/4/5/6/13/27 violations on unchanged trees and blocked
    # four agents in one night. Diff-scoped for the same reason as 634-39ik
    # above, and here the whole-repo sweep is the ARGUMENT for it: ~50 legacy
    # sites carry the shape and nearly all are benign (producer size decides,
    # and it is not statically decidable), so a corpus-wide gate would be a
    # false-alarm generator. New code gets the safe idiom for free.
    _step "Checking for newly-added SIGPIPE-decidable verdict pipelines (792-ksr8)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-sigpipe-verdict-pipelines-added.sh" 2>&1; then
        _error "a newly-added pipeline lets SIGPIPE decide a verdict (792-ksr8)"
        exit 1
    fi
    _info "SIGPIPE verdict-pipeline enforcement passed"

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

    # Order 885-92iu. Refuse a NEWLY FILED packet whose `verifiable_closure`
    # NAMES a litmus test that cannot run — one no test declares, or one no
    # spec binds (execution is binding-driven, so an unbound test runs in no
    # suite and is as inert as a missing one). 721-77yu already caught this
    # shape in shell scripts; the ledger, where the claim carries more weight,
    # was never scanned. 795-5itp declared a closure on 2026-08-17 that existed
    # in exactly one place in the repository — that field — for eight days,
    # while three slices landed against it and this gate stayed green.
    # Diff-scoped: standing debt is REPORTED by `tillandsias-plan
    # declared-closures` (exit 0), never redded here.
    _step "Checking that added fragments' declared closures resolve (885-92iu)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-declared-closures-added.sh" 2>&1; then
        _error "this change files a packet whose verifiable_closure names a litmus test that does not exist or that no spec binds (885-92iu)"
        exit 1
    fi
    _info "Declared-closure resolution check passed"

    # ORDER 977-448j. The gate above refuses a NEW packet whose closure names a
    # test that cannot run. It never asks whether a closure exists AT ALL — so a
    # new row with no pin, or a pin that is pure prose, passed it silently, and
    # that is exactly the row the retroactive backfill could not score (977-3dee
    # measured 2.6% coverage over 600 packets).
    #
    # "Require it hard going forward" is the operator's wording, and the fleet
    # has the evidence for why a soft version is the same as none: the
    # daily-maintenance marker existed only as prose for four days, so "did the
    # gate run" had no answer and the cheapest way to satisfy it was to skip it.
    #
    # Diff-scoped to NEW rows: the standing debt (451 of 563 packets carry no
    # verifiable_closure) is NOT redded here. A gate that reds the trunk on day
    # one gets switched off.
    _step "Checking new packets carry something the scorer can read (977-448j)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-scorable-obligation-added.sh" 2>&1; then
        _error "this change files a packet with no scorable obligation — name a litmus:<test> in its verifiable_closure, or state 'unscoreable: <reason>' (977-448j)"
        exit 1
    fi
    _info "Scorable-obligation check passed"

    # ADVISORY, never a gate (885-92iu). The gate above refuses NEW debt; this
    # names the STANDING debt, every run, so it cannot go quiet the way
    # 795-5itp's closure did for eight days. Reporting on demand is not
    # reporting: a number nobody is shown is a number nobody acts on.
    if _plan_bin="$(TILLANDSIAS_PLAN_BIN="${TILLANDSIAS_PLAN_BIN:-}" bash -c '. scripts/plan-binary-probe.sh; resolve_plan_binary')" \
       && [ -n "$_plan_bin" ] \
       && "$_plan_bin" capabilities 2>/dev/null | grep -qx declared-closures; then
        _closure_debt="$("$_plan_bin" declared-closures 2>/dev/null || true)"
        case "$_closure_debt" in
            violation:*) _warn "standing declared-closure debt: $_closure_debt (see 'tillandsias-plan declared-closures'; not a gate)" ;;
        esac
    fi

    # ORDER 656-spux. Every host compiles for itself and nothing else, so
    # cfg-gated code is verified by exactly the platform that cannot exercise
    # the other arms. This builds the workspace for ONE non-host target on hosts
    # that can. It SKIPS (exit 0, one line saying why) where the rustup std or
    # the C cross-toolchain is absent — 115 MiB of mingw is not something to
    # force onto every machine as a side effect of a lint, and a check that
    # reddens a host for lacking an optional toolchain would be turned off.
    #
    # Its first run found a live break on linux-next: a `#[cfg(unix)]`
    # definition with three unguarded callers and no fallback arm, invisible to
    # every host's gate. Same shape as 653-7rag.
    _step "Cross-target workspace check (656-spux)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-cross-target-build.sh" 2>&1; then
        _error "the workspace does not compile for a non-host target (656-spux) — a cfg arm is missing a fallback"
        exit 1
    fi

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

    # Order 795-imz3. `if ! <pipeline>` verdicts invert under pipefail when the
    # consumer exits early (grep -q SIGPIPEs its producer), so the gate refuses
    # the shape outright across scripts/ and build.sh. The gate shipped in
    # 3b71b105a but was invoked by nothing here; wiring it activates it as a
    # real --check gate (same activation shape as 599-4wzr below).
    _step "Checking for if-not pipeline verdict guards (795-imz3)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-no-spawn-in-if-not.sh" 2>&1; then
        _error "a script uses 'if ! <pipeline>' as a verdict — pipefail + SIGPIPE can invert the guard; capture the exit into a variable first or mark '# sigpipe-ok: <reason>' (795-imz3)"
        exit 1
    fi
    _info "If-not pipeline guard check passed"

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

    _step "Checking the litmus step model (901-jtvi)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-litmus-step-model.sh" 2>&1; then
        _error "the litmus step model regressed — a producer's failure or its stderr can go missing again (901-jtvi)"
        exit 1
    fi
    _info "Litmus step-model fixture passed"

    _step "Checking every litmus definition parses (933-4gm8)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-yaml-parses.sh" 2>&1; then
        _error "a litmus YAML does not load — the runner's fallbacks would silently re-bucket it (933-4gm8; the named file is above)"
        exit 1
    fi
    _info "Litmus YAML parse gate passed"

    _step "Checking the nix-capability probe's evidence survives a noisy shell (917-zkge)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-probe-nix-capability-evidence.sh" 2>&1; then
        _error "a capable row can carry shell noise as its proof that nix answered (917-zkge)"
        exit 1
    fi
    _info "Probe evidence-capture guard passed"

    _step "Checking a gate stamp cannot be written unearned (940-f77j)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-gate-stamp-must-be-earned.sh" 2>&1; then
        _error "a caller can stamp a tree the gate never passed — the stamp stops meaning 'this tree is green' (940-f77j)"
        exit 1
    fi
    _info "Gate-stamp earned-only guard passed"

    _step "Checking the hardware fingerprint refuses an untrue twin claim (805-r98w)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-hardware-fingerprint.sh" 2>&1; then
        _error "the hardware fingerprint would bless two different machines as a control — every tier number keyed on it inherits the difference (805-r98w)"
        exit 1
    fi
    _info "Hardware-fingerprint gate passed"

    _step "Checking uninstall sweeps BOTH macOS app dirs..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-uninstall-sweeps-both-app-dirs.sh" 2>&1; then
        _error "uninstall would leave the app in the DEFAULT install dir while removing the LaunchAgent beside it — the app stays, nothing launches it, and the uninstaller reports success"
        exit 1
    fi
    _info "Uninstall app-dir sweep gate passed"

    _step "Checking image rebuild keeps the installed binary's launch tag (747-knbp)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-build-image-installed-version-alias.sh" 2>&1; then
        _error "an image rebuild can orphan the tag the installed binary launches by — every forge launch would be dead on arrival (747-knbp)"
        exit 1
    fi
    _info "Image-rebuild launch-tag gate passed"

    _step "Checking end-user UX strings against recorded operator approval (626-w3fn)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-approved-ux-strings.sh" 2>&1; then
        # The script names the file, the string and the ledger it failed to
        # match, and states the two remedies. spec:tray-ux makes this a
        # governance gate rather than a style one: an unapproved user-facing
        # string must not ship, and the in-file unit test cannot catch a
        # reword because a single find-and-replace edits the assertion too.
        _error "an end-user UX string is not the one the operator approved in the ledger (626-w3fn, spec:tray-ux)"
        exit 1
    fi
    _info "Approved-UX-string gate passed"

    # ORDER 1022-y7kc cause 2. An orphaned guard is fixed by INVOKING it
    # (865-n8vq): a guard with no caller on any activation surface is a file
    # that looks like protection and provides none, and audit-guard-activation
    # fails --ci-full on exactly that. Both of these are STATIC — they read
    # source and nothing else — so --check is their surface.
    # ORDER 1022-y7kc cause 2, the fifth orphan. lenovinha's guard, wired here
    # with their go-ahead: build.sh was mine while 1003-444f was open and two
    # of us editing it inside one hour is how the merge conflict earlier this
    # cycle happened.
    #
    # It refuses \t, \d, \s and \w inside a grep/grep -E pattern in a litmus
    # command, because GNU ERE does not define them. GNU grep warns "stray \
    # before t" on STDERR — which a `-q` step discards — and then matches a
    # literal `t`, so the pattern silently never matches. That is not
    # hypothetical: it is how two --by-hardware steps of mine passed every
    # standalone check and failed in the runner, and I misdiagnosed it as
    # SIGPIPE from a comment block I had just read. The divergence is silent in
    # both directions, because an interactive shell here has `grep` shadowed by
    # a ugrep wrapper that DOES interpret those escapes, so hand-verification
    # and the runner disagree without either being wrong about itself.
    #
    # STATIC and unconditional — it reads openspec/litmus-tests/*.yaml and
    # nothing else, no podman, no network, no host state — so it has no skip
    # path and cannot be green-in-name-only. Measured green on two hosts:
    # `ok:litmus-grep-escapes:421 checked` on yoga and on lenovinha at HEAD.
    #
    # Call the .sh, never scripts/lib/litmus-grep-escapes.awk: the awk holds
    # the rule but expects to be driven with the file list and is not an entry
    # point. The 8-arm fixture (scripts/test-litmus-grep-escapes.sh) is already
    # wired into local-ci.sh, so --check needs only the check itself.
    _step "Checking litmus grep patterns use no GNU-undefined escapes (901-jtvi)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-grep-escapes.sh" 2>&1; then
        exit 1
    fi

    _step "Checking the CA path has one declaration (998-3z6g)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-ca-path-literals.sh" 2>&1; then
        exit 1
    fi

    # 967-6ax6 criterion 1. Ratchets the container NAME the accel-proof
    # producers look for against the name dev-inference-ensure.sh creates. It
    # reads source only; the one `podman exec` in the file is prose describing
    # the 2026-09-02 defect, not a call, so this does not need a live enclave.
    _step "Checking the inference container name agrees across producers (967-6ax6)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-inference-container-name-agreement.sh" 2>&1; then
        exit 1
    fi

    _step "Checking user-visible terminology against the dictionary (629-t6bx)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-terminology.sh" 2>&1; then
        # The script names the file, the variant and the offending string, and
        # says the two remedies (fix the string, or add the variant to the
        # dictionary if it is correct). Do not restate a cause here — its
        # verdict distinguishes a violation from a blocked/unreadable
        # dictionary, and a wrapper that collapses those sends the reader to
        # the wrong fix.
        exit 1
    fi
    _info "Terminology gate passed"

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
    # Order 660-ryhn. The mirror image of 721-77yu: a litmus FILE nothing
    # binds never executes in any suite, and the suite prints PASS while the
    # author's assertions have run zero times. 26 files were in that state
    # when measured, security-critical ones among them. Creation-time gate:
    # retired files are exempt, historical strays are grandfathered (ratchet
    # list — deletions only), NEW unbound files refuse here.
    _step "Checking every litmus file is bound, retired, or grandfathered (660-ryhn)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-bindings.sh" 2>&1; then
        _error "a litmus file exists that no suite will ever run, or a binding names no file (660-ryhn) — see the verdict line above"
        exit 1
    fi
    _info "Litmus bindings reconciliation passed"

    # Order 875-v7hv. The runner parses step fields with bash regexes, which
    # capture the RAW bytes of a double-quoted YAML scalar, so a `\"` arrives
    # as backslash-quote and must be unescaped by hand. That unescaping was
    # applied to `command:` alone; `expected_behavior:`, `success_pattern:` and
    # `failure_pattern:` got none, so a step whose command emits a quote could
    # never match its own declared expectation. The dangerous half is
    # `failure_pattern`: one carrying `\"` silently never fires, and a step
    # that should have gone red reports green. Same family as the two gates
    # above — all three ask whether an assertion can still fail.
    _step "Checking litmus step scalars are unescaped consistently (875-v7hv)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-litmus-scalar-unescape.sh" 2>&1; then
        _error "a litmus step field bypasses yaml_unescape_dq (875-v7hv) — see the verdict line above"
        exit 1
    fi
    _info "Litmus scalar-unescape check passed"

    # 956-llei: the kill-time adjudicator must diff THIS cgroup's cpu.pressure
    # stall counter across the step's own window and say CONTENDED / NOT
    # contended / UNCLASSIFIED — never the retired host-wide load1-vs-ncpus
    # rule, which judged forge steps by the host's runqueue. Three arms, run
    # through the real runner in a temp root with injected counters.
    _step "Checking the kill-time adjudicator diffs cpu.pressure (956-llei)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-litmus-kill-adjudicator.sh" 2>&1; then
        _error "the litmus kill-time adjudicator does not classify by cpu.pressure diff (956-llei) — see the verdict line above"
        exit 1
    fi
    _info "Litmus kill-time adjudicator check passed"

    _step "Checking the accel-proof and dev-inference lanes agree on the container name (967-6ax6)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-inference-container-name-agreement.sh" 2>&1; then
        _error "the accel-proof producers and dev-inference-ensure.sh name different containers (967-6ax6) — the rung silently reads the bottom of the scale on a working host"
        exit 1
    fi
    _info "Inference-container name agreement passed"

    _step "Checking this host has the tools the gate needs (989-ykks)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-host-tools.sh" 2>&1; then
        _error "a required host tool is missing, or a required-tool claim is unfalsifiable (989-ykks) — see the verdict above"
        exit 1
    fi
    _info "Host-tools check passed"

    _step "Checking the raw frame-decode ratchet (795-5itp)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-framing-raw-decodes.sh" 2>&1; then
        _error "the framing ratchet refused (795-5itp) — a new hand-rolled u32-BE frame decode, or a baseline nobody tightened after a migration"
        exit 1
    fi
    _info "Framing ratchet passed"

    _step "Checking the stale-base revert guard (1000-rqmx)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-no-stale-base-revert.sh" 2>&1; then
        _error "the stale-base revert guard regressed (1000-rqmx) — a force push whose diff reverts untouched files would not be refused"
        exit 1
    fi
    _info "Stale-base revert guard passed"

    _step "Checking the stale-base revert guard's RECEIVING half (1001-i5ux)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-no-stale-base-revert-pre-receive.sh" 2>&1; then
        _error "the pre-receive stale-base revert guard regressed (1001-i5ux) — a fast-forward push whose merge discards the trunk would be accepted by the mirror, which --no-verify cannot be blamed for"
        exit 1
    fi
    _info "Pre-receive stale-base revert guard passed"

    # 956-llei: a `phase: retired` litmus runs only under an explicit
    # `--phase retired`; the "all" default (which --diff-scope fails closed
    # into) must skip it with the retired reason. Two arms through the real
    # runner in a temp root; the retired probe fails loudly if it ever runs.
    _step "Checking retired-phase litmus tests run only when asked for (956-llei)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-litmus-retired-phase-skip.sh" 2>&1; then
        _error "the litmus runner executes retired-phase tests under the default phase filter (956-llei) — see the verdict line above"
        exit 1
    fi
    _info "Litmus retired-phase check passed"

    # 956-llei: a litmus step that reads stdin must not swallow the rest of its
    # spec's bound test list (the instant sweep ran 1 of 29 ci-release tests
    # and reported PASS before the runner fed steps from /dev/null).
    _step "Checking a stdin-reading litmus step does not eat its spec's test list (956-llei)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-litmus-stdin-does-not-eat-the-spec-list.sh" 2>&1; then
        _error "a stdin-reading litmus step swallows the rest of its spec's test list (956-llei) — see the verdict line above"
        exit 1
    fi
    _info "Litmus stdin isolation check passed"

    # 911-m7js: the archiver-check memo hits only on an unchanged ledger AND
    # unchanged instrument; a fragment written or removed flips it.
    _step "Checking the archiver-check memo keys on the ledger and the instrument (911-m7js)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-archiver-check-memo.sh" 2>&1; then
        _error "the archiver-check memo does not miss on a ledger or instrument change (911-m7js) — see the verdict line above"
        exit 1
    fi
    _info "Archiver-check memo check passed"

    # 965-sxec: a missing or unusable ruby must read as COULD-NOT-RUN (exit 3),
    # never as a claim about the ready set. Inside a forge `command -v ruby`
    # finds a brew shim that cannot install one, exits 127, and the caller's
    # `-ne 0` arm then asserted "the plan archiver would CHANGE THE READY SET" —
    # a substantive ledger claim from a command that never executed. Wired here
    # because the defect is invisible on any host that HAS ruby, which is every
    # host that runs this gate; only the stub-PATH arms exercise it.
    _step "Checking a missing ruby reads as could-not-run, not as a ledger verdict (965-sxec)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-archiver-ruby-could-not-run.sh" 2>&1; then
        _error "an absent ruby does not route to the could-not-run channel (965-sxec) — see the verdict line above"
        exit 1
    fi
    _info "Archiver could-not-run channel check passed"

    # 964-zedm: the index builder must stage where the payload FITS. It staged
    # via the ambient TMPDIR, and in a forge /tmp is a 256 MB tmpfs while the
    # index root is on a 1.2 TB overlay — so a cold 22,645-chunk build died on
    # ENOSPC with 1.2 TB free. Wired here because the defect is invisible on any
    # host with a roomy /tmp, which is every host that runs this gate.
    _step "Checking the spec-index builder stages where the payload fits (964-zedm)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-spec-index-staging-capacity.sh" 2>&1; then
        _error "the spec-index builder stages into the ambient TMPDIR (964-zedm) — see the verdict line above"
        exit 1
    fi
    _info "Spec-index staging capacity check passed"

    # Order 881-29me. A `plan/issues/` audit cites its evidence and nothing
    # checked those citations still resolved. Measured in one document: every
    # factual claim re-verified TRUE while every `file:line` citation
    # supporting it pointed at unrelated code — total drift, not an offset,
    # because the cited file had passed 22,000 lines. A reader following one
    # lands in plausible-looking neighbouring code and can "verify" a claim
    # against something unrelated.
    #
    # A convention ratchet, NOT a resolver, and deliberately so: checking that
    # the cited file has that many lines would PASS all six drifted citations.
    # Diff-scoped, because 1,282 citations already exist across 487 files and a
    # fleet-wide refusal would flip every host red at once (699-dycj).
    _step "Checking new plan/issues citations name symbols, not lines (881-29me)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-issue-citation-convention.sh" 2>&1; then
        _error "a newly added plan/issues citation names a source LINE (881-29me) — see the verdict line above"
        exit 1
    fi
    _info "Issue-citation convention check passed"

    # Order 889-twhe. The plan-only fast lane admits NEW plan/issues captures,
    # which WIDENS what may bypass this gate — so the fixture proving each
    # boundary of that admission runs INSIDE the gate. Half a second, and a
    # negative control nothing executes cannot protect the hole it names.
    _step "Checking the issue-capture fast lane keeps its boundaries (889-twhe)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-pre-push-issue-capture-lane.sh" 2>&1; then
        _error "the plan-only lane's plan/issues admission lost a boundary (889-twhe) — see the verdict line above"
        exit 1
    fi
    _info "Issue-capture lane fixture passed"

    # Order 251 criterion LM-04. `plan/long-running.md` is declared a filtered
    # view of the ledger's active multi_cycle packets and nothing enforced it.
    # It drifted in July (caught by a human verifier, repaired by hand, bought
    # six weeks) and again by 2026-08-25, when it was right about 7 of 31
    # packets: 11 rows, four naming obsoleted packets, twenty live ones absent.
    # A 23%-accurate sub-queue steers agents toward dead work.
    #
    # Checks MEMBERSHIP, not rendering: which orders appear is derivable and is
    # what rotted; the phase / blocked-on / verification columns are editorial
    # and fabricating them would make the view more convincing and no more true.
    _step "Checking plan/long-running.md matches the live multi_cycle set (251 LM-04)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-long-running-view.sh" 2>&1; then
        _error "the long-running view disagrees with the ledger (251 LM-04) — see the verdict line above"
        exit 1
    fi
    _info "Long-running view agreement check passed"

    _step "Checking the reclaim-stranded-claims fixture (943-unii)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-reclaim-stranded-claims.sh" 2>&1; then
        _error "the stranded-claim reaper regressed (943-unii) — see the failing case above"
        exit 1
    fi
    _info "Reclaim-stranded-claims fixture passed"

    _step "Checking the stranded-sweep predicate fixture (946-pdpi)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-check-stranded-in-progress.sh" 2>&1; then
        _error "the stranded sweep's age predicate regressed (946-pdpi) — see the failing case above"
        exit 1
    fi
    _info "Stranded-sweep predicate fixture passed"

    _step "Checking the inference pull-failure classifier (525)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-inference-pull-failure-classification.sh" 2>&1; then
        _error "a TLS-trust pull failure stopped being distinguishable from an empty cache (525) — see the failing case above"
        exit 1
    fi
    _info "Inference pull-failure classifier passed"

    _step "Checking backgrounded entrypoint jobs redirect stderr (702-6jza D4)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-backgrounded-jobs-redirect-stderr.sh" 2>&1; then
        _error "a backgrounded agent-entrypoint job redirects only fd 1 — its stderr lands on a live TUI (702-6jza D4)"
        exit 1
    fi
    _info "Backgrounded-job stderr check passed"

    _step "Checking bound litmus files are RUNNABLE, not merely parseable (958-b36m)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-bound-litmus-is-runnable.sh" 2>&1; then
        _error "the bound-but-unrunnable check regressed (958-b36m) — see the failing case above"
        exit 1
    fi
    _info "Bound-litmus-runnable fixture passed"

    _step "Verifying the skew line can see a behaviour change (984-i4k2)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-expert-capability-behaviour-skew.sh" 2>&1; then
        _error "the expert-capability behaviour-skew detector regressed (984-i4k2) — see the failing case above"
        exit 1
    fi
    _info "Expert-capability behaviour-skew fixture passed"

    _step "Verifying a MO-FULL marker cannot outrun its ledger record (974-uk95)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-mo-full-record-precedes-marker.sh" 2>&1; then
        _error "the marker/ledger coupling regressed (974-uk95) — see the failing case above"
        exit 1
    fi
    _info "MO-FULL record-precedes-marker fixture passed"

    _step "Checking every spec requirement carries a unique stable id (976-suab)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-requirement-ids.sh" 2>&1; then
        _error "a spec requirement is missing a req-id or shares one (976-suab) — see the verdict line above"
        exit 1
    fi
    _info "Requirement-id check passed"

    _step "Verifying the requirement-id generator stays idempotent (976-suab)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-requirement-ids.sh" 2>&1; then
        _error "the requirement-id generator/validator fixture regressed (976-suab) — see the failing case above"
        exit 1
    fi
    _info "Requirement-id fixture passed"

    _step "Checking the credential verdict tells invalid from unreachable (995-srbf)..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-credential-verdict-script.sh" 2>&1; then
        _error "the credential verdict script stopped distinguishing a refused token from an unanswered probe (995-srbf) — a false demotion logs the operator out, a missed one holds LoggedIn against a dead token"
        exit 1
    fi
    _info "Credential verdict fixture passed"

    _step "Checking litmus steps can actually fail (972-cvdg)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-steps-can-fail.sh" 2>&1; then
        _error "a litmus step prints the same token on success and failure (972-cvdg) — see the verdict line above"
        exit 1
    fi
    _info "Litmus steps-can-fail check passed"

    _step "Checking plan fragments use keys the fold reads (944-vim8)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-fragment-keys-are-read.sh" 2>&1; then
        _error "a plan/index.d/ fragment uses a top-level key the fold discards (944-vim8) — see the verdict line above"
        exit 1
    fi
    _info "Fragment key check passed"

    _step "Checking worker and coordinator agree on the claim protocol (943-unii)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-claim-protocol-agrees.sh" 2>&1; then
        _error "the worker and coordinator skills specify different claim mechanisms (943-unii) — see the verdict line above"
        exit 1
    fi
    _info "Claim-protocol agreement check passed"

    _step "Checking the enclave membership list matches the code (245 P8)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-enclave-membership-documented.sh" 2>&1; then
        _error "an enclave attach site is undocumented, or the spec names one that is gone (245 P8) — see the verdict line above"
        exit 1
    fi
    _info "Enclave membership documentation check passed"

    _step "Checking the proxy's permissive port agrees with its consumers (245 P6)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-proxy-permissive-port-routing.sh" 2>&1; then
        _error "squid.conf and the code disagree about whether :3129 is routed (245 P6) — see the verdict line above"
        exit 1
    fi
    _info "Proxy permissive-port routing check passed"

    _step "Checking litmus pin claims resolve and execute (721-77yu)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-litmus-pin-claims.sh" 2>&1; then
        _error "a script claims a litmus pin that cannot execute (721-77yu) — see the verdict line above"
        exit 1
    fi
    _info "Litmus pin-claim check passed"

    # Order 797-8dzt. A test that slices its own source between two SYMBOL
    # NAMES silently widens when one of those symbols is renamed away:
    # `str::split` on an absent needle returns the WHOLE remainder, so the
    # window runs past its intended end and the assertion is satisfied by
    # unrelated code. Measured in remote_projects.rs — a guard bounded by
    # `fn run_command_with_timeout`, a function no longer in that file, had
    # been unable to fail for as long as the bound had been missing, and
    # deleting the exact line it protected left it green. Same family as the
    # pin-claim gate above: both ask whether an assertion can still fail.
    _step "Checking source-slice bounds still resolve (797-8dzt)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-source-slice-bounds.sh" 2>&1; then
        _error "a source-slicing test is bounded by a symbol that no longer exists (797-8dzt) — see the verdict line above"
        exit 1
    fi
    _info "Source-slice bound check passed"

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

    # Order 795-jjw3. Exactly one module may construct a `wsl.exe` child, so a
    # cross-cutting policy about wsl.exe is set once rather than N times.
    # Collapsing the duplicate constructors was a one-time edit; this check is
    # what keeps it collapsed. The previous duplication cost something real:
    # WSL_UTF8 landed at 6 of 17 call sites and the other 11 hand-scrubbed NUL
    # bytes out of UTF-16LE output, indistinguishable by grep from the
    # legitimate scrubs on hcsdiag.exe and CIM output.
    _step "Checking wsl.exe has a single constructor (795-jjw3)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-wsl-exe-single-constructor.sh" 2>&1; then
        _error "a second wsl.exe constructor appeared (795-jjw3) — see the violation lines above"
        exit 1
    fi
    _info "wsl.exe single-constructor check passed"

    # Order 803-49re. A purge that destroys the guest must also clear the host's
    # copy of that guest's Vault identity. Part A landed the clearing in ONE of
    # the two installers and the packet read as fixed; the other one went on
    # unregistering the distro and clearing nothing for six days, reproducing the
    # 2026-08-17 GitHub-login incident in full on the developer-facing path. The
    # guard is here rather than a third careful edit because "one copy fixed, one
    # copy missed" is the defect this project repeats most.
    _step "Checking every guest-destroying purge clears the host vault credentials (803-49re)..."
    if ! _run bash "$SCRIPT_DIR/scripts/check-purge-clears-vault-credentials.sh" 2>&1; then
        _error "a script unregisters the tillandsias distro without clearing the host's copy of that guest's Vault identity (803-49re) — call Clear-TillandsiasVaultHostCredentials from scripts/clear-vault-host-credentials.ps1"
        exit 1
    fi
    _info "Purge credential-clearing check passed"

    # Order 716-f5kc. REPORT, not refusal. A Linux build of the Windows tray
    # compiles src/stubs/ and goes green without ever parsing the edited file,
    # which produced two unverified changes on 2026-08-13 alone. Refusing here
    # would strand finished work on a host whose native toolchain is blocked —
    # which the exit contract forbids more strongly than it forbids an
    # unverified commit — so the cycle is TOLD, and carries the verdict into its
    # handoff. Promotion to a refusal is an operator decision, and the moment
    # for it is when dev binaries are signed and SAC stops being a coin flip.
    _step "Reporting Windows-only source verification state (716-f5kc)..."
    _windows_only_verdict="$(bash "$SCRIPT_DIR/scripts/check-windows-only-sources-verified.sh" 2>/dev/null || echo "stale:sources-check-failed:windows-only")"
    case "$_windows_only_verdict" in
        ok:* | skip:*)
            _info "Windows-only sources: $_windows_only_verdict"
            ;;
        missing:*)
            # ORDER 738-3pft. This says the REPOSITORY holds no attestation —
            # never that the sources are unverified. Reading the second meaning
            # into the first is what held a release on 2026-08-14 while the
            # Windows host had run the suite natively, twice, and stamped both
            # times into a $GIT_DIR nobody else could see.
            _warn "Windows-only sources: $_windows_only_verdict"
            _warn "  No host has committed an attestation for these yet — this is a fact about"
            _warn "  the repository, NOT a claim that the sources are broken or unverified."
            _warn "  On a Windows host: cargo test -p tillandsias-windows-tray --bins | \\"
            _warn "    scripts/check-windows-only-sources-verified.sh attest --from -"
            ;;
        *)
            _warn "Windows-only sources: $_windows_only_verdict"
            _warn "  A Linux build compiles src/stubs/ for these — this gate did NOT read them."
            _warn "  Verify natively (cargo test -p tillandsias-windows-tray), then:"
            _warn "    scripts/check-windows-only-sources-verified.sh attest --from <transcript>"
            ;;
    esac

    # ORDER 739-6r6n. The macOS twin, reported in the SAME breath as the windows
    # one — the asymmetry this closes was not a missing script, it was that one
    # platform had a loud warning and the other had SILENCE, and the silent one
    # read as healthy. Same gate, same vocabulary, same attestation format; only
    # the scope differs.
    _step "Reporting macOS-only source verification state (739-6r6n)..."
    _macos_only_verdict="$(bash "$SCRIPT_DIR/scripts/check-macos-only-sources-verified.sh" 2>/dev/null || echo "stale:sources-check-failed:macos-only")"
    case "$_macos_only_verdict" in
        ok:* | skip:*)
            _info "macOS-only sources: $_macos_only_verdict"
            ;;
        missing:*)
            # Same distinction the windows arm draws, and for the same reason:
            # this says the REPOSITORY holds no attestation, never that the
            # sources are unverified.
            _warn "macOS-only sources: $_macos_only_verdict"
            _warn "  No host has committed an attestation for these yet — this is a fact about"
            _warn "  the repository, NOT a claim that the sources are broken or unverified."
            _warn "  On a macOS host: cargo test -p tillandsias-macos-tray --bins | \\"
            _warn "    scripts/check-macos-only-sources-verified.sh attest --from -"
            ;;
        *)
            _warn "macOS-only sources: $_macos_only_verdict"
            _warn "  A Linux or Windows build compiles stubs for these — this gate did NOT read them."
            _warn "  Verify natively (cargo test -p tillandsias-macos-tray --bins), then:"
            _warn "    scripts/check-macos-only-sources-verified.sh attest --from <transcript>"
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
    # 765-evbt: a release artifact must never carry false provenance.
    if [[ -n "${TILLANDSIAS_GIT_SHA_OVERRIDE:-}" ]] || [[ -n "${BUILD_COMMIT_SHA_OVERRIDE:-}" ]]; then
        _error "Fingerprint overrides must not be set during --release (TILLANDSIAS_GIT_SHA_OVERRIDE=${TILLANDSIAS_GIT_SHA_OVERRIDE:-}, BUILD_COMMIT_SHA_OVERRIDE=${BUILD_COMMIT_SHA_OVERRIDE:-})"
        _error "A release artifact must carry real provenance. Unset the overrides and retry."
        exit 1
    fi

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
