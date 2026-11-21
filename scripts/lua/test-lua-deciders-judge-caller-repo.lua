-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2166-zvst
--
-- test-lua-deciders-judge-caller-repo.lua — a Lua decider whose contract is
-- "judge the checkout I am run from" judges THAT checkout, even when the
-- environment names another repository root.
--
-- WHY: a proc.run without `cwd` runs in the runner's repository root, taken
-- from TILLANDSIAS_REPO_ROOT, then PROJECT_ROOT. The litmus runner exports
-- PROJECT_ROOT; land-queue sets TILLANDSIAS_REPO_ROOT. Each arm runs a decider
-- from a scratch repo with those two variables pointing at THIS checkout.
--
-- Arms (RED before 2166-zvst: each judged this checkout instead):
--   1  check-committable-branch names the scratch repo's branch, feature-here
--   2  the same with only PROJECT_ROOT set (the litmus runner's shape)
--   3  check-gate-step-prefix-across-refs skips: the scratch repo has no trunk ref
--      (this checkout has one, so the pre-fix code compared against it)
--   4  control: the scratch repo with no redirecting variables (green before and after)
--
-- Verdict: ok:lua-deciders-judge-caller-repo:<n> arms | violation:...:<n>-failed
local fixture = require "common.fixture"
local T = fixture.new("lua-deciders-judge-caller-repo")

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then verdict.emit("skip:lua-deciders-judge-caller-repo:no-plan-binary (set TILLANDSIAS_PLAN_BIN)", 0) end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")

local S = T:scratch("caller")
local GIT = { "git", "-C", S.abs, "-c", "user.name=t", "-c", "user.email=t@t" }
local function g(...)
    local a = {}
    for _, v in ipairs(GIT) do a[#a + 1] = v end
    for _, v in ipairs{ ... } do a[#a + 1] = v end
    T:must(a)
end
T:must{ "git", "init", "-q", "-b", "feature-here", S.abs }
fs.write(S.rel .. "/README", "scratch\n")
g("add", "-A"); g("commit", "-qm", "scratch")
g("config", "user.name", "t"); g("config", "user.email", "t@t")

local function decide(script, cwd, env)
    local r = T:run{ BIN, "script", "run", ROOT .. "/scripts/lua/" .. script, cwd = cwd, env = env }
    local last = ""
    for l in (r.stdout or ""):gmatch("[^\n]+") do last = l end
    return last, r
end

local both = { PROJECT_ROOT = ROOT, TILLANDSIAS_REPO_ROOT = ROOT, PWD = S.abs }
local out = decide("check-committable-branch.lua", S.abs, both)
T:arm("committable-branch judges the caller's repo under TILLANDSIAS_REPO_ROOT+PROJECT_ROOT",
    out == "ok:branch-feature-here", out)
out = decide("check-committable-branch.lua", S.abs, { PROJECT_ROOT = ROOT, PWD = S.abs })
T:arm("committable-branch judges the caller's repo under PROJECT_ROOT alone (litmus runner shape)",
    out == "ok:branch-feature-here", out)
out = decide("check-gate-step-prefix-across-refs.lua", S.abs, both)
T:arm("gate-step-prefix judges the caller's repo: no trunk ref there -> skip:no-trunk-ref",
    text.starts_with(out, "skip:gate-step-prefix-across-refs:no-trunk-ref"), out)
-- Control: the same scratch repo WITHOUT the redirecting variables. It is green
-- before and after the fix, so arms 1-3 failing can only be the variables.
-- (Not this checkout: the gate's isolated environment has no git identity.)
out = decide("check-committable-branch.lua", S.abs, { PWD = S.abs })
T:arm("control: no redirecting variables -> the scratch repo's branch", out == "ok:branch-feature-here", out)

T:finish()
