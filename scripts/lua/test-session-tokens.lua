-- @trace order:1437-3pj7, spec:meta-orchestration, order:2350-psb7
-- @env PATH HOME
--
-- test-session-tokens.lua — scripts/session-tokens.sh and cycle-metrics.sh --emit-tokens
-- --from-transcript (order 1437-3pj7), over a scratch transcript shaped like
-- ~/.claude/projects/<slug>/<session>.jsonl with a <session>/subagents/ child. Ported from
-- test-session-tokens.sh (2350-psb7); same five arms.
--
--   1 main_ctx sums the four usage fields over assistant messages at or after --since;
--     main_ctx_cumulative over all. One message is repeated on two lines (the harness writes
--     one line per content block), so a naive sum fails this arm
--   2 subagent_tokens, agents and by_model are summed from subagents/*.jsonl
--   3 --emit-tokens --from-transcript writes one record whose main_ctx equals arm 1's
--   4 NEGATIVE CONTROL no transcript resolvable -> zeros, source=absent, even with a
--     hand-passed number
--   5 NEGATIVE CONTROL a usage object missing a field -> source=absent:schema-drift:<field>
--
-- Every metrics log cycle-metrics.sh reads is pinned to an empty scratch file (2150-vf2v);
-- defaulted, they are this host's real logs (95 MB made it 118 s on one host).
--
-- GRAMMAR ok:session-tokens:5 arms | violation:session-tokens:<n>-failed | refused:session-tokens:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("session-tokens")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local ST, CM = ROOT .. "/scripts/session-tokens.sh", ROOT .. "/scripts/cycle-metrics.sh"
if not fs.exists("scripts/session-tokens.sh") then T:refuse("subject-missing", "scripts/session-tokens.sh") end

local W = T:scratch()
local PIN = {}
for _, k in ipairs{ "TILLANDSIAS_EXPERT_USAGE_LOG", "TILLANDSIAS_CYCLE_FLOW_LOG", "TILLANDSIAS_EXPERT_HEALTH_LOG" } do
    fs.write(W.rel .. "/pinned-" .. k .. ".jsonl", ""); PIN[k] = W.abs .. "/pinned-" .. k .. ".jsonl"
end
local proj = "/projects/-scratch-slug"
fs.mkdir(W.rel .. proj .. "/sess1/subagents")
local TR = W.abs .. proj .. "/sess1.jsonl"

local function rec(id, ts, model, i, cc, cr, o)
    return string.format('{"type":"assistant","timestamp":"%s","sessionId":"sess1","cwd":"/scratch","message":{"id":"%s","model":"%s","usage":'
        .. '{"input_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":%d}}}\n', ts, id, model, i, cc, cr, o)
end
fs.write(W.rel .. proj .. "/sess1.jsonl",
    '{"type":"user","timestamp":"2026-09-27T09:00:00.000Z","message":{"content":"hi"}}\n'
    .. rec("m1", "2026-09-27T09:00:01.100Z", "model-a", 1, 10, 100, 1000)      -- before since: 1111
    .. rec("m2", "2026-09-27T10:00:00.500Z", "model-a", 2, 20, 200, 2000)      -- 2222
    .. rec("m2", "2026-09-27T10:00:00.900Z", "model-a", 2, 20, 200, 2000)      -- same message, 2nd block
    .. rec("m3", "2026-09-27T10:30:00.000Z", "model-a", 3, 30, 300, 3000)      -- 3333
    .. "not json, a torn final line")
fs.write(W.rel .. proj .. "/sess1/subagents/agent-x.jsonl", rec("s1", "2026-09-27T10:05:00.000Z", "model-b", 5, 0, 0, 5))  -- 10
fs.write(W.rel .. proj .. "/sess1/subagents/agent-y.jsonl", rec("s2", "2026-09-27T10:06:00.000Z", "model-c", 7, 0, 0, 7))  -- 14
fs.write(W.rel .. proj .. "/sess1/subagents/agent-z.jsonl", rec("s3", "2026-09-27T08:00:00.000Z", "model-b", 9, 0, 0, 9))  -- before since

local UNSET = { "CLAUDE_CODE_SESSION_ID", "TILLANDSIAS_CYCLE_START_TS", "TILLANDSIAS_TOKENS_LOG", "CLAUDE_CONFIG_DIR" }
local function with(extra)
    local e = {}
    for k, v in pairs(PIN) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
local function tokens(transcript, since)
    local r = T:run{ SH, ST, "--transcript", transcript, "--since", since, cwd = ROOT, env = with(), env_unset = UNSET, timeout_ms = 60000 }
    local f = {}
    for k, v in (r.stdout or ""):gmatch("(%S+)=(%S*)") do f[k] = v end
    return f, r.stdout or ""
end
local function emit(log, extra, args)
    local argv = { SH, CM, "--emit-tokens", "--from-transcript" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, with(extra), UNSET, 120000
    argv.env.TILLANDSIAS_TOKENS_LOG = log
    T:run(argv)
end
local function jget(filter, file)
    return text.trim(T:run{ PLAN, "json", "get", "-c", filter, file, timeout_ms = 30000 }.stdout or "")
end

local f, out = tokens(TR, "2026-09-27T10:00:00Z")
T:arm("1 main_ctx=5555 main_ctx_cumulative=6666 (m2 counted once)",
    f.main_ctx == "5555" and f.main_ctx_cumulative == "6666" and f.source == TR, out)
T:arm("2 subagent_tokens=24 agents=2 by_model=model-b:1,model-c:1",
    f.subagent_tokens == "24" and f.agents == "2" and f.by_model == "model-b:1,model-c:1", out)

local log = W.abs .. "/tokens.jsonl"
emit(log, { CLAUDE_CONFIG_DIR = W.abs, CLAUDE_CODE_SESSION_ID = "sess1" }, { "host=h", "cycle=c1", "label=l", "since=2026-09-27T10:00:00Z" })
local body = fs.exists(W.rel .. "/tokens.jsonl") and fs.read(W.rel .. "/tokens.jsonl") or ""
local _, rows = body:gsub("\n", "")
local got = jget('select(.cycle == "c1") | [.main_ctx, .source]', log)
T:arm("3 --from-transcript wrote one record, main_ctx=5555 source=transcript", rows == 1 and got == '[5555,"' .. TR .. '"]',
    "rows=" .. rows .. " got '" .. got .. "'")

local log4 = W.abs .. "/tokens4.jsonl"
emit(log4, { CLAUDE_CONFIG_DIR = W.abs .. "/none" }, { "host=h", "cycle=c4", "label=l", "main_ctx=999" })
local got4 = jget("[.main_ctx, .source]", log4)
T:arm("4 CONTROL no transcript -> main_ctx=0 source=absent", got4 == '[0,"absent"]', "got '" .. got4 .. "'")

fs.write(W.rel .. "/drift.jsonl", '{"type":"assistant","timestamp":"2026-09-27T10:00:00Z","message":{"id":"d1","model":"m","usage":'
    .. '{"input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":1}}}\n')
local f5, out5 = tokens(W.abs .. "/drift.jsonl", "2026-09-27T00:00:00Z")
T:arm("5 CONTROL missing field -> source=absent:schema-drift:cache_read_input_tokens, zeros",
    f5.source == "absent:schema-drift:cache_read_input_tokens" and f5.main_ctx == "0" and f5.main_ctx_cumulative == "0", out5)

T:finish()
