#!/usr/bin/env bash
# Delegate bounded low-risk tasks to Claude Code, defaulting to Haiku.
# @trace spec:methodology-accountability

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  scripts/claude-delegate.sh audit "task"
  scripts/claude-delegate.sh patch-draft "task"
  scripts/claude-delegate.sh json "task"

Environment:
  CLAUDE_DELEGATE_MODEL   Model alias/name, default: haiku
  CLAUDE_DELEGATE_EFFORT  Effort level, default: low
EOF
}

MODE="${1:-}"
shift || true
TASK="${*:-}"

if [[ -z "$MODE" || -z "$TASK" ]]; then
    usage
    exit 2
fi

MODEL="${CLAUDE_DELEGATE_MODEL:-haiku}"
EFFORT="${CLAUDE_DELEGATE_EFFORT:-low}"

case "$MODE" in
    audit)
        OUTPUT_FORMAT="text"
        MODE_INSTRUCTIONS="Read-only audit. Do not edit files. Return concise findings with path:line references and residual uncertainty."
        ;;
    patch-draft)
        OUTPUT_FORMAT="text"
        MODE_INSTRUCTIONS="Read-only patch draft. Do not edit files. Return a minimal unified diff and a short rationale. Do not commit."
        ;;
    json)
        OUTPUT_FORMAT="json"
        MODE_INSTRUCTIONS="Read-only structured analysis. Do not edit files. Return compact JSON with keys: findings, evidence_refs, suggested_next_actions."
        ;;
    *)
        usage
        exit 2
        ;;
esac

PROMPT=$(cat <<EOF
You are a Claude Haiku delegate working inside the Tillandsias repository.
You are not alone in the codebase. Do not revert unrelated changes. Do not commit.
The primary agent owns methodology, architecture, verification, integration, and final decisions.

Mode: ${MODE}
Instructions: ${MODE_INSTRUCTIONS}

Task:
${TASK}
EOF
)

printf '%s\n' "$PROMPT" | exec claude \
    --print \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --output-format "$OUTPUT_FORMAT" \
    --permission-mode default \
    --allowedTools Read,Grep,Glob
