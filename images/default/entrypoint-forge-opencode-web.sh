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

# 2004-in3v: the start of the forge-entry-total span (bash 5 in the image).
FORGE_ENTRY_T0_US="${EPOCHREALTIME//[.,]/}"

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
# This exports AGENT_PROFILE, AGENT_SUPPORTS_WEB, and related variables
# based on the user's preferred agent (claude, opencode, opencode-web).
load_agent_profile   # lib-common; 1517-p83m (the /opt path never existed)

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
        # 1457-r8yi: when the host holds the window (tillandsias --hold-window
        # passes TILLANDSIAS_HOST_HOLDS_WINDOW=1 by name), it asks for the one
        # keypress; pausing here too asked for two. Other lanes (macOS, Windows,
        # an operator's own terminal) do not set it and still pause here.
        if [ "${TILLANDSIAS_HOST_HOLDS_WINDOW:-}" != 1 ]; then
            echo "Press any key to exit..."
            read -r -n 1 -s 2>/dev/null || true
        fi
    fi
}
trap 'exit_pause' EXIT

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft. Started by
# start_flaky_installs below (order 1951-vv5m).
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# EVERY_LAUNCH agent harness update; backgrounded, fail-soft.
ensure_forge_harnesses >>/tmp/forge-lifecycle.log 2>&1 &

# @trace spec:host-browser-mcp
trace_lifecycle "entrypoint" "opencode web starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:wsl-runtime
# Shared project materialization routine. It uses a host-mounted project when
# the launcher provides one, otherwise it clones from the git mirror.
forge_step_mark
clone_project_from_mirror
forge_step_done clone

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools, spec:simplified-tray-ux
forge_step_mark
require_opencode
forge_step_done require-harness
[ -x "$OC_BIN" ] || harness_missing_fatal opencode
forge_step_mark
apply_opencode_config_overlay
forge_step_done config-overlay
forge_step_mark
require_openspec
forge_step_done require-openspec
forge_step_mark
prepare_opencode_vault_auth
forge_step_done vault-auth
forge_step_mark
opencode_actual_auth_ok "$OC_BIN"
forge_step_done auth-check

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
forge_step_mark
find_project_dir
forge_step_done find-project

# ── Export project environment ───────────────────────────────
# @trace spec:forge-environment-discoverability
# Export discovery env vars: TILLANDSIAS_PROJECT_PATH, TILLANDSIAS_PROJECT_GENUS
forge_step_mark
export_project_env
forge_step_done project-env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
forge_step_mark
configure_git_identity
forge_step_done git-identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (only when absent, silent) ────────────────
# Never rewrites a committed /opsx set: a launch must not modify tracked
# files (order 1422-w3p8; see openspec_init_if_absent in lib-common.sh).
# The CLI is the project's pinned version when openspec/cli-version exists
# (order 1441-myz3; see ensure_openspec_pinned).
forge_step_mark
ensure_openspec_pinned "$PROJECT_DIR"
forge_step_done openspec-pin
# Flaky-optional installs (dev tools, prebuilt tools) run in
# the background with status files and first-use shims (order 1951-vv5m).
forge_step_mark
start_flaky_installs
forge_step_done flaky-installs
forge_step_mark
openspec_init_if_absent "$PROJECT_DIR" opencode
forge_step_done openspec-init

# ── Host lane before the agent (order 1863-eckw) ────────────
# OpenCode spawns its host-browser MCP client once, at serve start, and never
# retries; wait for the lane socket so that one attempt meets a listener, and
# record the verdict in the startup context below.
wait_for_lane_socket 10

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
forge_step_mark
inject_startup_context "$PROJECT_DIR"
forge_step_done startup-context

# ── Launch OpenCode Web Server ──────────────────────────────
# @trace spec:browser-isolation-tray-integration, spec:default-image
# OpenCode serves on loopback :4097. The local SSE/theme proxy owns :4096,
# injects the dark-theme bootstrap, strips service-worker headers, and keeps
# event streams alive for the browser-facing route.
trace_lifecycle "entrypoint" "opencode web serving behind local proxy on 0.0.0.0:4096"
trace_lifecycle "exec" "launching opencode serve upstream ($OC_BIN)"
forge_step_line total "$((($(_forge_now_us) - ${FORGE_ENTRY_T0_US:-$(_forge_now_us)}) / 1000))"
"$OC_BIN" serve --hostname 127.0.0.1 --port 4097 &
OC_PID=$!
cleanup() {
    kill "$OC_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

export LISTEN_PORT=4096
export UPSTREAM=127.0.0.1:4097
exec /usr/local/bin/sse-keepalive-proxy.js
