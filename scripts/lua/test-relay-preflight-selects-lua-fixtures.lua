-- @env PATH HOME
-- @trace order:2415-ea3h, order:1594-mtc3
--
-- test-relay-preflight-selects-lua-fixtures.lua — relay-preflight's phase 5 selects Lua fixtures,
-- and a Lua-only diff runs the fixtures that name what it changed.
--
-- WHY (2415-ea3h, doris's finding relayed as 2413-3dap). Phase 5 built its population from
-- `git ls-files 'scripts/test-*.sh'` and its subjects from DIFF_SCRIPTS, which keeps only *.sh. A
-- diff touching only Lua therefore selected ZERO fixtures on every host and still printed ok:
-- every relay-preflight of 2026-11-26 read fixtures=0.
--
-- The fixture runs scripts/relay-preflight.sh's own selection block (from `_all_fixtures=` to
-- `fixtures=`) in a scratch repo holding:
--   scripts/lua/check-x.lua            the subject the diff changes
--   scripts/lua/test-x.lua             a Lua fixture that names it
--   scripts/lua/test-unrelated.lua     a Lua fixture that does not
--   scripts/test-y.sh + scripts/y.sh   a shell fixture and its subject (the control)
--   1 SELECTED   a Lua-only diff of check-x.lua selects scripts/lua/test-x.lua (red on trunk's block)
--   2 SCOPED     it does not select test-unrelated.lua: selection is by subject, not "every .lua"
--   3 SET A      a diff of the Lua fixture itself selects it
--   4 CONTROL    a diff of y.sh still selects the shell fixture test-y.sh
--   5 DELETED    a deleted Lua fixture is not selected (the 1594-mtc3 rule, kept for .lua)
--   6 ZERO       a diff naming nothing selects nothing (so the line reads fixtures=not-run)
-- DIFF_SCRIPTS is set as relay-preflight sets it (*.sh of the diff) and DIFF_SUBJECTS as the fix
-- does (*.sh and *.lua), so trunk's block, which reads only DIFF_SCRIPTS, is measured as it runs.
--
-- Usage: tillandsias-plan script run scripts/lua/test-relay-preflight-selects-lua-fixtures.lua
-- Verdict: ok:relay-preflight-selects-lua-fixtures:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("relay-preflight-selects-lua-fixtures")
local SH = fixture.posix_shell()
local src = fs.read("scripts/relay-preflight.sh") or ""
local block = src:match("\n(_all_fixtures=.-\nfixtures=[^\n]*)\n")
T:arm("0 phase 5's selection block is found in scripts/relay-preflight.sh", block ~= nil)
if not block then T:finish() end

local d = T:scratch()
local R = d.rel .. "/repo"
fs.mkdir(R .. "/scripts/lua")
fs.write(R .. "/scripts/lua/check-x.lua", "-- subject\n")
fs.write(R .. "/scripts/lua/test-x.lua", "-- exercises scripts/lua/check-x.lua\n")
fs.write(R .. "/scripts/lua/test-unrelated.lua", "-- exercises nothing in this diff\n")
fs.write(R .. "/scripts/y.sh", "echo y\n")
fs.write(R .. "/scripts/test-y.sh", "#!/usr/bin/env bash\nbash scripts/y.sh\n")
local function git(...)
    local argv = { "git", "-C", d.abs .. "/repo", "-c", "user.name=f", "-c", "user.email=f@l", "-c", "commit.gpgsign=false", ... }
    argv.timeout_ms = 30000
    return T:run(argv)
end
git("init", "-q"); git("add", "-A"); git("commit", "-qm", "base")
fs.write(d.rel .. "/select.sh", 'cd "$1" || exit 2\nDIFF_ALL="$2"\n'
    .. "DIFF_SCRIPTS=\"$(printf '%s\\n' \"$DIFF_ALL\" | grep -E '^scripts/.*\\.sh$' || true)\"\n"
    .. "DIFF_SUBJECTS=\"$(printf '%s\\n' \"$DIFF_ALL\" | grep -E '^scripts/.*\\.(sh|lua)$' || true)\"\n"
    .. block .. "\nprintf 'selected:%s\\n' $fixtures\n")
local function select(diff)
    local r = T:run{ SH, d.abs .. "/select.sh", d.abs .. "/repo", diff, timeout_ms = 30000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function has(s, x) return s:find(x, 1, true) ~= nil end

local o = select("scripts/lua/check-x.lua")
T:arm("1 a Lua-only diff of check-x.lua selects scripts/lua/test-x.lua", has(o, "selected:scripts/lua/test-x.lua"), o)
T:arm("2 it does not select the unrelated Lua fixture", has(o, "selected:scripts/lua/test-x.lua") and not has(o, "test-unrelated.lua"), o)
o = select("scripts/lua/test-x.lua")
T:arm("3 a diff of the Lua fixture itself selects it", has(o, "selected:scripts/lua/test-x.lua"), o)
o = select("scripts/y.sh")
T:arm("4 a diff of y.sh still selects the shell fixture", has(o, "selected:scripts/test-y.sh"), o)
o = select("scripts/lua/test-gone.lua")
T:arm("5 a deleted Lua fixture is not selected", not has(o, "test-gone.lua"), o)
o = select("docs/nothing.md")
T:arm("6 a diff naming nothing selects nothing", not has(o, "selected:scripts/"), o)

-- 7 (2419-8him) a .lua fixture is run with TILLANDSIAS_PLAN_BIN and TILLANDSIAS_SCRIPT_RUNNER_BIN
-- naming the runner: 175 fixtures read one of them and refuse could-not-run without it, so 2415-ea3h
-- reported each red by construction (#1424's relay reddened on test-bare-mktemp.lua in 8 ms). The
-- loop's command construction is cut from the script and run with a stub runner that prints them.
local build = src:match("\n(%s*_fx_cmd=%(bash \"%$_fx\"%)\n.-\n%s*fi\n)")
T:arm("7 premise: the loop's _fx_cmd construction is found", build ~= nil)
if build then
    fs.write(d.rel .. "/runner", "#!/bin/sh\necho \"PLAN=$TILLANDSIAS_PLAN_BIN RUNNER=$TILLANDSIAS_SCRIPT_RUNNER_BIN\"\n")
    T:run{ "chmod", "+x", d.abs .. "/runner" }
    fs.write(d.rel .. "/cmd.sh", '_lua_runner() { _lb="$1"; }\nset -- "$1"\nR="$1"\n_fx=scripts/lua/test-x.lua; _name=fixture:test-x.lua\n'
        .. "_lua_runner() { _lb=\"$R\"; return 0; }\n" .. build .. '"${_fx_cmd[@]}"\n')
    local r = T:run{ SH, d.abs .. "/cmd.sh", d.abs .. "/runner", env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    local want = "PLAN=" .. d.abs .. "/runner RUNNER=" .. d.abs .. "/runner"
    T:arm("7 a .lua fixture sees TILLANDSIAS_PLAN_BIN and TILLANDSIAS_SCRIPT_RUNNER_BIN naming the runner",
        text.contains(r.stdout or "", want), (r.stdout or "") .. (r.stderr or ""))
end
T:finish()
