-- @env PATH HOME
-- @trace spec:meta-orchestration, order:2362-2cfp
--
-- test-check-opsx-generated-dirt.lua — check-opsx-generated-dirt.lua tells the dirt openspec's own
-- update writes at launch from anybody's edit. Ported from the .sh of the same name (2362-2cfp).
-- A scratch repository with the eleven generated commands and skills of each locus.
--
--   1 .opencode dirt alone: launch-dirt, rc 5   2 .claude dirt alone   3 both
--   4 a real edit beside generated dirt: named, rc 3   5 a tracked edit alone
--   6 an untracked file                         7 a clean tree: rc 0
--   8 a file under a generated directory that openspec does not write is not excused
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-opsx-generated-dirt.lua
-- Verdict: ok:check-opsx-generated-dirt:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-opsx-generated-dirt")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local d = T:git_repo()
local function git(...) return T:must{ "git", "-C", d.abs, ... } end
fs.write(d.rel .. "/base.txt", "base\n")
local CMDS = { "apply", "archive", "bulk-archive", "continue", "explore", "ff", "new", "onboard", "propose", "sync", "verify" }
local SKILLS = { "apply-change", "archive-change", "bulk-archive-change", "continue-change", "explore", "ff-change", "new-change", "onboard", "propose", "sync-specs", "verify-change" }
local function generated(locus, v)
    local opencode = locus == ".opencode"
    fs.mkdir(d.rel .. "/" .. locus .. "/commands" .. (opencode and "" or "/opsx"))
    for _, c in ipairs(CMDS) do fs.write(d.rel .. "/" .. locus .. "/commands/" .. (opencode and "opsx-" or "opsx/") .. c .. ".md", c .. " " .. v .. "\n") end
    for _, s in ipairs(SKILLS) do
        fs.mkdir(d.rel .. "/" .. locus .. "/skills/openspec-" .. s)
        fs.write(d.rel .. "/" .. locus .. "/skills/openspec-" .. s .. "/SKILL.md", s .. " " .. v .. "\n")
    end
end
local function commit(m) git("add", "-A"); git("commit", "-qm", m) end
local function clean() git("checkout", "-q", "--", "."); git("clean", "-fdq") end
local function arm(name, verdict, code)
    local r = proc.run{ argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/check-opsx-generated-dirt.lua" }, cwd = d.abs, timeout_ms = 30000,
        env_unset = { "TILLANDSIAS_*", "PROJECT_ROOT" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") } }
    T:arm(name, r.code == code and text.trim(r.stdout or "") == verdict, "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or ""))
end
local ONLY = "launch-dirt:opsx-only"
generated(".opencode", "v1"); commit("opencode")
generated(".opencode", "v2")
arm("1 only .opencode's generated files: launch dirt", ONLY, 5)
clean(); generated(".claude", "v1"); commit("claude")
generated(".claude", "v2")
arm("2 only .claude's", ONLY, 5)
generated(".opencode", "v3")
arm("3 both", ONLY, 5)
fs.write(d.rel .. "/base.txt", "real operator edit\n")
arm("4 a real edit beside generated dirt is named", "non-opsx:base.txt", 3)
clean(); fs.write(d.rel .. "/base.txt", "real operator edit\n")
arm("5 a tracked edit alone", "non-opsx:base.txt", 3)
clean(); fs.mkdir(d.rel .. "/plan/issues"); fs.write(d.rel .. "/plan/issues/operator-scratch.md", "scratch\n")
arm("6 an untracked file", "non-opsx:plan/issues/operator-scratch.md", 3)
clean()
arm("7 a clean tree", "ok:clean-tree", 0)
fs.write(d.rel .. "/.opencode/commands/mine.md", "v1\n"); commit("mine")
fs.write(d.rel .. "/.opencode/commands/mine.md", "v2\n"); generated(".opencode", "v4")
arm("8 a command that is not generated, in a generated directory", "non-opsx:.opencode/commands/mine.md", 3)
T:finish()
