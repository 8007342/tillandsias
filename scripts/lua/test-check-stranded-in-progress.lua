-- @env PATH HOME
-- @trace spec:methodology-accountability, order:946-pdpi, order:641-e2qa, order:2311-xca3
--
-- test-check-stranded-in-progress.lua — the stranding predicate of
-- scripts/check-stranded-in-progress.sh. Ported from the .sh of the same name (2311-xca3).
-- Two LONG-WORKED packets, alike but for when they were last touched: the old predicate
-- (count progress over all history, flag zero) flagged neither, so arm 2 fails on it.
--
--   1 a recent claim is NOT flagged   2 a stale claim IS flagged
--   3 its row carries its age         4 the population is confessed
--   5 the threshold is honoured       6 a non-numeric threshold refuses (943-unii)
--
-- Fixed instants and a pinned NOW: no date arithmetic (761-g36m).
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-stranded-in-progress.lua
-- Verdict: ok:check-stranded-in-progress:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-stranded-in-progress")
local PLAN, ROOT, SH = fixture.plan_binary(), fixture.repo_root(), fixture.posix_shell()
if PLAN == "" then T:refuse("no-plan-binary") end
local NOW_EPOCH = "1788177600" -- 2026-08-31T12:00:00Z
local RECENT, STALE, OLD = "2026-08-31T11:40:00Z", "2026-08-28T12:00:00Z", "2026-08-01T12:00:00Z"

local d = T:scratch()
local function row(id, order, ts)
    local function ev(t, s) return '      - type: progress\n        ts: "' .. t .. '"\n        host: fixture\n        summary: ' .. s .. "\n" end
    return "  - packet_id: " .. id .. "\n    order: " .. order .. "\n    status: in_progress\n    desired_release: v0.5\n"
        .. "    pickup_role: linux\n    priority: p2\n    events:\n" .. ev(OLD, "worked a long time ago") .. ev(ts, "last touched")
end
fs.write(d.rel .. "/ledger.yaml", "plan_index:\n  default_status_values: [ready, in_progress, completed]\npackets:\n"
    .. row("long-worked-recent-claim", "990-aaaa", RECENT) .. row("long-worked-stale-claim", "990-bbbb", STALE))
fs.write(d.rel .. "/plan", '#!/usr/bin/env bash\nexec "' .. PLAN .. '" --index "' .. d.abs .. '/ledger.yaml" "$@"\n')
T:must{ "chmod", "+x", d.abs .. "/plan" }

local function sweep(hours)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/check-stranded-in-progress.sh" }, cwd = ROOT, timeout_ms = 120000, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = d.abs .. "/plan",
        TILLANDSIAS_STRANDED_HOURS = hours, TILLANDSIAS_STRANDED_NOW_EPOCH = NOW_EPOCH } }
    return "\n" .. (r.stdout or ""):gsub("\r", ""), r.code
end
local o = sweep("8")
if text.contains(o, "unavailable:no-jq") then T:refuse("no-jq") end
T:arm("1 a recent claim on a long-worked packet is not flagged",
    text.contains(o, "\nsummary: population=") and not o:find("\nstranded[^\n]*long%-worked%-recent%-claim"), o)
T:arm("2 a stale claim on a long-worked packet is flagged", o:find("\nstranded[^\n]*long%-worked%-stale%-claim") ~= nil, o)
T:arm("3 the stranded row carries its age", o:find("\nstranded[^\n]*long%-worked%-stale%-claim[^\n]*idle%-since=" .. STALE:gsub("%-", "%%-"), 1) ~= nil, o)
T:arm("4 the population is confessed", o:find("\nsummary: population=2 in_progress=2 stranded=1 threshold_events=%d+\n") ~= nil, o)
o = sweep("96")
T:arm("5 a 96 h threshold puts the same claim inside the window", text.contains(o, "\nsummary: population=2 in_progress=2 stranded=0 "), o)
local rc
o, rc = sweep("abc")
T:arm("6 a non-numeric threshold refuses", text.contains(o, "\nsummary: unavailable:bad-stranded-hours:abc\n") and rc == 2, tostring(rc) .. o)
T:finish()
