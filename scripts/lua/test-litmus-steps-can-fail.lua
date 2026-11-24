-- @env PATH HOME
-- @trace spec:litmus-framework, spec:methodology-accountability
-- @trace order:972-cvdg, order:2278-zhqb
--
-- test-litmus-steps-can-fail.lua — fixture for scripts/lua/check-litmus-steps-can-fail.lua,
-- ported from the .sh of the same name (2278-zhqb); same four cases.
--
-- A guard against tests that cannot fail must itself be able to fail: the five
-- steps it was written for passed for their whole existence. So both directions
-- are driven over a scratch corpus.
--
--   1 DEFECT   the shipped defect (972-cvdg, verbatim) is caught
--   2 IDIOM    `cmd && echo A || echo B` with DIFFERENT tokens is left alone
--   3 QUOTING  'X' and "X" are the same token: spelling does not evade the guard
--   4 CLEAN    a corpus with no fallback passes quietly, naming how many it read
--   5 MUTANT   a guard that never compares the tokens lets case 1 through
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-steps-can-fail.lua
-- Verdict: ok:litmus-steps-can-fail-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-steps-can-fail-fixture")
local ROOT, PLAN = fixture.repo_root(), fixture.plan_binary()
local GUARD = "scripts/lua/check-litmus-steps-can-fail.lua"
if not PLAN or PLAN == "" then T:skip("no-runnable-plan-binary") end
local S = T:scratch()

local function guard(command, expected, script)
    fs.write(S.rel .. "/a.yaml", "critical_path:\n  - step: \"case\"\n    command: " .. command .. "\n    expected_behavior: \"" .. expected .. "\"\n")
    local r = proc.run{ argv = { PLAN, "script", "run", script or GUARD }, cwd = ROOT, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_LITMUS_DIR = S.abs, TILLANDSIAS_SCRIPT_RUNNER_BIN = PLAN } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function arm(name, rc, o, want_rc, want)
    T:arm(name, rc == want_rc and text.contains(o, want), "rc=" .. tostring(rc) .. " " .. o)
end

local DEFECT = [["podman inspect x --format='{{json .HostConfig.UsernsMode}}' | grep -q 'keep-id' && echo 'USERNS_KEEP_ID_SET' || echo 'USERNS_KEEP_ID_SET'"]]
local rc, o = guard(DEFECT, "USERNS_KEEP_ID_SET")
arm("1 DEFECT the shipped defect is caught", rc, o, 1, "violation:litmus-steps-cannot-fail:1")
rc, o = guard([["test -e /nope && echo 'PRESENT' || echo 'ABSENT'"]], "ABSENT")
arm("2 IDIOM two distinct tokens are left alone", rc, o, 0, "ok:litmus-steps-can-fail")
rc, o = guard([["grep -q foo bar && echo 'SAME' || echo \"SAME\""]], "SAME")
arm("3 QUOTING quote spelling does not evade the guard", rc, o, 1, "violation:litmus-steps-cannot-fail:1")
rc, o = guard([["podman info --format='{{.Security.Rootless}}'"]], "true")
arm("4 CLEAN a clean corpus passes quietly", rc, o, 0, "ok:litmus-steps-can-fail:1 file(s) checked")

-- 5: the guard's own comparison, made unsatisfiable, in a scratch copy
local src = fs.read(GUARD)
local mut, n = src:gsub("ok_branch == fail_branch then", "ok_branch == nil then", 1)
fs.write(S.rel .. "/mutant.lua", mut)
rc, o = guard(DEFECT, "USERNS_KEEP_ID_SET", S.abs .. "/mutant.lua")
T:arm("5 MUTANT a guard that never compares the tokens lets case 1 through", n >= 1 and rc == 0, "n=" .. n .. " rc=" .. tostring(rc) .. " " .. o)
T:finish()
