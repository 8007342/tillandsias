-- @env PATH HOME
-- @trace order:2408-rkvd
--
-- test-check-test-tmp-leftovers.lua — check-test-tmp-leftovers.lua passes an empty temp dir and
-- refuses one with anything left in it, naming each leftover's shape with a count.
--
--   1 an empty dir is ok:test-tmp-leftovers:0 left
--   2 a dir holding 3 numbered dirs of one helper and 1 tempfile dir is violation:...:4, the
--     helper's shape counted 3 and the remedy named
--   3 a hidden entry (a .tmpXXXXXX tempfile left behind) is counted, not skipped
--   4 a missing dir is could-not-run, never ok
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-test-tmp-leftovers.lua
-- Verdict: ok:check-test-tmp-leftovers:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-test-tmp-leftovers")
local PLAN = fixture.plan_binary()
if not PLAN then T:refuse("no-plan-binary", "the check runs through the plan binary") end
-- The kit's scratch (under the repository): the check does not care where its dir lives, and a
-- dir under /tmp is one the agent door will not let this fixture remove (it once leaked one).
local base = T:scratch().abs
local function check(dir)
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-test-tmp-leftovers.lua", "--", dir }, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
local function mk(p) T:must{ "mkdir", "-p", p } end

mk(base .. "/empty")
local o, rc = check(base .. "/empty")
T:arm("1 an empty temp dir passes", rc == 0 and text.contains(o, "ok:test-tmp-leftovers:0 left"), "rc=" .. tostring(rc) .. " " .. o)

for i = 1, 3 do mk(base .. "/left/tillandsias-test-cache-4242-" .. i) end
mk(base .. "/left/.tmpAbC123")
o, rc = check(base .. "/left")
T:arm("2 leftovers are refused with their count", rc == 1 and text.contains(o, "violation:test-tmp-leftovers:4"), "rc=" .. tostring(rc) .. " " .. o)
T:arm("2 one helper's dirs read as one shape counted 3", o:find("%s3%s+tillandsias%-test%-cache%-N%-N") ~= nil, o)
T:arm("2 and the remedy names the helper to use", text.contains(o, "test_scratch"), o)
T:arm("3 a hidden tempfile dir is counted, not skipped", text.contains(o, ".tmpXXXXXX"), o)

o, rc = check(base .. "/no-such-dir")
T:arm("4 a missing dir is could-not-run, never ok", rc ~= 0 and o:find("^could%-not%-run:test%-tmp%-leftovers") ~= nil
    or (rc ~= 0 and text.contains(o, "could-not-run:test-tmp-leftovers")), "rc=" .. tostring(rc) .. " " .. o)

T:finish()
