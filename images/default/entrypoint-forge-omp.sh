#!/usr/bin/env bash
# entrypoint-forge-omp.sh — Oh My Pi forge entrypoint (order 2455-lomp).
#
# omp runs on LOCAL models only: the Lemonade Server the host serves, at
# TILLANDSIAS_LEMONADE_URL (default http://lemonade:13305/api/v1). models.yml
# names that one provider (openai-models-list discovery, no auth) and
# config.yml disables every built-in provider omp documents. No cloud
# credential reaches this forge (the launcher maps the lane to no provider).
#
# Lifecycle: source common -> hot paths -> clone/find project -> banner ->
#            install pinned omp -> generate model config -> exec omp
#
# @trace order:2455-lomp, spec:forge-hot-cold-split

FORGE_ENTRY_T0_US="${EPOCHREALTIME//[.,]/}"

source /usr/local/lib/tillandsias/lib-common.sh
source /usr/local/lib/tillandsias/lib-local-models.sh

load_agent_profile

export TILLANDSIAS_AGENT_NAME="Oh My Pi"
export TILLANDSIAS_GENERATED_BY="tool=omp"
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
# This lane refreshes only openspec in the background; omp itself is pinned
# and installed in the foreground by require_omp below.
ensure_forge_harnesses omp >>/tmp/forge-lifecycle.log 2>&1 &

trace_lifecycle "entrypoint" "omp starting"

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

# ── omp's own agent dir, no telemetry, no setup scenes ──────
export PI_CODING_AGENT_DIR="${HOME:-/home/forge}/.omp/agent"
export OTEL_SDK_DISABLED=true
export OMP_SKIP_SETUP=1
mkdir -p "$PI_CODING_AGENT_DIR" && chmod 700 "$PI_CODING_AGENT_DIR"
# Lemonade is reached directly, never through the egress proxy.
lemonade_export_no_proxy || true

forge_step_mark
inject_startup_context "$PROJECT_DIR"
forge_step_done startup-context

forge_step_mark
show_banner "omp"
forge_step_done banner

require_omp
if [ ! -x "${OMP_BIN:-}" ]; then
    trace_lifecycle "error" "omp unavailable (pinned install failed or was refused)"
    echo ""
    echo "ERROR: Oh My Pi could not be installed or verified."
    echo "  It is the pinned $OMP_REPO v$OMP_VERSION linux-x64 binary and must"
    echo "  match its pinned sha256 and SHA256SUMS.txt. See /tmp/forge-lifecycle.log."
    exit 1
fi

if ! lemonade_omp_config "$PI_CODING_AGENT_DIR"; then
    echo ""
    echo "ERROR: the Lemonade URL was refused (TILLANDSIAS_LEMONADE_URL)."
    exit 1
fi
trace_lifecycle "models" "omp: lemonade only at $(lemonade_base_url)"

forge_step_line total "$((($(_forge_now_us) - ${FORGE_ENTRY_T0_US:-$(_forge_now_us)}) / 1000))"
trace_lifecycle "exec" "launching omp"
exec "$OMP_BIN" "$@"
