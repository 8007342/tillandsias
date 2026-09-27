#!/usr/bin/env bash
# @trace order:1437-3pj7, spec:meta-orchestration
#
# session-tokens.sh [--since <utc>] [--transcript <path>]
#
# Derives this session's BILLED token spend from the harness's own transcript,
# so `cycle-metrics.sh --emit-tokens --from-transcript` records a measurement
# instead of the 0 every row carried since 2026-09-14 (nothing computed it).
# Prints ONE line:
#
#   main_ctx=<n> main_ctx_cumulative=<n> subagent_tokens=<n> agents=<n>
#   by_model=<model:agents,...|-> source=<path|absent|absent:schema-drift:<field>>
#
# main_ctx is the sum of input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens + output_tokens over the main transcript's assistant
# messages at or after --since (default $TILLANDSIAS_CYCLE_START_TS; with no
# since at all main_ctx stays 0 and only the cumulative is answered). It is a
# billed-token figure, NOT a context size. The sub-agent fields are summed the
# same way from <session>/subagents/*.jsonl over the same window; by_model
# counts agents per model. Lines repeating one message's usage are counted
# once (by message.id): the harness writes one line per content block.
#
# THE WORK IS `tillandsias-plan session-tokens` (crates/tillandsias-plan/src/
# session_tokens.rs). This wrapper only resolves the binary: a sum is not
# something the 1375-tsfu jq ratchet admits, and `json get` has no arithmetic.
# With no plan binary resolvable the answer is source=absent, never a guess.
# Always exits 0 on an answer; 2 on a usage error.
set -uo pipefail

case "${1:-}" in
    -h|--help) sed -n '4,27p' "$0"; exit 0 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "main_ctx=0 main_ctx_cumulative=0 subagent_tokens=0 agents=0 by_model=- source=absent"
    exit 0
fi
exec "$_plan" session-tokens "$@"
