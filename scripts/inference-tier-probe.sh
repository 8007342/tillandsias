#!/usr/bin/env bash
# @trace spec:inference-container
#
# inference-tier-probe.sh — classify this host's inference hardware tier.
#
# Emits EXACTLY ONE line matching the falsifiable grammar (order 392):
#   ^tier:(gpu-cuda|gpu-rocm|metal|cpu)$
# and exits 0. The grammar is consumed by litmus, by the sibling lanes'
# tier-verification packets (orders 401/402), and mirrors the compiled
# detection in tillandsias --inference-tier (the runtime is authoritative
# for launches; this script is the diagnostics/litmus surface — when the
# installed binary is present we defer to it so the two can never drift).
#
# Detection order matters: rocm-smi ships on hosts WITHOUT an AMD GPU
# (Fedora), so presence of a tool is never enough — each probe must see
# actual hardware.
set -euo pipefail

# Prefer the compiled, launch-authoritative detection when installed.
if command -v tillandsias >/dev/null 2>&1; then
    if out="$(tillandsias --inference-tier 2>/dev/null)" \
        && [[ "$out" =~ ^tier:(gpu-cuda|gpu-rocm|metal|cpu)$ ]]; then
        echo "$out"
        exit 0
    fi
fi

case "$(uname -s)" in
    Darwin)
        echo "tier:metal"
        exit 0
        ;;
esac

# NVIDIA: nvidia-smi must LIST a GPU, not merely exist.
if command -v nvidia-smi >/dev/null 2>&1 \
    && [ -n "$(nvidia-smi -L 2>/dev/null | head -1)" ]; then
    echo "tier:gpu-cuda"
    exit 0
fi

# AMD: rocminfo must report a GPU agent (gfx target), not merely exist.
if command -v rocminfo >/dev/null 2>&1 \
    && rocminfo 2>/dev/null | grep -q 'gfx'; then
    echo "tier:gpu-rocm"
    exit 0
fi

echo "tier:cpu"
