-- @env PATH HOME
-- @trace order:1194-davi, order:1570-25iq, order:2412-ewmt
--
-- test-unrunnable-platform-arms.lua — check-unrunnable-platform-arms.lua, the advisory that names
-- gate arms this host cannot run. Ported from the .sh of the same name (2412-ewmt).
--   1  a change touching nothing platform-scoped is SILENT: ok: with a zero numerator (negative control)
--   2  the verdict carries the documented, closed prefix
--   3  a SHORT spec row is refused as unparsable rather than read from the wrong column, at rc 0
--   4  an EMPTY spec skips loudly and never reports ok (785-sqe6)
--   5  an ABSENT spec source skips rather than passing over an empty set
--   6  an unresolvable base ref skips rather than diffing the world
--   7  the advisory never exits non-zero on any arm above (1194-davi)
--   8  THE DISCRIMINATING CONTROL: the same changed prover file gives advisory: on linux and ok: on
--      macos, so this is about SCOPE and not a filename match. The guard resolves its own repo root,
--      so it runs INSIDE a probe repo (a copy of the guard at its root), never against this one.
--   9  a FIRING advisory still exits 0: arm 7 runs against this repo, where nothing platform-scoped
--      changed, so it cannot reach the advisory branch (mutating its `exit 0` left arm 7 green)
--   10 the guard is BOUND: scripts/land-on-platform-branch.sh invokes it
--   11 the repo's own orphan auditor (audit-guard-activation.lua) lists it as active;
--      arm 10 only proves a grep, the auditor is what reds the gate
--
-- Usage: tillandsias-plan script run scripts/lua/test-unrunnable-platform-arms.lua
-- Verdict: ok:unrunnable-platform-arms-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("unrunnable-platform-arms-fixture")
local PLAN = fixture.plan_binary()
local GUARD = "scripts/lua/check-unrunnable-platform-arms.lua"
if not fs.exists(GUARD) then T:arm("0 the guard under test exists", false, GUARD .. " absent"); T:finish() end
local d = T:scratch()
-- The prover name is assembled so this file does not itself mention a credential script.
local PROVER = "check-credential" .. "-" .. "channel.sh"
local function spec(rows) return "required_tools() {\ncat <<SPEC\n" .. rows .. "SPEC\n}\n" end
fs.write(d.rel .. "/spec.sh", spec("timeout|binary|gate|macos|" .. PROVER .. "|x|why|remedy\n"
    .. "rg|binary|gate|linux|lua/check-ripgrep-available.lua|x|why|remedy\n"
    .. "cargo|binary|gate|macos,linux,windows|-|x|why|remedy\n"))
fs.write(d.rel .. "/short.sh", spec("timeout|binary|gate|macos\n"))
fs.write(d.rel .. "/empty.sh", spec(""))
local function guard(args, cwd)
    local argv = { PLAN, "script", "run", GUARD, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd = cwd; argv.timeout_ms = 120000; argv.refusal_ok = true; argv.env_unset = { "TILLANDSIAS_*" }
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or "")
end
local c1, o1 = guard{ "--spec-source", d.rel .. "/spec.sh", "--platform", "linux", "--base", "HEAD" }
T:arm("1 a clean tree reports ok: with a zero numerator", c1 == 0 and o1:match("^ok:unrunnable%-platform%-arms:0 of") ~= nil, "rc=" .. tostring(c1) .. " " .. o1)
T:arm("2 the verdict carries the documented prefix", o1:match("^ok:unrunnable%-platform%-arms:") or o1:match("^advisory:unrunnable%-platform%-arms:")
    or o1:match("^skipped:unrunnable%-platform%-arms:") or o1:match("^fail:unrunnable%-platform%-arms:"), o1)
