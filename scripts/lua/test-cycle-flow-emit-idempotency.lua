-- @env PATH HOME
-- @trace order:682-epud, order:801-tpxd, spec:meta-orchestration, order:2306-y8sg
--
-- test-cycle-flow-emit-idempotency.lua — `cycle-metrics.sh --emit-flow` writes one record per
-- host+cycle. Ported from the .sh of the same name (2306-y8sg). Measured on windows
-- 2026-08-15: one cycle whose finalization was retried wrote three records, and the reporter
-- said cycles=8 over six. Retries happen on the cycles that went wrong, so duplicates add
-- count from the worst cases and dilute the averages. The real flow log is never touched.
--
--   1 a second emit for a host+cycle REPLACES the first
--   2 the LATER record survives (a retry runs after more work)
--   3 a different cycle appends
--   4 the same cycle id on another host appends, and neither it nor its retry evicts anybody
--   5 omitting cycle= MINTS <host>-<utc>, says so, and appends
--   6 every record is whole
--   7 an unwritable log still exits 0: the emit never fails the cycle it measures
--   8 "cycle":"-" is unreachable, even when asked for by name (801-tpxd)
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-flow-emit-idempotency.lua
-- Verdict: ok:cycle-flow-emit-idempotency:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-flow-emit-idempotency")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
local LOG = d.abs .. "/flow.jsonl"

local function emit(args, log)
    local argv = { SH, ROOT .. "/scripts/cycle-metrics.sh", "--emit-flow" }
    for a in args:gmatch("%S+") do argv[#argv + 1] = a end
    return proc.run{ argv = argv, cwd = ROOT, timeout_ms = 60000, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_CYCLE_FLOW_LOG = log or LOG } }
end
local function rows()
    local t = {}
    if fs.exists(d.rel .. "/flow.jsonl") then
        for l in fs.read(d.rel .. "/flow.jsonl"):gmatch("[^\r\n]+") do t[#t + 1] = l end
    end
    return t
end
local function all() return table.concat(rows(), " | ") end
-- The `completed` of every record for a host+cycle, comma-joined.
local function completed(host, cycle)
    local t = {}
    for _, l in ipairs(rows()) do
        if text.contains(l, '"host":"' .. host .. '","cycle":"' .. cycle .. '"') then t[#t + 1] = l:match('"completed":(%d+)') or "?" end
    end
    return table.concat(t, ",")
end

emit("host=windows cycle=c1 batch_epic=e completed=0 commits=1")
local first = #rows()
emit("host=windows cycle=c1 batch_epic=e completed=3 commits=2")
T:arm("1 a retry replaces, never appends", first == 1 and #rows() == 1, first .. " then " .. #rows())
T:arm("2 the later record survives", completed("windows", "c1") == "3", all())
emit("host=windows cycle=c2 batch_epic=e completed=1 commits=1")
T:arm("3 a new cycle appends", #rows() == 2, all())
emit("host=linux cycle=c2 batch_epic=e completed=8 commits=1")
emit("host=linux cycle=c2 batch_epic=e completed=9 commits=1")  -- a retry there: only its own row may go
T:arm("4 another host's cycle of the same id appends and evicts nobody",
    #rows() == 3 and completed("windows", "c2") == "1" and completed("linux", "c2") == "9", all())
local r = emit("host=windows batch_epic=e")
local minted = 0
for _, l in ipairs(rows()) do if l:find('"host":"windows","cycle":"windows%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ"') then minted = minted + 1 end end
T:arm("5 a missing cycle= mints <host>-<utc>, says so and appends",
    #rows() == 4 and minted == 1 and (r.stderr or ""):find("^note:[^\n]*minted cycle=windows%-") ~= nil, (r.stderr or "") .. " " .. all())
r = emit("host=windows cycle=c9", d.abs .. "/nonexistent-dir/flow.jsonl")
T:arm("7 an unwritable log still exits 0", r.code == 0, tostring(r.code) .. " " .. (r.stderr or ""))
emit("host=windows cycle=- completed=7")
local sentinel, torn = 0, {}
for _, l in ipairs(rows()) do
    if text.contains(l, '"cycle":"-"') then sentinel = sentinel + 1 end
    local ok, rec = pcall(json.parse, l)
    if not (ok and type(rec) == "table" and rec.host and rec.cycle) then torn[#torn + 1] = l end
end
T:arm("6 every record is whole JSON naming host and cycle", #rows() == 5 and #torn == 0, table.concat(torn, " | ") .. " of " .. #rows())
T:arm("8 cycle=- is rewritten, never stored", sentinel == 0 and text.contains(all(), '"completed":7'), all())
T:finish()
