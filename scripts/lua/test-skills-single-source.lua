-- @trace spec:methodology-accountability, order:631-wpkd, order:1238-u84w, order:1255-rvr7, order:1256-f7td, order:1247-amcu, order:2385-psbb
-- @env PATH HOME
--
-- test-skills-single-source.lua — fixture for scripts/check-skills-single-source.sh (order
-- 631-wpkd). Ported from test-skills-single-source.sh (2385-psbb); same fifteen arms.
--
-- The layout rule was CLAIMED in prose and false for months, so both drift directions get a
-- negative control (a real directory where a symlink belongs; a canonical skill a runtime cannot
-- see), and so does the declared-exception path (an allowlist that swallows everything is how a
-- check stops checking). Each case edits ONE scratch repo's INDEX in sequence, as the .sh does:
-- the check reads git's index, not the filesystem. Links are real symlinks where the host makes
-- them, else the placeholder git writes (`ln -s` exit status is not the test: MSYS returns 0
-- and copies). Arm 13 reads build.sh's skills-step refusal text with comments stripped; build.sh
-- is read, never run.
--
--   1  a fully symlinked layout passes
--   2  NEGATIVE a real directory where a symlink belongs is caught and named
--   3  a declared exception (HARNESS-SCOPED.txt) is accepted
--   4  NEGATIVE a canonical skill missing from a runtime is named, with why + link remedy (1247-amcu)
--   5  the committed shape wins over what the filesystem materialized (Windows)
--   6  a runtime linked as ONE directory symlink passes (1238-u84w)
--   6m a lone per-skill link is still held to Direction 2
--   7  a declared runtime with no tracked skills tree is refused by name (1255-rvr7 population)
--   7b the refusal names the declaration that governs the run (SKILLS_CHECK_RUNTIMES)
--   8  an absolute link target is refused (hole D)      9  a link leaving skills/ is refused (hole B)
--   10 a dangling link is refused (hole C)
--   11 a genuine second source is still refused after the widening
--   12 per-skill links are resolved too (found by mutation)
--   13 build.sh's skills refusal does not offer HARNESS-SCOPED for a link-shape mismatch (1256-f7td)
--
-- GRAMMAR ok:skills-single-source-fixture:<n> arms | violation:skills-single-source-fixture:<n>-failed
--       | refused:skills-single-source-fixture:<reason>
-- (named -fixture: the checker itself prints ok:skills-single-source:<runtimes>:<canonical>.)

local fixture = require "common.fixture"
local T = fixture.new("skills-single-source-fixture")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local CHECK = ROOT .. "/scripts/check-skills-single-source.sh"
if not fs.exists("scripts/check-skills-single-source.sh") then T:refuse("checker-missing", CHECK) end

local W = T:scratch()
local function g(...)
    local argv = { "git", "-C", W.abs }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    return T:run(argv)
end
local function gm(...)
    local r = g(...)
    if r.code ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr)) end
    return r
end
local function put(p, body)
    T:must{ "mkdir", "-p", (W.abs .. "/" .. p):match("^(.*)/[^/]*$") }
    fs.write(W.rel .. "/" .. p, body)
end
local function rmrf(p) T:must{ "rm", "-rf", W.abs .. "/" .. p } end
local function blob(target)
    local r = T:run{ "git", "-C", W.abs, "hash-object", "-w", "--stdin", stdin = target }
    return text.trim(r.stdout or "")
end
local function index_link(path, target)
    gm("update-index", "--add", "--cacheinfo", "120000," .. blob(target) .. "," .. path)
end
local function uncache(p) g("rm", "-q", "--cached", p) end

gm("init", "-q", "-b", "main")
gm("config", "user.email", "fixture@example.invalid")
gm("config", "user.name", "Fixture")
gm("config", "commit.gpgsign", "false")
put("skills/alpha/SKILL.md", "# alpha\n")
put("skills/beta/SKILL.md", "# beta\n")
T:must{ "mkdir", "-p", W.abs .. "/.harnessA/skills", W.abs .. "/.harnessB/skills" }
put("skills/HARNESS-SCOPED.txt", "generated-*\n")
gm("add", "-A"); gm("commit", "-qm", "base")

