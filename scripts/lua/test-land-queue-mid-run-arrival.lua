-- @env PATH HOME
-- @trace order:2435-lqpn, order:2143-z5uj
--
-- test-land-queue-mid-run-arrival.lua — a PR that becomes landable WHILE a run gates is taken by that
-- same run (2143-z5uj: pass 1 re-reads the queue before every pick, including the one after the last
-- candidate). Pinned because 2433-lqcm's design rests on it: the queue is never idle while busy, so the
-- wait between lands is a queue nobody started, not arrivals a run left behind.
-- Real bare remote, real lander clone, fake gh, stub gate (common.land_queue_fixture). The stub gate
-- publishes the next PR list while it gates.
--
--   1 ONE ARRIVAL  #1 is the only candidate; #2 appears during #1's gate: landed=2 in one invocation
--   2 CHAIN        #2 appears during #1's gate, #3 during #2's: landed=3 in one invocation
--   3 CONTROL      nothing arrives: landed=1
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-mid-run-arrival.lua
-- Verdict: ok:land-queue-mid-run-arrival:<n> arms | violation:land-queue-mid-run-arrival:<n>-failed

local fixture = require "common.fixture"
local u = text.trim((proc.run({ argv = { "uname", "-s" }, timeout_ms = 10000 }).stdout) or "")
if u ~= "Linux" and u ~= "Darwin" then
    verdict.emit("skip:land-queue-mid-run-arrival:" .. u .. "-land-queue-fixtures-need-a-posix-host", 0)
end
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-queue-mid-run-arrival")
local L = LQ.new(T)
local q = LQ.q

local function arriving_gate(S, lists)
    for k, body in ipairs(lists) do L:write(S.dir .. "/list" .. k .. ".json", body) end
    L:gate(S, "n=$(( $(cat " .. q(S.dir .. "/calls") .. " 2>/dev/null || echo 0) + 1 ))\n"
        .. "echo $n > " .. q(S.dir .. "/calls") .. "\n"
        .. "nx=" .. q(S.dir) .. "/list$((n + 1)).json\n"
        .. '[ -f "$nx" ] && cp "$nx" ' .. q(S.GH_PRS) .. "\n"
        .. "echo gate >> @GATE_LOG@\nexit 0\n")
end
local function rows(t)
    local r = {}
    for _, p in ipairs(t) do r[#r + 1] = string.format('{"number":%d,"headRefName":"%s","isDraft":false}', p[1], p[2]) end
    return "[" .. table.concat(r, ",") .. "]\n"
end
local A, B, C = { 1, "work/1001-aaaa" }, { 2, "work/1002-bbbb" }, { 3, "work/1003-cccc" }
local function arm(name, n, lists, want)
    local S = L:scaffold(name)
    local files = { "a.txt", "b.txt", "c.txt" }
    for i = 1, n do L:candidate(S, ({ "1001-aaaa", "1002-bbbb", "1003-cccc" })[i], files[i], files[i]) end
    arriving_gate(S, lists)
    L:prs(S, lists[1])
    local o, rc = L:run_queue(S)
    return rc == 0 and o:find("ok:land-queue:" .. want .. " landed=" .. want, 1, true) ~= nil, "rc=" .. tostring(rc) .. "\n" .. o:sub(-2000)
end

local ok, why = arm("one", 2, { rows{ A }, rows{ A, B } }, 2)
T:arm("1 ONE ARRIVAL a PR that appears during the only candidate's gate lands in the same run", ok, why)
ok, why = arm("chain", 3, { rows{ A }, rows{ A, B }, rows{ A, B, C } }, 3)
T:arm("2 CHAIN arrivals during each gate all land in one run", ok, why)
ok, why = arm("control", 1, { rows{ A } }, 1)
T:arm("3 CONTROL nothing arrives: landed=1", ok, why)
T:finish()
