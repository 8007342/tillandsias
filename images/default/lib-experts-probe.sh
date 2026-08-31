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

    # A binary predating this subcommand must be named as such, not read as a
    # dead endpoint — the stale-artifact signal order 569 established.
    if ! "$_tep_bin" capabilities 2>/dev/null | grep -qx 'experts-probe'; then
        TILLANDSIAS_EXPERTS_ADVICE="probe-subcommand-missing: this tillandsias-plan predates experts-probe (718-ja7g) — rebuild it; tier liveness is UNKNOWN, not absent"
        TILLANDSIAS_EXPERTS_LINE="experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=${TILLANDSIAS_EXPERTS_ADVICE}"
        return 0
    fi

    _tep_out="$("$_tep_bin" experts-probe 2>/dev/null | head -1)"
    case "$_tep_out" in
        experts_probe:*) : ;;
        *)
            TILLANDSIAS_EXPERTS_ADVICE="probe-no-verdict: experts-probe produced no parseable line"
            TILLANDSIAS_EXPERTS_LINE="experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=${TILLANDSIAS_EXPERTS_ADVICE}"
            return 0
            ;;
    esac

    TILLANDSIAS_EXPERTS_LINE="$_tep_out"
    # Field extraction without a JSON parser, matching the field=value idiom
    # lib-inference-state.sh already emits.
    TILLANDSIAS_EXPERTS_L1="$(printf '%s' "$_tep_out" | sed -n 's/.*[ ]l1=\([^ ]*\).*/\1/p')"
    TILLANDSIAS_EXPERTS_L2="$(printf '%s' "$_tep_out" | sed -n 's/.*[ ]l2=\([^ ]*\).*/\1/p')"
    # advice runs to end-of-line: it is a sentence and may contain spaces.
    TILLANDSIAS_EXPERTS_ADVICE="$(printf '%s' "$_tep_out" | sed -n 's/.*[ ]advice=\(.*\)$/\1/p')"
    [ -n "$TILLANDSIAS_EXPERTS_L1" ] || TILLANDSIAS_EXPERTS_L1="unknown"
    [ -n "$TILLANDSIAS_EXPERTS_L2" ] || TILLANDSIAS_EXPERTS_L2="unknown"
    [ -n "$TILLANDSIAS_EXPERTS_ADVICE" ] || TILLANDSIAS_EXPERTS_ADVICE="-"
    return 0
}
