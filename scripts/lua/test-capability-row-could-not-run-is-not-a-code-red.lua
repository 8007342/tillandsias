-- @trace order:2251-iyiu, order:1765-q7rg, order:1128-4ffr
--
-- test-capability-row-could-not-run-is-not-a-code-red.lua — gate step 275
-- (test-pending-capability-row-does-not-wedge.sh) exits 3 when an arm could
-- not run, and with no declaration the gate read that as a failure: #1249
-- (5e60118f5) was evicted on "8 passed, 0 failed, 1 could-not-run" (its KILL
-- arm's child never reached its hold within 30 s under load). Step 275 now
-- declares STEP_HOST_STATE="load", so the gate retries it once and a second
-- could-not-run is named flaky:, never violation:.
--
--   1 DECLARED   step 275 declares STEP_HOST_STATE
--   2 FORCED     the real fixture, with its hold window forced to zero
--                (TILLANDSIAS_1320_HOLD_WAIT_DS=0, the fixture's own seam),
--                reproduces #1249: no failure, one could-not-run, exit 3
--   3 RETRIED    the real gate loop (`./build.sh --gate-steps <root>`) over a
--                step that exits 3 with could-not-run, carrying 275's
--                declaration: it runs twice and is named flaky:, never
--                violation:
--   4 CONTROL    the same step WITHOUT the field runs once and is not named
--                flaky: (NEGATIVE CONTROL — the declaration is what changes it)
--
-- Verdict: ok:capability-row-could-not-run-is-not-a-code-red:<n> arms | violation:…:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("capability-row-could-not-run-is-not-a-code-red")
local ROOT = fixture.repo_root()
local STEP = "scripts/gate-steps.d/275-1128-4ffr.step"
local SH = fixture.posix_shell()

local uname = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
if uname ~= "Linux" and uname ~= "Darwin" then
    -- build.sh re-execs into the builder distro on MSYS (1765-q7rg's fixture
    -- skips the same way); the gate runs this step inside that distro.
    T:skip(uname .. "-re-execs-build-sh-into-wsl")
end

-- 1
local hs = (fs.read(STEP) or ""):match('\nSTEP_HOST_STATE="([^"]*)"')
T:arm("1 DECLARED step 275 declares STEP_HOST_STATE", hs == "load", "STEP_HOST_STATE=" .. tostring(hs))

-- 2
local r = proc.run{ argv = { SH, ROOT .. "/scripts/test-pending-capability-row-does-not-wedge.sh" },
    cwd = ROOT, timeout_ms = 900000, env = { TILLANDSIAS_1320_HOLD_WAIT_DS = "0" } }
local summary = ""
for _, l in ipairs(text.lines(r.stdout or "")) do
    if text.starts_with(l, "pending-capability-row-does-not-wedge:") then summary = l end
end
T:arm("2 FORCED a missed hold reproduces #1249: 0 failed, could-not-run, exit 3",
    r.status == "exited" and r.code == 3 and summary:find(" 0 failed", 1, true) ~= nil
        and summary:find("could-not-run", 1, true) ~= nil,
    "rc=" .. tostring(r.code) .. " " .. summary)

-- 3, 4: the real gate loop over a stub that answers exactly as 275 did.
local function gate(tag, host_state)
    local d = T:scratch(tag)
    proc.run{ argv = { "mkdir", "-p", d.abs .. "/scripts/gate-steps.d" } }
    fs.write(d.rel .. "/runs.log", "")
    fs.write(d.rel .. "/scripts/stub-cnr.sh", table.concat({
        "#!/usr/bin/env bash",
        'echo run >> "' .. d.abs .. '/runs.log"',
        'echo "pending-capability-row-does-not-wedge: 8 passed, 0 failed, 1 could-not-run"',
        "exit 3", "" }, "\n"))
    local step = {
        'STEP_DESC="Stub could-not-run step (2251-iyiu fixture)"',
        'STEP_SCRIPT="scripts/stub-cnr.sh"',
        'STEP_ERROR="stub could-not-run step failed"',
        'STEP_OK="Stub could-not-run step passed"',
    }
    if host_state then step[#step + 1] = 'STEP_HOST_STATE="' .. host_state .. '"' end
    fs.write(d.rel .. "/scripts/gate-steps.d/500-stub.step", table.concat(step, "\n") .. "\n")
    local g = proc.run{ argv = { SH, ROOT .. "/build.sh", "--gate-steps", d.abs }, cwd = ROOT,
        timeout_ms = 600000, env = { TILLANDSIAS_GATE_HOST_STATE_SETTLE_S = "0" } }
    local o = (g.stdout or "") .. (g.stderr or "")
    local runs = #text.lines(text.trim(fs.read(d.rel .. "/runs.log") or ""))
    return o, runs
end

local o3, runs3 = gate("declared", hs or "load")
local flaky3 = nil
for _, l in ipairs(text.lines(o3)) do if text.starts_with(l, "flaky:stub-cnr.sh:") then flaky3 = l end end
T:arm("3 RETRIED a could-not-run under 275's declaration runs twice and is named flaky:, never violation:",
    runs3 == 2 and flaky3 ~= nil and not flaky3:find("violation:", 1, true),
    "runs=" .. runs3 .. " flaky=" .. tostring(flaky3))

local o4, runs4 = gate("undeclared", nil)
T:arm("4 CONTROL without the field it runs once and is not named flaky:",
    runs4 == 1 and not o4:find("flaky:stub-cnr.sh", 1, true), "runs=" .. runs4)

T:finish()
