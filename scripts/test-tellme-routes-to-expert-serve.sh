#!/usr/bin/env bash
# @trace order:1814-x78v, spec:expert-serve-grounded-pipeline
#
# Fixture for order 1814-x78v: `tellme howto` and free-form `tellme about`
# answer through expert-serve (OpenAI-shaped /v1/chat/completions, model id
# cheatsheet|all) when it answers; the keyword-grep + /api/generate path runs
# only when it does not, without the "general knowledge" sentence, and honours
# TILLANDSIAS_INFERENCE_MODEL. One arm per exit criterion, plus controls:
#
#   1. expert-serve up: `tellme howto <q>` sends exactly ONE POST to
#      <expert>/v1/chat/completions whose model is `cheatsheet` and whose last
#      user message is <q>, prints the answer and its citation, and never
#      posts /api/generate.
#   2. expert-serve up: `tellme about "<sentence>"` sends one chat completion
#      with model `all`; a one-word `tellme about <slug>` stays an index
#      lookup and contacts nobody (control).
#   3. expert-serve down: `tellme howto <q>` posts /api/generate, its prompt
#      contains no "general knowledge" text, and the output says UNGROUNDED.
#   4. expert-serve down, TILLANDSIAS_INFERENCE_MODEL=llama3.2:3b: the
#      /api/generate request names llama3.2:3b; unset, it names qwen2.5:0.5b
#      (control: the arm discriminates the env var, not a changed default).
#
# HERMETIC: a `curl` shim first on PATH answers every request from canned
# bodies and records each URL and body; no socket is opened, so a real
# expert-serve or ollama on this host cannot leak in. "Port closed" is the
# shim exiting 7 (curl's could-not-connect) for the expert URL.
#
# PRE-FIX RESULT: FAILS arms 1-4 — pre-fix tellme posts /api/generate and never
# contacts the expert URL, its prompt carries "use your general knowledge", and
# its hardcoded qwen2.5:0.5b-first list beats the env var.
#
# TELLME_UNDER_TEST=<path> runs the arms against another copy (pre-fix runs).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TELLME="${TELLME_UNDER_TEST:-$ROOT/images/default/cli/tellme}"
pass=0; total=4
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "skip:tellme-routes-to-expert-serve:no-plan-binary — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
# Reads go through the plan binary's `json get`, not jq (1375-tsfu ratchet).
# tellme's own fallback path still parses ollama's stream with jq.
command -v jq >/dev/null 2>&1 || { echo "skip:tellme-routes-to-expert-serve:no-jq-for-the-tellme-fallback"; exit 0; }
jget() { "$_plan" json get "$@"; }

_tmpbase="${TMPDIR:-/tmp}"
[ ! -d /tmp/opencode ] || _tmpbase=/tmp/opencode
W="$(mktemp -d "$_tmpbase/tellme-expert.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

EXPERT="http://127.0.0.1:65011"
INFER="http://inference.stub:11434"

# A cheatsheet corpus with one entry the keyword search can find.
mkdir -p "$W/cheatsheets/runtime" "$W/bin"
cat > "$W/cheatsheets/INDEX.md" <<'EOF'
# Cheatsheet index

## runtime
- runtime/database-containers.md — run a database container with rootless podman
EOF
cat > "$W/cheatsheets/runtime/database-containers.md" <<'EOF'
---
title: database containers
---
# Database containers
Use rootless podman: `podman run -d postgres:16`.
EOF

