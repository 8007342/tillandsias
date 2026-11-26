-- @trace order:1187-iij8, order:820-c8q8, order:956-llei, order:1204-3s2s, order:1427-utmy, order:2399-lrg3
-- @env PATH HOME
--
-- test-litmus-budget-tally.lua — a step killed at its budget is COUNTED apart from a failed
-- assertion, and still FAILS. Ported from test-litmus-budget-tally.sh (2399-lrg3); same seven
-- checks in its order.
--
-- THE ASSERTION THAT MATTERS IS NOT THE LABEL. 820-c8q8 settled that a timed-out step still
-- fails. The danger in 1187-iij8 is a BUDGET count implemented as a fourth bucket, so a timeout
-- stops failing: a fail-open gate. So every budget case asserts three things: the run exits
-- non-zero, the spec is still [FAIL], and only then that the BUDGET line names it.
--
--   0 PREMISE  the throwaway spec is discovered and its step executes (a printed [STEP 1/1]);
--              every absence arm below is vacuous over a run that executed nothing
--   1 a budget kill still exits NON-ZERO
--   2 a budget kill still reports Status: [FAIL]
--   3 the BUDGET line names it as a subset of the FAILs
--   4 NEGATIVE CONTROL a genuine assertion failure still fails
--   5 and is NOT counted as a budget kill
--   6 a green run prints no BUDGET line
--
-- HERMETIC. Each case is a scratch root holding a symlinked scripts/ and one probe spec, run
-- through the real runner. The probe's name is composed, never a literal `litmus:<slug>` token
-- (721-77yu). All four metrics logs are named into the scratch root (1204-3s2s), and the runner
-- is handed this checkout's plan binary (1427-utmy). TILLANDSIAS_* and PROJECT_ROOT are unset.
--
-- GRAMMAR ok:litmus-budget-tally:<n> arms | violation:litmus-budget-tally:<n>-failed
--       | skip:litmus-budget-tally:no-runnable-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("litmus-budget-tally")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
if PLAN:sub(1, 1) ~= "/" and not PLAN:match("^%a:[/\\]") then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local SH = fixture.posix_shell()

local SPEC = "budget-probe"
local NAME = "litmus" .. ":" .. SPEC

-- One scratch root per case; the step command must hold no double quote and no colon (it is
-- interpolated into a double-quoted YAML scalar, and invalid YAML is SKIPPED, not refused).
local function mkroot(cmd, timeout_ms)
    local W = T:scratch()
    for _, d in ipairs({ "openspec/litmus-tests", "methodology", "metrics" }) do fs.mkdir(W.rel .. "/" .. d) end
    T:must{ "ln", "-s", ROOT .. "/scripts", W.abs .. "/scripts" }
    T:must{ "ln", "-s", ROOT .. "/methodology/litmus.yaml", W.abs .. "/methodology/litmus.yaml" }
    fs.write(W.rel .. "/openspec/litmus-bindings.yaml", "version: '1.0'\ndescription: throwaway registry built at runtime\nspecs:\n- spec_id: "
        .. SPEC .. "\n  status: active\n  litmus_tests:\n  - " .. NAME .. "\n  coverage_ratio: 100\n  last_verified: '2026-01-01'\n")
    fs.write(W.rel .. "/openspec/litmus-tests/litmus-" .. SPEC .. ".yaml", table.concat({
        "name: " .. NAME, "spec: " .. SPEC, "phase: pre-build", "description: >",
        "  A throwaway probe built by test-litmus-budget-tally.lua.", "severity: high", "size: instant",
        "critical_path:", '  - step: "the probe step"', '    command: "' .. cmd .. '"',
        "    timeout_ms: " .. timeout_ms, '    expected_behavior: "ok-probe"', "" }, "\n"))
    return W
end

local function run(W)
    local m = W.abs .. "/metrics/"
    local r = T:run{ SH, W.abs .. "/scripts/run-litmus-test.sh", SPEC, "--phase", "pre-build", "--size", "all",
        cwd = W.abs, stdin = "", timeout_ms = 180000, env_unset = { "TILLANDSIAS_*", "PROJECT_ROOT" },
        env = { TILLANDSIAS_PLAN_BIN = PLAN,
            TILLANDSIAS_TIMING_LOG = m .. "tillandsias-timing.jsonl",
            TILLANDSIAS_CYCLE_FLOW_LOG = m .. "tillandsias-cycle-flow.jsonl",
            TILLANDSIAS_EXPERT_USAGE_LOG = m .. "forge-expert-usage.jsonl",
            TILLANDSIAS_EXPERT_HEALTH_LOG = m .. "forge-expert-health.jsonl" } }
    local plain = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", "")
    return r.code, plain
end
local function tail(s)
    local l = text.lines(s); local k = {}
    for i = math.max(1, #l - 5), #l do k[#k + 1] = l[i] end
    return table.concat(k, "|")
end

-- ARM 0: only a printed STEP proves a step ran (not the spec name: the size filter's
-- "selected 1 test(s) and executed NONE" line carries it too).
local rc, o = run(mkroot("echo ok-probe", 30000))
T:arm("0 PREMISE: the throwaway spec is discovered and its step executes", text.contains(o, "[STEP 1/1]"),
    "the runner never reached the step; every absence assertion below would be vacuous: " .. tail(o))

-- ARMS 1-3: a budget kill.
rc, o = run(mkroot("sleep 5; echo ok-probe", 1000))
T:arm("1 a budget kill still exits NON-ZERO", rc ~= nil and rc ~= 0,
    "rc=" .. tostring(rc) .. " — the verdict flipped; this is the fail-open gate 820-c8q8 forbids")
T:arm("2 a budget kill still reports Status: [FAIL]", text.contains(o, "Status: [FAIL]"), "no FAIL status: " .. tail(o))
T:arm("3 the BUDGET line names it as a subset of the FAILs", o:find("BUDGET.*killed at their budget") ~= nil,
    "no BUDGET line in: " .. tail(o))

-- ARMS 4-5: a genuine assertion failure is not a budget kill.
rc, o = run(mkroot("echo not-the-expected-output; exit 1", 30000))
T:arm("4 a genuine assertion failure still fails", rc ~= nil and rc ~= 0, "rc=" .. tostring(rc))
T:arm("5 a genuine failure is NOT counted as a budget kill", not text.contains(o, "killed at their budget"),
    "the BUDGET line appeared for a fast assertion failure")

-- ARM 6: a line that prints always is a line nobody reads.
rc, o = run(mkroot("echo ok-probe", 30000))
T:arm("6 a green run prints no BUDGET line", not text.contains(o, "killed at their budget"), "it printed one")

T:finish()
