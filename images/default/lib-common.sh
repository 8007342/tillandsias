#!/usr/bin/env bash
# lib-common.sh — Shared setup for all Tillandsias entrypoints.
#
# This file is SOURCED (not executed) by per-type entrypoint scripts.
# It must NOT contain `exit` or `exec` statements.
#
# Location in image: /usr/local/lib/tillandsias/lib-common.sh

set -euo pipefail

# Ensure all files created by this script and any process it execs are
# user-writable. Without this, tools running inside the container may
# create files on bind-mounted directories with restrictive modes.
umask 0022

# Kill background jobs (spinners) on signal, but do NOT call exit —
# this file is sourced by entrypoints that end with `exec`, and an
# `exit` in the EXIT trap would prevent the exec from replacing the shell.
_cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap '_cleanup' SIGTERM SIGINT
trap '_cleanup' EXIT

# ── Locale detection ─────────────────────────────────────────
# Extract the 2-letter language code from the OS locale environment.
# Priority: LC_ALL > LC_MESSAGES > LANG > LANGUAGE (POSIX standard).
_LOCALE_RAW="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
_LOCALE="${_LOCALE_RAW%%_*}"  # Strip region: "es_MX.UTF-8" -> "es_MX"
_LOCALE="${_LOCALE%%.*}"      # Strip encoding: "es.UTF-8" -> "es"
_LOCALE_FILE="/etc/tillandsias/locales/${_LOCALE}.sh"
[ -f "$_LOCALE_FILE" ] || _LOCALE_FILE="/etc/tillandsias/locales/en.sh"
# shellcheck source=/dev/null
[ -f "$_LOCALE_FILE" ] && source "$_LOCALE_FILE"
unset _LOCALE_RAW _LOCALE _LOCALE_FILE

# ── Secrets directories ─────────────────────────────────────
# Forge containers carry ZERO credentials. Git identity is the only
# artifact the forge needs on disk; the gh CLI is not wired to a token
# here — authenticated git traffic flows through the git mirror service,
# which bridges to the host OS keyring via D-Bus.
# @trace spec:secrets-management
touch ~/.gitconfig 2>/dev/null || true

# ── Shell configs ───────────────────────────────────────────
# Deploy configs from /etc/skel/ to $HOME if not already present.
for f in .bashrc .zshrc; do
    [ -f "$HOME/$f" ] || cp "/etc/skel/$f" "$HOME/$f" 2>/dev/null || true
done
mkdir -p "$HOME/.config/fish"
[ -f "$HOME/.config/fish/config.fish" ] || \
    cp "/etc/skel/.config/fish/config.fish" "$HOME/.config/fish/config.fish" 2>/dev/null || true

# ── Common PATH setup ───────────────────────────────────────
CACHE="$HOME/.cache/tillandsias"
export PATH="$CACHE/openspec/bin:$HOME/.local/bin:$PATH"

# ── External-logs consumer path ─────────────────────────────
# @trace spec:external-logs-layer
# Canonical path where external logs from enclave service containers are
# mounted RO inside forge/maintenance containers. Tools (tillandsias-logs,
# agent scripts) that want the path without shelling out to the CLI can
# reference this env var directly.
# Producer containers see their own role subdir here (RW); consumers see
# the full parent dir (RO). The var is always exported for consistency —
# on non-consumer containers the directory may not be mounted.
export TILLANDSIAS_EXTERNAL_LOGS="/var/log/tillandsias/external"

# ── Lifecycle tracing ───────────────────────────────────────
# Structured trace output for --log-environment-lifecycle troubleshooting.
# Format: [lifecycle] <phase> | <detail>
trace_lifecycle() {
    # Only emit lifecycle traces when TILLANDSIAS_DEBUG is set.
    # In production, these clutter the terminal (stderr shares the display).
    [ -n "${TILLANDSIAS_DEBUG:-}" ] || return 0
    local phase="$1"
    shift
    echo "[lifecycle] $phase | $*" >&2
}

# ── Package manager cache strategy (dual-cache architecture) ──────
# @trace spec:forge-cache-architecture, spec:forge-cache-dual, spec:forge-shell-tools
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
#
# Per-project cache lives at /home/forge/.cache/tillandsias-project/
# (RW bind-mount from the host's per-project cache directory). Built
# artifacts that are expensive to rebuild for THIS project go here.
# Project A's container CANNOT see project B's cache.
#
# Shared cache lives at /nix/store/ (RO bind-mount from the host's
# nix store). Single entry point: nix flakes only — other tools never
# write here. See runtime/forge-shared-cache-via-nix.md for why.
#
# Project workspace (/home/forge/src/<project>/) is for SOURCE only —
# build artifacts redirect via the env vars below to the per-project
# cache. Treat /tmp/ and unmounted ~/.<dotdirs> as ephemeral scratch.
PROJECT_CACHE="/home/forge/.cache/tillandsias-project"

