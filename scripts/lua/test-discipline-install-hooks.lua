-- @trace order:1446-xqi6, order:1446-664f, order:1442-wyf9, order:1788-qlwq, order:2356-d66j, spec:branch-discipline
--
-- test-discipline-install-hooks.lua — hook templates embedded in the plan binary, installed
-- on demand per project. Ported from the .sh (2356-d66j).
--
--   1 no seed: the level-0 set goes into a repo-LOCAL core.hooksPath; under a GLOBAL one
--     (the forge image's) a local one is set beside it, named, and nothing is written to
--     the global dir; a push to main is not refused and prints nothing
--   2 raise --to 1: level 1 is read; before an integration branch exists on origin a push
--     to main warns (seed ahead of reality), after it is refused with the affordance;
--     a push to the integration branch passes; raise --to 0 is refused (forward-only)
--   3 level 0 with two committer identities: post-commit advises and refuses nothing
--   4 a project override .tillandsias/hooks/pre-push.lua runs instead
--   5 every stub is under sixty lines, bash-dialect clean, and refuses with
--     blocked:hook:<event>:no-plan-binary when the binary is not runnable
--   6 the forge installs them for a checkout that is NOT Tillandsias, and traces the level
--   7 NEGATIVE: a second install is a no-op; a hook that is not ours is left untouched
-- Every arm runs with PROJECT_ROOT naming THIS checkout, hostile on purpose: a hook that
-- trusted it read this repo's level-2 discipline for the scratch project.
--
-- Verdict: ok:discipline-install-hooks:<n> arms | violation:discipline-install-hooks:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("discipline-install-hooks")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()
fs.mkdir(W.rel .. "/home"); fs.mkdir(W.rel .. "/global-hooks")
fs.write(W.rel .. "/home/.gitconfig", "[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n")
local GLOBAL = W.abs .. "/global-hooks"

local function run(argv, cwd, extra)
    local e = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1", TILLANDSIAS_PLAN_BIN = PLAN, PROJECT_ROOT = ROOT }
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.cwd, argv.env, argv.env_unset = cwd, e, { "TILLANDSIAS_*", "GIT_*", "XDG_CONFIG_HOME", "CARGO_TARGET_DIR" }
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or ""), (r.stdout or "") .. (r.stderr or "")
end
local function git(p, ...)
    local argv = { "git" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return run(argv, p)
end
local function must(p, ...)
    local rc, o, all = git(p, ...)
    if rc ~= 0 then T:refuse("setup-failed", table.concat({ ... }, " ") .. ": " .. all) end
    return o
end
local function plan(p, ...)
    local argv = { PLAN, "discipline" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return run(argv, p)
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function line(o, l) return ("\n" .. o .. "\n"):find("\n" .. l .. "\n", 1, true) ~= nil end
local function flat(rc, o) return "rc=" .. tostring(rc) .. " " .. o:gsub("\n", " | ") end
local function project(name)
    local p = { abs = W.abs .. "/" .. name, rel = W.rel .. "/" .. name }
    must(W.abs, "init", "-q", "--bare", name .. "-remote.git")
    must(W.abs, "init", "-q", name)
    fs.write(p.rel .. "/README", "one\n")
    must(p.abs, "add", "README"); must(p.abs, "commit", "-qm", "one")
    must(p.abs, "remote", "add", "origin", p.abs .. "-remote.git")
    return p
end
local function scope(p) local _, o = git(p.abs, "config", "--show-scope", "--get", "core.hooksPath"); return o:match("^(%S+)\t(.*)$") end

-- 1
local P1 = project("bare")
local rc, o, all = plan(P1.abs, "install-hooks")
T:arm("1 no seed installs the level-0 set into a repo-local core.hooksPath", rc == 0 and o == "ok:discipline:hooks-installed:level=0:3 hooks" and scope(P1) == "local", flat(rc, all))
rc, o, all = git(P1.abs, "push", "origin", "main")
T:arm("1 a push to main at level 0 is not refused and prints no warning", rc == 0 and not has(all, "refused") and not has(all, "advised") and not has(all, "warn") and not has(all, "blocked"), flat(rc, all))
local PG = project("globalpath")
must(W.abs, "config", "--global", "core.hooksPath", GLOBAL)
rc, o, all = plan(PG.abs, "install-hooks")
local s, dir = scope(PG)
must(W.abs, "config", "--global", "--unset", "core.hooksPath")
T:arm("1 under a global core.hooksPath a local one is set and named, nothing written to the global dir", rc == 0 and s == "local"
    and line(o, "set:discipline:install-hooks:local-hooks-path:" .. tostring(dir) .. " (this repo's core.hooksPath now overrides the global one, " .. GLOBAL .. ", which is left untouched)")
    and line(o, "ok:discipline:hooks-installed:level=0:3 hooks") and T:run{ "test", "-x", tostring(dir) .. "/pre-push" }.code == 0
    and #fs.list(W.rel .. "/global-hooks") == 0, flat(rc, all) .. " scope=" .. tostring(s) .. " " .. tostring(dir))

-- 2
rc, o, all = plan(P1.abs, "raise", "--to", "1")
local _, shown = plan(P1.abs, "show", "--json")
local level = shown ~= "" and json.parse(shown).level
T:arm("2 raise --to 1 writes a level-1 seed and installs the level-1 set", rc == 0 and level == 1 and line(o, "ok:discipline:hooks-installed:level=1:5 hooks"), flat(rc, all) .. " level=" .. tostring(level))
local function commit(p, word) fs.write(p.rel .. "/README", fs.read(p.rel .. "/README") .. word .. "\n"); git(p.abs, "commit", "-qam", word) end
commit(P1, "two")
rc, o, all = git(P1.abs, "push", "origin", "main")
T:arm("2 before an integration branch exists on origin, level 1 warns (1446-664f)", rc == 0 and has(all, "warn: refs/heads/main — default-branch-protected:seed-ahead-of-reality"), flat(rc, all))
git(P1.abs, "push", "-q", "origin", "HEAD:develop"); git(P1.abs, "fetch", "-q", "origin")
commit(P1, "three")
rc, o, all = git(P1.abs, "push", "origin", "main")
T:arm("2 a push to main at level 1 is refused with the affordance", rc ~= 0 and line(all, "refused:hook:pre-push:default-branch-protected:enforced")
    and line(all, "this project at level 1 (default_branch enforced) needs pushes on develop; use /project-discipline for instructions"), flat(rc, all))
rc, o, all = git(P1.abs, "push", "-q", "origin", "HEAD:develop")
T:arm("2 a push to the integration branch passes", rc == 0, flat(rc, all))
rc, o, all = plan(P1.abs, "raise", "--to", "0")
T:arm("2 raise --to 0 is refused (forward-only)", rc == 1 and o == "refused:discipline:raise:forward-only:1->0", flat(rc, all))

-- 3, 4
local P3 = project("committers")
plan(P3.abs, "install-hooks")
fs.write(P3.rel .. "/x", "x\n"); must(P3.abs, "add", "x")
rc, o, all = git(P3.abs, "-c", "user.name=someone-else", "-c", "user.email=else@example.invalid", "commit", "-m", "second")
T:arm("3 two committer identities at level 0 advise the raise and refuse nothing", rc == 0 and line(all, "advised:hook:post-commit:multiple-committers")
    and has(all, "use /project-discipline for how to raise to level 1"), flat(rc, all))
fs.mkdir(P3.rel .. "/.tillandsias/hooks")
fs.write(P3.rel .. "/.tillandsias/hooks/pre-push.lua", 'io.stderr:write("OVERRIDE-MARKER-1446\\n")\nreturn "ok:hook:pre-push:override"\n')
rc, o, all = git(P3.abs, "push", "origin", "main")
T:arm("4 .tillandsias/hooks/pre-push.lua runs instead of the embedded template", rc == 0 and line(all, "OVERRIDE-MARKER-1446"), flat(rc, all))

-- 5
local HOOKS = P1.rel .. "/.git/hooks/"
local EVENTS = { "pre-commit", "post-commit", "post-merge", "post-checkout", "pre-push" }
for _, ev in ipairs(EVENTS) do
    local _, n = fs.read(HOOKS .. ev):gsub("\n", "")
    local d = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/check-bash-dialect.lua", cwd = ROOT, env = { TILLANDSIAS_DIALECT_SCAN_DIR = P1.abs .. "/.git/hooks/" .. ev } }
    rc, o = run({ SH, P1.abs .. "/.git/hooks/" .. ev }, P1.abs, { TILLANDSIAS_PLAN_BIN = W.abs .. "/not-runnable" })
    T:arm("5 the " .. ev .. " stub is short, bash-dialect clean, and refuses without a plan binary", n < 60 and text.trim(d.stdout or "") == "ok:bash-dialect-clean"
        and rc == 1 and o == "blocked:hook:" .. ev .. ":no-plan-binary", "lines=" .. n .. " dialect=" .. tostring(d.stdout) .. " " .. flat(rc, o))
end

-- 6: the forge's functions, extracted from lib-common.sh.
local fns = { 'trace_lifecycle() { printf "%s %s\\n" "$1" "$2"; }' }
for _, name in ipairs{ "install_project_guard_hooks", "install_project_discipline_hooks" } do
    local p = false
    for l in (fs.read("images/default/lib-common.sh") .. "\n"):gmatch("([^\n]*)\n") do
        if l:sub(1, #name + 2) == name .. "()" then p = true end
        if p then fns[#fns + 1] = l end
        if p and l == "}" then break end
    end
    if not p then T:refuse("no-subject", name .. " not found in images/default/lib-common.sh") end
end
local P6 = project("forgeproject")
fs.write(W.rel .. "/forge.sh", table.concat(fns, "\n") .. '\ninstall_project_guard_hooks "$1"\n')
rc, o, all = run({ SH, W.abs .. "/forge.sh", P6.abs }, P6.abs)
local pp = P6.rel .. "/.git/hooks/pre-push"
T:arm("6 the forge installs discipline hooks for a non-Tillandsias checkout and traces the level", fs.exists(pp) and T:run{ "test", "-x", P6.abs .. "/.git/hooks/pre-push" }.code == 0
    and has(fs.read(pp), "tillandsias-discipline-hook v1") and has(all, "discipline hooks installed: level=0:3 hooks"), flat(rc, all))

-- 7
local function bytes() local t = {}; for _, ev in ipairs(EVENTS) do t[#t + 1] = fs.read(HOOKS .. ev) end; return table.concat(t) end
local before = bytes()
rc, o, all = plan(P1.abs, "install-hooks")
T:arm("7 NEGATIVE a second install is a no-op", bytes() == before and has(all, "0 written this run"), flat(rc, all))
local P7 = project("tillandsias-like")
local GATE = "#!/usr/bin/env bash\n# tillandsias-pre-push-v9\nexit 0\n"
fs.mkdir(P7.rel .. "/.git/hooks")
fs.write(W.rel .. "/gate", GATE)
T:must{ "cp", W.abs .. "/gate", P7.abs .. "/.git/hooks/pre-push" }
T:must{ "chmod", "+x", P7.abs .. "/.git/hooks/pre-push" }
rc, o, all = plan(P7.abs, "install-hooks")
T:arm("7 NEGATIVE a pre-push that is not ours is left untouched", fs.read(P7.rel .. "/.git/hooks/pre-push") == GATE
    and ("\n" .. all):find("\nskip:discipline:hook-not-ours:pre-push", 1, true), flat(rc, all))
T:finish()
