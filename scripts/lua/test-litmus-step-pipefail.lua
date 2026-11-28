-- @trace order:1293-wka4, order:1611-imnj, order:2399-lrg3, spec:spec-traceability
-- @env PATH HOME
--
-- test-litmus-step-pipefail.lua — a litmus step's spawned shell carries pipefail ONLY for the
-- shape where a filter would swallow the producer's status. Ported from
-- test-litmus-step-pipefail.sh (2399-lrg3); same six checks in its order.
--
-- THE DEFECT. run-litmus-test.sh runs under `set -uo pipefail`, but each step is spawned with a
-- fresh shell that does not inherit it, so `producer | head` returned 0 when the producer exited
-- non-zero and `assert_exit: 0` adjudicated HEAD. The fix is SHAPE-GATED, not a blanket: most
-- piped steps end in `grep -q`, where grep IS the adjudicator, and pipefail would invert the
-- negated ones (arm 4b).
--
--   1  the row's reproduction returns 7 when the spawned shell carries pipefail (pre-fix: 0)
--   2  through the real runner, a producer failing into head is RED
--   3  PRE-FIX CONTROL: a copy with the prelude neutralised PASSES the same step
--   4a a pipeline that genuinely succeeds still passes
--   4b a grep-adjudicated step is unchanged by a failing producer
--   5  KNOWN HOLE pinned: a `bash -lc` grandchild does not inherit the prelude (rc=0)
--
-- The pre-fix copy lives in this fixture's scratch, never beside the scripts (1611-imnj), and
-- its own-path lookups are pinned to this checkout. The probe's name is composed (721-77yu).
--
-- GRAMMAR ok:litmus-step-pipefail:<n> arms | violation:litmus-step-pipefail:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-step-pipefail")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local LIT = "litmus"
local W = T:scratch()
fs.mkdir(W.rel .. "/tests")
fs.write(W.rel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 1293-wka4\nspecs:\n- spec_id: spec-traceability\n  status: active\n  "
    .. LIT .. "_tests:\n  - " .. LIT .. ":wka4-probe\n  coverage_ratio: 100\n  last_verified: '2026-09-20'\n")

local function write_probe(cmd)
    fs.write(W.rel .. "/tests/" .. LIT .. "-wka4-probe.yaml", table.concat({
        "name: " .. LIT .. ":wka4-probe", "spec: spec-traceability", "phase: pre-build", "severity: high", "size: instant",
        "description: >", "  probe for 1293-wka4", "critical_path:", '  - step: "probe"', '    command: "' .. cmd .. '"',
        "    timeout_ms: 5000", '    expected_behavior: "the producer\'s status must reach the verdict"', "    assert_exit: 0", "" }, "\n"))
end
local function run_probe(runner)
    local r = T:run{ SH, runner, "spec-traceability", "--phase", "pre-build", "--size", "instant", "--compact",
        cwd = ROOT, stdin = "", timeout_ms = 120000,
        env = { TILLANDSIAS_LITMUS_BINDINGS = W.abs .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = W.abs .. "/tests" } }
    local plain = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", "")
    for _, l in ipairs(text.lines(plain)) do
        local s = l:match("^(Status: %[[A-Z]+%])")
        if s == "Status: [PASS]" or s == "Status: [FAIL]" then return s end
    end
    return "<none>"
end
local function sh_file(name, body)
    fs.write(W.rel .. "/" .. name, body .. "\n")
    return T:run{ SH, W.abs .. "/" .. name, cwd = ROOT, timeout_ms = 30000,
        env = { LITMUS_STDLIB = ROOT .. "/scripts/" .. LIT .. "-stdlib.sh" } }.code
end

-- ARM 1: the row's exact reproduction.
local rc = sh_file("repro.sh", 'set -o pipefail; . "$LITMUS_STDLIB"; sh -c "echo out; exit 7" 2>&1 | head -20 >/dev/null')
T:arm("ARM 1: the reproduction returns 7 when the spawned shell carries pipefail (pre-fix: 0)", rc == 7,
    "returned " .. tostring(rc) .. ", expected 7")

-- ARM 2: through the real runner.
local RUNNER = ROOT .. "/scripts/run-" .. LIT .. "-test.sh"
write_probe('sh -c \\"echo out; exit 7\\" 2>&1 | head -20')
local v = run_probe(RUNNER)
T:arm("ARM 2: a step whose producer fails into head is RED (assert_exit no longer adjudicates the filter)",
    v == "Status: [FAIL]", "expected FAIL, got '" .. v .. "'")

-- ARM 3: pre-fix control, on a copy in scratch.
local live = fs.read("scripts/run-" .. LIT .. "-test.sh") or ""
local live_hits = select(2, live:gsub('step_shell_prelude="set %-o pipefail; "', ""))
local mut, mut_n = live:gsub('\n *step_shell_prelude="set %-o pipefail; "', '\n                    step_shell_prelude=""')
mut = mut:gsub('%$%(dirname "%${BASH_SOURCE%[0%]}"%)', function() return ROOT .. "/scripts" end)
local mut_hits = select(2, mut:gsub('step_shell_prelude="set %-o pipefail; "', ""))
local PREFIX = W.rel .. "/wka4-prefix-runner.sh"
fs.write(PREFIX, mut)
if mut:find("BASH_SOURCE", 1, true) then
    T:arm("ARM 3: the pre-fix copy can run from scratch", false,
        "the copy still resolves a path from its own location (BASH_SOURCE); pin the new lookup")
elseif live_hits >= 1 and mut_n >= 1 and mut_hits == 0 then
    v = run_probe(W.abs .. "/wka4-prefix-runner.sh")
    T:arm("ARM 3: PRE-FIX the same step PASSES — the defect reproduces on demand", v == "Status: [PASS]",
        "pre-fix copy did not reproduce the false green (got '" .. v .. "')")
else
    T:arm("ARM 3: PRE-FIX the same step PASSES — the defect reproduces on demand", false,
        "mutation did not apply (live=" .. live_hits .. " mutant=" .. mut_hits .. ") — refusing a verdict from an unmutated copy")
end

-- ARM 4: the negative controls that make the gating worth it.
write_probe('sh -c \\"echo out; exit 0\\" 2>&1 | head -20')
v = run_probe(RUNNER)
T:arm("ARM 4a: a pipeline that genuinely succeeds still passes", v == "Status: [PASS]",
    "a genuinely-succeeding pipeline now fails ('" .. v .. "') — false green traded for false red")
write_probe('sh -c \\"echo hit; exit 7\\" 2>&1 | grep -q hit')
v = run_probe(RUNNER)
T:arm("ARM 4b: a grep-adjudicated step is UNCHANGED — the steps a blanket would have inverted are untouched",
    v == "Status: [PASS]", "a grep-adjudicated step changed verdict ('" .. v .. "') — a blanket has been applied")

-- ARM 5: the limitation, pinned.
rc = sh_file("grandchild.sh", "set -o pipefail; bash -lc 'sh -c \"exit 7\" | head -1' >/dev/null 2>&1")
T:arm("ARM 5: KNOWN HOLE pinned — a bash -lc grandchild still does not inherit pipefail (rc=0)", rc == 0,
    "the grandchild now returns " .. tostring(rc) .. " — the hole closed; record it on 1293-wka4 and update this arm")

T:finish()
