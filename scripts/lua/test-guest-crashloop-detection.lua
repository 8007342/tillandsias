-- @env PATH HOME
-- @trace order:2080-zcur
--
-- test-guest-crashloop-detection.lua — the guest crash-loop detector
-- (tillandsias-control-wire, `crashloop` unit tests) trips on a driven
-- restart/unseal series within the window and stays quiet on a
-- slow-but-progressing provision. Each named test must have RUN and passed;
-- a filter that matched nothing is not green.
-- Ported from scripts/test-guest-crashloop-detection.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-guest-crashloop-detection.lua
-- Verdict: ok:guest-crashloop-detection:<n> arms | violation:guest-crashloop-detection:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("guest-crashloop-detection")
local r = T:run{ "cargo", "test", "-p", "tillandsias-control-wire", "--lib", "crashloop", "--", "--nocapture",
    cwd = fixture.repo_root(), timeout_ms = 1800000,
    env = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = env.get("HOME") or "" } }
local o = (r.stdout or "") .. (r.stderr or "")
local tail = o:sub(-1500)
T:arm("the crashloop unit suite passes", r.code == 0 and o:find("test result: ok%. %d+ passed; 0 failed") ~= nil,
    "status=" .. tostring(r.status) .. " rc=" .. tostring(r.code) .. "\n" .. tail)
for _, t in ipairs{ "driven_restart_series_trips_crash_loop", "sealed_vault_loop_trips_vault_unseal_subsystem",
    "slow_but_progressing_provision_never_trips" } do
    T:arm(t .. " ran and passed", o:find(t .. " ... ok", 1, true) ~= nil, "not in the cargo output")
end
T:finish()
