#!/usr/bin/env bash
# @trace spec:inference-container, spec:cheatsheet-tooling
#
# check-dev-embed-model-agreement.sh — the dev embed MODEL must match the dev
# embed ENDPOINT (order 760-hzi4).
#
# WHY. Two files independently default the same variable, for two different
# runtimes:
#   * images/default/config-overlay/mcp/forge-plan.sh defaults to a
#     lemonade/LM-Studio model name, because it was written for the ENCLAVE
#     inference container.
#   * scripts/dev-inference-ensure.sh pulls an ollama model, because on a
#     bare-metal dev host that is what serves the endpoint.
# Ask ollama for the lemonade name and the embed call 404s, so `spec_answer`
# refuses EVEN AFTER a real index is built — a failure that looks like a
# missing index and is really a model-name mismatch. Nothing tied the two
# together, so they could drift silently.
#
# The dev environment now names its own model in lib-dev-env.sh (the same file
# that already splits the dev endpoint from the enclave one). THIS check keeps
# that name in step with the model dev-inference-ensure.sh actually pulls.
# It deliberately does NOT constrain forge-plan.sh's runtime default — the
# enclave is a different runtime and is allowed a different name.
#
# Output grammar (exactly one line):
#   ^(ok:dev-embed-model-agreement:[a-z0-9.:-]+|violation:dev-embed-model-mismatch:.*)$
#
# Usage:
#   scripts/check-dev-embed-model-agreement.sh
#   scripts/check-dev-embed-model-agreement.sh --selftest
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/images/default/config-overlay/mcp/lib-dev-env.sh"
ENSURE="$ROOT/scripts/dev-inference-ensure.sh"

_hook_model() {
    sed -n 's/.*export TILLANDSIAS_EMBED_MODEL="\([^"]*\)".*/\1/p' "$1" | head -1
}
_ensure_model() {
    sed -n 's/.*EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-\([^}]*\)}".*/\1/p' "$1" | head -1
}

if [[ "${1:-}" == "--selftest" ]]; then
    # NEGATIVE CONTROL: a check that only ever compares two equal strings
    # proves nothing. Build a disagreeing pair and require a refusal.
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    printf 'export TILLANDSIAS_EMBED_MODEL="model-a"\n' > "$tmp/hook.sh"
    printf 'EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-model-a}"\n' > "$tmp/ensure.sh"
    [[ "$(_hook_model "$tmp/hook.sh")" == "$(_ensure_model "$tmp/ensure.sh")" ]] \
        || { echo "selftest:FAIL matching pair read as different"; exit 1; }
    printf 'EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-model-b}"\n' > "$tmp/ensure.sh"
    [[ "$(_hook_model "$tmp/hook.sh")" != "$(_ensure_model "$tmp/ensure.sh")" ]] \
        || { echo "selftest:FAIL disagreeing pair read as equal"; exit 1; }
    # And the extractors must actually find something — a silently empty
    # match would make every comparison trivially "equal".
    [[ -n "$(_hook_model "$tmp/hook.sh")" ]] || { echo "selftest:FAIL hook extractor returned empty"; exit 1; }
    echo "selftest:dev-embed-model-agreement:3 cases PASS"
    exit 0
fi

hook_model="$(_hook_model "$HOOK")"
ensure_model="$(_ensure_model "$ENSURE")"

if [[ -z "$hook_model" || -z "$ensure_model" ]]; then
    echo "violation:dev-embed-model-mismatch:could not read a default (hook='${hook_model}' ensure='${ensure_model}')"
    exit 1
fi
if [[ "$hook_model" != "$ensure_model" ]]; then
    echo "violation:dev-embed-model-mismatch:hook=${hook_model} ensure=${ensure_model}"
    exit 1
fi
echo "ok:dev-embed-model-agreement:${hook_model}"
