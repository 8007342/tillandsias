#!/bin/sh
# @trace spec:inference-container
# @trace spec:async-inference-launch
# order 392a — inference-startup-cleanup/model-preload-policy
#
# Forge-side inference readiness + MODEL-WARM state.
#
# WHY A SEPARATE FILE: lib-common.sh cannot be sourced outside the forge image
# (it hard-fails on the vendor CA bundle), so the state grammar would only ever
# be grep-pinned. This helper has no import-time side effects, so
# litmus:inference-model-preload-policy can run it directly with a stubbed
# `curl` and assert EVERY branch of the grammar. No python, no jq. Since
# 2049-y7k8 the probe body is lua/inference-state.lua (`script run --helper`);
# a stub curl on PATH still reaches it, because the Lua child keeps PATH.
#
# PINNED GRAMMAR — the human string:
#   READY (models=<N>, warm=<csv>)
#   NOT-READY (<reason>: <detail>)
# and the machine line agents branch on:
#   inference_state=<ready|not-ready> inference_models=<N> inference_warm=<csv|-> inference_reason=<name|->
#
# Reason vocabulary (CLOSED SET — there is deliberately no "starting up"):
#   no-models            endpoint answers, zero models cached. THREE CAUSES
#                        share this token — preload pending, a lazy/off preload
#                        policy, or a FAILED PULL — and this probe cannot tell
#                        them apart, because it speaks plain HTTP to the local
#                        endpoint while a pull fails on the container's OUTBOUND
#                        path. Order 525: a TLS-trust failure used to be
#                        indistinguishable from an empty cache. The engine now
#                        classifies its own pull failures into stable tokens
#                        (pull-failed-tls-untrusted / -unreachable / -not-found
#                        / -other, images/inference/entrypoint.sh
#                        tillandsias_classify_pull_failure), so the two states
#                        ARE distinguishable — by reading the engine's log for a
#                        `reason=pull-failed-*` line, which the detail string
#                        below now names explicitly.
#                        STILL OPEN: the probe cannot report that token itself.
#                        It runs in the forge; the evidence is in the inference
#                        container, and no channel carries it across. Adding a
#                        reason here that nothing can set would be a vocabulary
#                        entry with no producer, so it is deliberately NOT added.
#   endpoint-unreachable curl 6/7 — DNS or connect refused; ALSO what an engine
#                        the inference container refused to execute looks like
#                        from here (order 521), so its detail names the
#                        `reason=engine-*` log line to read
#   endpoint-timeout     curl 28 — probe deadline exceeded
#   endpoint-http-error  curl 22 — served a non-2xx
#   probe-tool-missing   no curl in this image
#   probe-error-<n>      any other curl exit n (still named, still falsifiable)
#   probe-error-helper   the Lua helper ran but printed no state (2049-y7k8)
#
# Order 392a extends the order-392 READY / NOT-READY tokens rather than
# replacing them: an endpoint that answers but serves NO model is not useful to
# an agent, so READY additionally requires >=1 cached model.
#
# Contract: ALWAYS exit 0. Inference is optional — probing it must never fail a
# forge launch (order 486 warn-and-continue).

tillandsias_inference_state() {
    TILLANDSIAS_INFERENCE_ENDPOINT="${1:-${TILLANDSIAS_INFERENCE_ENDPOINT:-http://inference:11434}}"
    TILLANDSIAS_INFERENCE_STATE="not-ready"
    TILLANDSIAS_INFERENCE_MODELS=0
    TILLANDSIAS_INFERENCE_WARM="-"
    TILLANDSIAS_INFERENCE_REASON="-"
    TILLANDSIAS_INFERENCE_STATUS=""

    # ORDER 2049-y7k8 (openspec forge-lua-helpers D3.1): the probe and the
    # parse are lua/inference-state.lua on `tillandsias-plan script run
    # --helper`; this function keeps its name, its variables and its grammar.
    # The module sits beside this file (images/default/lua/ in a checkout,
    # /usr/local/lib/tillandsias/lua/ in the image). There is no second
    # implementation: without the runner or the module this reports the same
    # named reason the old code gave when its tool was absent.
    _tis_self="${BASH_SOURCE:-$0}"
    _tis_lua=""
    for _tis_c in "${_tis_self%/*}/lua/inference-state.lua" /usr/local/lib/tillandsias/lua/inference-state.lua; do
        if [ -r "$_tis_c" ]; then _tis_lua="$_tis_c"; break; fi
    done
    _tis_plan="${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}"
    if [ -z "$_tis_lua" ] || ! command -v "$_tis_plan" >/dev/null 2>&1; then
        TILLANDSIAS_INFERENCE_REASON="probe-tool-missing"
        if [ -z "$_tis_lua" ]; then _tis_missing="lua/inference-state.lua"; else _tis_missing="$_tis_plan"; fi
        TILLANDSIAS_INFERENCE_STATUS="NOT-READY (probe-tool-missing: ${_tis_missing} is absent from this image)"
        _tillandsias_inference_emit
        return 0
    fi

    _tis_vals="$("$_tis_plan" script run --helper "$_tis_lua" -- "$TILLANDSIAS_INFERENCE_ENDPOINT" 2>/dev/null)" || _tis_vals=""
    # Five lines in a fixed order (the module's header): state, models, warm,
    # reason, status. read -r, no eval, no sed.
    {
        IFS= read -r _tis_state
        IFS= read -r _tis_models
        IFS= read -r _tis_warm
        IFS= read -r _tis_reason
        IFS= read -r _tis_status
    } <<EOF
$_tis_vals
EOF
    case "$_tis_state" in
        ready | not-ready) ;;
        *)
            # The runner ran but produced no grammar: named, never a guess.
            TILLANDSIAS_INFERENCE_REASON="probe-error-helper"
            TILLANDSIAS_INFERENCE_STATUS="NOT-READY (probe-error-helper: ${_tis_lua} printed no inference state)"
            _tillandsias_inference_emit
            return 0
            ;;
    esac
    TILLANDSIAS_INFERENCE_STATE="$_tis_state"
    TILLANDSIAS_INFERENCE_MODELS="${_tis_models:-0}"
    TILLANDSIAS_INFERENCE_WARM="${_tis_warm:--}"
    TILLANDSIAS_INFERENCE_REASON="${_tis_reason:--}"
    TILLANDSIAS_INFERENCE_STATUS="$_tis_status"
    _tillandsias_inference_emit
    return 0
}

_tillandsias_inference_emit() {
    TILLANDSIAS_INFERENCE_LINE="inference_state=${TILLANDSIAS_INFERENCE_STATE} inference_models=${TILLANDSIAS_INFERENCE_MODELS} inference_warm=${TILLANDSIAS_INFERENCE_WARM} inference_reason=${TILLANDSIAS_INFERENCE_REASON}"
}

# Run directly (litmus / operator diagnostics) vs sourced (lib-common.sh):
# when this file IS the program, $0 ends in its own basename.
case "${0##*/}" in
    lib-inference-state.sh)
        tillandsias_inference_state "$@"
        printf '%s\n' "$TILLANDSIAS_INFERENCE_STATUS"
        printf '%s\n' "$TILLANDSIAS_INFERENCE_LINE"
        ;;
esac
