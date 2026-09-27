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
# counts agents per model.
#
# ONE MESSAGE, SEVERAL LINES. The harness writes one transcript line per content
# block, each repeating the response's usage. Measured on tlatoanis-macbook-air
# 2026-09-27: 3486 assistant lines, 1519 distinct message ids — a naive sum
# overcounts 2.3x. Lines are deduplicated by message.id, keeping the last.
#
# THE FORMAT IS INTERNAL AND VERSION-DEPENDENT. The four usage fields are
# asserted on every counted message; a missing or non-numeric one answers
# source=absent:schema-drift:<field> with zeros, so a format change reads as a
# missing instrument rather than as a measured zero (agent-observability.yaml
# proxy_discipline). No transcript resolvable (opencode, codex, a forge whose
# HOME lacks the directory) answers source=absent with zeros, never a guess.
#
# Resolution: --transcript; else CLAUDE_CODE_SESSION_ID looked up under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<id>.jsonl (by id, not by cwd
# slug: a cycle often runs its scripts from a worktree whose slug differs from
# the session's). Needs jq; without it the answer is source=absent.
# Always exits 0 on an answer; 2 on a usage error.
set -uo pipefail

since="${TILLANDSIAS_CYCLE_START_TS:-}"
transcript=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since)      since="${2:-}"; shift 2 ;;
        --since=*)    since="${1#--since=}"; shift ;;
        --transcript) transcript="${2:-}"; shift 2 ;;
        --transcript=*) transcript="${1#--transcript=}"; shift ;;
        -h|--help)    sed -n '4,22p' "$0"; exit 0 ;;
        *) echo "usage: session-tokens.sh [--since <utc>] [--transcript <path>]" >&2; exit 2 ;;
    esac
done

absent() {
    printf 'main_ctx=0 main_ctx_cumulative=0 subagent_tokens=0 agents=0 by_model=- source=%s\n' "$1"
    exit 0
}

command -v jq >/dev/null 2>&1 || absent absent

if [ -z "$transcript" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
    for cand in "$projects"/*/"${CLAUDE_CODE_SESSION_ID}.jsonl"; do
        [ -f "$cand" ] && { transcript="$cand"; break; }
    done
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || absent absent

# One file -> {drift, all, win, model}. `win` counts messages at or after
# $since; timestamps are compared with fractional seconds stripped, because
# "…:26.570Z" sorts BEFORE "…:26Z" as a string.
# shellcheck disable=SC2016
JQ_SUM='
def norm: sub("\\.[0-9]+"; "");
def fields: ["input_tokens","cache_creation_input_tokens","cache_read_input_tokens","output_tokens"];
[inputs | fromjson? | select(type == "object" and .type == "assistant"
    and (.message.usage | type) == "object" and .message.model != "<synthetic>")]
| (map(.message.usage as $u | fields[] | select(($u[.] | type) != "number")) | first) as $drift
| reduce .[] as $r ({}; .[($r.message.id // $r.uuid // ($r | tostring))] = $r)
| [.[]] as $msgs
| def tok: .message.usage | (.input_tokens + .cache_creation_input_tokens
                             + .cache_read_input_tokens + .output_tokens);
  { drift: $drift,
    all: ($msgs | map(tok) | add // 0),
    win: (if $since == "" then 0
          else ($msgs | map(select((.timestamp // "" | norm) >= ($since | norm)) | tok) | add // 0)
          end),
    model: ($msgs | map(.message.model) | first // "-") }'

sum_file() { jq -R -n -c --arg since "$since" "$JQ_SUM" "$1" 2>/dev/null; }

main_json="$(sum_file "$transcript")" || absent absent
[ -n "$main_json" ] || absent absent
drift="$(printf '%s' "$main_json" | jq -r '.drift // empty')"
[ -z "$drift" ] || absent "absent:schema-drift:$drift"
main_ctx="$(printf '%s' "$main_json" | jq -r '.win')"
main_cum="$(printf '%s' "$main_json" | jq -r '.all')"

sub_tokens=0; agents=0; models=""
subdir="${transcript%.jsonl}/subagents"
if [ -d "$subdir" ]; then
    for f in "$subdir"/*.jsonl; do
        [ -f "$f" ] || continue
        j="$(sum_file "$f")" || continue
        [ -n "$j" ] || continue
        d="$(printf '%s' "$j" | jq -r '.drift // empty')"
        [ -z "$d" ] || absent "absent:schema-drift:$d"
        # Per-cycle: an agent counts only when it spent inside the window (or,
        # with no window, at all).
        if [ -n "$since" ]; then n="$(printf '%s' "$j" | jq -r '.win')"; else n="$(printf '%s' "$j" | jq -r '.all')"; fi
        [ "$n" -gt 0 ] 2>/dev/null || continue
        sub_tokens=$((sub_tokens + n)); agents=$((agents + 1))
        models="${models}$(printf '%s' "$j" | jq -r '.model')
"
    done
fi
by_model="$(printf '%s' "$models" | awk 'NF { c[$0]++ } END { for (m in c) print m ":" c[m] }' | sort | paste -sd, -)"
[ -n "$by_model" ] || by_model="-"

printf 'main_ctx=%s main_ctx_cumulative=%s subagent_tokens=%s agents=%s by_model=%s source=%s\n' \
    "$main_ctx" "$main_cum" "$sub_tokens" "$agents" "$by_model" "$transcript"
