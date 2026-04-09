#!/usr/bin/env bash
# @trace spec:inference-container
# pull-models.sh — GPU-aware model tier puller for Tillandsias inference.
#
# Reads models.json, detects available VRAM, and pulls models the
# hardware can actually run. Models requiring more VRAM than available
# are NEVER pulled.
#
# Usage:
#   pull-models.sh --init        Pull only pull_at_init=true models (T0+T1)
#   pull-models.sh --background  Pull all models supported by hardware
#   pull-models.sh --init /path/to/models.json   Use custom models.json path
#
# Requires: bash, jq, ollama. Optional: nvidia-smi (for GPU detection).

set -euo pipefail

# ── Parse arguments ────────────────────────────────────────────
MODE=""
MODELS_JSON=""

for arg in "$@"; do
    case "$arg" in
        --init)       MODE="init" ;;
        --background) MODE="background" ;;
        *)
            if [ -f "$arg" ]; then
                MODELS_JSON="$arg"
            else
                echo "[pull-models] ERROR: unknown argument or missing file: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "[pull-models] ERROR: specify --init or --background" >&2
    exit 1
fi

# ── Locate models.json ─────────────────────────────────────────
if [ -z "$MODELS_JSON" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MODELS_JSON="$SCRIPT_DIR/models.json"
fi

if [ ! -f "$MODELS_JSON" ]; then
    echo "[pull-models] ERROR: models.json not found at $MODELS_JSON" >&2
    exit 1
fi

# ── Detect GPU VRAM ────────────────────────────────────────────
# @trace spec:inference-container
detect_vram_gb() {
    local vram_mb
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    if [ -z "$vram_mb" ] || [ "$vram_mb" = "0" ]; then
        echo 0
        return
    fi
    echo $(( vram_mb / 1024 ))
}

VRAM_GB=$(detect_vram_gb)
echo "[pull-models] Detected VRAM: ${VRAM_GB}GB"

# ── Wait for ollama to be ready ────────────────────────────────
wait_for_ollama() {
    local max_attempts=30
    local attempt=0
    while ! ollama list &>/dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "[pull-models] ERROR: ollama not responding after ${max_attempts}s" >&2
            return 1
        fi
        sleep 1
    done
}

echo "[pull-models] Waiting for ollama..."
wait_for_ollama
echo "[pull-models] ollama ready"

# ── Pull models ────────────────────────────────────────────────
TIER_COUNT=$(jq '.tiers | length' "$MODELS_JSON")
PULLED=0
SKIPPED=0

for i in $(seq 0 $(( TIER_COUNT - 1 ))); do
    TIER_ID=$(jq -r ".tiers[$i].id" "$MODELS_JSON")
    MODEL_NAME=$(jq -r ".tiers[$i].name" "$MODELS_JSON")
    VRAM_REQ=$(jq -r ".tiers[$i].vram_required_gb" "$MODELS_JSON")
    PULL_AT_INIT=$(jq -r ".tiers[$i].pull_at_init // false" "$MODELS_JSON")
    ROLE=$(jq -r ".tiers[$i].role" "$MODELS_JSON")

    # Skip models the hardware can't run
    if [ "$VRAM_REQ" -gt "$VRAM_GB" ] && [ "$VRAM_REQ" -gt 0 ]; then
        echo "[pull-models] $TIER_ID ($MODEL_NAME) — skipped (needs ${VRAM_REQ}GB VRAM, have ${VRAM_GB}GB)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # In --init mode, only pull models marked pull_at_init
    if [ "$MODE" = "init" ] && [ "$PULL_AT_INIT" != "true" ]; then
        continue
    fi

    echo "[pull-models] $TIER_ID ($MODEL_NAME) — pulling [role: $ROLE]..."
    if ollama pull "$MODEL_NAME"; then
        echo "[pull-models] $TIER_ID ($MODEL_NAME) — ready"
        PULLED=$((PULLED + 1))
    else
        echo "[pull-models] $TIER_ID ($MODEL_NAME) — FAILED" >&2
    fi
done

echo "[pull-models] Done. Pulled: $PULLED, Skipped (insufficient VRAM): $SKIPPED"
