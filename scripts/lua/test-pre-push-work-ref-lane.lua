-- @trace order:1315-4a7j, order:2195-wlsh, order:874-w2gc, order:2400-prg4, spec:ci-release
-- @env PATH HOME
--
-- test-pre-push-work-ref-lane.lua — the work/<order> lane of pre-push-local-gate.sh.
-- Ported from test-pre-push-work-ref-lane.sh (2400-prg4); same arms, in its order.
--
-- The defect this closes was a contradiction across three documents: the hook demanded a
-- stamp for a work ref, the methodology exempted it, and creation_regex admitted no work/
-- ref at all. Measured consequence: 92 salvage/* refs against 34 work/*, hosts using the
-- rescue lane as their everyday branch. PHASE 1 IS MIGRATION: nothing new refuses, the
-- deciders WARN on a work push, and ARM 2 keeps the linux-next gate unchanged.
--
--   CONTROL  the hook runs in a scratch world whose HEAD is not this checkout's
--   ARM 0    a salvage-only DELETION is REFUSED naming 874-w2gc (not the work lane)
--   ARM 0b   CONTROL: the same deletion with TILLANDSIAS_SALVAGE_DELETE_OK=1 is accepted
--   ARM 1    a stampless work push is accepted and carries the affordance
--   ARM 2    the same stampless commit is still refused to linux-next
--   ARM 3    the land tool's race refusal carries the affordance
--   ARM 4    creation_regex admits work/ by the packet-id grammar only
--   ARM 5    the provenance classifier counts a scaffold history correctly
--
-- THE SCRATCH WORLD (2195-wlsh). The .sh built it as a `git worktree` of this checkout;
-- the port uses a --shared clone under kit scratch instead, so the checkout's worktree
-- list is never touched. The clone sits on trunk (this checkout's origin/linux-next, else
-- HEAD) plus ONE empty commit of its own, with refs/remotes/origin/linux-next set to that
-- trunk as a worktree would have seen it, and this tree's scripts/ overlaid uncommitted:
-- the hook and deciders under test are this tree's, the commits judged are not. The
-- clone's origin is this checkout's path (a local read), never the network.
--
-- The hook gets the gate's env (TILLANDSIAS_* kept, as the .sh's child inherited it),
-- minus TILLANDSIAS_SALVAGE_DELETE_OK outside arm 0b. It never re-enters build.sh.
--
-- GRAMMAR ok:work-ref-lane:<n> arms | violation:work-ref-lane:<n>-failed
--       | skip:work-ref-lane:no-hook | refused:work-ref-lane:<reason>

local fixture = require "common.fixture"
local T = fixture.new("work-ref-lane")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
if not fs.exists("scripts/hooks/pre-push-local-gate.sh") then T:skip("no-hook") end
local GITUNSET = { "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX" }
local function git(dir, ...)
    local argv = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }
    argv.env_unset, argv.timeout_ms = GITUNSET, 300000
    return T:run(argv)
end
local function gitm(dir, ...)
    local r = git(dir, ...)
    if r.code ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr or r.why)) end
    return text.trim(r.stdout or "")
end

local W = T:scratch()
local WT = W.abs .. "/wt"
local base = text.trim(git(ROOT, "rev-parse", "--verify", "--quiet", "origin/linux-next^{commit}").stdout or "")
if base == "" then base = gitm(ROOT, "rev-parse", "HEAD") end
T:must{ "git", "clone", "-q", "--shared", "--no-checkout", ROOT, WT, env_unset = GITUNSET, timeout_ms = 300000 }
gitm(WT, "checkout", "-q", "--detach", base)
gitm(WT, "update-ref", "refs/remotes/origin/linux-next", base)
T:must{ "cp", "-a", ROOT .. "/scripts/.", WT .. "/scripts/" }
local sc = gitm(WT, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "scratch: 2195-wlsh")
gitm(WT, "update-ref", "--no-deref", "HEAD", sc)
local HOOK = WT .. "/scripts/hooks/pre-push-local-gate.sh"
local SHA = gitm(WT, "rev-parse", "HEAD")
local ZERO = string.rep("0", 40)
local REMOTE = "file://" .. W.abs .. "/scaffold.git"

-- CONTROL
local top = gitm(WT, "rev-parse", "--show-toplevel")
T:arm("CONTROL: the hook runs in a scratch world whose HEAD is not this checkout's",
    SHA ~= gitm(ROOT, "rev-parse", "HEAD") and top ~= ROOT, "sha=" .. SHA .. " top=" .. top)

local HOOK_UNSET = { "TILLANDSIAS_SALVAGE_DELETE_OK" }
for _, k in ipairs(GITUNSET) do HOOK_UNSET[#HOOK_UNSET + 1] = k end
local function run_hook_line(lsha, rref, rsha, env)
    local r = T:run{ SH, HOOK, "origin", REMOTE, cwd = WT, env = env, env_unset = HOOK_UNSET, timeout_ms = 300000,
        stdin = "refs/heads/x " .. lsha .. " " .. rref .. " " .. rsha .. "\n" }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function run_hook(rref) return run_hook_line(SHA, rref, ZERO) end

-- ARM 0: the deletion is the one salvage shape whose correct answer is a refusal.
local rc0, a0 = run_hook_line(ZERO, "refs/heads/salvage/yoga/20260921-probe", SHA)
T:arm("ARM 0 (regression): a salvage-only DELETION push is REFUSED naming 874-w2gc",
    text.contains(a0, "874-w2gc") and rc0 ~= 0 and rc0 ~= nil,
    "rc=" .. tostring(rc0) .. (text.contains(a0, "warn:pre-push:") and " (took the WORK LANE and warned)" or "") .. ": " .. a0:sub(1, 300))
-- ARM 0b
local rc0b, a0b = run_hook_line(ZERO, "refs/heads/salvage/yoga/20260921-probe", SHA, { TILLANDSIAS_SALVAGE_DELETE_OK = "1" })
T:arm("ARM 0b (control): the same deletion with TILLANDSIAS_SALVAGE_DELETE_OK=1 is accepted", rc0b == 0,
    "rc=" .. tostring(rc0b) .. ": " .. a0b:sub(1, 300))

-- ARM 1
local rc1, a1 = run_hook("refs/heads/work/1315-4a7j")
T:arm("ARM 1: a work push with no stamp is ACCEPTED and carries the affordance",
    rc1 == 0 and text.contains(a1, "prefer work branches"), "rc=" .. tostring(rc1) .. ": " .. a1:sub(1, 400))

-- ARM 2
local rc2, a2 = run_hook("refs/heads/linux-next")
T:arm("ARM 2: the same stampless commit is still REFUSED to linux-next — the integration gate is untouched",
    rc2 ~= 0 and rc2 ~= nil, "rc=" .. tostring(rc2) .. ": " .. a2:sub(1, 300))

-- ARM 3: within 16 lines after 'attempts-exhausted' in the land tool.
local land = fs.read("scripts/land-on-platform-branch.sh")
local found = false
if land then
    local L = text.lines(land)
    for i, l in ipairs(L) do
        if text.contains(l, "attempts-exhausted") then
            for j = i, math.min(#L, i + 16) do if text.contains(L[j], "prefer work branches") then found = true end end
        end
    end
end
T:arm("ARM 3: the trunk-race refusal carries the affordance naming work/<order>", land ~= nil and found,
    land and "no 'prefer work branches' within 16 lines of attempts-exhausted" or "land tool absent")

-- ARM 4
local md = fs.read("methodology/multi-host-development.yaml") or ""
local rx
for _, l in ipairs(text.lines(md)) do
    if text.contains(l, "^refs/heads/(main") then rx = l:gsub("^%s+", ""); break end
end
T:arm("ARM 4: creation_regex admits work/<order> by the PACKET-ID grammar",
    rx ~= nil and text.contains(rx, "work/") and rx:find("work/%[0%-9%]{%d,%d}%-%[a%-z0%-9%]{4}") ~= nil,
    rx or "creation_regex not found")

-- ARM 5
local PROV = "scripts/lua/check-landing-provenance.lua"
if not fs.exists(PROV) then
    T:arm("ARM 5: the provenance classifier is present", false, PROV .. " absent")
else
    local S = W.abs .. "/scaffold"
    T:must{ "git", "init", "-q", S, env_unset = GITUNSET }
    fs.mkdir(W.rel .. "/scaffold/plan/index.d"); fs.mkdir(W.rel .. "/scaffold/scripts")
    for _, c in ipairs{ { "plan/index.d/f.yaml", "a", "plan(x): a fragment" },
            { "scripts/s.sh", "b", "Merge pull request #1 from work/1234-abcd" },
            { "scripts/t.sh", "c", "relay(osx-next): plan-only" },
            { "scripts/u.sh", "d", "fix(9999-zzzz): a direct push" } } do
        fs.write(W.rel .. "/scaffold/" .. c[1], c[2] .. "\n")
        gitm(S, "add", "-A"); gitm(S, "commit", "-q", "-m", c[3])
    end
    local PLAN = fixture.plan_binary()
    if PLAN ~= "" and not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
    local r = T:run{ PLAN, "script", "run", PROV, "--", "50.years", cwd = ROOT,
        env = { TILLANDSIAS_PROVENANCE_REPO = S, TILLANDSIAS_PROVENANCE_REF = "HEAD" }, timeout_ms = 120000 }
    local line = text.lines(r.stdout or "")[1] or ""
    T:arm("ARM 5: the classifier counts one of each correctly",
        text.contains(line, "queue=1") and text.contains(line, "plan=1") and text.contains(line, "relay=1")
            and text.contains(line, "direct=1"), line ~= "" and line or "<nothing>")
end

T:finish()
