-- @env PATH HOME
-- inputs: openspec/litmus-tests/litmus-lww-channel-fields-alias.yaml plan/index.yaml scripts/lua/check-fragment-status-loss.lua scripts/lua/check-litmus-mutation-arms-mutate.lua scripts/lua/test-litmus-item-opener-refused.lua scripts/plan-binary-probe.sh scripts/run-litmus-test.sh scripts/test-fragment-status-loss.sh lib/lua/common/ crates/tillandsias-plan/
-- @trace order:1059-pb2j, order:2310-eji3
--
-- test-litmus-mutation-arm-guard.lua — check-litmus-mutation-arms-mutate.lua flags an arm
-- named MUTATION that mutates nothing. Ported from the .sh of the same name (2310-eji3).
-- Arm 1 is the REAL pre-fix text, read from history, not an imitation. The negative controls
-- matter as much: a guard that flags correct work gets switched off.
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-mutation-arm-guard.lua
-- Verdict: ok:litmus-mutation-arm-guard:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-mutation-arm-guard")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
-- want: "flagged" (rc 1 and a violation naming the file) or "passed" (rc 0).
local function arm(name, want, yaml)
    local d = T:scratch()
    fs.write(d.rel .. "/litmus-x.yaml", yaml)
    local r = T:run{ PLAN, "script", "run", "scripts/lua/check-litmus-mutation-arms-mutate.lua", "--", d.abs, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    local got = r.code == 0 and "passed" or (r.code == 1 and text.contains(o, "violation:") and text.contains(o, "litmus-x.yaml")) and "flagged" or "other"
    T:arm(name, got == want, "want " .. want .. " got " .. got .. " rc=" .. tostring(r.code) .. " " .. o:sub(1, 400))
end
local function step(name, command) return 'steps:\n  - step: "' .. name .. '"\n    command: "' .. command .. '"\n    timeout_ms: 10000\n' end

local REV = "5083b2649^:openspec/litmus-tests/litmus-lww-channel-fields-alias.yaml"
local pre = T:run{ "git", "show", REV, cwd = ROOT }
if pre.code == 0 then
    T:arm("1a the recovered pre-fix text holds the MUTATION arm", text.contains(pre.stdout, "MUTATION"), pre.stdout:sub(1, 100))
    arm("1b the REAL pre-fix arm is flagged", "flagged", pre.stdout)
else
    out.line("skip: 1 " .. REV .. " is not in this clone")
end
arm("2 a renamed SOURCE PIN over the same command passes", "passed",
    step("SOURCE PIN: the reader still reads both channels", "grep -q 'for channel in' crates/x/src/y.rs"))
arm("3 an arm that mutates inline passes", "passed",
    step("MUTATION: the guard still refuses after the field is removed", "t=$(mktemp -d); trap 'rm -rf \\\"$t\\\"' EXIT; " .. "sed " .. "-i 's/foo/bar/' \\\"$t/f\\\"; bash guard.sh"))
arm("4 an arm delegating its mutation to a fixture passes", "passed",
    step("MUTATION CONTROL: every status-loss class is still refused", "bash scripts/test-fragment-status-loss.sh >/tmp/out.log 2>&1"))
arm("5 a command that only MENTIONS a mutating verb is flagged", "flagged",
    step("MUTATION: the alias removal must be observed", "grep -q 'alias' src/x.rs # this used to " .. "sed " .. "-i the reader and git checkout it back"))
arm("6 redirections to /dev/null and fd 2 are not mutations", "flagged",
    step("MUTATION: the reader must fail once the field is gone", "grep -q 'field' src/x.rs >/dev/null 2>&1 && echo ok"))
-- The boundary before a script path is usually a QUOTE in a YAML scalar (order 147).
arm("7 a delegation written as a bare quoted path passes", "passed",
    step("MUTATION CONTROL: the guard catches a lost static and a retry loop", "scripts/test-fragment-status-loss.sh"))
-- 8-10 (2325-qmsb): a fixture in Lua is a fixture. Running it delegates; naming it as another command's
-- argument does not.
arm("8 a MUTATION step that runs a scripts/lua fixture passes", "passed",
    step("MUTATION CONTROL: without the fix the silent merge returns", "\\\"$P\\\" script run scripts/lua/test-litmus-item-opener-refused.lua 2>&1"))
arm("9 CONTROL a MUTATION step that does not delegate is flagged", "flagged",
    step("MUTATION: the reader must fail once the field is gone", "\\\"$P\\\" script run --help >/dev/null"))
arm("10 CONTROL naming a scripts/lua file in another command is flagged", "flagged",
    step("MUTATION: the alias removal must be observed", "grep -q 'alias' scripts/lua/test-litmus-item-opener-refused.lua"))
T:finish()
