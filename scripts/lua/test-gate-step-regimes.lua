-- @env PATH HOME
-- @trace order:1302-7j8p, order:2221-vjqb, order:2124-mwzr
--
-- test-gate-step-regimes.lua — check-gate-step-regimes.lua refuses a step whose second-regime record
-- is missing, malformed or Linux-only. Ported from the .sh of the same name (2124-mwzr). Scratch
-- step directories.
--
--   1 no record: NAMED, not merely counted     2 a darwin record passes
--   3 a Linux record is still single-regime (1 and 2 pass a checker that only asks whether the
--     variable exists)                         4 CONTROL a named skip counts (965-sxec)
--   5 a bad SECOND record refuses the step     6 darwin and msys pass and are both reported
--   7 a STEP_HOST_STATE that is not keyring or load is refused, 8 CONTROL load is not
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-regimes.lua
-- Verdict: ok:gate-step-regimes-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("gate-step-regimes-fixture")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local DARWIN = 'STEP_SECOND_REGIME="macneo 2026-09-22 darwin ok:probe-passed"'
local function check(...)
    local d = T:scratch()
    fs.write(d.rel .. "/100-probe.step", table.concat({ 'STEP_DESC="probe"', 'STEP_SCRIPT="scripts/true.sh"', 'STEP_ERROR="probe failed"', 'STEP_OK="probe ok"', ... }, "\n") .. "\n")
    local r = T:run{ PLAN, "script", "run", "scripts/lua/check-gate-step-regimes.lua", "--", d.rel, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return { rc = r.code, out = o, ok = r.code == 0 and ("\n" .. (r.stdout or "")):find("\nok:gate%-step%-regimes:1\n") ~= nil, why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300) }
end
local function named(x) return x.rc == 1 and text.contains(x.out, "violation:gate-step-single-regime:100-probe.step") end
local x = check()
T:arm("1 an unrecorded step is named", named(x), x.why)
x = check(DARWIN)
T:arm("2 a recorded step passes", x.ok, x.why)
x = check('STEP_SECOND_REGIME="lenovinha 2026-09-22 linux ok:probe-passed"')
T:arm("3 a Linux record is single-regime", named(x) and text.contains(x.out, "is-not-a-second-regime"), x.why)
x = check('STEP_SECOND_REGIME="macneo 2026-09-22 darwin skip:no-podman-on-darwin"')
T:arm("4 CONTROL a named skip counts", x.ok, x.why)
for _, b in ipairs{ { "lenovinha 2026-11-22 linux ok:probe", "regime-linux-is-not-a-second-regime" }, { "yolanda 22-11-2026 msys ok:probe", "date-not-yyyy-mm-dd" }, { "yolanda", "malformed-record" } } do
    x = check(DARWIN, 'STEP_SECOND_REGIME="' .. b[1] .. '"')
    T:arm("5 a bad second record refuses the step: " .. b[2], named(x) and text.contains(x.out, "100-probe.step:" .. b[2]), x.why)
end
x = check(DARWIN, 'STEP_SECOND_REGIME="yolanda 2026-11-21 msys ok:probe-passed"')
T:arm("6 darwin and msys pass and both are reported", x.ok and text.contains(x.out, "regimes: darwin=1 msys=1"), x.why)
x = check(DARWIN, 'STEP_HOST_STATE="network"')
T:arm("7 an unknown host state is refused", x.rc == 1 and text.contains(x.out, "violation:gate-step-host-state:100-probe.step:network-is-not-keyring-or-load"), x.why)
x = check(DARWIN, 'STEP_HOST_STATE="load"')
T:arm("8 CONTROL load is a host state", x.ok, x.why)
T:finish()
