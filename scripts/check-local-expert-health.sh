#!/usr/bin/env bash
# check-local-expert-health.sh — probe local Ollama inference endpoint
#
# Prints exactly one line matching:
#   ^(ok:local-experts-healthy|degraded:local-experts[^;]*|down:local-experts[^;]*|skip:not-applicable)$
#
# Exit 0 on ok/degraded/skip, non-zero on down.

set -euo pipefail

# 2026-08-28 repair: the stack's env family is TILLANDSIAS_INFERENCE_* with a
# CPU-floor model default (lib-dev-env.sh tier table picks bigger models only
# when the hardware carries them; pipeline.rs InferenceConfig agrees). The
# TILLANDSIAS_OLLAMA_URL / TILLANDSIAS_EXPERT_MODEL names this script invented
# had no other reader (grepped 2026-08-28) and are dropped, not aliased.
ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
MODEL="${TILLANDSIAS_INFERENCE_MODEL:-qwen2.5:0.5b}"

# Skip if not applicable (e.g. forge without native Ollama)
if [[ "${TILLANDSIAS_SKIP_LOCAL_EXPERTS:-}" == "1" ]]; then
    echo "skip:not-applicable"
    exit 0
fi

# Check if Ollama is reachable
if ! curl -sf --max-time 3 "${ENDPOINT}/api/tags" >/dev/null 2>&1; then
    echo "down:local-experts-ollama-unreachable"
    exit 1
fi

# Check if the model is available. Herestring, not a pipeline: an
# `if ! <pipeline>` verdict can invert under pipefail + SIGPIPE (795-imz3).
_available_models="$(curl -sf --max-time 5 "${ENDPOINT}/api/tags" 2>/dev/null | jq -r '.models[].name // empty' 2>/dev/null | tr -d '' || echo "")"
_model_present_rc=0
grep -qF "$MODEL" <<<"$_available_models" || _model_present_rc=$?
if [[ "$_model_present_rc" -ne 0 ]]; then
    echo "degraded:local-experts-model-missing:${MODEL}"
    exit 0
fi

# Quick inference test
_test_response="$(curl -sf --max-time 10 "${ENDPOINT}/api/generate" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Say OK\",\"stream\":false}" 2>/dev/null \
    | jq -r '.response // empty' 2>/dev/null || echo "")"

if [[ -z "$_test_response" ]]; then
    echo "degraded:local-experts-inference-failed:${MODEL}"
    exit 0
fi

echo "ok:local-experts-healthy"
exit 0
