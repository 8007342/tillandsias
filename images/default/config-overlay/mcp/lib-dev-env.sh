#!/usr/bin/env bash
# Shared MCP-server environment hook: bare-metal DEVELOPMENT ENVIRONMENT vs
# forge USER RUNTIME ENVIRONMENT.
# @trace spec:layered-tools-overlay, spec:inference-container, order:718-nkm2
#
# WHY THIS EXISTS (2026-08-15 live outage + refusal pair). The expert servers'
# semantic lanes (plan_answer's 706-f7mq fallback, spec_answer, project_answer
# synthesis) resolve their inference endpoint to the ENCLAVE DNS name
# `http://inference:11434` — a name that only resolves inside the forge's
# podman network. On the bare-metal development host that endpoint is
# unreachable by construction, nothing launched an inference runtime, and the
# expert system silently lost its semantic tier: every open-ended question
# degraded to `confidence=unsupported`.
#
# The two environments are DIFFERENT LIFECYCLES, and this file is the one
# place that names the split:
#
#   runtime (in-forge)  — the enclave owns inference: lib-common.sh ensures
#                         the tillandsias-inference container, the endpoint is
#                         `http://inference:11434`, and this hook DOES NOTHING.
#   dev (bare metal)    — the expert servers own their own dependency: the
#                         endpoint defaults to loopback 127.0.0.1:11434 and the
#                         IDEMPOTENT ensure (scripts/dev-inference-ensure.sh —
#                         reuse-if-running, start-if-stopped, launch-if-missing,
#                         never duplicate) is fired ONCE, in the background, at
#                         server start. Its verdict is written to a state file
#                         so a refusal can NAME why inference is absent instead
#                         of shrugging `endpoint-unreachable`.
#
# Fail-soft by construction: every path here is guarded — the servers run
# under `set -euo pipefail`, and an environment hook that can kill the JSON-RPC
# loop would be a worse defect than the one it fixes. Fail-LOUD by contract:
# nothing here swallows the outcome — the verdict file and the refusal reasons
# carry it.

# tillandsias_exec_env — prints `dev` or `runtime`.
# TILLANDSIAS_EXEC_ENV overrides for tests and operator pins.
tillandsias_exec_env() {
    case "${TILLANDSIAS_EXEC_ENV:-}" in
        dev | runtime)
            printf '%s\n' "$TILLANDSIAS_EXEC_ENV"
            return 0
            ;;
    esac
    if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then
        printf 'runtime\n'
    else
        printf 'dev\n'
    fi
}

# tillandsias_dev_env_hook <repo_root>
# Dev-environment wiring; a no-op in the runtime environment.
tillandsias_dev_env_hook() {
    _deh_root="${1:-$PWD}"
    [ "$(tillandsias_exec_env)" = "dev" ] || return 0
    # Under the litmus/test harness (which exports TILLANDSIAS_NO_SINGLETON=1
    # for exactly this "no ambient lifecycles" reason) the hook is INERT:
    # fixtures own their endpoints, and a test run must never launch a
    # container as a side effect. TILLANDSIAS_DEV_INFERENCE_AUTOSTART=0 is the
    # explicit operator opt-out for real sessions.
    [ -z "${TILLANDSIAS_NO_SINGLETON:-}" ] || return 0
    if [ "${TILLANDSIAS_DEV_INFERENCE_AUTOSTART:-1}" = "0" ]; then
        return 0
    fi

    # Endpoint defaults for the bare-metal expert system. Only when unset —
    # an explicit operator endpoint always wins. The loopback default is the
    # 718-nkm2 design: the expert servers and the endpoint share a loopback,
    # so there is nothing to discover and nothing that moves across reboots.
    if [ -z "${TILLANDSIAS_INFERENCE_ENDPOINT:-}" ]; then
        export TILLANDSIAS_INFERENCE_ENDPOINT="http://127.0.0.1:${TILLANDSIAS_DEV_INFERENCE_PORT:-11434}"
    fi
    if [ -z "${TILLANDSIAS_EMBED_ENDPOINT:-}" ]; then
        # ollama's OpenAI-compatible surface, for spec_answer's /embeddings.
        export TILLANDSIAS_EMBED_ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT%/}/v1"
    fi

    # Operator kill switch (620-ca7g): honored here too, loudly.
    _deh_state_dir="${XDG_RUNTIME_DIR:-/tmp}"
    _deh_verdict="$_deh_state_dir/tillandsias-dev-inference.verdict"
    if [ -n "${TILLANDSIAS_NO_LOCAL_INFERENCE:-}" ] && [ "${TILLANDSIAS_NO_LOCAL_INFERENCE}" != "0" ]; then
        printf 'skip:no-local-inference\n' > "$_deh_verdict" 2>/dev/null || true
        return 0
    fi

    _deh_ensure="$_deh_root/scripts/dev-inference-ensure.sh"
    [ -f "$_deh_ensure" ] || {
        printf 'skip:no-ensure-script:%s\n' "$_deh_ensure" > "$_deh_verdict" 2>/dev/null || true
        return 0
    }

    # Fire the idempotent ensure ONCE per host boot window, backgrounded so
    # `initialize` never waits on a model pull. mkdir is the lock; a stale
    # lock (>15min) is retaken so a crashed ensure cannot wedge the hook
    # forever. Two servers racing here is harmless — the ensure itself is
    # idempotent — the lock only stops the noise.
    _deh_lock="$_deh_state_dir/tillandsias-dev-inference.ensure.lock"
    if [ -d "$_deh_lock" ]; then
        _deh_age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$_deh_lock" 2>/dev/null || echo 0) ))
        [ "$_deh_age" -gt 900 ] || return 0
        rmdir "$_deh_lock" 2>/dev/null || true
    fi
    mkdir "$_deh_lock" 2>/dev/null || return 0
    (
        _deh_out="$(bash "$_deh_ensure" 2>>"$_deh_state_dir/tillandsias-dev-inference.log" | tail -1)"
        printf '%s\n' "${_deh_out:-unknown}" > "$_deh_verdict" 2>/dev/null || true
        rmdir "$_deh_lock" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
}