# @tombstone superseded:forge-cache-architecture — kept for three releases
# (until 0.1.169.232). Old paths pointed at $CACHE/<lang>/ which was the
# cheatsheets-cache mount, NOT bind-mounted to the host. Every container
# restart re-downloaded everything for every language. Verified pre-fix
# in the planner's PLAN-from-java-audits.md cache discipline audit.
#
# OLD (removed in this change):
# export NPM_CONFIG_PREFIX="$CACHE/npm-global"
# export CARGO_HOME="$CACHE/cargo"
# export GOPATH="$CACHE/go"
# export PIP_USER=1
# export PYTHONUSERBASE="$CACHE/pip"

# Cargo
export CARGO_HOME="$PROJECT_CACHE/cargo"
export CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target"

# Go
export GOPATH="$PROJECT_CACHE/go"
export GOMODCACHE="$PROJECT_CACHE/go/pkg/mod"

# Maven (note: MAVEN_OPTS is the standard knob; -Dmaven.repo.local is the property name)
export MAVEN_OPTS="-Dmaven.repo.local=$PROJECT_CACHE/maven ${MAVEN_OPTS:-}"

# Gradle
export GRADLE_USER_HOME="$PROJECT_CACHE/gradle"

# Flutter / Dart pub cache (overrides the image-baked /opt/flutter/.pub-cache
# which is read-only image-state for shared Flutter SDK files; per-project
# packages flow through here instead)
export PUB_CACHE="$PROJECT_CACHE/pub"

# npm — note the unusual env var name (npm uses lowercase with underscores)
export npm_config_cache="$PROJECT_CACHE/npm"
export NPM_CONFIG_PREFIX="$PROJECT_CACHE/npm/global"

# Yarn (classic and berry both honor this)
export YARN_CACHE_FOLDER="$PROJECT_CACHE/yarn"

# pnpm
export PNPM_HOME="$PROJECT_CACHE/pnpm"

# uv (Astral's pip replacement)
export UV_CACHE_DIR="$PROJECT_CACHE/uv"

# pip (per-project; pipx tools live in /opt/pipx, image-state)
export PIP_CACHE_DIR="$PROJECT_CACHE/pip"

# PATH augmentation for per-project binaries (cargo install, go install,
# npm -g into PROJECT_CACHE/npm/global)
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PNPM_HOME:$PATH"

# ── Update-check rate-limiting ──────────────────────────────
# Returns 0 (true) if the last check was more than 24 hours ago or never ran.
needs_update_check() {
    local stamp_file="$1"
    if [ ! -f "$stamp_file" ]; then
        return 0
    fi
    local now last_check age
    now="$(date +%s)"
    last_check="$(cat "$stamp_file" 2>/dev/null || echo 0)"
    age=$(( now - last_check ))
    # 86400 seconds = 24 hours
    [ "$age" -ge 86400 ]
}

record_update_check() {
    local stamp_file="$1"
    mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
    date +%s > "$stamp_file"
}

