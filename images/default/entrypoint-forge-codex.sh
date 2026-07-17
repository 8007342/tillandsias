#!/usr/bin/env bash
# entrypoint-forge-codex.sh — Codex code analysis agent forge entrypoint.
#
# Lifecycle: source common -> populate hot paths -> setup CA -> find project -> banner -> exec codex
#
# @trace spec:codex-tray-launcher, spec:forge-hot-cold-split

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
export TILLANDSIAS_AGENT_NAME="OpenAI Codex"
export TILLANDSIAS_GENERATED_BY="tool=codex"
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
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "codex starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

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

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Agent binary (EVERY_LAUNCH install/update) ─────────────
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
require_codex
[ -x "$CX_BIN" ] || harness_missing_fatal codex

# API-key launches need no OAuth state. Otherwise restore the complete opaque
# Codex credential document from the scoped Vault lease mounted only for this
# agent mode; failure is loud before the TUI starts.
if [ -z "${OPENAI_API_KEY:-}" ]; then
    /usr/local/bin/codex-oauth-vault restore
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "codex"

# ── Launch Codex ────────────────────────────────────────────
# @trace plan/issues/codex-forge-yolo-defaults-2026-07-04.md (order 171)
# Full-auto inside the forge. The forge container IS the containment boundary
# (--cap-drop=ALL, --security-opt=no-new-privileges, --userns=keep-id,
# proxy-only egress on the --internal enclave network), so Codex's own approval
# prompts and inner seccomp/landlock sandbox add no meaningful security — they
# only stall unattended /meta-orchestration loops and (because the default inner
# sandbox can restrict egress) can block the agent's own network calls.
# `--dangerously-bypass-approvals-and-sandbox` is documented by Codex 0.137.0 as
# "intended solely for running in environments that are externally sandboxed",
# which is exactly this forge. Gated on TILLANDSIAS_HOST_KIND=forge so it can
# only ever engage inside the forge; a non-forge invocation keeps Codex's normal
# approval/sandbox posture. Does NOT weaken the host credential boundary (that is
# the source-mount quarantine, order 170) — it governs command execution and the
# inner sandbox only.
codex_forge_args=()
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    codex_forge_args+=(--dangerously-bypass-approvals-and-sandbox)
fi

# ── Non-interactive prompt mode (e2e smoke / unattended loops) ──
# @trace spec:codex-tray-launcher
# When the host launcher passes a prompt (TILLANDSIAS_CODEX_PROMPT, set by
# `tillandsias --codex <project> --prompt "<text>"`), run Codex HEADLESS via
# its `exec` subcommand instead of the interactive TUI — the mirror of the
# OpenCode lane's `opencode run --dangerously-skip-permissions "<prompt>"`.
# This is what lets a forge smoke agent run `/meta-orchestration` as Codex
# alongside OpenCode so their results can be compared. The bypass flag rides
# the exec subcommand (documented on `codex exec`); it stays forge-gated
# above. No TTY is claimed (the launcher already drops --interactive --tty
# for a prompt run), so a background harness never wedges in T-state.
if [ -n "${TILLANDSIAS_CODEX_PROMPT:-}" ]; then
    trace_lifecycle "entrypoint" "codex launching (non-interactive exec)"
    trace_lifecycle "exec" "launching codex exec"
    exec /usr/local/bin/codex-oauth-session -- \
        codex exec "${codex_forge_args[@]}" "$TILLANDSIAS_CODEX_PROMPT"
fi

trace_lifecycle "entrypoint" "codex launching"
trace_lifecycle "exec" "launching codex"
exec /usr/local/bin/codex-oauth-session -- codex "${codex_forge_args[@]}" "$@"
