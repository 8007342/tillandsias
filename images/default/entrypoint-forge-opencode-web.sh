#!/usr/bin/env bash
# entrypoint-forge-opencode-web.sh — OpenCode Web forge entrypoint.
#
# Lifecycle: source common -> require OpenCode + OpenSpec (hard-installed) ->
#            clone project from git mirror -> openspec init ->
#            exec opencode serve (no banner, no TTY)
#
# Secrets: git identity env only; GitHub token stays in git service.
# Unlike the CLI variant, there is no TTY and no user-facing banner —
# this entrypoint drives a headless HTTP server rendered in a host webview.
#
# @trace spec:browser-isolation-tray-integration, spec:default-image, spec:environment-runtime, spec:secrets-management, spec:simplified-tray-ux

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
# This exports AGENT_PROFILE, AGENT_SUPPORTS_WEB, and related variables
# based on the user's preferred agent (claude, opencode, opencode-web).
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers.
export TILLANDSIAS_AGENT_NAME="OpenCode"
export TILLANDSIAS_GENERATED_BY="tool=opencode"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:simplified-tray-ux
# EXIT trap: pause on error so the popup terminal stays open long enough to
# read the failure. Without this an entrypoint/exec failure closes the window
# instantly (operator repro 2026-07-12: Antigravity lane "crashed right away"
# with no readable error). Mirrors entrypoint-terminal.sh::exit_pause; a
# successful `exec <agent>` replaces the shell, so the trap never fires on
# the happy path.
exit_pause() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -t 0 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "ERROR: forge agent launch failed (exit code: $exit_code)"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        echo "Press any key to exit..."
        read -r -n 1 -s 2>/dev/null || true
    fi
}
trap 'exit_pause' EXIT

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft.
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# EVERY_LAUNCH agent harness update; backgrounded, fail-soft.
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

# @trace spec:host-browser-mcp
trace_lifecycle "entrypoint" "opencode web starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared project materialization routine. It uses a host-mounted project when
# the launcher provides one, otherwise it clones from the git mirror.
clone_project_from_mirror

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools, spec:simplified-tray-ux
require_opencode
[ -x "$OC_BIN" ] || harness_missing_fatal opencode
apply_opencode_config_overlay
require_openspec

trace_lifecycle "entrypoint" "opencode web ready"

# ── Inference probe (async-inference-launch contract) ───────
# Non-blocking probe. OpenCode will surface a provider error at the moment
# the user invokes a local-LLM action if inference isn't ready yet.
# @trace spec:async-inference-launch, spec:inference-container
if command -v curl &>/dev/null; then
    if curl -m 1 -sf "http://inference:11434/api/version" >/dev/null 2>&1; then
        trace_lifecycle "inference" "ready (probe passed)"
    else
        trace_lifecycle "inference" "not-ready (probe failed; opencode will surface provider error if you try local inference)"
    fi
fi

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
# Automatically discover and export SSH keys/agent from the host.
# This enables SSH-based git operations without manual configuration.
export_ssh_env || true

# ── Find project directory ──────────────────────────────────
find_project_dir

# ── Export project environment ───────────────────────────────
# @trace spec:forge-environment-discoverability
# Export discovery env vars: TILLANDSIAS_PROJECT_PATH, TILLANDSIAS_PROJECT_GENUS
export_project_env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools opencode </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Launch OpenCode Web Server ──────────────────────────────
# @trace spec:browser-isolation-tray-integration, spec:default-image
# OpenCode serves on loopback :4097. The local SSE/theme proxy owns :4096,
# injects the dark-theme bootstrap, strips service-worker headers, and keeps
# event streams alive for the browser-facing route.
trace_lifecycle "entrypoint" "opencode web serving behind local proxy on 0.0.0.0:4096"
trace_lifecycle "exec" "launching opencode serve upstream ($OC_BIN)"
"$OC_BIN" serve --hostname 127.0.0.1 --port 4097 &
OC_PID=$!
cleanup() {
    kill "$OC_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

export LISTEN_PORT=4096
export UPSTREAM=127.0.0.1:4097
exec /usr/local/bin/sse-keepalive-proxy.js
