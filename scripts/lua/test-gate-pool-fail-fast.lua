-- @env PATH HOME XDG_RUNTIME_DIR TOOLBOX_PATH container
-- @trace order:2430-ffst
--
-- test-gate-pool-fail-fast.lua — under the gate-step POOL, a red ends the gate without paying for the
-- rest of the pool, and TILLANDSIAS_GATE_STEP_ORDER starts the likeliest reds first.
-- The real build.sh step loop runs over a scratch root: one fast red step (a) and six slow green steps,
-- each sleeping SLOW seconds, at jobs=2.
--
--   1 ORDERED   with the order file naming the red first: rc 1, a named, well under the pool's
--               green pool's time less one slow step (before 2430 the pool waited for every worker)
--   2 UNORDERED filename order still fails fast: the red is named before the whole pool ran
--   3 GREEN     an all-green pool is unchanged: rc 0, every step ran
--   4 KEEP-GOING --keep-going still runs every step and names the red
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-pool-fail-fast.lua
-- Verdict: ok:gate-pool-fail-fast:<n> arms | violation:gate-pool-fail-fast:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-pool-fail-fast")
local ROOT = fixture.repo_root()
local S = T:scratch()
local SLOW = 4

local function step(dir, n, name, rc, secs)
    fs.write(dir.rel .. "/scripts/s-" .. name .. ".sh",
        "#!/usr/bin/env bash\nsleep " .. secs .. "\necho step-" .. name .. "-ran\nexit " .. rc .. "\n")
    fs.write(dir.rel .. "/scripts/gate-steps.d/" .. n .. "-" .. name .. ".step", table.concat({
        'STEP_DESC="pool fail-fast fixture step ' .. name .. '"',
        'STEP_SCRIPT="scripts/s-' .. name .. '.sh"',
        'STEP_ERROR="step ' .. name .. ' failed"',
        'STEP_OK="step ' .. name .. ' passed"',
    }, "\n") .. "\n")
end
local function mkroot(name, red)
    local d = { rel = S.rel .. "/" .. name, abs = S.abs .. "/" .. name }
    fs.mkdir(d.rel .. "/scripts/gate-steps.d")
    for i, s in ipairs{ "b", "c", "d", "e", "f", "g" } do step(d, tostring(100 * i), s, 0, SLOW) end
    if red then step(d, "900", "a", 1, 0) end  -- LAST by filename: only the order file starts it first
    return d
end
local mixed, green = mkroot("mixed", true), mkroot("green", false)
local ORDER = S.rel .. "/order"
fs.write(ORDER, "900-a.step\n")

local function gate(r, extra)
    extra = extra or {}
    local argv = { fixture.posix_shell(), ROOT .. "/build.sh", "--gate-steps", r.abs }
    if extra.kg then argv[#argv + 1] = "--keep-going" end
    local t0 = time.now_ms()
    local res = proc.run({ argv = argv, timeout_ms = 300000, cwd = ROOT,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR"),
                TOOLBOX_PATH = env.get("TOOLBOX_PATH"), container = env.get("container"),
                TILLANDSIAS_GATE_STEP_JOBS = "2", TILLANDSIAS_GATE_STEP_ORDER = extra.order } })
    local o = (res.stdout or "") .. (res.stderr or "")
    local ran = 0
    for _ in o:gmatch("step%-[a-g]%-ran") do ran = ran + 1 end
    return res.code, o, (time.now_ms() - t0) / 1000, ran
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function why(rc, s, ran, o) return ("rc=%s %.1fs ran=%d\n%s"):format(tostring(rc), s, ran, o:sub(-1500)) end

-- green first: the first build.sh run pays its cold preamble, which is not the pool's cost
local rc, o, s, ran = gate(green)
local green_s = s
out.line(("measure: green %.1fs, %d step(s) ran"):format(s, ran))
T:arm("3 GREEN an all-green pool runs every step, rc 0", rc == 0 and ran == 6, why(rc, s, ran, o))

rc, o, s, ran = gate(mixed, { order = S.abs .. "/order" })
out.line(("measure: ordered red %.1fs, %d step(s) ran"):format(s, ran))
T:arm("1 ORDERED the red dispatched first ends the gate before the pool's slow steps all ran",
    rc == 1 and has(o, "step a failed") and ran < 7 and s < green_s - SLOW, why(rc, s, ran, o))

rc, o, s, ran = gate(mixed)
out.line(("measure: unordered red %.1fs, %d step(s) ran"):format(s, ran))
T:arm("2 UNORDERED the red is still named, rc 1", rc == 1 and has(o, "step a failed"), why(rc, s, ran, o))

rc, o, s, ran = gate(mixed, { kg = true, order = S.abs .. "/order" })
T:arm("4 KEEP-GOING every step still runs and the red is named",
    rc == 1 and ran == 7 and has(o, "red-step:900-a.step:"), why(rc, s, ran, o))

T:finish()
