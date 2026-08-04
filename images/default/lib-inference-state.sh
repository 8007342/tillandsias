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
# `curl` and assert EVERY branch of the grammar. No python, no jq.
#
# PINNED GRAMMAR — the human string:
#   READY (models=<N>, warm=<csv>)
#   NOT-READY (<reason>: <detail>)
# and the machine line agents branch on:
#   inference_state=<ready|not-ready> inference_models=<N> inference_warm=<csv|-> inference_reason=<name|->
#
# Reason vocabulary (CLOSED SET — there is deliberately no "starting up"):
#   no-models            endpoint answers, zero models cached (preload pending,
#                        a lazy/off preload policy, or a failed pull)
#   endpoint-unreachable curl 6/7 — DNS or connect refused
#   endpoint-timeout     curl 28 — probe deadline exceeded
#   endpoint-http-error  curl 22 — served a non-2xx
#   probe-tool-missing   no curl in this image
#   probe-error-<n>      any other curl exit n (still named, still falsifiable)
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

    if ! command -v curl >/dev/null 2>&1; then
        TILLANDSIAS_INFERENCE_REASON="probe-tool-missing"
        TILLANDSIAS_INFERENCE_STATUS="NOT-READY (probe-tool-missing: curl is absent from this image)"
        _tillandsias_inference_emit
        return 0
    fi

    _tis_out=""
    _tis_rc=0
    # 1s budget: this probe is a report, never a gate.
    _tis_out="$(curl -fsS --max-time 1 "${TILLANDSIAS_INFERENCE_ENDPOINT}/api/tags" 2>&1)" || _tis_rc=$?

    if [ "$_tis_rc" -ne 0 ]; then
        case "$_tis_rc" in
            6 | 7) TILLANDSIAS_INFERENCE_REASON="endpoint-unreachable" ;;
            28) TILLANDSIAS_INFERENCE_REASON="endpoint-timeout" ;;
            22) TILLANDSIAS_INFERENCE_REASON="endpoint-http-error" ;;
            *) TILLANDSIAS_INFERENCE_REASON="probe-error-${_tis_rc}" ;;
        esac
        TILLANDSIAS_INFERENCE_STATUS="NOT-READY (${TILLANDSIAS_INFERENCE_REASON}: ${_tis_out:-curl exit ${_tis_rc}})"
        _tillandsias_inference_emit
        return 0
    fi

    # /api/tags emits one "name" key per installed model. Splitting on commas
    # puts each JSON field on its own line, so a sed capture is enough — no
    # JSON parser, no external tooling.
    _tis_names="$(printf '%s' "$_tis_out" | tr ',' '\n' \
        | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | sort -u)"
    for _tis_n in $_tis_names; do
        TILLANDSIAS_INFERENCE_MODELS=$((TILLANDSIAS_INFERENCE_MODELS + 1))
        if [ "$TILLANDSIAS_INFERENCE_WARM" = "-" ]; then
            TILLANDSIAS_INFERENCE_WARM="$_tis_n"
        else
            TILLANDSIAS_INFERENCE_WARM="${TILLANDSIAS_INFERENCE_WARM},${_tis_n}"
        fi
    done

    if [ "$TILLANDSIAS_INFERENCE_MODELS" -gt 0 ]; then
        TILLANDSIAS_INFERENCE_STATE="ready"
        TILLANDSIAS_INFERENCE_STATUS="READY (models=${TILLANDSIAS_INFERENCE_MODELS}, warm=${TILLANDSIAS_INFERENCE_WARM})"
    else
        TILLANDSIAS_INFERENCE_REASON="no-models"
        TILLANDSIAS_INFERENCE_STATUS="NOT-READY (no-models: endpoint is serving but no model is cached — preload pending, a lazy/off preload policy, or a failed pull; see \`podman logs tillandsias-inference\`)"
    fi
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