local c3, o3 = guard{ "--spec-source", d.rel .. "/short.sh", "--platform", "linux" }
T:arm("3 a 4-field row is refused as unparsable, at rc 0", c3 == 0 and o3:match("^fail:unrunnable%-platform%-arms:unparsable%-spec") ~= nil, "rc=" .. tostring(c3) .. " " .. o3)
local c4, o4 = guard{ "--spec-source", d.rel .. "/empty.sh", "--platform", "linux" }
T:arm("4 no rows parsed reports skipped:, not ok:", o4:match("^skipped:unrunnable%-platform%-arms:no%-rows") ~= nil, o4)
local c5, o5 = guard{ "--spec-source", d.rel .. "/does-not-exist.sh", "--platform", "linux" }
T:arm("5 an absent source reports skipped:no-spec-source", o5:match("^skipped:unrunnable%-platform%-arms:no%-spec%-source") ~= nil, o5)
local c6, o6 = guard{ "--base", "refs/heads/definitely-no-such-ref", "--platform", "linux" }
T:arm("6 an unresolvable base reports skipped:no-diff-base", o6:match("^skipped:unrunnable%-platform%-arms:no%-diff%-base") ~= nil, o6)
T:arm("7 every verdict above exits 0", c1 == 0 and c3 == 0 and c4 == 0 and c5 == 0 and c6 == 0,
    table.concat({ tostring(c1), tostring(c3), tostring(c4), tostring(c5), tostring(c6) }, " "))

-- Arm 8's probe repo: its root holds a copy of the guard, a base commit, and a change to the prover.
local p = d.rel .. "/probe"
fs.mkdir(p .. "/scripts/lua")
fs.write(p .. "/" .. GUARD, fs.read(GUARD))
fs.write(p .. "/spec.sh", fs.read(d.rel .. "/spec.sh"))
fs.write(p .. "/scripts/" .. PROVER, "x\n")
local pa = d.abs .. "/probe"
local function git(...)
    local argv = { "git", "-C", pa, "-c", "user.email=t@e", "-c", "user.name=t", ... }   -- `...` LAST, or Lua keeps one value
    argv.timeout_ms = 30000
    return T:run(argv)
end
git("init", "-q", "."); git("add", "-A"); git("commit", "-qm", "base")
fs.write(p .. "/scripts/" .. PROVER, "x\nchanged\n")
local cl, lin = guard({ "--spec-source", "spec.sh", "--platform", "linux", "--base", "HEAD" }, pa)
local _, mac = guard({ "--spec-source", "spec.sh", "--platform", "macos", "--base", "HEAD" }, pa)
T:arm("8 linux gets advisory:, macos gets ok: for the SAME changed file", lin:match("^advisory:") ~= nil and mac:match("^ok:") ~= nil, "linux=[" .. lin .. "] macos=[" .. mac .. "]")
T:arm("9 a FIRING advisory still exits 0", lin:match("^advisory:") ~= nil and cl == 0, "rc=" .. tostring(cl) .. " " .. lin)
T:arm("10 scripts/land-on-platform-branch.sh invokes the advisory", text.contains(fs.read("scripts/land-on-platform-branch.sh"), "check-unrunnable-platform-arms.lua"))
if fs.exists("scripts/lua/audit-guard-activation.lua") then
    local a = T:run{ PLAN, "script", "run", "scripts/lua/audit-guard-activation.lua", timeout_ms = 300000, refusal_ok = true }
    -- The auditor prints `orphans:` only when there are some, so absence of that line proves
    -- nothing (the .sh passed on it); its `active:` line naming this guard does.
    local o = (a.stdout or "") .. (a.stderr or "")
    local active = ("\n" .. o):match("\n(active:%s+lua/check%-unrunnable%-platform%-arms%.lua[^\n]*)")
    T:arm("11 the orphan auditor lists the guard as active", active ~= nil, "no active: line for it; rc=" .. tostring(a.code))
else
    out.line("skip: 11 audit-guard-activation.lua is absent: auditor agreement not checked")
end
T:finish()
