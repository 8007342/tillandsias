#!/usr/bin/env bash
# entrypoint-terminal.sh — Maintenance terminal entrypoint.
#
# Lifecycle: source common -> install OpenSpec -> find project ->
#            openspec init -> welcome banner -> exec fish
#
# Secrets: git identity env only; GitHub token stays in git service.

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
        echo "Press any key to exit..."
        read -r -n 1 -s 2>/dev/null || true
    fi
}
trap 'exit_pause' EXIT

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "terminal starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

# ── OpenSpec + OpenCode (hard-installed) ────────────────────
# @trace spec:default-image, spec:forge-shell-tools
# Apply the opencode config overlay even in terminal mode so `opencode run`
# from a maintenance shell finds the right model + provider.
require_openspec
apply_opencode_config_overlay

# @trace plan/issues/forge-image-creation-vs-firstrun-split-research-2026-07-04.md (order 220)
# FIRST_RUN arch-aware prebuilt dev-tools + EVERY_LAUNCH agent harness update.
# Every other forge entrypoint (claude/codex/opencode/opencode-web/antigravity)
# backgrounds these; the maintenance/--bash terminal was missed when orders
# 180/181 landed, so a --bash session never got the FIRST_RUN cargo dev-tools
# (cargo-nextest, actionlint, wasmtime, marksman, dart) or the EVERY_LAUNCH
# harness set (codex/claude/opencode-ai), even though the welcome banner
# advertises the full combined tool stack. Backgrounded + fail-soft, same as
# the agent entrypoints, so it never blocks shell startup.
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

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

# ── Multi-workspace discovery ───────────────────────────────
# @trace gap:ON-006
# Discover and export sibling projects in parent directory
export_workspace_env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

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
if command -v fish &>/dev/null; then
    trace_lifecycle "exec" "launching fish"
    exec fish
else
    exec bash
fi
