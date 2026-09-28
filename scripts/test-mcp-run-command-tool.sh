#!/usr/bin/env bash
# @trace order:1443-r4cj, spec:command-runtime, spec:forge-environment-discoverability
#
# test-mcp-run-command-tool.sh — project-info's `run_command` tool, the MCP door
# onto `tillandsias-plan run --json` (1443-8pur), driven over stdio.
#
#   1  tools/list includes run_command: argv (array of strings, required), cwd,
#      env, timeout_ms, stdin, capture_bytes
#   2  run_command {argv:["git","status","--porcelain"]} returns the object
#      `run --json` prints (the same eleven keys, a run_id, policy allow) and
#      the same stdout as the verb run directly; the audit says caller=mcp
#   3  a denied argv (gh auth token) is a RESULT with status=policy_denied, a
#      why and a remedy — not a JSON-RPC error
#   4  no eval and no `bash -c` in the run_command arm, and argv reaches the
#      verb through --argv-json - on stdin
#   5  hostile argv entries ($(…), backticks, ;, |) reach the child literally
#      and execute nothing; stdin and an env value holding a newline arrive
#      byte for byte
#   6  a deadline is status timed_out (a result); bad params are -32602; a
#      binary without `run` is -32603 naming it, and the server keeps serving
#
# Pre-fix: FAILS at arm 1 (no run_command tool).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/images/default/config-overlay/mcp/project-info.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/mcp-run-command.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
caps="$("$PLAN" capabilities 2>/dev/null)"
grep -qx run <<<"$caps" || { echo "FAIL: $PLAN has no \`run\` verb (stale artifact; rebuild tillandsias-plan)" >&2; exit 1; }
jget() { "$PLAN" json get "$@"; }

# Hermetic: the audit log and the server's usage log land in the scratch HOME;
# the server runs from a scratch git repo so `git status` has something to say.
export HOME="$W/home"
export TILLANDSIAS_PLAN_BIN="$PLAN"
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/audit.jsonl"
mkdir -p "$HOME" "$W/repo"
cd "$W/repo" || exit 1
git init -q . && : >untracked.txt

# One request per server process: each answer is the server's single stdout line.
rpc() { printf '%s\n' "$1" | bash "$SERVER" 2>/dev/null; }
call() { rpc "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"run_command\",\"arguments\":$1}}"; }
text() { jget -r '.result.content[0].text' <<<"$1" 2>/dev/null; }

# ── 1 ───────────────────────────────────────────────────────────────────────
list="$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
schema="$(jget -c '.result.tools[] | select(.name == "run_command") | .inputSchema' <<<"$list" 2>/dev/null)"
props="$(jget -c '.properties | keys' <<<"$schema" 2>/dev/null)"
if [ "$props" = '["argv","capture_bytes","cwd","env","stdin","timeout_ms"]' ] &&
    [ "$(jget -c '.required' <<<"$schema")" = '["argv"]' ] &&
    [ "$(jget -r '.properties.argv.items.type' <<<"$schema")" = string ]; then
    ok "arm 1: tools/list includes run_command with argv (string[], required), cwd, env, timeout_ms, stdin, capture_bytes"
else
    bad "arm 1: schema=[$schema]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
resp="$(call '{"argv":["git","status","--porcelain"]}')"
obj="$(text "$resp")"
direct="$("$PLAN" run --json -- git status --porcelain 2>/dev/null)"
keys="$(jget -c 'keys' <<<"$obj" 2>/dev/null)"
if [ "$(jget -c '.error' <<<"$resp")" = null ] && [ -n "$keys" ] &&
    [ "$keys" = "$(jget -c 'keys' <<<"$direct")" ] &&
    [ "$(jget -r '.status' <<<"$obj")" = exited ] && [ "$(jget -r '.run_id' <<<"$obj")" != null ] &&
    [ "$(jget -r '.policy.decision' <<<"$obj")" = allow ] &&
    [ "$(jget -r '.stdout' <<<"$obj")" = "$(jget -r '.stdout' <<<"$direct")" ] &&
    [ "$(jget -r '.stdout' <<<"$obj")" = "?? untracked.txt" ]; then
    ok "arm 2: git status --porcelain returns the verb's object (keys $keys) with its stdout"
else
    bad "arm 2: resp=[$resp] direct=[$direct]"
fi
# The direct run above audited last as caller=run; the MCP call just before it
# must have audited as caller=mcp (so the audit tells the doors apart).
mcp_line="$(grep -F '"caller":"mcp"' "$TILLANDSIAS_POLICY_AUDIT_LOG" | tail -n 1)"
run_line="$(tail -n 1 "$TILLANDSIAS_POLICY_AUDIT_LOG")"
if [ "$(jget -r '.program' <<<"$mcp_line" 2>/dev/null)" = git ] && [ "$(jget -r '.caller' <<<"$run_line")" = run ]; then
    ok "arm 2: the MCP call is audited as caller=mcp, the direct verb as caller=run"
else
    bad "arm 2 audit: mcp=[$mcp_line] run=[$run_line]"
fi

