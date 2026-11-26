-- @trace order:956-llei, order:1358-9wzz, order:1096-p3tn, order:2387-lrg2
-- @env PATH HOME
--
-- test-litmus-kill-adjudicator.lua — the kill-time adjudicator classifies a step TIMEOUT by
-- diffing THIS cgroup's cpu.pressure `some total=` counter across the step's own window, never
-- by the retired host-wide load1-vs-ncpus rule. Ported from test-litmus-kill-adjudicator.sh
-- (2387-lrg2); same seven checks over three arms, in its order.
--
--   1  advancing counter -> CONTENDED, names cpu.pressure and the stall
--   1b retired load1-vs-ncpus instrument absent
--   2  flat counter -> CPU starvation excluded, cause otherwise UNCLASSIFIED (1358-9wzz)
--   2b a low stall claims neither 'NOT contended' nor 'genuinely too slow'
--   2c a low stall names the next measurement: re-run the step alone
--   2d the slowest-tests table marks the killed probe as censored
--   3  no pressure file -> UNCLASSIFIED, and no fallback instrument
--
-- Every arm runs THROUGH THE REAL RUNNER, from a scratch root with a symlinked scripts/ and one
-- probe yaml; LITMUS_PSI_FILE points the adjudicator at an injected counter. Every arm also
-- asserts the step reached TIMEOUT: a probe the runner skipped would pass every negative check.
--
-- PORT NOTE. The probe's name is composed, never a literal `litmus:<slug>` token (the 721-77yu
-- pin checker). The timing log is named into the scratch dir (1096-p3tn). TILLANDSIAS_* is
-- unset and only the three variables the runner needs are passed. The io/memory pressure
-- arms of draft #1212 are not here: they need a runner change that is not on trunk.
--
-- GRAMMAR ok:litmus-kill-adjudicator:<n> arms | violation:litmus-kill-adjudicator:<n>-failed
--       | skip:litmus-kill-adjudicator:no-validator

local fixture = require "common.fixture"
local T = fixture.new("litmus-kill-adjudicator")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
local SH = fixture.posix_shell()

local W = T:scratch("root")
for _, d in ipairs({ "openspec/litmus-tests", "methodology", "target" }) do fs.mkdir(W.rel .. "/" .. d) end
T:must{ "ln", "-s", ROOT .. "/scripts", W.abs .. "/scripts" }
T:must{ "ln", "-s", ROOT .. "/methodology/litmus.yaml", W.abs .. "/methodology/litmus.yaml" }

local SLUG = "kill-adjudicator-probe"
local NAME = "litmus" .. ":" .. SLUG
fs.write(W.rel .. "/openspec/litmus-bindings.yaml",
    "specs:\n  - spec_id: " .. SLUG .. "\n    status: active\n    litmus_tests:\n      - " .. NAME .. "\n")
local PSI = W.abs .. "/cpu.pressure"
local PSI_REL = W.rel .. "/cpu.pressure"
local PROBE = W.rel .. "/openspec/litmus-tests/litmus-" .. SLUG .. ".yaml"

local function write_probe(cmd)
    fs.write(PROBE, table.concat({
        "# fixture-only probe: deliberately overruns its budget so the TIMEOUT",
        "# adjudicator runs (956-llei). Lives only in a scratch root, never in the suite.",
        "name: " .. NAME, "spec: " .. SLUG, "phase: pre-build", "size: instant", "severity: low",
        "description: >", "  Fixture probe for the kill-time adjudicator (956-llei).",
        "critical_path:", '  - step: "overrun the budget"', '    command: "' .. cmd .. '"',
        "    timeout_ms: 2000", '    expected_behavior: "never-matches"', "" }, "\n"))
end
local function run_probe(psi)
    local r = T:run{ SH, W.abs .. "/scripts/run-litmus-test.sh", SLUG, "--phase", "pre-build", "--timeout", "2",
        cwd = W.abs, stdin = "", timeout_ms = 180000, env_unset = { "TILLANDSIAS_*", "PROJECT_ROOT" },
        env = { TILLANDSIAS_PLAN_BIN = PLAN, LITMUS_PSI_FILE = psi,
            TILLANDSIAS_TIMING_LOG = W.abs .. "/timing-FIXTURES.jsonl" } }
    return (r.stdout or "") .. (r.stderr or "")
end
local function has(s, pat) return s:find(pat) ~= nil end
local function why(s)
    local k = {}
    for _, l in ipairs(text.lines(s)) do
        if (l:find("TIMEOUT") or l:find("pressure") or l:find("load1") or l:find("SKIP") or l:lower():find("error")) and #k < 5 then
            k[#k + 1] = l
        end
    end
    return table.concat(k, " | ")
end
local function reached(s) return text.contains(s, "TIMEOUT") end
local function no_load1(s) return not text.contains(s, "load1=") end

-- Arm 1
fs.write(PSI_REL, "some avg10=0.00 avg60=0.00 avg300=0.00 total=1000000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
write_probe("echo 'some avg10=0.00 avg60=0.00 avg300=0.00 total=4000000' > $LITMUS_PSI_FILE; sleep 30")
local o = run_probe(PSI)
T:arm("1 advancing counter -> CONTENDED, names cpu.pressure and the stall", reached(o)
    and has(o, "cpu%.pressure some%-stall 3000000us over %d+s %(%d+%%%) in this cgroup — step CONTENDED at kill time"), why(o))
T:arm("1b retired load1-vs-ncpus instrument absent (arm 1)", no_load1(o), why(o))

-- Arm 2
fs.write(PSI_REL, "some avg10=0.00 avg60=0.00 avg300=0.00 total=5000000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
write_probe("sleep 30")
o = run_probe(PSI)
T:arm("2 flat counter -> CPU starvation excluded, cause otherwise UNCLASSIFIED", reached(o)
    and has(o, "cpu%.pressure some%-stall 0us over %d+s %(0%%%) in this cgroup — CPU starvation EXCLUDED; cause otherwise UNCLASSIFIED"), why(o))
T:arm("2b low stall claims neither 'NOT contended' nor 'genuinely too slow'",
    not text.contains(o, "NOT contended at kill time") and not text.contains(o, "genuinely too slow"), why(o))
T:arm("2c low stall names the next measurement: re-run the step alone", text.contains(o, "Re-run this step ALONE"), why(o))
T:arm("2d slowest-tests table marks the killed probe as censored", text.contains(o, "killed at budget — censored"), why(o))

-- Arm 3
write_probe("sleep 30")
o = run_probe(W.abs .. "/absent-cpu.pressure")
T:arm("3 no pressure file -> UNCLASSIFIED, no fallback instrument", reached(o)
    and text.contains(o, "cpu.pressure unavailable in this cgroup — cause UNCLASSIFIED") and no_load1(o), why(o))

T:finish()
