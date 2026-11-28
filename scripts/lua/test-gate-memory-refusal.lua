-- @trace order:1176-fn2p, order:1047-h88p, order:1354-apns, order:2167-gmfl, order:2355-ncuh
-- @env PATH
--
-- test-gate-memory-refusal.lua — a gate too short of memory refuses BY NAME, and a gate
-- the kernel killed says so. Both deciders (check-gate-memory-floor.lua,
-- check-oom-postmortem.lua) are driven through their seams; the wiring arms read build.sh
-- and land-on-platform-branch.sh as TEXT. Hermetic: an OOM cannot be provoked on demand.
-- The stub journal's date is never compared against now. Ported from the .sh (2355-ncuh).
--
--    1 below the floor: refused, naming the floor and the reading
--    2 NC1: above the floor nothing new refuses (the floor is not a second cliff)
--    3 the shipped default is far below a host known to complete this gate
--    4 no MemAvailable is could-not-run (MemFree would under-report), ends on the skip:
--      a scorer knows, and a real refusal carries no skip: (1354-apns)
--    5 a kernel OOM record is refused:gate:oom-killed
--    6 NC2: another victim's OOM is not laundered into this gate's verdict
--    7 a quiet journal answers cleanly; an unreadable one is could-not-run
--    8 wired: the floor runs before the first compile; build.sh and the land driver ask
--    9 NC2 by line order: the driver asks ONLY on the no-failing-line path
--   10 the bootstrap with no plan binary names could-not-run and ends on skip:, exit 3
--   11 ... and still refuses a starved host (a fresh checkout is where it matters most)
--
-- Verdict: ok:gate-memory-refusal:<n> arms | violation:gate-memory-refusal:<n>-failed
--        | could-not-run:gate-memory-refusal:missing:<probe> (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("gate-memory-refusal")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local FLOOR, OOM = "scripts/lua/check-gate-memory-floor.lua", "scripts/lua/check-oom-postmortem.lua"
for _, f in ipairs{ FLOOR, OOM } do
    if not fs.exists(f) then verdict.emit("could-not-run:gate-memory-refusal:missing:" .. f, 3) end
end
local W = T:scratch()
local HEALTHY_KB = 11979624
for name, s in pairs{
    starved = "MemTotal:       15490628 kB\nMemAvailable:     131072 kB\n",
    healthy = "MemTotal:       15490628 kB\nMemAvailable:   " .. HEALTHY_KB .. " kB\n",
    ["no-memavailable"] = "MemTotal:       15490628 kB\nMemFree:          131072 kB\n",
    ["journal-oom"] = "sep 14 01:02:03 h kernel: Out of memory: Killed process 4123 (rustc) total-vm:9000000kB\n",
    ["journal-quiet"] = "sep 14 01:02:03 h kernel: usb 1-2: new high-speed USB device\n",
} do fs.write(W.rel .. "/" .. name, s) end

local function has(o, s) return o:find(s, 1, true) ~= nil end
local function ask(script, ...)
    local argv = { PLAN, "script", "run", script, "--" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.cwd, argv.env_unset = ROOT, { "TILLANDSIAS_GATE_*" }
    local r = T:run(argv)
    return r.code, r.stdout or ""
end
local function floor(f) return ask(FLOOR, "--meminfo-from", W.rel .. "/" .. f) end
local function oom(f, ...) return ask(OOM, "--journal-from", W.rel .. "/" .. f, ...) end
local function got(rc, o) return "rc=" .. tostring(rc) .. " " .. o:gsub("\n", " | ") end

local rc, o = floor("starved")
T:arm("1 a host below the floor is refused by name, with the floor and the reading", rc == 1
    and has(o, "refused:gate:insufficient-memory") and (has(o, "128MB") or has(o, "floor 1024MB")), got(rc, o))
T:arm("4 a real refusal carries no skip line (1354-apns)", rc ~= 0 and has(o, "refused:gate:insufficient-memory") and not has(o, "skip:"), got(rc, o))
rc, o = floor("healthy")
T:arm("2 NC1 a host above the floor is unaffected", rc == 0 and o:find("^ok:gate%-memory:") ~= nil, got(rc, o))
local default = tonumber(o:match("floor (%d+)MB"))
T:arm("3 the default floor is well under a completing host's headroom", default and default <= HEALTHY_KB // 1024 // 4, "default=" .. tostring(default))
rc, o = floor("no-memavailable")
T:arm("4 no MemAvailable is could-not-run, not a verdict", rc == 3 and has(o, "could-not-run:gate-memory:no-memavailable"), got(rc, o))
T:arm("4 and it ends on the skip: a scorer knows", has(o, "skip:gate-memory:no-memavailable"), got(rc, o))

rc, o = oom("journal-oom", "--victim", "rustc")
T:arm("5 a kernel OOM record is refused:gate:oom-killed", rc == 1 and has(o, "refused:gate:oom-killed"), got(rc, o))
rc, o = oom("journal-oom", "--victim", "some-other-process")
T:arm("6 NC2 an OOM naming a different victim is not this gate's kill", rc == 0, got(rc, o))
rc, o = oom("journal-quiet")
T:arm("7 a readable, quiet journal answers cleanly", rc == 0, got(rc, o))
rc, o = oom("does-not-exist")
T:arm("7 an unreadable journal is could-not-run", rc == 3, got(rc, o))

local function lines(p)
    local t = {}
    for l in (fs.read(p) .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end
local function first(ls, want)
    for i = 1, #ls do if ls[i]:find(want, 1, true) then return i end end
end
local build, land = lines("build.sh"), lines("scripts/land-on-platform-branch.sh")
local floor_at, clippy_at = first(build, "check-gate-memory-floor.sh"), first(build, "cargo clippy")
T:arm("8 the floor is checked before the first compile", floor_at and (not clippy_at or floor_at < clippy_at), "floor:" .. tostring(floor_at) .. " clippy:" .. tostring(clippy_at))
T:arm("8 build.sh consults the OOM record", first(build, "check-oom-postmortem.lua"), "no call")
T:arm("8 the land driver consults the OOM record", first(land, "check-oom-postmortem.lua"), "no call")
-- The branch is found by its own lines, never by prose the consult could move.
local if_at = first(land, 'if [ -n "$_first_fail" ]; then')
local else_at
for i = (if_at or #land) + 1, #land do if land[i] == "        else" then else_at = i; break end end
local oom_at = first(land, "check-oom-postmortem.lua")
T:arm("9 NC2 the driver consults the OOM record only on the no-failing-line path", if_at and else_at and oom_at and oom_at > else_at,
    "if:" .. tostring(if_at) .. " else:" .. tostring(else_at) .. " oom:" .. tostring(oom_at))

-- The bootstrap, in a tree with no binary and a PATH that holds none.
fs.mkdir(W.rel .. "/boot/scripts")
for _, f in ipairs{ "check-gate-memory-floor.sh", "plan-binary-probe.sh" } do
    fs.write(W.rel .. "/boot/scripts/" .. f, fs.read("scripts/" .. f))
end
local function boot(f)
    local r = T:run{ SH, "-s", "--", W.abs .. "/" .. f, cwd = W.abs .. "/boot", env = { PATH = env.get("PATH") },
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, stdin = [[
np=""; IFS=:
for d in $PATH; do
    [ -n "$d" ] || continue
    [ -e "$d/tillandsias-plan" ] || [ -e "$d/tillandsias-plan.exe" ] || np="${np:+$np:}$d"
done
unset IFS
PATH="$np" bash scripts/check-gate-memory-floor.sh --meminfo-from "$1" </dev/null 2>/dev/null
]] }
    return r.code, r.stdout or ""
end
rc, o = boot("healthy")
T:arm("10 with no plan binary the bootstrap names could-not-run and ends on skip:", rc == 3
    and ("\n" .. o):find("\ncould-not-run:gate-memory:no-plan-binary", 1, true) and text.trim(o):match("([^\n]*)$") == "skip:gate-memory:no-plan-binary", got(rc, o))
rc, o = boot("starved")
T:arm("11 with no plan binary the bootstrap still refuses a starved host", rc == 1 and ("\n" .. o):find("\nrefused:gate:insufficient-memory", 1, true), got(rc, o))
T:finish()
