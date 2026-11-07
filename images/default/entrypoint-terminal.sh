#!/usr/bin/env bash
# entrypoint-terminal.sh — Maintenance terminal entrypoint.
#
# Lifecycle: source common -> install OpenSpec -> find project ->
#            openspec init -> welcome banner -> exec fish
#
# Secrets: git identity env only; GitHub token stays in git service.

# 2004-in3v: the start of the forge-entry-total span (bash 5 in the image).
FORGE_ENTRY_T0_US="${EPOCHREALTIME//[.,]/}"

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:forge-git-identity-anonymization
# Terminal entrypoint is human-driven; set agent attribution to empty so
# the prepare-commit-msg hook is a no-op unless an agent session is active.
export TILLANDSIAS_AGENT_NAME=""
export TILLANDSIAS_GENERATED_BY="tool=terminal"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:simplified-tray-ux
# EXIT trap: pause on error so user can read git cloning errors before terminal closes
exit_pause() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -t 0 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "ERROR: Terminal startup failed (exit code: $exit_code)"
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

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
forge_step_mark
populate_hot_paths
forge_step_done hot-paths

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "terminal starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
forge_step_mark
clone_project_from_mirror
forge_step_done clone

# ── OpenSpec + OpenCode (hard-installed) ────────────────────
# @trace spec:default-image, spec:forge-shell-tools
# Apply the opencode config overlay even in terminal mode so `opencode run`
# from a maintenance shell finds the right model + provider.
forge_step_mark
require_openspec
forge_step_done require-openspec
forge_step_mark
apply_opencode_config_overlay
forge_step_done config-overlay

# @trace plan/issues/forge-image-creation-vs-firstrun-split-research-2026-07-04.md (order 220)
# FIRST_RUN arch-aware prebuilt dev-tools + EVERY_LAUNCH agent harness update.
# Every other forge entrypoint (claude/codex/opencode/opencode-web/antigravity)
# backgrounds these; the maintenance/--bash terminal was missed when orders
# 180/181 landed, so a --bash session never got the FIRST_RUN cargo dev-tools
# (cargo-nextest, actionlint, wasmtime, marksman, dart) or the EVERY_LAUNCH
# harness set (codex/claude/opencode-ai), even though the welcome banner
# advertises the full combined tool stack. Backgrounded + fail-soft, same as
# the agent entrypoints, so it never blocks shell startup. The prebuilt
# dev-tools start with start_flaky_installs below (order 1951-vv5m).
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

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

# ── Multi-workspace discovery ───────────────────────────────
# @trace gap:ON-006
# Discover and export sibling projects in parent directory
forge_step_mark
export_workspace_env
forge_step_done workspace-env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
forge_step_mark
configure_git_identity
forge_step_done git-identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# Order 534: terminal is a first-class forge lane and needs the same truthful
# base, expert-source, inference, and experts verdict as every agent lane.
forge_step_mark
inject_startup_context "$PROJECT_DIR"
forge_step_done startup-context

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
openspec_init_if_absent "$PROJECT_DIR"
forge_step_done openspec-init

# ── Multi-workspace quick-switch menu ──────────────────────
# @trace gap:ON-006
# Display available sibling projects and provide quick-switch function
if [ "$TILLANDSIAS_WORKSPACE_COUNT" -gt 0 ]; then
    echo ""
    echo "Available projects in $(dirname "$TILLANDSIAS_PROJECT_PATH"):"
    IFS=':' read -ra projects <<< "$TILLANDSIAS_SIBLING_PROJECTS"
    for proj in "${projects[@]}"; do
        echo "  • $proj"
    done
    echo ""
    echo "Quick switch: switch-project <name>"
    echo ""
fi

# ── Welcome banner ──────────────────────────────────────────
# Use the dedicated welcome script if available (shows mount info, tips).
WELCOME_SCRIPT="/usr/local/share/tillandsias/forge-welcome.sh"
if [ -x "$WELCOME_SCRIPT" ]; then
    "$WELCOME_SCRIPT" || true
else
    show_banner "terminal"
fi

# Prevent fish's config.fish from showing the welcome banner again.
export TILLANDSIAS_WELCOME_SHOWN=1

# ── Launch shell ────────────────────────────────────────────
trace_lifecycle "entrypoint" "terminal launching"
forge_step_line total "$((($(_forge_now_us) - ${FORGE_ENTRY_T0_US:-$(_forge_now_us)}) / 1000))"
if command -v fish &>/dev/null; then
    trace_lifecycle "exec" "launching fish"
    exec fish
else
    exec bash
fi
