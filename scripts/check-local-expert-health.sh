#!/usr/bin/env bash
# check-local-expert-health.sh — probe local Ollama inference endpoint
#
# Prints exactly one line matching:
#   ^(ok:local-experts-healthy|degraded:local-experts[^;]*|down:local-experts[^;]*|skip:not-applicable)$
#
# Exit 0 on ok/degraded/skip, non-zero on down.

set -euo pipefail

OLLAMA_URL="${TILLANDSIAS_OLLAMA_URL:-http://127.0.0.1:11434}"
MODEL="${TILLANDSIAS_EXPERT_MODEL:-qwen2.5:14b}"

# Skip if not applicable (e.g. forge without native Ollama)
if [[ "${TILLANDSIAS_SKIP_LOCAL_EXPERTS:-}" == "1" ]]; then
    echo "skip:not-applicable"
    exit 0
fi

# Check if Ollama is reachable
if ! curl -sf --max-time 3 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
    echo "down:local-experts-ollama-unreachable"
    exit 1
fi

# Check if the model is available
_available_models="$(curl -sf --max-time 5 "${OLLAMA_URL}/api/tags" 2>/dev/null | jq -r '.models[].name // empty' 2>/dev/null || echo "")"
if ! echo "$_available_models" | grep -qF "$MODEL"; then
    echo "degraded:local-experts-model-missing:${MODEL}"
    exit 0
fi

# Quick inference test
_test_response="$(curl -sf --max-time 10 "${OLLAMA_URL}/api/generate" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"Say OK\",\"stream\":false}" 2>/dev/null \
    | jq -r '.response // empty' 2>/dev/null || echo "")"

if [[ -z "$_test_response" ]]; then
    echo "degraded:local-experts-inference-failed:${MODEL}"
    exit 0
fi

echo "ok:local-experts-healthy"
exit 0
