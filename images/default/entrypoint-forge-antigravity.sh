#!/usr/bin/env bash
# entrypoint-forge-antigravity.sh — Antigravity agent forge entrypoint.
#
# Lifecycle: source common -> populate hot paths -> setup CA -> find project -> banner -> exec agy
#
# @trace spec:forge-hot-cold-split

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers.
export TILLANDSIAS_AGENT_NAME="Google Antigravity"
export TILLANDSIAS_GENERATED_BY="tool=antigravity"
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
# Refresh every provider harness on each forge launch.  The updater is
# idempotent and fail-soft; require_antigravity below remains the primary
# lane's actionable gate when no cached binary exists.
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "antigravity starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
clone_project_from_mirror

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
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

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Banner ──────────────────────────────────────────────────
show_banner "antigravity"

# ── Ensure the Antigravity CLI (agy) — EVERY_LAUNCH, latest ─────
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# require_antigravity lives in lib-common.sh (shared with the --agy-login
# ephemeral login container; operator repro 2026-07-15).
if ! require_antigravity; then
    trace_lifecycle "error" "agy not found on PATH after 3 install attempts"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "ERROR: Antigravity CLI (agy) could not be installed."
    echo ""
    echo "The installer failed after 3 attempts. Common causes:"
    echo "  - Forge proxy does not allow antigravity.google domains"
    echo "  - Network timeout during installer download"
    echo ""
    echo "To fix: ensure the forge proxy egress allowlist includes"
    echo "  antigravity-cli-auto-updater-*.us-central1.run.app"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    exit 1
fi

# ── Forge bypass: auto-approve permissions without prompting ───
# `--dangerously-skip-permissions` is documented by agy --help as the
# non-interactive / skip-approvals flag, analogous to OpenCode's
# `--dangerously-skip-permissions` and Codex's
# `--dangerously-bypass-approvals-and-sandbox`. Gated on
# TILLANDSIAS_HOST_KIND=forge so it only activates inside the already-
# sandboxed forge container. Verified against `agy --help` on 2026-07-06.
agy_forge_args=()
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    agy_forge_args+=(--dangerously-skip-permissions)
fi

# ── Credentials ─────────────────────────────────────────────
# @trace spec:tillandsias-vault
# API-key launches need no OAuth state. Otherwise restore the opaque agy
# credential from Vault (harvested by `tillandsias --agy-login`). Upstream
# antigravity-cli issue #479: the FILE token store can be write-only for
# fresh headless processes, so the restore also materializes an
# ANTIGRAVITY_TOKEN env file (the sanctioned headless channel) which we
# source before exec — both channels populated.
if [ -z "${GEMINI_API_KEY:-}" ]; then
    TILLANDSIAS_OAUTH_PROVIDER=antigravity /usr/local/bin/provider-oauth-vault restore
    # shellcheck disable=SC1091
    [ -f /tmp/agy-token.env ] && . /tmp/agy-token.env
    trace_lifecycle "credentials" "antigravity: OAuth restored (file + ANTIGRAVITY_TOKEN env)"
else
    trace_lifecycle "credentials" "antigravity: API-key session (no OAuth restore)"
fi

# ── Launch Antigravity ──────────────────────────────────────
trace_lifecycle "entrypoint" "antigravity launching"
trace_lifecycle "exec" "launching agy"
export TILLANDSIAS_OAUTH_PROVIDER=antigravity
export TILLANDSIAS_CODEX_VAULT_HELPER=/usr/local/bin/provider-oauth-vault
exec /usr/local/bin/codex-oauth-session -- agy "${agy_forge_args[@]}" "$@"
