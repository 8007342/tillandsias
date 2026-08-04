#!/bin/sh
# @trace spec:inference-container
# @trace spec:zen-default-with-ollama-analysis-pool
# order 392a — inference-startup-cleanup/model-preload-policy
#
# Model preload policy for the Tillandsias inference container.
#
# WHY A SEPARATE FILE: the policy has to be FALSIFIABLE without booting a
# container. This is POSIX sh with no side effects beyond setting shell
# variables and printing one line, so entrypoint.sh can `.` (source) it while
# litmus:inference-model-preload-policy runs it standalone with stubbed inputs
# and asserts every branch. No python, no eval of untrusted text.
#
# PINNED GRAMMAR — exactly one line, always exit 0:
#   preload: policy=<eager|lazy|off> models=<csv|-> expert_slots=<N> max_loaded=<N> ram_gb=<N>
#
# ── Policy (TILLANDSIAS_INFERENCE_PRELOAD) ───────────────────────────────
#   eager (DEFAULT) — the TILLANDSIAS_DEFAULT_MODELS set is pulled at container
#                     start so a forge launch finds a WARM model. This NEVER
#                     gates a lane launch: `ollama serve` already answers
#                     /api/version before the first pull begins, and the
#                     launcher's readiness gate is warn-and-continue (order 486).
#   lazy            — nothing is pulled at start; the first consumer pulls what
#                     it needs. The forge startup context reports
#                     NOT-READY (no-models: ...) until a model exists.
#   off             — nothing is ever pulled. Only models already in the mounted
#                     cache (or baked into /opt/baked-models) are served.
#                     Offline / air-gapped / bandwidth-capped hosts.
# An unrecognized value degrades to `eager` (fail-soft, never fail-closed).
#
# ── Expert slots (order 392a, milestone 391 forge-local EXPERTS) ─────────
# The EXPERTS family (orders 393/394/457) builds EPHEMERAL per-launch expert
# models on this same endpoint. With OLLAMA_MAX_LOADED_MODELS=1 every expert
# load EVICTS the warm default model, so the default is reserved a slot of its
# own and experts get the remainder:
#
#   max_loaded = 1 (default model) + expert_slots
#
# The ladder is RAM-derived and a 4 GB host gets ZERO extra slots — max_loaded
# stays 1, i.e. NO new OOM risk on exactly the constrained hosts order 168
# tuned the default model set for:
#
#   ram <  8 GB -> 0 expert slots (max_loaded 1)  <- unchanged from pre-392a
#   ram < 16 GB -> 1 expert slot  (max_loaded 2)
#   ram >= 16GB -> 2 expert slots (max_loaded 3)
#
# Overrides (both respected verbatim, highest precedence first):
#   OLLAMA_MAX_LOADED_MODELS         — operator pins the ollama limit directly;
#                                      expert_slots is reported as the residual.
#   TILLANDSIAS_INFERENCE_EXPERT_SLOTS — pins the reservation, max_loaded follows.
#   TILLANDSIAS_PRELOAD_RAM_GB       — stubs the RAM reading (litmus/dev only).

# ── Inputs ───────────────────────────────────────────────────────────────
# Default model set. entrypoint.sh owns the canonical assignment (order 168
# narrowed it to qwen2.5:0.5b, ~400MB, to fix a real OOM / ~32s
# container-death on constrained hosts; litmus:zen-default-with-ollama-shape
# pins that literal in entrypoint.sh). When sourced, DEFAULT_MODELS is already
# set and passes through untouched; when run standalone by litmus the same
# fallback chain applies, so the two surfaces cannot disagree.
DEFAULT_MODELS="${DEFAULT_MODELS:-${TILLANDSIAS_DEFAULT_MODELS:-qwen2.5:0.5b}}"

PRELOAD_POLICY="${TILLANDSIAS_INFERENCE_PRELOAD:-eager}"
case "$PRELOAD_POLICY" in
    eager | lazy | off) ;;
    *) PRELOAD_POLICY="eager" ;;
esac

# RAM in GB. Stubbable so the ladder is testable without a matching host.
PRELOAD_RAM_GB="${TILLANDSIAS_PRELOAD_RAM_GB:-}"
if [ -z "$PRELOAD_RAM_GB" ]; then
    PRELOAD_RAM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
fi
case "$PRELOAD_RAM_GB" in
    '' | *[!0-9]*) PRELOAD_RAM_GB=0 ;;
esac

# ── Expert slot reservation ──────────────────────────────────────────────
if [ -n "${TILLANDSIAS_INFERENCE_EXPERT_SLOTS:-}" ]; then
    PRELOAD_EXPERT_SLOTS="$TILLANDSIAS_INFERENCE_EXPERT_SLOTS"
    case "$PRELOAD_EXPERT_SLOTS" in
        '' | *[!0-9]*) PRELOAD_EXPERT_SLOTS=0 ;;
    esac
elif [ "$PRELOAD_RAM_GB" -lt 8 ]; then
    PRELOAD_EXPERT_SLOTS=0
elif [ "$PRELOAD_RAM_GB" -lt 16 ]; then
    PRELOAD_EXPERT_SLOTS=1
else
    PRELOAD_EXPERT_SLOTS=2
fi

# An operator-pinned OLLAMA_MAX_LOADED_MODELS wins outright; the reservation is
# then reported as the residual so the emitted line stays internally consistent
# (max_loaded = 1 + expert_slots) instead of advertising a slot ollama will not
# honour.
if [ -n "${OLLAMA_MAX_LOADED_MODELS:-}" ]; then
    case "$OLLAMA_MAX_LOADED_MODELS" in
        '' | *[!0-9]*) OLLAMA_MAX_LOADED_MODELS=1 ;;
    esac
    [ "$OLLAMA_MAX_LOADED_MODELS" -ge 1 ] || OLLAMA_MAX_LOADED_MODELS=1
    PRELOAD_EXPERT_SLOTS=$((OLLAMA_MAX_LOADED_MODELS - 1))
else
    OLLAMA_MAX_LOADED_MODELS=$((1 + PRELOAD_EXPERT_SLOTS))
fi
export OLLAMA_MAX_LOADED_MODELS

# ── Model set actually preloaded under this policy ───────────────────────
# `lazy` and `off` both preload nothing; they differ in what happens LATER
# (lazy lets a consumer pull, off never pulls at all — enforced at the call
# site in entrypoint.sh, which refuses on-demand pulls under `off`).
if [ "$PRELOAD_POLICY" = "eager" ]; then
    PRELOAD_MODELS="$DEFAULT_MODELS"
else
    PRELOAD_MODELS=""
fi

# ── Compose the pinned line ──────────────────────────────────────────────
_preload_models_csv="$(printf '%s' "$PRELOAD_MODELS" | tr -s ' ' ',' | sed 's/^,//; s/,$//')"
[ -n "$_preload_models_csv" ] || _preload_models_csv="-"
PRELOAD_LINE="preload: policy=${PRELOAD_POLICY} models=${_preload_models_csv} expert_slots=${PRELOAD_EXPERT_SLOTS} max_loaded=${OLLAMA_MAX_LOADED_MODELS} ram_gb=${PRELOAD_RAM_GB}"
unset _preload_models_csv

# Run directly (litmus / operator diagnostics) vs sourced by entrypoint.sh:
# when this file IS the program, $0 ends in its own basename. Sourced, it stays
# silent so the entrypoint owns a single `[inference] preload: …` log line.
case "${0##*/}" in
    preload-policy.sh | tillandsias-preload-policy.sh)
        printf '%s\n' "$PRELOAD_LINE"
        ;;
esac
