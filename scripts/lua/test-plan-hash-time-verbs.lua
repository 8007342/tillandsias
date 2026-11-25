-- @env PATH
-- @trace order:1375-8g5t, order:2300-6m9m
--
-- test-plan-hash-time-verbs.lua — the plan binary's hash and time verbs, ported from the
-- .sh of the same name (2300-6m9m).
--
--   1 VECTOR  sha256 of "abc" from stdin is the NIST vector
--   2 FILE    the file form equals the host's sha256sum / shasum (named skip with neither)
--   3 MS      time now --ms is 13 digits and advances across a 20 ms sleep (a one-second
--             clock cannot: BSD date answers %s%3N at one-second resolution, 1279-a7b6)
--   4 ISO     time now --iso is the fragment-filename clock
--   5 RFC     time now --rfc3339 is UTC with a Z
--   6 USAGE   an unknown form is exit 2 and no output
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-hash-time-verbs.lua
-- Verdict: ok:plan-hash-time-verbs:<n> arms | violation:... | could-not-run:... (3)

local fixture = require "common.fixture"
local T = fixture.new("plan-hash-time-verbs")
local PLAN = fixture.plan_binary()
local function plan(argv, stdin)
    local a = { PLAN }
    for _, x in ipairs(argv) do a[#a + 1] = x end
    local r = proc.run{ argv = a, stdin = stdin, timeout_ms = 30000 }
    return r.code, text.trim(r.stdout or "")
end
local _, caps = plan{ "capabilities" }
T:arm("0 PREMISE the binary names hash and time", ("\n" .. caps .. "\n"):find("\nhash\n", 1, true) ~= nil and ("\n" .. caps .. "\n"):find("\ntime\n", 1, true) ~= nil, "blocked:hash-time-verbs-absent")

local _, o = plan({ "hash", "sha256", "-" }, "abc")
T:arm("1 VECTOR sha256(abc) from stdin is the NIST vector", o == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", o)

local S = T:scratch()
local b = {}
for i = 0, 1999 do b[#b + 1] = "line " .. i .. " of a file larger than one read block\n" end
fs.write(S.rel .. "/blob", table.concat(b))
local _, mine = plan{ "hash", "sha256", S.abs .. "/blob" }
local theirs, tool
for _, t in ipairs{ { "sha256sum" }, { "shasum", "-a", "256" } } do
    if not theirs then
        local argv = {}
        for _, x in ipairs(t) do argv[#argv + 1] = x end
        argv[#argv + 1] = S.abs .. "/blob"
        local ok, r = pcall(proc.run, { argv = argv, timeout_ms = 30000 })
        if ok and r.status == "exited" and r.code == 0 then theirs, tool = (r.stdout or ""):match("^\\?(%x+)"), t[1] end
    end
end
if not theirs then out.line("skip: 2 FILE host has neither sha256sum nor shasum")
else T:arm("2 FILE the file digest equals the host tool's", mine == theirs and #mine == 64, tool .. " " .. tostring(theirs) .. " vs " .. mine) end

local _, t1 = plan{ "time", "now", "--ms" }
T:must{ "sleep", "0.02" }
local _, t2 = plan{ "time", "now", "--ms" }
local whole = t1:match("^%d+$") and t2:match("^%d+$") and #t1 == 13
T:arm("3 MS 13 digits, advancing in milliseconds", whole ~= nil and whole and tonumber(t2) > tonumber(t1) and tonumber(t2) - tonumber(t1) < 30000, t1 .. " " .. t2)
local _, iso = plan{ "time", "now", "--iso" }
T:arm("4 ISO the fragment-filename clock", iso:match("^%d%d%d%d%d%d%d%dt%d%d%d%d%d%dz$") ~= nil, iso)
local _, rfc = plan{ "time", "now", "--rfc3339" }
T:arm("5 RFC UTC with a Z", rfc:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil, rfc)
local c, e = plan{ "hash", "md5", S.abs .. "/blob" }
T:arm("6 USAGE an unknown form is exit 2 and no output", c == 2 and e == "", tostring(c) .. " " .. e)
T:finish()
