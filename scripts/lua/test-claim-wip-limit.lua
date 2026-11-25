-- @env PATH HOME
-- @trace order:1367-2sbc, order:1588-27v3, order:2311-xca3
--
-- test-claim-wip-limit.lua — a host finishes or releases before it starts more. Ported from
-- the .sh of the same name (2311-xca3). Measured 2026-09-13..23: hosts climbed to 10, 8 and 6
-- concurrent claims and filing outran closing, because set-field admitted any number.
--
--   1 WIP LIMIT at the cap a loose claim is REFUSED, names the held orders, writes nothing
--   2 STORY     claims sharing --story are one unit; a new story is refused while it is open
--   3 RELEASE   completing one packet admits the next claim
--   4 OVERRIDE  the refusal names --over-wip; the override is recorded with its reason
--   5 NEGATIVE  another host's claims do not count
--
-- Hermetic: scratch ledgers driven through --index, each with a methodology file of its own,
-- so the cap is READ, as in the real tree.
--
-- Usage: tillandsias-plan script run scripts/lua/test-claim-wip-limit.lua
-- Verdict: ok:claim-wip-limit:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("claim-wip-limit")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end

local function mk()
    local d = T:scratch()
    fs.mkdir(d.rel .. "/plan/index.d"); fs.mkdir(d.rel .. "/methodology")
    fs.write(d.rel .. "/methodology/distributed-work.yaml",
        "distributed_work:\n  packet_discipline:\n    wip_limit: 2\n    fleet_hosts: [hosta, hostb]\n")
    local y = { "packets:" }
    for i, o in ipairs{ "1-aaaa", "2-bbbb", "3-cccc", "4-dddd", "5-eeee", "6-ffff" } do
        y[#y + 1] = "  - packet_id: fixture-row-" .. i .. "\n    order: " .. o .. "\n    status: ready\n    kind: bug\n"
            .. "    priority: p2\n    desired_release: v0.5\n    pickup_role: linux\n    title: fixture row " .. i .. "\n"
            .. '    unscoreable: "fixture packet; not scored"\n    events: []'
    end
    fs.write(d.rel .. "/plan/index.yaml", table.concat(y, "\n") .. "\n")
    return d
end
local function set(d, ...)
    local argv = { PLAN, "--index", d.abs .. "/plan/index.yaml", "set-field", ... }
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_HOST_KIND = "" } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function claim(d, order, host, ...) return set(d, order, "status", "in_progress", "--host", host, "--reason", "fixture", ...) end
local function frags(d)
    local t = {}
    for _, f in ipairs(fs.walk(d.rel .. "/plan/index.d", { suffix = ".yaml" })) do t[#t + 1] = fs.read(f) end
    return t
end
local function say(...) return table.concat({ ... }, " | "):sub(1, 300) end

local a = mk()
local r1, o1 = claim(a, "1-aaaa", "hosta")
local r2, o2 = claim(a, "2-bbbb", "hosta")
local before = #frags(a)
local rc, o = claim(a, "3-cccc", "hosta")
T:arm("1 WIP LIMIT at the cap read from methodology a third claim is refused, names the two held and writes nothing",
    r1 == 0 and r2 == 0 and before == 2 and rc ~= 0 and text.contains(o, "refused:set-field:wip-limit:2/2") and text.contains(o, "1-aaaa")
    and text.contains(o, "2-bbbb") and text.contains(o, "from methodology/distributed-work.yaml") and #frags(a) == before,
    say("rc " .. tostring(r1) .. tostring(r2) .. tostring(rc), before .. "->" .. #frags(a), o, o1, o2))

local b, rcs = mk(), ""
for _, c in ipairs{ { "1-aaaa", "s-one" }, { "2-bbbb", "s-one" }, { "3-cccc", "s-one" }, { "4-dddd" }, { "5-eeee" } } do
    local r
    if c[2] then r = claim(b, c[1], "hosta", "--story", c[2]) else r = claim(b, c[1], "hosta") end
    rcs = rcs .. tostring(r)
end
local stamped = 0
for _, s in ipairs(frags(b)) do if ("\n" .. s):find("\n    story: s%-one\r?\n") then stamped = stamped + 1 end end
rc, o = claim(b, "6-ffff", "hosta", "--story", "s-two")
T:arm("2 STORY three claims under one story are one unit and a new story is refused while it is open",
    rcs == "00000" and stamped == 3 and rc ~= 0 and text.contains(o, "refused:set-field:story-open:s-one"), say(rcs, "stamped " .. stamped, o))

T:must{ "sleep", "1" } -- the completion must postdate the claim in the LWW fold
local rd, od = set(a, "1-aaaa", "status", "completed", "--host", "hosta", "--evidence", "deadbeef")
rc, o = claim(a, "3-cccc", "hosta")
T:arm("3 RELEASE completing 1-aaaa admits the claim on 3-cccc", rd == 0 and rc == 0, say(tostring(rd) .. tostring(rc), o, od))

local rr, ro = claim(a, "4-dddd", "hosta")
rc, o = claim(a, "4-dddd", "hosta", "--over-wip", "operator asked for 4-dddd tonight")
local rec = ""
for _, s in ipairs(frags(a)) do if text.contains(s, "wip-override by hosta: operator asked for 4-dddd tonight") then rec = s end end
T:arm("4 OVERRIDE the refusal names --over-wip and the override is recorded with its reason and the held orders",
    rr ~= 0 and text.contains(ro, "--over-wip") and rc == 0 and text.contains(rec, "wip-limit:2/2") and text.contains(rec, "3-cccc"),
    say(tostring(rr) .. tostring(rc), rec, ro, o))

local c = mk()
for _, x in ipairs{ "1-aaaa", "2-bbbb" } do
    local r = claim(c, x, "hostb")
    if r ~= 0 then T:refuse("setup-failed", "hostb could not hold " .. x) end
end
rc, o = claim(c, "4-dddd", "hosta")
T:arm("5 NEGATIVE CONTROL two claims held by hostb, its cap, do not count against hosta", rc == 0, say(tostring(rc), o))
T:finish()
