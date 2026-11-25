-- @env PATH HOME
-- @trace order:1440-w8g8, order:1422-w3p8, order:2328-r8qf
--
-- test-meta-orchestration-opsx-sync-merge.lua — launch-generated opsx dirt is REFUSED, never
-- committed. Ported from the .sh of the same name (2328-r8qf). Order 540 had the cycle commit
-- it; the operator reversed that on 2026-09-27. The name stays: litmus-bindings binds it.
--
--   1 a checkout whose only dirt is the 22 regenerated paths reads launch-dirt:opsx-only, rc 5
--   2 the refused cycle commits nothing, keeps the dirt, and its boundary verifies
--   3 any non-opsx path still fails closed
--   4 the boundary refuses changed startup bytes, and accepts them restored
--   5 the skill wires the checker, and nothing tells an agent to commit those files
--
-- Usage: tillandsias-plan script run scripts/lua/test-meta-orchestration-opsx-sync-merge.lua
-- Verdict: ok:meta-orchestration-opsx-sync-merge:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("meta-orchestration-opsx-sync-merge")
local SH, ROOT, PLAN = fixture.posix_shell(), fixture.repo_root(), fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local repo, b = T:git_repo(), T:scratch("boundary")
local CMDS = { "apply", "archive", "bulk-archive", "continue", "explore", "ff", "new", "onboard", "propose", "sync", "verify" }
local SKILLS = { "apply-change", "archive-change", "bulk-archive-change", "continue-change", "explore", "ff-change", "new-change", "onboard", "propose", "sync-specs", "verify-change" }
local function write(v)
    for _, c in ipairs(CMDS) do fs.write(repo.rel .. "/.opencode/commands/opsx-" .. c .. ".md", "opsx-" .. c .. " " .. v .. "\n") end
    for _, s in ipairs(SKILLS) do fs.write(repo.rel .. "/.opencode/skills/openspec-" .. s .. "/SKILL.md", "openspec-" .. s .. " " .. v .. "\n") end
end
fs.mkdir(repo.rel .. "/.opencode/commands")
for _, s in ipairs(SKILLS) do fs.mkdir(repo.rel .. "/.opencode/skills/openspec-" .. s) end
local function git(...) return T:must{ "git", "-C", repo.abs, ... }.stdout end
local function base(body) fs.write(repo.rel .. "/base.txt", body) end
base("base\n"); write("v1"); git("add", "-A"); git("commit", "-q", "-m", "baseline")
local function check()
    local r = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/check-opsx-generated-dirt.lua", cwd = repo.abs, env_unset = { "TILLANDSIAS_REPO_ROOT", "PROJECT_ROOT" }, timeout_ms = 60000 }
    return text.trim(r.stdout or ""), r.code, "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end
local function guard(verb, n)
    local r = T:run{ SH, ROOT .. "/scripts/meta-orchestration-worktree-guard.sh", verb, b.abs .. "/" .. n, cwd = repo.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local PRESERVED = "ok: startup worktree boundary preserved"

write("v2")
local o, rc, why = check()
T:arm("1 only the 22 regenerated paths dirty is launch-dirt:opsx-only, rc 5", o == "launch-dirt:opsx-only" and rc == 5, why)
local head = git("rev-parse", "HEAD")
guard("snapshot", "1")
local vrc, vo = guard("verify", "1")
local _, dirty = git("status", "--porcelain"):gsub("[^\n]+", "")
T:arm("2 the refused cycle commits nothing and keeps the dirt", vrc == 0 and text.contains(vo, PRESERVED) and git("rev-parse", "HEAD") == head and dirty == 22,
    "rc=" .. tostring(vrc) .. " dirty=" .. dirty .. " " .. vo)
git("checkout", "-q", "--", ".")
base("operator tracked edit\n")
guard("snapshot", "2")
fs.write(b.rel .. "/2/tmp/probe.log", "preflight diagnostic only\n")
vrc, vo = guard("verify", "2")
o, rc, why = check()
T:arm("3 a non-opsx path fails closed, naming it, rc 3", o == "non-opsx:base.txt" and rc == 3, why)
base("tampered during blocked exit\n")
local trc, to = guard("verify", "2")
base("operator tracked edit\n")
local rrc = guard("verify", "2")
T:arm("4 the boundary refuses changed startup bytes and accepts them restored", vrc == 0 and trc ~= 0 and rrc == 0,
    tostring(vrc) .. " " .. tostring(trc) .. " " .. tostring(rrc) .. " " .. to)
local skill = fs.read("skills/meta-orchestration/SKILL.md")
local SELF = "scripts/lua/test-meta-orchestration-opsx-sync-merge.lua"
-- Split, so this file is not its own hit.
local hits = T:run{ "git", "grep", "-n", "-F", "-e", "chore(opsx): sync " .. "generated", "-e", "git add .opencode/commands/" .. "opsx-", "--",
    "skills", "methodology", "methodology.yaml", "scripts", "images", ":!" .. SELF, cwd = ROOT }
T:arm("5 the skill wires the checker and nothing commits launch-generated opsx files", text.contains(skill, "scripts/lua/check-opsx-generated-dirt.lua")
    and text.contains(skill, "launch-dirt:opsx-only") and hits.code == 1 and hits.stdout == "", "rc=" .. tostring(hits.code) .. " " .. (hits.stdout or "") .. (hits.stderr or ""))
T:finish()