# ── Find project directory ──────────────────────────────────
# Sets PROJECT_DIR to the first directory found in ~/src/.
# Entrypoints can cd into it after sourcing this library.
find_project_dir() {
    PROJECT_DIR=""
    for dir in "$HOME/src"/*/; do
        [ -d "$dir" ] && PROJECT_DIR="$dir" && break
    done
    # The for-loop's exit code is the last body command's exit code.
    # When the glob matches nothing, [ -d "$dir" ] fails (exit 1) and
    # the function would propagate that to the caller — fatal under set -e.
    return 0
}

# ── Progress indicator ──────────────────────────────────────
# @trace spec:install-progress
# Usage: spin "message" command [args...]
# Prints a status message, runs the command, prints dots while waiting.
# Uses newline-based output (no \r) to avoid PTY buffering issues on
# Windows terminals attached through podman.
spin() {
    local msg="$1"; shift
    printf '  %s' "$msg" >&2
    local spin_pid
    ( trap 'exit 0' TERM
      while true; do
          sleep 2
          printf '.' >&2
      done ) &
    spin_pid=$!
    local rc=0
    "$@" </dev/null >/dev/null 2>&1 || rc=$?
    kill "$spin_pid" 2>/dev/null; wait "$spin_pid" 2>/dev/null
    echo "" >&2
    return $rc
}

# ── Coding agents (hard-installed in image) ─────────────────
# @trace spec:default-image, spec:forge-shell-tools
# OpenCode, Claude Code, and OpenSpec are baked into /opt/agents/ at image
# build time and symlinked into /usr/local/bin/ — see images/default/Containerfile.
# These helpers verify presence and export the canonical bin path each
# entrypoint needs. Failure here means the image is corrupt; bail loudly.
require_opencode() {
    OC_BIN="/usr/local/bin/opencode"
    if [ ! -x "$OC_BIN" ]; then
        echo "[entrypoint] FATAL: OpenCode missing at $OC_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "opencode: hard-installed ($OC_BIN)"
}

require_claude() {
    CC_BIN="/usr/local/bin/claude"
    if [ ! -x "$CC_BIN" ]; then
        echo "[entrypoint] FATAL: Claude Code missing at $CC_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "claude-code: hard-installed ($CC_BIN)"
}

require_openspec() {
    OS_BIN="/usr/local/bin/openspec"
    if [ ! -x "$OS_BIN" ]; then
        echo "[entrypoint] FATAL: OpenSpec missing at $OS_BIN — forge image is corrupt" >&2
        exit 1
    fi
    trace_lifecycle "install" "openspec: hard-installed ($OS_BIN)"
}

# ── OpenCode config overlay ─────────────────────────────────
# @trace spec:opencode-web-session, spec:layered-tools-overlay
# The Containerfile bakes a minimal stub at ~/.config/opencode/config.json
# (just `{ "autoupdate": false }`). Replace it with the host-mounted overlay
# so MCPs, instructions, dark theme, and the enclave-local ollama baseURL
# all take effect. Without this step the stub wins and OpenCode reports
# "Model not found" because the provider list is empty. Idempotent.
apply_opencode_config_overlay() {
    local overlay_cfg="/home/forge/.config-overlay/opencode/config.json"
    local overlay_tui="/home/forge/.config-overlay/opencode/tui.json"
    local user_cfg="/home/forge/.config/opencode/config.json"
    local user_tui="/home/forge/.config/opencode/tui.json"
    mkdir -p "$(dirname "$user_cfg")"
    if [ -f "$overlay_cfg" ]; then
        cp -f "$overlay_cfg" "$user_cfg"
        trace_lifecycle "config" "opencode config overlay applied"
    fi
    if [ -f "$overlay_tui" ]; then
        cp -f "$overlay_tui" "$user_tui"
    fi
}

# ── Hot-path population ─────────────────────────────────────
# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Called once at container start, AFTER the podman --tmpfs mounts are in
# place (those are established by the kernel before the entrypoint runs).
# Copies /opt/cheatsheets-image/ (RO image lower layer baked at build time)
# into /opt/cheatsheets/ (tmpfs hot mount, 8MB cap) so every agent read is
# RAM-served rather than overlayfs-backed.
#
# Idempotent: re-running on an already-populated tmpfs is harmless.
# Silent failure: 2>/dev/null || true means a missing source or mount point
# doesn't abort the entrypoint.
populate_hot_paths() {
    if [ -d /opt/cheatsheets-image ] && [ -d /opt/cheatsheets ]; then
        cp -a /opt/cheatsheets-image/. /opt/cheatsheets/ 2>/dev/null || true
        trace_lifecycle "hot-paths" "cheatsheets copied to tmpfs (/opt/cheatsheets)"
    else
        trace_lifecycle "hot-paths" "skipped: /opt/cheatsheets-image or /opt/cheatsheets not found"
    fi
}

# ── Banner ──────────────────────────────────────────────────
show_banner() {
    local agent_name="${1:-terminal}"
    # Use locale-aware strings if available, fall back to English.
    local banner_forge="${L_BANNER_FORGE:-tillandsias forge}"
    local banner_project="${L_BANNER_PROJECT:-project:}"
    local banner_agent="${L_BANNER_AGENT:-agent:}"
    echo ""
    echo "========================================"
    echo "  $banner_forge"
    echo "  $banner_project $(basename "$(pwd)")"
    echo "  $banner_agent $agent_name"
    echo "========================================"
    echo ""
}
