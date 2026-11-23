-- @trace order:1233-jqp4, order:2183-mfbn
-- @env PATH HOME TMPDIR TILLANDSIAS_TIMING_LOG TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-litmus-budget-negative-control.lua — 1233-jqp4 criterion 4, the
-- NEGATIVE CONTROL for every budget change: making room for a slow CORRECT step
-- must not make room for a BROKEN one. Through the REAL runner, in a scratch
-- project root (956-llei's construction). Ported from the .sh of the same name
-- (order 2183-mfbn); same three arms, same bounds.
--   arm 1 — a HUNG producer is killed at its budget AND the test's verdict is
--           red (a kill that the verdict ignored would pass a hang as green);
--   arm 2 — a WRONG producer (exits 0, prints the wrong answer) under a
--           GENEROUS 300 s budget is red, and red FAST: the budget is a
--           ceiling on waiting, not a grace period for a wrong answer;
--   arm 3 — POSITIVE CONTROL: the right answer under the same setup is green,
--           so arms 1-2 cannot pass on a runner that fails everything.
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-budget-negative-control.lua
-- Verdicts:
--   ok:litmus-budget-negative-control:<n>-arms                       exit 0
--   violation:litmus-budget-negative-control:<n>-failed              exit 1
--   could-not-run:litmus-budget-negative-control:no-plan-binary      exit 3

local NAME = "litmus-budget-negative-control"
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local TMP = env.get("TMPDIR"); if TMP == nil or TMP == "" then TMP = "/tmp" end
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = BASE }).stdout or "")

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then
    -- proc.run denies `sh -c`, so plan-binary-probe.sh cannot be sourced.
    for dir in (BASE.PATH or ""):gmatch("[^:]+") do
        local c = dir .. "/tillandsias-plan"
        if dir:sub(1, 1) == "/" and proc.run({ argv = { "test", "-x", c }, env = BASE }).code == 0 then PLAN = c; break end
    end
end
if PLAN == nil or PLAN == "" then verdict.emit("could-not-run:" .. NAME .. ":no-plan-binary", 3) end

local REL = "target/plan-scratch/litmus-budget-neg." .. tostring(time.now_ms())
local T = ROOT .. "/" .. REL
for _, d in ipairs({ "openspec/litmus-tests", "methodology", "target" }) do fs.mkdir(REL .. "/" .. d) end
proc.run({ argv = { "ln", "-s", ROOT .. "/scripts", T .. "/scripts" }, env = BASE })
proc.run({ argv = { "ln", "-s", ROOT .. "/methodology/litmus.yaml", T .. "/methodology/litmus.yaml" }, env = BASE })
local function cleanup() proc.run({ argv = { "rm", "-rf", T }, env = BASE }) end

local slug = "budget-negative-control-probe"
local name = "litmus:" .. slug
fs.write(REL .. "/openspec/litmus-bindings.yaml",
    "specs:\n  - spec_id: " .. slug .. "\n    status: active\n    litmus_tests:\n      - " .. name .. "\n")

local function write_probe(cmd, ms, expected)
    fs.write(REL .. "/openspec/litmus-tests/litmus-" .. slug .. ".yaml", table.concat({
        "# fixture-only probe (1233-jqp4); lives only in a scratch root.",
        "name: " .. name, "spec: " .. slug, "phase: pre-build", "size: instant", "severity: low",
        "description: >", "  Fixture probe for the budget negative control.", "critical_path:",
        "  - step: \"the probe step\"", "    command: \"" .. cmd .. "\"", "    timeout_ms: " .. ms,
        "    expected_behavior: \"" .. expected .. "\"", "" }, "\n"))
end
local OUT, RC, ELAPSED = "", 0, 0
local function run_probe()
    local e = { PATH = BASE.PATH, HOME = BASE.HOME, TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = PLAN,
        TILLANDSIAS_TIMING_LOG = env.get("TILLANDSIAS_TIMING_LOG") or (TMP .. "/tillandsias-timing-FIXTURES.jsonl"),
        LITMUS_STEP_TIMING_LOG = TMP .. "/litmus-step-timing-FIXTURES.jsonl" }
    local t0 = time.now_ms()
    local r = proc.run({ argv = { "bash", T .. "/scripts/run-litmus-test.sh", slug, "--phase", "pre-build" },
        env = e, cwd = T, timeout_ms = 600000 })
    ELAPSED = math.floor((time.now_ms() - t0) / 1000)
    RC = r.code
    OUT = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[%d;]*m", "")
end
local pass, fail = 0, 0
local function ok(m) pass = pass + 1; out.line("ok   " .. m) end
local function bad(m) fail = fail + 1; out.line("FAIL " .. m) end
local function red() return OUT:find("[FAIL] spec=" .. slug, 1, true) ~= nil end
local function tail2() local l = text.lines(OUT); return (l[#l - 1] or "") .. " " .. (l[#l] or "") end

-- 3 first: the positive control, so a red below means something.
write_probe("echo right-answer", 10000, "right-answer"); run_probe()
if RC == 0 and not red() and (text.contains(OUT, "[PASS]") or text.contains(OUT, "passed=1")) then
    ok("positive control: the right answer is green (rc=" .. tostring(RC) .. ")")
else bad("positive control: the right answer did not pass (rc=" .. tostring(RC) .. "): " .. tail2()) end

write_probe("sleep 30; echo right-answer", 2000, "right-answer"); run_probe()
if text.contains(OUT, "TIMEOUT") and red() and RC ~= 0 and ELAPSED < 25 then
    ok("a hung producer is killed at its budget and the verdict is red (rc=" .. tostring(RC) .. ", " .. ELAPSED .. "s)")
else bad("hung producer: TIMEOUT=" .. tostring(text.contains(OUT, "TIMEOUT")) .. " red=" .. tostring(red()) .. " rc=" .. tostring(RC) .. " elapsed=" .. ELAPSED .. "s") end

write_probe("echo wrong-answer", 300000, "right-answer"); run_probe()
if red() and RC ~= 0 and ELAPSED < 60 then
    ok("a wrong producer under a 300 s budget is red, and fast (rc=" .. tostring(RC) .. ", " .. ELAPSED .. "s)")
else bad("wrong producer: red=" .. tostring(red()) .. " rc=" .. tostring(RC) .. " elapsed=" .. ELAPSED .. "s") end

cleanup()
if fail > 0 then verdict.emit("violation:" .. NAME .. ":" .. fail .. "-failed", 1) end
verdict.ok(NAME, pass .. "-arms")