# The curl shim: logs `<n> <url>` to calls.log and the request body to
# body.<n>; answers by URL. Body forms: -d/--data/--data-raw/--data-binary
# with a literal, @file or @-.
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
log="$SHIM_DIR/calls.log"
n=$(( $( [ -f "$log" ] && wc -l < "$log" || echo 0 ) + 1 ))
url="" body=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--data|--data-raw|--data-binary) body="$2"; shift 2 ;;
        --max-time|-m|-X|-H|-o|-w) shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$body" in
    @-) body="$(cat)" ;;
    @*) body="$(cat "${body#@}")" ;;
esac
printf '%s %s\n' "$n" "$url" >> "$log"
printf '%s' "$body" > "$SHIM_DIR/body.$n"
case "$url" in
    "$SHIM_EXPERT"/*)
        [ ! -f "$SHIM_DIR/expert.down" ] || exit 7
        case "$url" in
            */v1/models) printf '%s\n' '{"object":"list","data":[{"id":"all","object":"model"},{"id":"cheatsheet","object":"model"}]}' ;;
            */v1/chat/completions) printf '%s\n' '{"id":"expert-serve-1","object":"chat.completion","model":"cheatsheet","choices":[{"index":0,"message":{"role":"assistant","content":"STUB-GROUNDED-ANSWER use podman run"},"finish_reason":"stop"}],"tillandsias_envelope":{"answer":"STUB-GROUNDED-ANSWER use podman run","citations":[{"path":"cheatsheets/runtime/forge-constraints.md","line_start":3,"line_end":9,"kind":"cheatsheet","authority":{}}]}}' ;;
            *) exit 22 ;;
        esac ;;
    "$SHIM_INFER"/api/tags) printf '%s\n' '{"models":[{"name":"qwen2.5:0.5b"},{"name":"llama3.2:3b"}]}' ;;
    "$SHIM_INFER"/api/generate) printf '%s\n' '{"response":"STUB-FALLBACK-ANSWER","done":true}' ;;
    *) exit 7 ;;
esac
EOF
chmod +x "$W/bin/curl"

# run_tellme <case-dir> <args...> — fresh log per case; stdout+stderr to out.
run_tellme() {
    local d="$1"; shift
    mkdir -p "$d"
    env PATH="$W/bin:$PATH" SHIM_DIR="$d" SHIM_EXPERT="$EXPERT" SHIM_INFER="$INFER" \
        TELLME_EXPERT_URL="$EXPERT" TILLANDSIAS_INFERENCE_URL="$INFER" \
        TILLANDSIAS_CHEATSHEETS="$W/cheatsheets" TELLME_PLAN_BIN="$_plan" \
        BASH_ENV=/dev/null bash "$TELLME" "$@" > "$d/out" 2>&1 </dev/null
    echo $? > "$d/rc"
}
# calls <case-dir> <url-suffix> — the call numbers whose URL ends in suffix.
calls() { [ -f "$1/calls.log" ] && grep -E " .*$2\$" "$1/calls.log" | cut -d' ' -f1; }
count() { local c; c="$(calls "$1" "$2")"; [ -n "$c" ] && printf '%s\n' "$c" | wc -l | tr -d ' ' || echo 0; }

# 1 — howto through expert-serve, model cheatsheet.
C="$W/c1"; Q="run a database container"
run_tellme "$C" howto "$Q"
n_chat="$(count "$C" '/v1/chat/completions')"
n_gen="$(count "$C" '/api/generate')"
m="" u=""
if [ "$n_chat" = 1 ]; then
    b="$C/body.$(calls "$C" '/v1/chat/completions')"
    m="$(jget -r '.model' "$b" 2>/dev/null)"
    u="$(jget -r '.messages[-1].content' "$b" 2>/dev/null)"
fi
if [ "$n_chat" = 1 ] && [ "$m" = cheatsheet ] && [ "$u" = "$Q" ] && [ "$n_gen" = 0 ] \
   && grep -q 'STUB-GROUNDED-ANSWER' "$C/out" \
   && grep -q 'cheatsheets/runtime/forge-constraints.md:3-9' "$C/out"; then
    ok "arm 1: howto sent one /v1/chat/completions (model=cheatsheet), printed answer + citation, no /api/generate"
else
    bad "arm 1: chat_posts=$n_chat model='$m' user='$u' generate_posts=$n_gen rc=$(cat "$C/rc") out: $(tr '\n' ' ' < "$C/out" | cut -c1-300)"
