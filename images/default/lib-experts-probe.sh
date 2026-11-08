#!/usr/bin/env bash
# ORDER 718-ja7g — ONE reachability answer for the expert tiers, shared by both
# MCP servers instead of each deriving its own.
#
# WHAT WAS WRONG. forge-plan.sh derived tier liveness by curling
# $TILLANDSIAS_EMBED_ENDPOINT/embeddings and $TILLANDSIAS_SPEC_EXPERT_ENDPOINT/
# chat_completions; project-info.sh asked lib-inference-state.sh, which curls
# $TILLANDSIAS_INFERENCE_ENDPOINT/api/tags. Two servers, two vocabularies, two
# different questions — and the second one is OPTIMISTIC in a way that matters.
#
# MEASURED ON lenovinha 2026-08-29, with a real Ollama serving two models:
#
#   TILLANDSIAS_INFERENCE_ENDPOINT=http://127.0.0.1:11434   (root url, no /v1)
#     lib-inference-state.sh : READY (models=2, warm=nomic-embed-text,qwen2.5:0.5b)
#     experts-probe          : l1=unset  l2=ready
#
# Both are truthful about what they asked. `/api/tags` is Ollama's NATIVE api at
# the ROOT and it really is serving two models. But the expert path speaks only
# the OpenAI shape under /v1, and TILLANDSIAS_INFERENCE_ENDPOINT feeds
# synth_base ONLY — embed_base has no fallback in the precedence chain — so
# RETRIEVAL is dead on that host while the probe an operator is most likely to
# read says READY in capitals. `inference_state=ready` answers "is there an
# Ollama", not "can the experts work", and nothing said so.
#
# THIS FILE DOES NOT REPLACE lib-inference-state.sh. That probe answers a
# genuine and different question (is the inference CONTAINER up, with which
# models warm) and its answer is still worth printing. What changes is that a
# statement about EXPERT TIERS now comes from the binary that implements them.
#
# FAIL LOUD, NEVER SILENT: if the binary is absent the tiers are `unknown` with
# reason probe-binary-missing — never `unset`, never `ready`. An absent probe
# reporting a verdict is the lie order 531 recorded as `experts: ready`.
#
# BASH 3.2 CLEAN. Sourced, not executed.

# tillandsias_experts_probe [plan-binary]
#
# Sets, always:
#   TILLANDSIAS_EXPERTS_LINE   the binary's verdict line, or a named substitute
#   TILLANDSIAS_EXPERTS_L0/L1/L2   per-tier token from the closed vocabulary
#   TILLANDSIAS_EXPERTS_ADVICE the single next action, or '-'
#
# Closed vocabulary per tier: ready | unset | unreachable | scheme-unsupported
#                             | malformed | unknown
tillandsias_experts_probe() {
    _tep_bin="${1:-${TILLANDSIAS_PLAN_BIN:-}}"
    if [ -z "$_tep_bin" ] || [ ! -x "$_tep_bin" ]; then
        _tep_bin="$(command -v tillandsias-plan 2>/dev/null || true)"
    fi

    TILLANDSIAS_EXPERTS_L0="ready"   # file-backed; true with no endpoint at all
    TILLANDSIAS_EXPERTS_L1="unknown"
    TILLANDSIAS_EXPERTS_L2="unknown"
    TILLANDSIAS_EXPERTS_ADVICE="-"

    if [ -z "$_tep_bin" ]; then
        TILLANDSIAS_EXPERTS_ADVICE="probe-binary-missing: tillandsias-plan is not on PATH, so tier liveness is UNKNOWN rather than absent"
        TILLANDSIAS_EXPERTS_LINE="experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=${TILLANDSIAS_EXPERTS_ADVICE}"
        return 0
    fi

    # ORDER 2049-krk2 (openspec forge-lua-helpers D3.2): the capabilities
    # check, the probe and the field split are lua/experts-probe.lua on
    # `script run --helper`, run BY the binary being probed. The module sits
    # beside this file (images/default/lua/ in a checkout,
    # /usr/local/lib/tillandsias/lua/ in the image). No second implementation:
    # a missing module, or a binary too old to run a helper, is named.
    _tep_lua=""
    for _tep_c in "${BASH_SOURCE[0]%/*}/lua/experts-probe.lua" /usr/local/lib/tillandsias/lua/experts-probe.lua; do
        if [ -r "$_tep_c" ]; then _tep_lua="$_tep_c"; break; fi
    done
    if [ -z "$_tep_lua" ]; then
        TILLANDSIAS_EXPERTS_ADVICE="probe-helper-missing: lua/experts-probe.lua is absent from this image — tier liveness is UNKNOWN, not absent"
        TILLANDSIAS_EXPERTS_LINE="experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=${TILLANDSIAS_EXPERTS_ADVICE}"
        return 0
    fi

    # The RUNNER is the tillandsias-plan on PATH; the PROBED binary is the one
    # resolved above (often the same file). Kept apart so a stale probed binary
    # is still named probe-subcommand-missing / probe-no-verdict by the module.
    _tep_runner="$(command -v tillandsias-plan 2>/dev/null || true)"
    [ -n "$_tep_runner" ] || _tep_runner="$_tep_bin"
    _tep_vals="$("$_tep_runner" script run --helper "$_tep_lua" -- "$_tep_bin" 2>/dev/null)" || _tep_vals=""
    # Four lines in a fixed order (the module's header): line, l1, l2, advice.
    {
        IFS= read -r _tep_line
        IFS= read -r _tep_l1
        IFS= read -r _tep_l2
        IFS= read -r _tep_advice
    } <<EOF
$_tep_vals
EOF
    case "$_tep_line" in
        experts_probe:*) : ;;
        *)
            # A RUNNER that cannot run a --helper predates 2049-w2q6: the
            # stale-artifact signal, named like the missing subcommand.
            TILLANDSIAS_EXPERTS_ADVICE="probe-subcommand-missing: ${_tep_runner} cannot run script run --helper (2049-w2q6) — rebuild it; tier liveness is UNKNOWN, not absent"
            TILLANDSIAS_EXPERTS_LINE="experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=${TILLANDSIAS_EXPERTS_ADVICE}"
            return 0
            ;;
    esac
    TILLANDSIAS_EXPERTS_LINE="$_tep_line"
    TILLANDSIAS_EXPERTS_L1="${_tep_l1:-unknown}"
    TILLANDSIAS_EXPERTS_L2="${_tep_l2:-unknown}"
    TILLANDSIAS_EXPERTS_ADVICE="${_tep_advice:--}"
    return 0
}
