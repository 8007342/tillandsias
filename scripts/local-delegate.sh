#!/usr/bin/env bash
# @trace order:1833-ytbe, spec:local-coding-delegation
#
# Delegate ONE packet to the local inference endpoint (implementer tier
# `local`, below haiku). Sibling of scripts/claude-delegate.sh: same
# `<mode> <subject>` shape, one verdict line, never commits.
#
#   scripts/local-delegate.sh implement <order> [--model M] [--max-rounds N]
#                                               [--max-turns N] [--wall-s N]
#
# The loop is scripts/lua/local-delegate.lua (verdict grammar, protocol and
# bounds are documented there); this file only resolves the plan binary and
# the repository and hands over. Run it from the checkout whose tree the
# delegate may edit; it refuses a dirty tree.
#
# Environment:
#   TILLANDSIAS_INFERENCE_ENDPOINT  OpenAI-compatible base URL (ollama: http://127.0.0.1:11434)
#   TILLANDSIAS_INFERENCE_MODEL     default model when --model is not given (qwen2.5:7b)
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  scripts/local-delegate.sh implement <order> [--model M] [--max-rounds N] [--max-turns N] [--wall-s N]

Environment:
  TILLANDSIAS_INFERENCE_ENDPOINT  OpenAI-compatible base URL, required (fail-closed: no-endpoint)
  TILLANDSIAS_INFERENCE_MODEL     model name, default: qwen2.5:7b
EOF
}

MODE="${1:-}"
ORDER="${2:-}"
if [[ "$MODE" != "implement" || -z "$ORDER" ]]; then
    usage
    exit 2
fi
shift 2

MODEL="${TILLANDSIAS_INFERENCE_MODEL:-qwen2.5:7b}"
EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
        --max-rounds|--max-turns|--wall-s) EXTRA+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "refused:local-delegate:${ORDER}:not-a-work-tree"
    echo "  why: $(pwd) is not inside a git work tree; the scope check and the revert need one" >&2
    echo "  remedy: run from the checkout the delegate may edit" >&2
    exit 1
}
# shellcheck source=scripts/plan-binary-probe.sh
. "$HERE/plan-binary-probe.sh"
PLAN="$(cd "$HERE/.." && resolve_plan_binary)" || {
    echo "refused:local-delegate:${ORDER}:no-plan-binary"
    echo "  why: the loop runs on the plan binary's Lua runner (script run) and none runs here" >&2
    echo "  remedy: cargo build --release -p tillandsias-plan" >&2
    exit 1
}
case "$PLAN" in ./*) PLAN="$HERE/../${PLAN#./}" ;; esac

cd "$REPO"
TILLANDSIAS_REPO_ROOT="$REPO" exec "$PLAN" script run "$HERE/lua/local-delegate.lua" -- \
    implement "$ORDER" --repo "$REPO" \
    --endpoint "${TILLANDSIAS_INFERENCE_ENDPOINT:-}" --model "$MODEL" \
    "${EXTRA[@]+"${EXTRA[@]}"}"
