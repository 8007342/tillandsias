#!/usr/bin/env bash
# entrypoint-forge-copilot.sh — GitHub Copilot CLI agent forge entrypoint (order 2063-nfag).
#
# Lifecycle: source common -> populate hot paths -> setup CA -> find project -> banner -> exec copilot
#
# @trace spec:forge-hot-cold-split

# 2004-in3v: the start of the forge-entry-total span (bash 5 in the image).
FORGE_ENTRY_T0_US="${EPOCHREALTIME//[.,]/}"

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
load_agent_profile   # lib-common; 1517-p83m (the /opt path never existed)

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers.
export TILLANDSIAS_AGENT_NAME="GitHub Copilot"
export TILLANDSIAS_GENERATED_BY="tool=copilot"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:simplified-tray-ux
# EXIT trap: pause on error so the popup terminal stays open long enough to
# read the failure. Without this an entrypoint/exec failure closes the window
# instantly (operator repro 2026-07-12: a lane "crashed right away"
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

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
forge_step_mark
populate_hot_paths
forge_step_done hot-paths

forge_step_mark
start_flaky_installs
forge_step_done flaky-installs
# Refresh the shared harnesses for THIS lane only (openspec). copilot itself
# is fetched in the foreground by require_copilot below (2063-nfag), so no
# other lane ever refreshes it and this lane refreshes no other.
ensure_forge_harnesses copilot >>/tmp/forge-lifecycle.log 2>&1 &

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "copilot starting"

# @trace spec:git-mirror-service, spec:forge-offline
forge_step_mark
clone_project_from_mirror
forge_step_done clone

export_ssh_env || true

forge_step_mark
find_project_dir
forge_step_done find-project

forge_step_mark
export_project_env
forge_step_done project-env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
forge_step_mark
configure_git_identity
forge_step_done git-identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── Copilot state in RAM ────────────────────────────────────
# COPILOT_HOME holds copilot's config, its sign-in file and sessions. It lives
# on /dev/shm (RAM), so nothing copilot writes reaches disk.
export COPILOT_HOME="${COPILOT_HOME:-/dev/shm/copilot-home}"
mkdir -p "$COPILOT_HOME" && chmod 700 "$COPILOT_HOME"

forge_step_mark
inject_startup_context "$PROJECT_DIR"
forge_step_done startup-context

forge_step_mark
show_banner "copilot"
forge_step_done banner

# ── The copilot CLI: upstream latest, verified twice (2063-nfag) ─
require_copilot
if [ ! -x "${COPILOT_BIN:-}" ]; then
    trace_lifecycle "error" "copilot CLI unavailable (no verified release and no last-good)"
    echo ""
    echo "ERROR: the GitHub Copilot CLI could not be installed or verified."
    echo "  It is fetched from github.com/github/copilot-cli releases and must"
    echo "  match both the published digest and SHA256SUMS.txt. Check the forge"
    echo "  log (/tmp/forge-lifecycle.log) for the refused: line."
    exit 1
fi

# ── Credentials ─────────────────────────────────────────────
# @trace spec:tillandsias-vault
# Restore the copilot sign-in (archived by `tillandsias --copilot-login`) from
# secret/copilot/oauth, which only this lane's Vault policy can read, into the
# RAM COPILOT_HOME. Without it the lane stops and names the operator's
# sign-in: copilot's own /login would leave the token in a file we did not
# put in Vault.
if ! TILLANDSIAS_OAUTH_PROVIDER=copilot /usr/local/bin/provider-oauth-vault restore; then
    trace_lifecycle "credentials" "copilot: no sign-in in Vault"
    echo ""
    echo "GitHub Copilot is not signed in for this host."
    echo "  The operator signs in once with: tillandsias --copilot-login"
    echo "  (or the tray's Copilot sign-in item); the sign-in is kept in Vault."
    exit 1
fi
trace_lifecycle "credentials" "copilot: sign-in restored from Vault"

# Trust the checkout so copilot does not ask before working in it (merged
# into the restored config, never replacing it), then the MCP servers.
_cfg="$COPILOT_HOME/config.json"
[ -s "$_cfg" ] || echo '{}' > "$_cfg"
if jq --arg a /home/forge/src --arg b "${PROJECT_DIR:-/home/forge/src}" \
    '.trustedFolders = (((.trustedFolders // []) + [$a, $b]) | unique)' "$_cfg" > "$_cfg.tmp"; then
    chmod 600 "$_cfg.tmp" && mv -f "$_cfg.tmp" "$_cfg"
else
    rm -f "$_cfg.tmp"
fi
apply_copilot_config_overlay || true

copilot_args=(--no-auto-update --disable-builtin-mcps)
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    copilot_args+=(--yolo)
fi

trace_lifecycle "entrypoint" "copilot launching"
forge_step_line total "$((($(_forge_now_us) - ${FORGE_ENTRY_T0_US:-$(_forge_now_us)}) / 1000))"
trace_lifecycle "exec" "launching copilot"
# The session wrapper harvests a rotated sign-in back to Vault while copilot
# runs, and once more when it exits (the antigravity lane's pattern).
export TILLANDSIAS_OAUTH_PROVIDER=copilot
export TILLANDSIAS_CODEX_VAULT_HELPER=/usr/local/bin/provider-oauth-vault
exec /usr/local/bin/codex-oauth-session -- "$COPILOT_BIN" "${copilot_args[@]}" "$@"
