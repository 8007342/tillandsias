#!/usr/bin/env bash
# @trace order:1437-3pj7, spec:meta-orchestration
set -uo pipefail

# Fixture for scripts/session-tokens.sh and cycle-metrics.sh --emit-tokens
# --from-transcript (order 1437-3pj7), over a scratch transcript shaped like
# ~/.claude/projects/<slug>/<session>.jsonl with a <session>/subagents/ child.
#
#   1. main_ctx sums the four usage fields over assistant messages at or after
#      --since; main_ctx_cumulative over all of them. The scratch transcript
#      repeats one message on two lines (the harness writes one line per
#      content block), so a naive sum fails this arm.
#   2. subagent_tokens, agents and by_model are summed from subagents/*.jsonl.
#   3. --emit-tokens --from-transcript writes one record whose main_ctx is
#      non-zero and equals arm 1's.
#   4. NEGATIVE CONTROL: no transcript resolvable -> zeros, source=absent.
#   5. NEGATIVE CONTROL: a usage object missing a field ->
#      source=absent:schema-drift:<field> and zeros.
#
# PRE-FIX RESULT: FAILS — session-tokens.sh did not exist and --from-transcript
# was not an --emit-tokens option.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ST="$ROOT/scripts/session-tokens.sh"
CM="$ROOT/scripts/cycle-metrics.sh"
pass=0; total=5
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "skip:session-tokens:no-jq"; exit 0; }
[ -f "$ST" ] || { echo "fail:session-tokens:0/$total (session-tokens.sh missing)"; exit 1; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/session-tokens.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
proj="$scratch/projects/-scratch-slug"
mkdir -p "$proj/sess1/subagents"
T="$proj/sess1.jsonl"

rec() { # id ts model in cc cr out
    printf '{"type":"assistant","timestamp":"%s","sessionId":"sess1","cwd":"/scratch","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
        "$2" "$1" "$3" "$4" "$5" "$6" "$7"
}
{
    printf '{"type":"user","timestamp":"2026-09-27T09:00:00.000Z","message":{"content":"hi"}}\n'
    rec m1 2026-09-27T09:00:01.100Z model-a 1 10 100 1000      # before since: 1111
    rec m2 2026-09-27T10:00:00.500Z model-a 2 20 200 2000      # 2222
    rec m2 2026-09-27T10:00:00.900Z model-a 2 20 200 2000      # same message, 2nd block
    rec m3 2026-09-27T10:30:00.000Z model-a 3 30 300 3000      # 3333
    printf 'not json, a torn final line'
} > "$T"
rec s1 2026-09-27T10:05:00.000Z model-b 5 0 0 5 > "$proj/sess1/subagents/agent-x.jsonl"   # 10
rec s2 2026-09-27T10:06:00.000Z model-c 7 0 0 7 > "$proj/sess1/subagents/agent-y.jsonl"   # 14
rec s3 2026-09-27T08:00:00.000Z model-b 9 0 0 9 > "$proj/sess1/subagents/agent-z.jsonl"   # before since

run() { env -u CLAUDE_CODE_SESSION_ID -u TILLANDSIAS_CYCLE_START_TS bash "$ST" "$@" 2>/dev/null; }
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# 1 — main window and cumulative, deduplicated by message id.
out="$(run --transcript "$T" --since 2026-09-27T10:00:00Z)"
if [ "$(field "$out" main_ctx)" = 5555 ] && [ "$(field "$out" main_ctx_cumulative)" = 6666 ] \
   && [ "$(field "$out" source)" = "$T" ]; then
    ok "arm 1: main_ctx=5555 main_ctx_cumulative=6666 (m2 counted once)"
else
    bad "arm 1: want main_ctx=5555 main_ctx_cumulative=6666 source=$T, got: $out"
fi

# 2 — sub-agents in the window, by model.
if [ "$(field "$out" subagent_tokens)" = 24 ] && [ "$(field "$out" agents)" = 2 ] \
   && [ "$(field "$out" by_model)" = "model-b:1,model-c:1" ]; then
    ok "arm 2: subagent_tokens=24 agents=2 by_model=model-b:1,model-c:1"
else
    bad "arm 2: want subagent_tokens=24 agents=2 by_model=model-b:1,model-c:1, got: $out"
fi

# 3 — the emit records the measurement, resolved by session id.
log="$scratch/tokens.jsonl"
CLAUDE_CONFIG_DIR="$scratch" CLAUDE_CODE_SESSION_ID=sess1 TILLANDSIAS_TOKENS_LOG="$log" \
    bash "$CM" --emit-tokens --from-transcript host=h cycle=c1 label=l since=2026-09-27T10:00:00Z >/dev/null 2>&1
rows="$(wc -l < "$log" 2>/dev/null | tr -d ' ')"
got="$(jq -r 'select(.cycle == "c1") | "\(.main_ctx) \(.source)"' "$log" 2>/dev/null)"
if [ "$rows" = 1 ] && [ "$got" = "5555 $T" ]; then
    ok "arm 3: --from-transcript wrote one record, main_ctx=5555 source=transcript"
else
    bad "arm 3: want one record '5555 $T', got rows=$rows '$got'"
fi

# 4 — NEGATIVE CONTROL: nothing resolvable is absent, not a guess, even when
#     the caller also hand-passed a number.
log4="$scratch/tokens4.jsonl"
env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$scratch/none" TILLANDSIAS_TOKENS_LOG="$log4" \
    bash "$CM" --emit-tokens --from-transcript host=h cycle=c4 label=l main_ctx=999 >/dev/null 2>&1
got4="$(jq -r '"\(.main_ctx) \(.source)"' "$log4" 2>/dev/null)"
if [ "$got4" = "0 absent" ]; then
    ok "arm 4: no transcript -> main_ctx=0 source=absent"
else
    bad "arm 4: want '0 absent', got '$got4'"
fi

# 5 — NEGATIVE CONTROL: a drifted usage object names the missing field.
D="$scratch/drift.jsonl"
printf '{"type":"assistant","timestamp":"2026-09-27T10:00:00Z","message":{"id":"d1","model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":1}}}\n' > "$D"
out5="$(run --transcript "$D" --since 2026-09-27T00:00:00Z)"
if [ "$(field "$out5" source)" = "absent:schema-drift:cache_read_input_tokens" ] \
   && [ "$(field "$out5" main_ctx)" = 0 ] && [ "$(field "$out5" main_ctx_cumulative)" = 0 ]; then
    ok "arm 5: missing field -> source=absent:schema-drift:cache_read_input_tokens, zeros"
else
    bad "arm 5: want schema-drift:cache_read_input_tokens with zeros, got: $out5"
fi

if [ "$pass" -eq "$total" ]; then
    echo "ok:session-tokens:$pass/$total"
    exit 0
fi
echo "fail:session-tokens:$pass/$total"
exit 1