# ── 3 ───────────────────────────────────────────────────────────────────────
resp="$(call '{"argv":["gh","auth","token"]}')"
obj="$(text "$resp")"
if [ "$(jget -c '.error' <<<"$resp")" = null ] && [ "$(jget -r '.status' <<<"$obj")" = policy_denied ] &&
    [ "$(jget -r '.policy.rule_id' <<<"$obj")" = no-credential-mutation ] &&
    [ -n "$(jget -r '.policy.why // empty' <<<"$obj")" ] && [ -n "$(jget -r '.policy.remedy // empty' <<<"$obj")" ]; then
    ok "arm 3: a denied argv is a result with status policy_denied, a why and a remedy — not an error"
else
    bad "arm 3: resp=[$resp]"
fi

# ── 4 ───────────────────────────────────────────────────────────────────────
arm="$(awk '/^                "run_command"\)$/ { on = 1 } on { print } on && /^                    ;;$/ { exit }' "$SERVER")"
hits="$(grep -nE 'eval |bash -c' <<<"$arm")"
if [ -n "$arm" ] && [ -z "$hits" ] && grep -qF -- '--argv-json -' <<<"$arm"; then
    ok "arm 4: the run_command arm has no eval and no bash -c, and hands argv over as --argv-json -"
else
    bad "arm 4: arm_lines=$(grep -c . <<<"$arm") hits=[$hits]"
fi

# ── 5 ───────────────────────────────────────────────────────────────────────
resp="$(call '{"argv":["printf","%s|%s|%s","$(touch MARK1)","`touch MARK2`","; touch MARK3 | cat"]}')"
got="$(jget -r '.stdout' <<<"$(text "$resp")" 2>/dev/null)"
want='$(touch MARK1)|`touch MARK2`|; touch MARK3 | cat'
if [ "$got" = "$want" ] && [ ! -e MARK1 ] && [ ! -e MARK2 ] && [ ! -e MARK3 ]; then
    ok "arm 5: hostile argv entries reach the child literally and execute nothing"
else
    bad "arm 5: got=[$got] markers=[$(ls MARK* 2>/dev/null)]"
fi
resp="$(call '{"argv":["cat"],"stdin":"line one\n$(x) `y` \"q\""}')"
got="$(jget -r '.stdout' <<<"$(text "$resp")" 2>/dev/null)"
want="$(printf 'line one\n$(x) `y` "q"')"
[ "$got" = "$want" ] && ok "arm 5: stdin arrives byte for byte" || bad "arm 5 stdin: got=[$got]"
resp="$(call '{"argv":["printenv","R4CJ_VALUE"],"env":{"R4CJ_VALUE":"a b\nc"}}')"
got="$(jget -r '.stdout' <<<"$(text "$resp")" 2>/dev/null)"
[ "$got" = "$(printf 'a b\nc\n')" ] && ok "arm 5: an env value holding a newline arrives intact" || bad "arm 5 env: got=[$got]"

# ── 6 ───────────────────────────────────────────────────────────────────────
resp="$(call '{"argv":["sleep","5"],"timeout_ms":300}')"
obj="$(text "$resp")"
[ "$(jget -r '.status' <<<"$obj")" = timed_out ] && [ "$(jget -r '.code' <<<"$obj")" = null ] &&
    ok "arm 6: a deadline is a result with status timed_out and no code" || bad "arm 6 timeout: [$resp]"
bad_params=0
for a in '{"argv":"git status"}' '{"argv":[]}' '{"argv":["git",1]}' '{"argv":["true"],"env":{"A B":"x"}}' \
    '{"argv":["true"],"timeout_ms":-1}' '{}'; do
    [ "$(jget -r '.error.code' <<<"$(call "$a")" 2>/dev/null)" = -32602 ] || { bad_params=1; bad "arm 6 params: $a"; }
done
[ "$bad_params" = 0 ] && ok "arm 6: malformed params (string argv, [], non-string entry, bad env key, negative deadline, none) are -32602"
printf '#!/bin/sh\n[ "$1" = capabilities ] && { echo query; exit 0; }\necho "error: unknown subcommand '"'"'run'"'"'" >&2\nexit 2\n' >"$W/stale-plan"
chmod +x "$W/stale-plan"
out="$({
    printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"run_command","arguments":{"argv":["true"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'
} | TILLANDSIAS_PLAN_BIN="$W/stale-plan" bash "$SERVER" 2>/dev/null)"
first="$(head -n 1 <<<"$out")"
second="$(sed -n 2p <<<"$out")"
if [ "$(jget -r '.error.code' <<<"$first")" = -32603 ] && grep -qF "unknown subcommand 'run'" <<<"$(jget -r '.error.message' <<<"$first")" &&
    [ "$(jget -r '.id' <<<"$second")" = 9 ]; then
    ok "arm 6: a binary without run is -32603 naming it, and the server answers the next request"
else
    bad "arm 6 stale: [$out]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: mcp-run-command-tool $pass/$total (1443-r4cj)"
    exit 0
fi
echo "FAIL: mcp-run-command-tool $pass/$total (1443-r4cj)"
exit 1
