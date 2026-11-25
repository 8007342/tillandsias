-- @env PATH HOME
-- @trace order:901-jtvi, order:1637-5765, order:2332-rxkr
--
-- test-litmus-grep-escapes.lua — check-litmus-grep-escapes.lua refuses a litmus grep pattern
-- whose escape GNU grep does not define. Ported from the .sh of the same name (2332-rxkr).
-- The escapes were measured against /usr/bin/grep (GNU grep 3.12), not an interactive ugrep
-- function, which interprets \t. Arm 1 is the REAL pre-fix file, read from history; the
-- accepting arms matter as much, since a guard that fires on working code gets switched off.
--
--   1 the pre-fix steps are refused at both lines      2 the post-fix forms are accepted
--   3 the committed corpus is clean                    4 "$(printf '\t')" is accepted
--   5 -F interprets no regex                           6 -P defines the escapes
--   7 \s and \w are GNU extensions                     8 a fresh \t is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-grep-escapes.lua
-- Verdict: ok:litmus-grep-escapes-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-grep-escapes-fixture")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local FIX, FILE = "6fc5b7ac2", ":openspec/litmus-tests/litmus-capability-routing-shape.yaml"

local function check(yaml)
    local argv = { PLAN, "script", "run", "scripts/lua/check-litmus-grep-escapes.lua" }
    if yaml then
        local d = T:scratch()
        fs.write(d.rel .. "/x.yaml", yaml)
        argv[5], argv[6] = "--", d.rel
    end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 500)
end
local function accepted(name, yaml)
    local rc, o, why = check(yaml)
    T:arm(name, rc == 0 and text.contains(o, "ok:litmus-grep-escapes:"), why)
end
local function step(command) return 'steps:\n  - command: "' .. command .. '"\n' end

local pre, post = T:run{ "git", "show", FIX .. "^" .. FILE, cwd = ROOT }, T:run{ "git", "show", FIX .. FILE, cwd = ROOT }
if pre.code == 0 and post.code == 0 then
    local rc, o, why = check(pre.stdout)
    T:arm("1 the REAL pre-fix steps are refused at both lines", rc == 1 and text.contains(o, ":55:") and text.contains(o, ":64:"), why)
    accepted("2 the post-fix forms are accepted", post.stdout)
else
    out.line("skip: 1 and 2, " .. FIX .. " is not in this clone")
end
accepted("3 the committed corpus is clean", nil)
accepted([[4 the $(printf '\t') idiom is accepted]], step([[out=$(x); printf %s \"$out\" | grep -c \"^packet$(printf '\\t')\"]]))
accepted("5 a grep -F pattern is accepted", step([[grep -qF 'Servicing\\tRebootPending' f.ps1]]))
accepted("6 a grep -P pattern is accepted", step([[grep -qP '[^\\x00-\\x7F]' scripts/install-windows.ps1]]))
accepted([[7 \s and \w are accepted]], step([[grep -qE '^\\s+-\\s*\\w+:' .github/workflows/x.yml]]))
local rc, o, why = check(step([[printf %s \"$out\" | grep -qE '^hardware\\tloci=']]))
T:arm([[8 a fresh \t is refused]], rc == 1 and text.contains(o, "x.yaml:2:"), why)
T:finish()
