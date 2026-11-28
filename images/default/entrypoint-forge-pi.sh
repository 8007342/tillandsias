#!/usr/bin/env bash
# entrypoint-forge-pi.sh — Pi coding agent forge entrypoint (order 2454-lhar).
#
# Pi runs on LOCAL models only: the Lemonade Server the host serves, at
# TILLANDSIAS_LEMONADE_URL (default http://lemonade:13305/api/v1). Pi has no
# model discovery, so models.json is generated from Lemonade's /models answer
# by lib-local-models.sh at every launch. No cloud credential reaches this
# forge (the launcher maps the lane to no provider).
#
# Lifecycle: source common -> hot paths -> clone/find project -> banner ->
#            install pinned pi -> generate model config -> exec pi
#
# @trace order:2454-lhar, spec:forge-hot-cold-split

FORGE_ENTRY_T0_US="${EPOCHREALTIME//[.,]/}"

source /usr/local/lib/tillandsias/lib-common.sh
source /usr/local/lib/tillandsias/lib-local-models.sh

load_agent_profile

export TILLANDSIAS_AGENT_NAME="Pi"
export TILLANDSIAS_GENERATED_BY="tool=pi"
export TILLANDSIAS_HOST_KIND="forge"

# Pause on error so the popup terminal stays readable (as the other lanes).
exit_pause() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -t 0 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "ERROR: forge agent launch failed (exit code: $exit_code)"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        if [ "${TILLANDSIAS_HOST_HOLDS_WINDOW:-}" != 1 ]; then
            echo "Press any key to exit..."
            read -r -n 1 -s 2>/dev/null || true
        fi
    fi
}
trap 'exit_pause' EXIT

forge_step_mark
populate_hot_paths
forge_step_done hot-paths

forge_step_mark
start_flaky_installs
forge_step_done flaky-installs
# This lane refreshes only openspec in the background; pi itself is pinned
# and installed in the foreground by require_pi below.
ensure_forge_harnesses pi >>/tmp/forge-lifecycle.log 2>&1 &

trace_lifecycle "entrypoint" "pi starting"

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

# ── Pi's own agent dir, offline ─────────────────────────────
# Its own directory, so Oh My Pi (which also reads PI_CODING_AGENT_DIR) never
# shares this config.
export PI_CODING_AGENT_DIR="${HOME:-/home/forge}/.pi/tillandsias-agent"
export PI_OFFLINE=1
mkdir -p "$PI_CODING_AGENT_DIR" && chmod 700 "$PI_CODING_AGENT_DIR"
# Lemonade is reached directly, never through the egress proxy.
lemonade_export_no_proxy || true

forge_step_mark
inject_startup_context "$PROJECT_DIR"
forge_step_done startup-context

forge_step_mark
show_banner "pi"
forge_step_done banner

require_pi
if [ ! -x "${PI_BIN:-}" ]; then
    trace_lifecycle "error" "pi unavailable (pinned install failed or was refused)"
    echo ""
    echo "ERROR: the Pi coding agent could not be installed or verified."
    echo "  It is the pinned npm package $PI_NPM_PACKAGE@$PI_VERSION and needs"
    echo "  Node >= $PI_NODE_MIN. See /tmp/forge-lifecycle.log for the refused: line."
    exit 1
fi

# ── Models: only what Lemonade serves ───────────────────────
_answer="$(mktemp /tmp/lemonade-models.XXXXXX)"
if ! lemonade_fetch_models "$_answer"; then
    trace_lifecycle "error" "lemonade unreachable at $(lemonade_base_url 2>/dev/null)"
    echo ""
    echo "ERROR: Lemonade Server did not answer at $(lemonade_base_url 2>/dev/null)/models."
    echo "  Pi uses local models only. Start Lemonade on the host and relaunch."
    exit 1
fi
if ! lemonade_pi_config "$_answer" "$PI_CODING_AGENT_DIR"; then
    echo ""
    echo "ERROR: Lemonade lists no downloaded chat or tool-calling model."
    echo "  Download one in Lemonade, then relaunch."
    exit 1
fi
rm -f "$_answer"
trace_lifecycle "models" "pi: $(jq '.providers.lemonade.models | length' "$PI_CODING_AGENT_DIR/models.json") local model(s)"

forge_step_line total "$((($(_forge_now_us) - ${FORGE_ENTRY_T0_US:-$(_forge_now_us)}) / 1000))"
trace_lifecycle "exec" "launching pi"
exec "$PI_BIN" "$@"
