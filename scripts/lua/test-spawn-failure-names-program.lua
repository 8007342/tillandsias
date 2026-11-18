-- @env PATH HOME
-- @trace order:2080-zcur
--
-- test-spawn-failure-names-program.lua — a failed spawn in the headless
-- launcher names the program and the path it tried, and only a real spawn
-- miss is collapsible. One arm per named unit test, run with --exact so a
-- renamed test cannot shrink the arm count by matching nothing.
-- Keeps the established verdict line the litmus greps:
--   ok:spawn-failure-names-program:2/2 | violation:spawn-failure-names-program:<n>/2
-- Ported from scripts/test-spawn-failure-names-program.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spawn-failure-names-program.lua

local fixture = require "common.fixture"
local T = fixture.new("spawn-failure-names-program")
local E = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = env.get("HOME") or "" }
if proc.run{ argv = { "which", "cargo" }, env = E }.code ~= 0 then T:skip("no-cargo") end
local ARMS = { "a_spawn_failure_names_the_program_and_the_path", "only_a_real_spawn_miss_is_collapsible" }
for _, a in ipairs(ARMS) do
    local r = T:run{ "cargo", "test", "-p", "tillandsias-headless", "--offline", "--bin", "tillandsias",
        "--", "--exact", "tests::" .. a, cwd = fixture.repo_root(), timeout_ms = 1800000, env = E }
    local o = (r.stdout or "") .. (r.stderr or "")
    T:arm(a, r.code == 0 and o:find("test result: ok. 1 passed", 1, true) ~= nil,
        "rc=" .. tostring(r.code) .. "\n" .. o:sub(-800))
end
T:finish{
    ok = function(p) return "ok:spawn-failure-names-program:" .. p .. "/2" end,
    fail = function(n) return "violation:spawn-failure-names-program:" .. (2 - n) .. "/2" end,
}
