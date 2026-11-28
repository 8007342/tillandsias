-- @env PATH
-- @trace order:1063-363b, order:2188-qaaj, order:2384-5fj5
--
-- test-tracked-files-unwritten-guard.lua — scripts/lua/check-tracked-files-unwritten.lua, run in a scratch
-- repo: lenovinha's exact corruption (plan-binary-probe.sh overwritten with check-fragment-status-loss.sh) is
-- named; so is a content change, a path with spaces, a deleted path and a retargeted directory symlink. A
-- missing baseline blocks; an untracked file is not a write. Each main assertion has a mutant.
-- Ported from scripts/test-tracked-files-unwritten-guard.sh.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tracked-files-unwritten-guard.lua
-- Verdict: ok:tracked-files-unwritten-guard:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("tracked-files-unwritten-guard")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local GUARD = "scripts/lua/check-tracked-files-unwritten.lua"
if PLAN == "" then T:refuse("no-plan-binary") end
local src = fs.read(GUARD):gsub("\r\n", "\n")
local R = T:git_repo()
local S = T:scratch("state")
fs.mkdir(R.rel .. "/scripts")
fs.write(R.rel .. "/scripts/plan-binary-probe.sh", "probe contents\n")
fs.write(R.rel .. "/scripts/check-fragment-status-loss.sh", "status loss contents\n")
fs.write(R.rel .. "/a file with spaces.txt", "a tracked file\n")
local function sh(script) return T:must{ SH, "-s", cwd = R.abs, stdin = script, env = { PATH = env.get("PATH") }, env_unset = { "GIT_*" } } end
-- core.autocrlf off: a checkout that rewrote line endings would itself read as a write.
sh("git config core.autocrlf false && git add -A && git commit -q -m base\n")

-- The guard, or a mutant of it, from inside the scratch repo.
local function guard(mode, o)
    o = o or {}
    local script = ROOT .. "/" .. GUARD
    if o.body then fs.write(S.rel .. "/mutant.lua", o.body); script = S.abs .. "/mutant.lua" end
    local r = T:run{ PLAN, "script", "run", script, "--", mode, o.state or (S.abs .. "/state"), R.abs, cwd = ROOT, env_unset = { "GIT_*" } }
    local line = text.trim((r.stdout or ""):gsub("\r", ""))
    return { code = r.code, line = line, err = (r.stderr or ""):gsub("\r", ""), got = "rc=" .. tostring(r.code) .. " " .. line .. " " .. (r.stderr or ""):sub(1, 300) }
end
local function snap(o) return guard("snapshot", o) end
local function verify(o) return guard("verify", o) end
local function names(x, p) return text.contains(x.err, "\n    " .. p) or text.contains(x.err, "\n    " .. p .. "  (gone)") end

local x = snap()
T:arm("0 the snapshot succeeds on a clean tree", x.code == 0 and x.line:find("^ok:tracked%-files%-unwritten:%d+ files$") ~= nil, x.got)
x = verify()
T:arm("1 CONTROL an untouched tree verifies clean", x.code == 0, x.got)
fs.write(R.rel .. "/scripts/plan-binary-probe.sh", "status loss contents\n")
x = verify()
T:arm("2 an instrument overwritten mid-run is named", x.code == 1 and x.line == "violation:gate-wrote-tracked-files:1" and names(x, "scripts/plan-binary-probe.sh"), x.got)
sh("git checkout -- scripts/plan-binary-probe.sh\n")
fs.write(R.rel .. "/scripts/plan-binary-probe.sh", "probe contents modified\n")
x = verify()
T:arm("3 a content change is caught", x.code == 1, x.got)
sh("git checkout -- scripts/plan-binary-probe.sh\n")
fs.write(R.rel .. "/a file with spaces.txt", "overwritten\n")
x = verify()
T:arm("4 a path with spaces is compared and named", x.code == 1 and names(x, "a file with spaces.txt"), x.got)
sh("git checkout -- 'a file with spaces.txt'\nrm -f scripts/check-fragment-status-loss.sh\n")
x = verify()
T:arm("5 a deleted tracked path is named", x.code == 1 and text.contains(x.err, "scripts/check-fragment-status-loss.sh  (gone)"), x.got)
sh("git checkout -- scripts/check-fragment-status-loss.sh\n")
x = verify{ state = S.abs .. "/no-such-state" }
T:arm("6 a missing baseline blocks, never reads clean", x.code == 2 and x.line:find("^blocked:tracked%-files%-unwritten:no%-snapshot%-at:") ~= nil, x.got)
snap()
fs.write(R.rel .. "/untracked-scratch.txt", "scratch\n")
x = verify()
T:arm("7 CONTROL an untracked scratch file is not a write", x.code == 0, x.got)
sh("rm -f untracked-scratch.txt\n")