fi

# 2 — free-form about through expert-serve, model all; a slug stays local.
C="$W/c2"; Q="how do I push from the forge"
run_tellme "$C" about "$Q"
n_chat="$(count "$C" '/v1/chat/completions')"
m=""
[ "$n_chat" != 1 ] || m="$(jget -r '.model' "$C/body.$(calls "$C" '/v1/chat/completions')" 2>/dev/null)"
S="$W/c2-slug"
run_tellme "$S" about runtime
if [ "$n_chat" = 1 ] && [ "$m" = all ] && grep -q 'STUB-GROUNDED-ANSWER' "$C/out" \
   && [ ! -s "$S/calls.log" ] && grep -q 'database-containers.md' "$S/out"; then
    ok "arm 2: free-form about sent one chat completion (model=all); slug about stayed an index lookup"
else
    bad "arm 2: chat_posts=$n_chat model='$m' slug_calls=$( [ -f "$S/calls.log" ] && wc -l < "$S/calls.log" || echo 0) out: $(tr '\n' ' ' < "$C/out" | cut -c1-200) slug-out: $(tr '\n' ' ' < "$S/out" | cut -c1-120)"
fi

# 3 — port closed: grep fallback, no "general knowledge", labelled.
C="$W/c3"; mkdir -p "$C"; : > "$C/expert.down"
run_tellme "$C" howto "run a database container"
n_gen="$(count "$C" '/api/generate')"
p=""
[ "$n_gen" != 1 ] || p="$(jget -r '.prompt' "$C/body.$(calls "$C" '/api/generate')" 2>/dev/null)"
if [ "$n_gen" = 1 ] && [ -n "$p" ] && ! grep -qi 'general knowledge' <<<"$p" \
   && grep -q 'database-containers.md' <<<"$p" \
   && ! grep -qi 'general knowledge' "$C/out" && grep -q 'UNGROUNDED' "$C/out" \
   && [ "$(count "$C" '/v1/chat/completions')" = 0 ]; then
    ok "arm 3: port closed -> one /api/generate, grep context present, no 'general knowledge', output labelled UNGROUNDED"
else
    gk=no; grep -qi 'general knowledge' <<<"$p" && gk=yes
    bad "arm 3: generate_posts=$n_gen prompt_has_general_knowledge=$gk ungrounded_label=$(grep -c UNGROUNDED "$C/out") out: $(tr '\n' ' ' < "$C/out" | cut -c1-200)"
fi

# 4 — fallback honours TILLANDSIAS_INFERENCE_MODEL; unset keeps qwen first.
C="$W/c4"; mkdir -p "$C"; : > "$C/expert.down"
TILLANDSIAS_INFERENCE_MODEL=llama3.2:3b run_tellme "$C" howto "run a database container"
D="$W/c4-default"; mkdir -p "$D"; : > "$D/expert.down"
( unset TILLANDSIAS_INFERENCE_MODEL; run_tellme "$D" howto "run a database container" )
m4=""; md=""
[ "$(count "$C" '/api/generate')" != 1 ] || m4="$(jget -r '.model' "$C/body.$(calls "$C" '/api/generate')" 2>/dev/null)"
[ "$(count "$D" '/api/generate')" != 1 ] || md="$(jget -r '.model' "$D/body.$(calls "$D" '/api/generate')" 2>/dev/null)"
if [ "$m4" = llama3.2:3b ] && [ "$md" = qwen2.5:0.5b ]; then
    ok "arm 4: fallback request named TILLANDSIAS_INFERENCE_MODEL=llama3.2:3b; unset it named qwen2.5:0.5b"
else
    bad "arm 4: with env model='$m4' (want llama3.2:3b), without env model='$md' (want qwen2.5:0.5b)"
fi

echo "tellme-routes-to-expert-serve: $pass/$total"
[ "$pass" -eq "$total" ]
