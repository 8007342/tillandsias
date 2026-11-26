-- @env PATH HOME
-- @trace order:1311-ajpm, order:1317-9ugn, order:1255-s4im, order:2392-dn3f, spec:methodology-accountability
--
-- test-join-the-fleet-idempotent.lua — pins the contract of scripts/lua/check-fleet-membership.lua,
-- the verifier behind ./skills/join-the-fleet. Ported from the .sh of the same name; same arms, plus
-- a mutation control for arm 7.
--
--   1  IDEMPOTENT AND NON-MUTATING: two runs on this checkout, same verdict and rc, tree untouched
--   2  FORGE REGIME: host-only steps are named skips, skipped= equals the skip lines, none ran
--   3  TROUBLESHOOTING: a scaffold git dir with no pre-push hook is the installer todo, rc != 0
--   4  RERERE off is the config todo; on is ok           5 a work ref is noted, never a branch todo
--   7  MASKED: a hook in .git/hooks under an empty core.hooksPath is a todo (1255-s4im)
--   7m MUTATION a checker that reads .git/hooks unconditionally says ok there (arm 7 has teeth)
--   8  FORGE: a hook only in a shared core.hooksPath is ok
--   6  AFFORDANCE: the skill's §3 block is byte-identical to what the pre-push hook prints
--
-- Arms 2-8 run with JOIN_FLEET_PROBES=0, so they never execute the other guards; arm 1 runs the
-- real probes, because idempotence is a property of the whole walk.
--
-- Usage: tillandsias-plan script run scripts/lua/test-join-the-fleet-idempotent.lua
-- Verdict: ok:join-the-fleet-idempotent:<n> arms | violation:join-the-fleet-idempotent:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("join-the-fleet-idempotent")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local CHECKER = "scripts/lua/check-fleet-membership.lua"
local RUNNER = fixture.plan_binary()
if RUNNER == "" then T:refuse("no-plan-binary", "the checker is Lua; build tillandsias-plan to run it") end
if not fs.exists(CHECKER) then T:refuse("no-checker", CHECKER) end

