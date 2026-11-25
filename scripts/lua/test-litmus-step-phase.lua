-- @env PATH HOME
-- @trace order:2349-b3u2
--
-- test-litmus-step-phase.lua — check-litmus-step-phase.lua refuses a step's `phase:` and nothing else.
--
--   1 planted on a step: refused, by line       2 as the step's first key
--   3 CONTROL at the top level: accepted        4 CONTROL inside a block scalar: accepted
--   5 CONTROL another section's list: accepted  6 the corpus is clean
--   7 PREMISE the runner still reads only the top level
--   8 a directory that is not there is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-step-phase.lua
-- Verdict: ok:litmus-step-phase-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-step-phase-fixture")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local function check(dir)
    local argv = { PLAN, "script", "run", "scripts/lua/check-litmus-step-phase.lua" }
    if dir then argv[5], argv[6] = "--", dir end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400)
end
local function planted(body)
    local d = T:scratch()
    fs.write(d.rel .. "/x.yaml", "name: x\nphase: pre-build\n" .. body)
    return check(d.rel)
end
local function arm(name, want, body)
    local rc, o, why = planted(body)
    T:arm(name, want and rc == 1 and text.contains(o, "x.yaml:" .. want .. ":") and text.contains(o, "violation:litmus-step-phase:1")
        or not want and rc == 0 and text.contains(o, "ok:litmus-step-phase:1 files"), why)
end
arm("1 a phase on a step is refused by line", 5, 'critical_path:\n  - step: "a"\n    phase: pre-build\n    command: "true"\n')
arm("2 as the step's first key", 4, 'critical_path:\n  - phase: pre-build\n    step: "a"\n')
arm("3 CONTROL a top-level phase is accepted", nil, 'critical_path:\n  - step: "a"\n    command: "true"\n')
arm("4 CONTROL a phase inside a block scalar is accepted", nil, 'critical_path:\n  - step: "a"\n    command: |\n      cat <<X\n      phase: pre-build\n      - step: q\n        phase: post-build\n      X\n')
arm("5 CONTROL a list under another key is accepted", nil, 'critical_path:\n  - step: "a"\nobservability:\n  - step: "a"\n    phase: pre-build\n')
local rc, o, why = check(nil)
T:arm("6 the corpus is clean", rc == 0, why)
local RUN = fs.read("scripts/run-litmus-test.sh")
local reader = RUN:match("\nget_test_phase%(%) {\n(.-)\n}\n") or ""
T:arm("7 PREMISE the runner reads the top-level phase and no step's", text.contains(reader, ".phase // \"runtime\"") and not text.contains(RUN, "step.phase") and not text.contains(RUN, "critical_path[].phase"), reader:sub(1, 300))
rc, o, why = check("target/plan-scratch/no-such-litmus-dir")
T:arm("8 a directory that is not there is refused", rc == 1 and text.contains(o, "refused:litmus-step-phase:no-dir:"), why)
T:finish()
