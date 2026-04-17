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

# ── Package manager cache strategy ──────────────────────────
# Global installs go to the persistent cache mount, surviving container
# restarts. Project-local installs (npm install, cargo build) use the
# project directory which is also bind-mounted.
# @trace spec:forge-shell-tools
export NPM_CONFIG_PREFIX="$CACHE/npm-global"
export CARGO_HOME="$CACHE/cargo"
export GOPATH="$CACHE/go"
export PIP_USER=1
export PYTHONUSERBASE="$CACHE/pip"
export PATH="$NPM_CONFIG_PREFIX/bin:$CARGO_HOME/bin:$GOPATH/bin:$PYTHONUSERBASE/bin:$PATH"

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

# ── OpenSpec (overlay-only) ─────────────────────────────────
# @trace spec:forge-shell-tools, spec:layered-tools-overlay
# Hard requirement: the tools overlay must be mounted. Inline install
# fallback removed — if the overlay is missing, fail the entrypoint
# so the real error (overlay build failure, bad mount) is visible.
require_openspec() {
    local overlay_bin="/home/forge/.tools/openspec/bin/openspec"
    if [ ! -x "$overlay_bin" ]; then
        echo "[entrypoint] FATAL: OpenSpec not found in tools overlay at $overlay_bin" >&2
        echo "[entrypoint] The tools overlay is missing or incomplete. The host tray" >&2
        echo "[entrypoint] should have built it before launching this container." >&2
        exit 1
    fi
    export PATH="/home/forge/.tools/openspec/bin:$PATH"
    trace_lifecycle "install" "openspec: overlay ($overlay_bin)"
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