-- A REAL symlink where the platform allows one, else git's placeholder file at mode 120000.
local function link(rt, s)
    local p = rt .. "/skills/" .. s
    T:must{ "mkdir", "-p", W.abs .. "/" .. rt .. "/skills" }
    rmrf(p)
    T:run{ "ln", "-s", "../../skills/" .. s, W.abs .. "/" .. p }
    if T:run{ "test", "-L", W.abs .. "/" .. p }.code == 0 then
        gm("update-index", "--add", p)
    else
        rmrf(p)
        fs.write(W.rel .. "/" .. p, "../../skills/" .. s)
        index_link(p, "../../skills/" .. s)
    end
end

local function run(runtimes)
    local r = T:run{ SH, CHECK, cwd = W.abs, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" },
        env = { SKILLS_CHECK_ROOT = W.abs, SKILLS_CHECK_RUNTIMES = runtimes or ".harnessA .harnessB" } }
    return text.trim(r.stdout or ""), r.code, r.stderr or ""
end
local function starts(s, p) return s:sub(1, #p) == p end
local OK22 = "ok:skills-single-source:2:2"

-- 1
for _, d in ipairs{ ".harnessA", ".harnessB" } do for _, s in ipairs{ "alpha", "beta" } do link(d, s) end end
local o, rc, err = run()
T:arm("1 fully symlinked layout passes", o == OK22, o)

-- 2: the shape the 2026-08-09 audit found thirteen of. update-index, never `git add`: add
-- behaves differently with and without host symlink support (Git Bash vs WSL).
put(".harnessA/skills/rogue/SKILL.md", "# rogue\n")
gm("update-index", "--add", ".harnessA/skills/rogue/SKILL.md")
o, rc = run()
T:arm("2 a real directory where a symlink belongs is caught and named",
    rc ~= 0 and o == "violation:second-source:.harnessA/skills/rogue", "rc=" .. tostring(rc) .. " " .. o)

-- 3: harness-specific is allowed; UNDOCUMENTED divergence is not.
put("skills/HARNESS-SCOPED.txt", "generated-*\nrogue\n")
gm("add", "-A")
o = run()
T:arm("3 a declared exception is accepted", o == OK22, o)

-- 4: the defect still live on 2026-08-13 (multihost-orchestration linked from one runtime of five).
uncache(".harnessB/skills/beta")
o, rc, err = run()
local remedy = err:find("why: skills/beta is canonical", 1, true)
remedy = remedy and err:find("remedy: link it (ln -s ../../skills/beta .harnessB/skills/beta", remedy, true)
T:arm("4 a canonical skill missing from a runtime is caught and named, with its remedy",
    rc ~= 0 and o == "violation:missing-from-runtime:.harnessB/skills/beta" and remedy ~= nil,
    "rc=" .. tostring(rc) .. " " .. o .. " stderr=" .. err)

-- 5: a checkout without symlink support materializes links as real directories.
link(".harnessB", "beta")
rmrf(".harnessB/skills/beta")
put(".harnessB/skills/beta/SKILL.md", "# materialized as a real dir, as Windows does\n")
o = run()
T:arm("5 committed shape wins over what the filesystem materialized", o == OK22, o)

-- 6: 51db2c14c collapsed .gemini/skills to one directory symlink; git tracks nothing beneath it.
uncache(".harnessB/skills/alpha"); uncache(".harnessB/skills/beta")
rmrf(".harnessB/skills")
index_link(".harnessB/skills", "../skills")
o = run()
T:arm("6 a runtime linked as ONE directory symlink passes", o == OK22, o)

-- 6m: the discriminator is the tracked PATH, not "exactly one tracked symlink".
uncache(".harnessB/skills")
link(".harnessB", "alpha")
o, rc = run()
T:arm("6m a lone per-skill link is still held to Direction 2",
    rc ~= 0 and o == "violation:missing-from-runtime:.harnessB/skills/beta", "rc=" .. tostring(rc) .. " " .. o)

-- 7: measured pre-fix: a population of ZERO read ok:skills-single-source:0:18.
o, rc = run(".harnessA .nonexistent-runtime")
T:arm("7 a declared runtime with no tracked skills tree is refused by name",
    rc ~= 0 and starts(o, "violation:runtime-missing:.nonexistent-runtime/skills"), "rc=" .. tostring(rc) .. " " .. o)
T:arm("7b the refusal names the declaration that governs this run",
    o:find("declared in SKILLS_CHECK_RUNTIMES", 1, true) ~= nil, o)

-- 8: read from the INDEX so the verdict does not depend on whether it resolves HERE.
uncache(".harnessB/skills"); uncache(".harnessB/skills/alpha")
index_link(".harnessB/skills", "/home/someone/skills")
o, rc = run()
T:arm("8 an absolute link target is refused (hole D)",
    rc ~= 0 and starts(o, "violation:absolute-link-target:.harnessB/skills"), "rc=" .. tostring(rc) .. " " .. o)

-- 9
uncache(".harnessB/skills")
index_link(".harnessB/skills", "../other-tree")
o, rc = run()
T:arm("9 a link that leaves canonical skills/ is refused (hole B)",
    rc ~= 0 and starts(o, "violation:link-leaves-canonical:.harnessB/skills"), "rc=" .. tostring(rc) .. " " .. o)

-- 10
uncache(".harnessB/skills")
index_link(".harnessB/skills", "../skills/does-not-exist")
o, rc = run()
T:arm("10 a dangling link is refused (hole C)",
    rc ~= 0 and starts(o, "violation:dangling-link:.harnessB/skills"), "rc=" .. tostring(rc) .. " " .. o)

-- 11: the original invariant re-asserted after all the widening.
uncache(".harnessB/skills")
index_link(".harnessB/skills", "../skills")
put(".harnessA/skills/gamma/SKILL.md", "# a genuine second source\n")
g("add", "-f", ".harnessA/skills/gamma/SKILL.md")
o, rc = run()
T:arm("11 a genuine second source is still refused after the widening",
    rc ~= 0 and starts(o, "violation:second-source:.harnessA/skills/gamma"), "rc=" .. tostring(rc) .. " " .. o)

-- 12: cases 8-10 all plant a DIRECTORY link; deleting per-skill resolution left them green.
uncache(".harnessB/skills"); uncache(".harnessA/skills/gamma/SKILL.md")
rmrf(".harnessA/skills/gamma")
for _, s in ipairs{ "alpha", "beta" } do link(".harnessB", s) end
uncache(".harnessB/skills/alpha")
index_link(".harnessB/skills/alpha", "/somewhere/else/alpha")
o, rc = run()
T:arm("12 per-skill links are resolved too, not only the directory link",
    rc ~= 0 and starts(o, "violation:absolute-link-target:.harnessB/skills/alpha"), "rc=" .. tostring(rc) .. " " .. o)

-- 13: comments STRIPPED (the explanation beside the fix quotes the phrase it forbids). PRE-FIX
-- the refusal read "declare it in skills/HARNESS-SCOPED.txt or link it (631-wpkd)".
local skills_err, on = nil, false
for l in (fs.read("build.sh") .. "\n"):gmatch("([^\n]*)\n") do
    local cut = l:find("%s#")
    if cut then l = l:sub(1, cut - 1) end
    if not l:find("^%s*#") then
        if l:find("Checking skills have exactly one source of truth", 1, true) then on = true end
        if on and l:find("_error ", 1, true) then skills_err = l; break end
    end
end
T:arm("13 the gate's refusal does not offer HARNESS-SCOPED for a link-shape mismatch",
    skills_err ~= nil and not skills_err:find("declare it in skills/HARNESS-SCOPED", 1, true)
        and skills_err:find("LINK", 1, true) ~= nil,
    skills_err or "could not find the skills-step _error in build.sh (the fixture must not pass blind)")

T:finish()