local function check(e, script)
    local env_ = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for k, v in pairs(e or {}) do env_[k] = v end
    local r = proc.run{ argv = { RUNNER, "script", "run", script or CHECKER }, cwd = ROOT, env = env_,
        env_unset = { "JOIN_FLEET_*", "TILLANDSIAS_HOST_KIND" }, timeout_ms = 600000 }
    local o = (r.stdout or ""):gsub("\r", "")
    local last = ""
    for l in (o .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then last = l end end
    return { rc = r.code, out = "\n" .. o, last = last, why = "rc=" .. tostring(r.code) .. " " .. o:sub(-400) }
end
local function has(x, line) return text.contains(x.out, "\n" .. line .. "\n") end
local function porcelain() return T:run{ "git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all" }.stdout or "" end

-- ---- arm 1 ------------------------------------------------------------------
local before = porcelain()
local o1, o2 = check(), check()
local after = porcelain()
T:arm("1a the verdict has the grammar", o1.last:find("^ok:join%-the%-fleet:.*:ran=") ~= nil or o1.last:find("^todo:join%-the%-fleet:.*:todos=") ~= nil, o1.why)
T:arm("1b the verdict and rc are stable across two runs", o1.last == o2.last and o1.rc == o2.rc, o1.last .. " vs " .. o2.last)
T:arm("1c git status is unchanged by two runs", before == after, "the checker changed the tree")

-- ---- arm 2 ------------------------------------------------------------------
local f = check{ TILLANDSIAS_HOST_KIND = "forge", JOIN_FLEET_PROBES = "0" }
local nskip = 0
for l in f.out:gmatch("\n(skip:join%-the%-fleet:[^\n]*)") do nskip = nskip + 1 end
local claimed = tonumber(f.last:match("skipped=(%d+)") or "")
T:arm("2a the regime is forge", text.contains(f.last, ":forge:"), f.why)
T:arm("2b skipped= equals the named skip lines", claimed == nskip, tostring(claimed) .. " vs " .. nskip)
T:arm("2c toolbox is a named skip in a forge", has(f, "skip:join-the-fleet:toolbox:forge"), f.why)
T:arm("2d no host-only step reported as ran", not f.out:find("\nok:join%-the%-fleet:toolbox") and not f.out:find("\nok:join%-the%-fleet:substrate"), f.why)

-- ---- arm 3 ------------------------------------------------------------------
local w = T:scratch()
fs.mkdir(w.rel .. "/scaffold.git/hooks")
local x = check{ JOIN_FLEET_GIT_DIR = w.abs .. "/scaffold.git", JOIN_FLEET_PROBES = "0" }
T:arm("3 a missing pre-push hook is the installer todo, rc != 0", has(x, "todo:join-the-fleet:hooks:scripts/install-hooks.sh") and x.rc ~= 0, x.why)

-- ---- arms 4, 5 (1317-9ugn) on a scratch repo on a work ref --------------------
local g = T:git_repo()
T:must{ "git", "-C", g.abs, "checkout", "-q", "-b", "work/1317-9ugn" }
local function in_scratch(e)
    e = e or {}
    e.JOIN_FLEET_ROOT = g.abs; e.JOIN_FLEET_PROBES = "0"
    return check(e)
end
T:must{ "git", "-C", g.abs, "config", "rerere.enabled", "false" }
local off = in_scratch()
T:must{ "git", "-C", g.abs, "config", "rerere.enabled", "true" }
local on = in_scratch()
T:arm("4a rerere off is the todo naming the config command", has(off, "todo:join-the-fleet:rerere:git config rerere.enabled true"), off.why)
T:arm("4b rerere on is ok", has(on, "ok:join-the-fleet:rerere"), on.why)
T:arm("5a a work ref is noted", has(on, "note:join-the-fleet:branch:work/1317-9ugn"), on.why)
T:arm("5b and is never a branch todo", not on.out:find("\ntodo:join%-the%-fleet:branch:"), on.why)

-- ---- arms 7, 7m, 8 (1255-s4im: the hook git will RUN) -------------------------
local HOOK = "#!/bin/sh\n# tillandsias-pre-push-v9\nexit 0\n"
fs.mkdir(g.rel .. "/.git/hooks"); fs.write(g.rel .. "/.git/hooks/pre-push", HOOK)
fs.mkdir(w.rel .. "/empty-hooks")
T:must{ "git", "-C", g.abs, "config", "core.hooksPath", w.abs .. "/empty-hooks" }
x = in_scratch()
T:arm("7 a hook in .git/hooks under an empty core.hooksPath is a todo, not ok", has(x, "todo:join-the-fleet:hooks:scripts/install-hooks.sh"), x.why)
-- The pre-1255-s4im reading: the checker's hooks dir is always <git-dir>/hooks.
local src = fs.read(CHECKER)
local mut, n = src:gsub('local hp, hrc = git%("rev%-parse", "%-%-path%-format=absolute", "%-%-git%-path", "hooks"%)',
    'local hp, hrc = git("rev-parse", "--absolute-git-dir"); hp = hp .. "/hooks"')
if n ~= 1 then T:refuse("mutation-site-not-found", "the hooks resolution line in " .. CHECKER) end
fs.write(w.rel .. "/check-fleet-membership-pre-1255.lua", mut)
local m = check({ JOIN_FLEET_ROOT = g.abs, JOIN_FLEET_PROBES = "0" }, w.abs .. "/check-fleet-membership-pre-1255.lua")
T:arm("7m MUTATION reading .git/hooks unconditionally says ok here (arm 7 has teeth)", has(m, "ok:join-the-fleet:hooks:tillandsias-pre-push-v9"), m.why)
T:must{ "rm", "-f", g.abs .. "/.git/hooks/pre-push" }
fs.mkdir(w.rel .. "/shared-hooks"); fs.write(w.rel .. "/shared-hooks/pre-push", HOOK)
T:must{ "git", "-C", g.abs, "config", "core.hooksPath", w.abs .. "/shared-hooks" }
x = in_scratch()
T:arm("8 a hook only in a shared core.hooksPath is ok", has(x, "ok:join-the-fleet:hooks:tillandsias-pre-push-v9"), x.why)

-- ---- arm 6: the skill's affordance block is the pre-push hook's, word for word -
local function block(s, from, to)
    local out, inside = {}, false
    for l in ((s:gsub("\r", "")) .. "\n"):gmatch("([^\n]*)\n") do
        if l:find(from, 1, true) then inside = true end
        if inside then out[#out + 1] = l end
        if inside and l:find(to, 1, true) and #out > 1 then break end
    end
    return out
end
local hook_lines, skill_lines = {}, {}
for _, l in ipairs(block(fs.read("scripts/hooks/pre-push-local-gate.sh"), "work_lane_affordance() {", "}")) do
    local t = l:match('^    echo "  (.*)" >&2$')
    if t then hook_lines[#hook_lines + 1] = t end
end
for _, l in ipairs(block(fs.read("skills/join-the-fleet/SKILL.md"), "<!-- affordance:begin -->", "<!-- affordance:end -->")) do
    if not l:find("<!--", 1, true) and not l:find("^ *```") then skill_lines[#skill_lines + 1] = (l:gsub("^  ", "")) end
end
local hj, sj = table.concat(hook_lines, "\n"), table.concat(skill_lines, "\n")
T:arm("6 the skill's §3 affordance is byte-identical to the pre-push hook's", #hook_lines > 0 and hj == sj, "hook:\n" .. hj .. "\nskill:\n" .. sj)

T:finish()
