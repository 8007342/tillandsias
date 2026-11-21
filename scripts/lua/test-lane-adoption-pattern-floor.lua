-- @trace spec:mcp-tool-socket
-- @trace order:1929-gfxy, order:2080-zcur
--
-- test-lane-adoption-pattern-floor.lua — litmus:lane-socket-survives-launcher-exit
-- step 1 pinned "test result: ok. 5 passed". The lane_adoption_tests module grew
-- to 7 (1863-eckw, 1911-3dqo), so a green run was refused in two v56.10.31.1 cut
-- gates. The pattern is now a FLOOR of 5 with no failures. These arms judge the
-- pattern AS THE YAML PARSES IT, with the litmus runner's own matcher (grep -E).
-- Ported from scripts/test-lane-adoption-pattern-floor.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-lane-adoption-pattern-floor.lua
-- Verdict: ok:lane-adoption-pattern-floor:<n> arms | violation:lane-adoption-pattern-floor:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("lane-adoption-pattern-floor")

local doc = yaml.parse(fs.read("openspec/litmus-tests/litmus-lane-socket-survives-launcher-exit.yaml") or "")
local pat = doc and doc.critical_path and doc.critical_path[1] and doc.critical_path[1].success_pattern
if type(pat) ~= "string" or pat == "" then T:refuse("no-success-pattern", "could not read step 1's success_pattern") end

local function matches(p, s)
    local r = proc.run{ argv = { "grep", "-qE", "--", p }, stdin = s .. "\n" }
    if r.status ~= "exited" or r.code > 1 then T:refuse("grep-could-not-run", tostring(r.stderr)) end
    return r.code == 0
end
local function line(p, f)
    return "test result: ok. " .. p .. " passed; " .. f .. " failed; 0 ignored; 0 measured; 1272 filtered out; finished in 0.00s"
end

for _, n in ipairs{ 5, 7, 12 } do
    T:arm("accepts " .. n .. " passed, 0 failed", matches(pat, line(n, 0)), "refuses a green run: " .. pat)
end
for _, c in ipairs{ { 4, 0 }, { 7, 1 }, { 0, 0 } } do
    T:arm("refuses " .. c[1] .. " passed, " .. c[2] .. " failed", not matches(pat, line(c[1], c[2])),
        "accepted — the floor or the no-failure clause is gone")
end
T:arm("refuses a FAILED result", not matches(pat, "test result: FAILED. 7 passed; 1 failed"), "accepted")
-- The retired exact pin refuses today's real shape, which is why it went.
T:arm("the retired exact pin refuses today's 7-test output",
    not matches("test result: ok. 5 passed", line(7, 0)), "accepted — this arm has no subject")

T:finish()
