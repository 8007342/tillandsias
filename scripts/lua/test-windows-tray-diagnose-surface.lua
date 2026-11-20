-- @trace spec:windows-native-tray, order:624-cf9f, order:2080-8i25
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- test-windows-tray-diagnose-surface.lua: scripts/lua/check-windows-tray-diagnose-surface.lua
-- (ported from the .sh) on six arms, every verdict of its grammar, from
-- recorded cargo transcripts:
--   1 a passing run verifies the surface (count = the pinned list's length)
--   2 NEGATIVE CONTROL: a pinned test absent from a run that ran is named
--   3 NEGATIVE CONTROL: a FAILING pinned test is named (no grep could see it)
--   4 a toolchain blocked by Smart App Control skips, accusing no test
--   5 output with no test results skips as no-test-run
--   6 skips exit 0, violations exit 1
-- The transcript is generated from the check's own PINNED_TESTS, so the
-- fixture cannot drift from what the check demands.
local SUBJECT = "scripts/lua/check-windows-tray-diagnose-surface.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:diagnose-surface-fixture:no-subject", 1, SUBJECT .. " does not exist")
end
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then
    verdict.could_not_run("diagnose-surface-fixture", "no-plan-binary — set TILLANDSIAS_PLAN_BIN")
end

local src = fs.read(SUBJECT)
local block = src:match("local PINNED_TESTS = {(.-)\n}")
local names = {}
for n in (block or ""):gmatch('"([a-z_]+)"') do names[#names + 1] = n end
if #names < 10 then
    verdict.emit("violation:diagnose-surface-fixture:pinned-list-unread:" .. #names, 1)
end

local function all_ok(drop, fail)
    local out = {}
    for _, t in ipairs(names) do
        if t ~= drop then
            out[#out + 1] = "test notify_icon::tests::" .. t .. " ... " .. (t == fail and "FAILED" or "ok")
        end
    end
    out[#out + 1] = "test result: ok. 40 passed; 0 failed; 0 ignored"
    return table.concat(out, "\n") .. "\n"
end

local stamp = time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local DIR = "target/plan-scratch/diagnose-surface-" .. stamp
fs.mkdir(DIR)
local n = 0
local function run(transcript)
    n = n + 1
    local f = DIR .. "/t" .. n .. ".txt"
    fs.write(f, transcript)
    local r = proc.run({ argv = { BIN, "script", "run", SUBJECT }, env = { TRAY_DIAGNOSE_FIXTURE_FILE = f }, timeout_ms = 30000 })
    local last = text.trim(r.stdout or ""):match("([^\n]*)$") or ""
    return last, r.code
end
local failed = {}
local function want(arm, got, expect, why)
    if got ~= expect then failed[#failed + 1] = "arm" .. arm .. ":" .. why .. ":got=" .. tostring(got) end
end

local o1, c1 = run(all_ok())
want(1, o1, "ok:diagnose-surface-verified:" .. #names, "pass-not-verified")
local o2, c2 = run(all_ok("status_once_json_keys_pinned"))
want(2, o2, "violation:diagnose-surface:missing-test:status_once_json_keys_pinned", "missing-not-named")
local o3 = run(all_ok(nil, "exit_code_separates_healthy_converging_and_degraded"))
want(3, o3, "violation:diagnose-surface:tests-failed:exit_code_separates_healthy_converging_and_degraded", "failure-not-named")
local o4, c4 = run("error: command failed: 'cargo': An Application Control policy has blocked this file. (os error 4551)\n")
want(4, o4, "skip:diagnose-surface-unverifiable:windows-toolchain-blocked", "blocked-not-skipped")
local o5 = run("warning: unused import\nerror: could not compile\n")
want(5, o5, "skip:diagnose-surface-unverifiable:no-test-run", "no-run-not-skipped")
want(6, c1, 0, "pass-exit")
want(6, c4, 0, "skip-exit")
want(6, c2, 1, "violation-exit")

if #failed > 0 then
    verdict.emit("violation:diagnose-surface-fixture:" .. table.concat(failed, ","), 1)
end
verdict.emit("ok:diagnose-surface-fixture:6-arms", 0)
