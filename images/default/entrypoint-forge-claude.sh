#!/usr/bin/env bash
# entrypoint-forge-claude.sh — Claude Code forge entrypoint.
#
# Lifecycle: source common -> install/update Claude Code -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec claude
#
# Secrets: git identity env plus Claude auth; GitHub token stays in git service.

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
export TILLANDSIAS_AGENT_NAME="Claude Code"
export TILLANDSIAS_GENERATED_BY="tool=claude-code"
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

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft.
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log 2>&1 &

# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# EVERY_LAUNCH agent harness update; backgrounded, fail-soft.
ensure_forge_harnesses >>/tmp/forge-lifecycle.log 2>&1 &

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "claude-code starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

# ── Claude Code + OpenSpec (hard-installed) ────────────────
# @trace spec:default-image, spec:forge-shell-tools
require_claude
[ -x "$CC_BIN" ] || harness_missing_fatal claude-code
require_openspec

# @trace spec:forge-offline, spec:podman-secrets-integration, spec:tillandsias-vault
# API-key launches need no OAuth state. Otherwise restore the complete opaque
# Claude credential document (harvested by `tillandsias --claude-login`,
# device flow) from Vault — Codex order-339 pattern; failure is loud before
# the TUI starts and names the login command.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    TILLANDSIAS_OAUTH_PROVIDER=claude /usr/local/bin/provider-oauth-vault restore
    trace_lifecycle "credentials" "claude: OAuth document restored from vault"
else
    trace_lifecycle "credentials" "claude: API-key session (no OAuth restore)"
fi

# @trace spec:forge-environment-discoverability, order:568
# Run after OAuth restore because Claude keeps credentials and MCP registration
# in the same document. The overlay merge preserves every non-MCP field.
apply_claude_config_overlay
seed_claude_first_run_defaults
# @trace spec:default-image, order:1437-y2wu
# Pre-accept the bypass-permissions dialog (forge-gated inside the function
# itself). Must run BEFORE the approvals restore below so the live config
# already carries the consent and a stale/absent vault doc can never bring
# the dialog back.
seed_claude_bypass_consent
# Operator-approved interactive dialogs, restored from vault (2026-08-31):
# first-ever launch prompts once — those are valid prompts — the watcher
# below harvests the approval, and every later forge launch restores it.
/usr/local/bin/claude-approvals-vault restore || true

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
# Automatically discover and export SSH keys/agent from the host.
# This enables SSH-based git operations without manual configuration.
export_ssh_env || true

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── Export project environment ───────────────────────────────
# @trace spec:forge-environment-discoverability
# Export discovery env vars: TILLANDSIAS_PROJECT_PATH, TILLANDSIAS_PROJECT_GENUS
export_project_env

# ── OpenSpec init (only when absent, silent) ────────────────
# Never rewrites a committed /opsx set: a launch must not modify tracked
# files (order 1422-w3p8; see openspec_init_if_absent in lib-common.sh).
# The CLI is the project's pinned version when openspec/cli-version exists
# (order 1441-myz3; see ensure_openspec_pinned).
ensure_openspec_pinned "$PROJECT_DIR"
openspec_init_if_absent "$PROJECT_DIR" claude

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Banner ──────────────────────────────────────────────────
show_banner "claude"

# ── Launch Claude Code ──────────────────────────────────────
trace_lifecycle "entrypoint" "claude launching"
trace_lifecycle "exec" "launching claude-code ($CC_BIN)"
# Rotation harvest (Codex order-340 pattern): the session wrapper watches the
# credential file and persists refresh-token rotations back to Vault before
# --rm teardown, so the NEXT launch does not re-prompt.
export TILLANDSIAS_OAUTH_PROVIDER=claude
export TILLANDSIAS_CODEX_VAULT_HELPER=/usr/local/bin/provider-oauth-vault
# Approvals watcher: $$ becomes claude's pid at exec below, so the watch
# tracks the session itself and performs a final harvest when it exits —
# the operator's first-ever approval reaches vault within seconds.
/usr/local/bin/claude-approvals-vault watch $$ &
# Mirror of the codex full-auto gate (order 358 family; operator repro
# 2026-07-16: interactive Claude prompted for every tool call inside the
# forge — 'regular mode is too slow'). The forge IS the external sandbox
# (--cap-drop=ALL, enclave egress, credential quarantine order 170), so
# per-action permission prompts add no security and stall both attended
# and unattended sessions. Gated on TILLANDSIAS_HOST_KIND=forge so a
# non-forge invocation keeps Claude's normal permission posture.
claude_forge_args=()
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    claude_forge_args+=(--dangerously-skip-permissions)
fi
# Coordinator-minted sessions (2026-08-31): an initial prompt threaded from
# `tillandsias <project> --claude --prompt "<text>"` opens the INTERACTIVE
# session with the message already submitted — typically "report to the
# coordinator for directions" — so a fleet coordinator can launch sibling
# forge agents and direct them over the remote-control channel.
if [ -n "${TILLANDSIAS_CLAUDE_PROMPT:-}" ]; then
    claude_forge_args+=("$TILLANDSIAS_CLAUDE_PROMPT")
fi
exec /usr/local/bin/codex-oauth-session -- "$CC_BIN" "${claude_forge_args[@]}" "$@"
