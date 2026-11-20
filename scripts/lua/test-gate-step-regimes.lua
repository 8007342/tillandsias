-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1302-7j8p, order:2124-mwzr
--
-- test-gate-step-regimes.lua — fixture for scripts/lua/check-gate-step-regimes.lua.
-- The Lua port of scripts/test-gate-step-regimes.sh (2124-mwzr). Hermetic: each
-- arm builds a step dir under target/plan-scratch and points the checker at it.
--
--   1 a step with NO record is NAMED, not merely counted
--   2 a step WITH a darwin record passes
--   3 a record naming only LINUX is still single-regime (THE ARM THAT MATTERS:
--     arms 1-2 pass a checker that only asks whether the variable EXISTS)
--   4 CONTROL: a named skip from the other regime counts as a record (without it
--     a checker could refuse steps that genuinely cannot run off Linux, 965-sxec)
local NAME = "gate-step-regimes-fixture"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then verdict.could_not_run(NAME, "set TILLANDSIAS_PLAN_BIN to the plan binary under test") end
local CHECK = "scripts/lua/check-gate-step-regimes.lua"
if not fs.exists(CHECK) then verdict.emit("skip:" .. NAME .. ":checker-absent", 0) end

local REL = "target/plan-scratch/gate-step-regimes-" .. tostring(time.now_ms())
local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:" .. NAME .. ":" .. name)
    else failed[#failed + 1] = name; out.line("FAIL:" .. name .. "; got: " .. tostring(got)) end
end

local function mk(dir, regime)
    fs.mkdir(dir)
    local t = { 'STEP_DESC="probe"', 'STEP_SCRIPT="scripts/true.sh"', 'STEP_ERROR="probe failed"', 'STEP_OK="probe ok"' }
    if regime then t[#t + 1] = 'STEP_SECOND_REGIME="' .. regime .. '"' end
    fs.write(dir .. "/100-probe.step", table.concat(t, "\n") .. "\n")
end
local function check(dir)
    local r = proc.run({ argv = { PLAN, "script", "run", CHECK, "--", dir }, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local d = REL .. "/a1"; mk(d)
local rc, o = check(d)
arm("arm1-unrecorded-step-is-named", rc ~= 0 and has(o, "violation:gate-step-single-regime:100-probe.step"), "rc=" .. rc .. " " .. o)

d = REL .. "/a2"; mk(d, "macneo 2026-09-22 darwin ok:probe-passed")
rc, o = check(d)
arm("arm2-recorded-step-passes", rc == 0 and o:find("^ok:gate%-step%-regimes:1\n") ~= nil, "rc=" .. rc .. " " .. o)

d = REL .. "/a3"; mk(d, "lenovinha 2026-09-22 linux ok:probe-passed")
rc, o = check(d)
arm("arm3-linux-only-is-single-regime", rc ~= 0 and has(o, "is-not-a-second-regime"), "rc=" .. rc .. " " .. o)

d = REL .. "/a4"; mk(d, "macneo 2026-09-22 darwin skip:no-podman-on-darwin")
rc, o = check(d)
arm("arm4-a-named-skip-counts", rc == 0 and o:find("^ok:gate%-step%-regimes:1\n") ~= nil, "rc=" .. rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", REL } })
if #failed == 0 then verdict.ok(NAME .. ":" .. passed .. " arms") end
verdict.refused(NAME .. ":" .. #failed .. "-failed", table.concat(failed, "; "))
