-- @trace order:1337-7jr5, order:2167-gmfl, order:2375-ch7i
--
-- test-gate-memory-wsl2-guest.lua — inside a WSL2 guest /proc/meminfo is the utility VM's
-- memory, not the Windows host's that reaps the gate, so the floor check must not answer
-- ok from it (yolanda 2026-09-21: guest ok at 5578MB, host at 28.7%). Hermetic: the kernel
-- identity and the host figure come through seams. Ported from the .sh (2375-ch7i).
--
--   1 WSL2, default read: could-not-run, last line skip:, rc 3, and no ok line
--   2 WSL2, a healthy host figure passed in: judged ok
--   3 WSL2, a starved one: still refused
--   4 a native kernel: the WSL2 refusal does not appear
--
-- Verdict: ok:gate-memory-wsl2-guest:<n>/<n> | violation:gate-memory-wsl2-guest:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-memory-wsl2-guest")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end -- a skip would be a permanent green over the WSL2 rule
local FLOOR = "scripts/lua/check-gate-memory-floor.lua"
if not fs.exists(FLOOR) then T:refuse("absent", FLOOR) end
local W = T:scratch()
for name, s in pairs{ wsl2 = "5.15.167.4-microsoft-standard-WSL2\n", native = "6.10.0-100.fc40.x86_64\n",
    healthy = "MemTotal:       16000000 kB\nMemAvailable:    8000000 kB\n", starved = "MemTotal:       16000000 kB\nMemAvailable:     200000 kB\n" } do
    fs.write(W.rel .. "/" .. name, s)
end
local function floor(kernel, meminfo)
    local argv = { PLAN, "script", "run", FLOOR, "--" }
    if meminfo then argv[#argv + 1] = "--meminfo-from"; argv[#argv + 1] = W.abs .. "/" .. meminfo end
    argv.cwd, argv.env, argv.env_unset = fixture.repo_root(), { TILLANDSIAS_GATE_MEMORY_OSRELEASE = W.abs .. "/" .. kernel }, { "TILLANDSIAS_*" }
    local r = T:run(argv)
    return r.code, r.stdout or ""
end
local function got(rc, o) return "rc=" .. tostring(rc) .. " " .. o:gsub("\n", " | ") end
local rc, o = floor("wsl2")
T:arm("1 a WSL2 guest refuses to assert from its own meminfo", rc == 3 and o:find("could-not-run:gate-memory:wsl2-guest-meminfo-is-not-the-host", 1, true)
    and not o:find("ok:gate-memory", 1, true) and (text.trim(o):match("([^\n]*)$") or ""):find("^skip:"), got(rc, o))
rc, o = floor("wsl2", "healthy")
T:arm("2 a host figure passed in is judged normally", rc == 0 and o:find("^ok:gate%-memory:"), got(rc, o))
rc, o = floor("wsl2", "starved")
T:arm("3 a starved host figure is still refused", rc == 1 and o:find("^refused:gate:insufficient%-memory"), got(rc, o))
rc, o = floor("native")
T:arm("4 a native kernel is not refused as WSL2", o ~= "" and not o:find("wsl2-guest", 1, true), got(rc, o))
T:finish({ ok = function(n) return "ok:gate-memory-wsl2-guest:" .. n .. "/" .. n end })
