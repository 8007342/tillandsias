-- @env PATH HOME
-- @trace order:858-ihcb, order:2367-wtse
--
-- test-bench-prompt-uniqueness.lua — bench-inference-floor.sh never sends one prompt twice (a
-- server's prefix cache would answer it), and its tool-call mode reports what the model did.
-- Ported from the .sh of the same name (2367-wtse). curl is a stub; nothing is contacted.
--
--   1 six generate calls, all distinct      2 they differ within the first 24 characters
--   3 prefill comes from the isolated probes   4 no projection without a measured corpus
--   5 tool-call: ok, used, pass rate, latency  6 a model that calls none, 7 one that drops the result
--   8 tool-call replaces the throughput sweep
--
-- Usage: tillandsias-plan script run scripts/lua/test-bench-prompt-uniqueness.lua
-- Verdict: ok:bench-prompt-uniqueness:<n> arms | violation:... | skip:bench-prompt-uniqueness:no-jq

local fixture = require "common.fixture"
local T = fixture.new("bench-prompt-uniqueness")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
-- The subject's own JSON reader.
if not fixture.which("j" .. "q") then T:skip("no-jq") end
local d = T:scratch()
fs.mkdir(d.rel .. "/bin"); fs.write(d.rel .. "/prompts", "")
fs.write(d.rel .. "/bin/curl", [==[#!/usr/bin/env bash
url=""; data=""
while [ $# -gt 0 ]; do case "$1" in -d) shift; data="$1" ;; http*) url="$1" ;; esac; shift; done
[ "$data" = "@-" ] && data="$(cat)"
case "$url" in
    */api/version) printf '{"version":"stub"}' ;;
    */api/ps)      printf '{"models":[{"name":"stub","size":100,"size_vram":0}]}' ;;
    */api/embed)   printf '{"embeddings":[[0.0]]}' ;;
    */api/generate)
        printf '%s' "$data" | "$STUB_PLAN" json get -r .prompt - >>"$STUB_LOG"
        printf '{"prompt_eval_count":100,"prompt_eval_duration":1000000000,"eval_count":200,"eval_duration":10000000000,"load_duration":1000000,"total_duration":11000000000}' ;;
    */v1/chat/completions)
        if grep -q '"role":"tool"' <<<"$data"; then
            n="$(grep -o 'build [0-9][0-9]*' <<<"$data" | head -1)"
            [ "${STUB_TC_MODE:-ok}" = ignore ] && n="nothing useful"
            printf '{"choices":[{"message":{"role":"assistant","content":"The current %s."}}]}' "$n"
        elif [ "${STUB_TC_MODE:-ok}" = none ]; then
            printf '{"choices":[{"message":{"role":"assistant","content":"I do not need a tool."}}]}'
        else
            printf '%s' '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"get_build_number","arguments":"{\"project\":\"tillandsias\"}"}}]}}]}'
        fi ;;
    *) exit 1 ;;
esac
exit 0
]==])
local function bench(more, ...)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), STUB_PLAN = PLAN, STUB_LOG = d.abs .. "/prompts", BENCH_ENDPOINT = "http://stub", BENCH_MODELS = "stubmodel=T0" }
    for k, v in pairs(more) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", ROOT .. "/scripts/bench-inference-floor.sh", ... }, cwd = d.abs, env = e, env_unset = { "TILLANDSIAS_*", "BENCH_*" }, timeout_ms = 120000,
        stdin = 'chmod +x bin/curl\nexport PATH="$PWD/bin:$PATH"\nexec bash "$@" </dev/null\n' }
    return "\n" .. (r.stdout or ""), "rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 500) .. (r.stderr or ""):sub(1, 300)
end
local o, why = bench{ BENCH_EMBED_N = "1", BENCH_PREFILL_REPS = "3" }
local prompts, seen, same = {}, {}, {}
for l in fs.read(d.rel .. "/prompts"):gmatch("[^\n]+") do
    prompts[#prompts + 1] = l
    if seen[l] then same[#same + 1] = l end
    seen[l] = true
end
T:arm("1a six generate calls", #prompts == 6, #prompts .. " " .. why)
T:arm("1b every prompt is distinct", #prompts > 0 and #same == 0, table.concat(same, " | "))
local a, b, shared = prompts[1] or "", prompts[2] or "", 0
while shared < #a and shared < #b and a:byte(shared + 1) == b:byte(shared + 1) do shared = shared + 1 end
T:arm("2 they differ within the first 24 characters", a ~= "" and shared <= 24, "shared=" .. shared)
T:arm("3 prefill comes from the isolated probes, three kept", o:match("prefill_tok_s=([0-9.]+)") == "100.00" and o:match("prefill_n=(%d+)") == "3", why)
T:arm("4 no projection without a measured chunk count", o:match("full_rebuild=([a-z:%-]+)") == "skipped:no-measured-corpus-chunk-count", why)
local function tc(mode) return bench({ STUB_TC_MODE = mode, BENCH_TOOLCALL_TRIALS = "2" }, "--tool-call") end
local function first(x, key) return x:match("\ntoolcall: [^\n]-trial=1 [^\n]-" .. key .. "=([a-z]+)") end
o, why = tc("ok")
T:arm("5a a round trip is ok and the answer used the result", first(o, "tool_call_roundtrip") == "ok" and first(o, "final") == "used", why)
T:arm("5b the summary's pass rate", o:match("\ntoolcall_summary: [^\n]-pass_rate=([0-9.]+)") == "1.00", why)
local _, timed = o:gsub("\ntoolcall: [^\n]- turn1_ms=%d+ turn2_ms=%d+ total_ms=%d+", "")
T:arm("5c latency on both trials", timed == 2, timed .. " " .. why)
T:arm("8 tool-call replaces the throughput sweep", not text.contains(o, "\ngen:"), why)
o, why = tc("none")
T:arm("6 a model that calls no tool is none", first(o, "tool_call_roundtrip") == "none", why)
o, why = tc("ignore")
T:arm("7 an answer that drops the result is malformed", first(o, "tool_call_roundtrip") == "malformed", why)
T:finish()