-- A tracked symlink to a directory, then retargeted. Where git checks out no symlinks the link is a file holding
-- its target, and the arm is the same comparison.
local link = sh([[mkdir -p skills-a/x skills-b/x .claude/skills
printf 'a\n' > skills-a/x/SKILL.md; printf 'b\n' > skills-b/x/SKILL.md
ln -s ../../skills-a/x .claude/skills/x 2>/dev/null
if [ -L .claude/skills/x ]; then echo link; git add -A; else
    # What git itself checks out under core.symlinks=false: a file holding the target, indexed as a link.
    rm -rf .claude/skills/x; printf '../../skills-a/x' > .claude/skills/x; echo file
    git add skills-a skills-b && git update-index --add --cacheinfo "120000,$(git hash-object -w .claude/skills/x),.claude/skills/x"
fi
git ls-files -s .claude/skills/x | cut -c1-6
git commit -q -m symlinks
]])
local real = text.contains(link.stdout or "", "link")
x = snap()
T:arm("8 a tracked " .. (real and "symlink to a directory" or "link checked out as a file") .. " is in the baseline", x.code == 0
    and text.contains(link.stdout or "", "120000"), x.got .. " " .. (link.stdout or ""))
sh(real and "rm .claude/skills/x && ln -s ../../skills-b/x .claude/skills/x\n" or "printf '../../skills-b/x' > .claude/skills/x\n")
x = verify()
T:arm("8 retargeting it is named", x.code == 1 and names(x, ".claude/skills/x"), x.got)
sh("git checkout -- .claude/skills/x\n")

-- An unreadable tracked file refuses the snapshot rather than dropping out of it. chmod cannot make a file
-- unreadable to its owner on Windows, nor to root anywhere.
local unread = sh("chmod 000 skills-a/x/SKILL.md; if cat skills-a/x/SKILL.md >/dev/null 2>&1; then echo readable; fi\n")
if text.contains(unread.stdout or "", "readable") then
    out.line("skip: 10 an unreadable file cannot be made here")
else
    x = snap()
    T:arm("10 an unreadable tracked path refuses the snapshot", x.code == 2 and x.line:find("^blocked:tracked%-files%-unwritten:unhashable:") ~= nil, x.got)
end
sh("chmod 644 skills-a/x/SKILL.md\n")

-- MUTATION
local function mutant(from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return src:sub(1, a - 1) .. to .. src:sub(b + 1)
end
local BLIND = mutant("for p, x in pairs(before) do if now[p] ~= x then", "for p, x in pairs(before) do if now[p] and now[p] ~= x then")
snap()
sh("rm -f scripts/check-fragment-status-loss.sh\n")
x = verify{ body = BLIND }
T:arm("9 MUTATION a guard that skips paths that are gone fails arm 5", x.code == 0, x.got)
sh("git checkout -- scripts/check-fragment-status-loss.sh\n")
x = verify{ state = S.abs .. "/no-such-state", body = mutant('if base == "" then', 'if false then') }
T:arm("9 MUTATION a guard that reads no baseline as clean fails arm 6", x.code == 0, x.got)
local NOLINKS = mutant('if m == "120000" then links[#links + 1] = p elseif', "if m == \"120000\" then n = n - 1 elseif")
x = snap{ body = NOLINKS }
T:arm("9 PREMISE the mutant snapshots", x.code == 0, x.got)
sh(real and "rm .claude/skills/x && ln -s ../../skills-b/x .claude/skills/x\n" or "printf '../../skills-b/x' > .claude/skills/x\n")
x = verify{ body = NOLINKS }
T:arm("9 MUTATION a guard that drops tracked links fails arm 8", x.code == 0, x.got)
sh("git checkout -- .claude/skills/x\n")

T:finish()
