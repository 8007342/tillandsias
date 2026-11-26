-- @env PATH
-- @trace spec:git-mirror-service, order:2287-mg7v
--
-- test-git-mirror-stale-reconcile.lua — regression pin for order 449, ported from
-- the .sh of the same name (2287-mg7v): a host coordinator pushing DIRECT to origin
-- must not strand forge agents on a stale mirror. Reproduces the stranding, then
-- proves images/git/reconcile-exported-heads.sh (the SAME file the entrypoint's
-- periodic loop runs) heals it without clobbering a mirror head that carries
-- un-relayed agent commits. Offline: file transports only.
--
--   0 PREMISE  HEAD of the mirror is seeded; upstream advanced past it
--   1 STRANDED the mirror and an agent clone are left on the stale base
--   2 HEALED   one reconcile pass fast-forwards the head, and a new clone is current
--   3 KEPT     a diverged un-relayed agent head survives a pass
--   4 OTHERS   the non-diverged head is not regressed by that pass
--
-- The EMAIL halves of the identity are load-bearing (830-t4qp): git cannot
-- auto-detect an address on an MSYS host whose name has no domain.
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-stale-reconcile.lua
-- Verdict: ok:git-mirror-stale-reconcile:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-stale-reconcile")
local SH = fixture.posix_shell()
local ROOT = fixture.repo_root()
local S = T:scratch()
local RECONCILE = ROOT .. "/images/git/reconcile-exported-heads.sh"
local ENSURE = ROOT .. "/images/git/ensure-mirror-head.sh"
local ENV = { PATH = env.get("PATH"), HOME = S.abs, GIT_CONFIG_NOSYSTEM = "1", ENSURE_HEAD = ENSURE,
    GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
local UP, MIRROR, HOST = S.abs .. "/up.git", S.abs .. "/mirror.git", S.abs .. "/hostwork"

local function run(...) return proc.run{ argv = { ... }, env = ENV, timeout_ms = 60000 } end
local function must(...)
    local r = run(...)
    if r.code ~= 0 then T:refuse("setup-failed", table.concat({ ... }, " ") .. ": " .. tostring(r.stderr)) end
    return text.trim(r.stdout or "")
end
local function at(dir, ref) return must("git", "-C", dir, "rev-parse", ref) end
local function commit(dir, file, body, msg)
    fs.write(S.rel .. "/" .. dir .. "/" .. file, body)
    must("git", "-C", S.abs .. "/" .. dir, "add", file)
    must("git", "-C", S.abs .. "/" .. dir, "commit", "-q", "-m", msg)
end
local function reconcile() return run(SH, RECONCILE, MIRROR) end

must("git", "init", "-q", "--bare", UP)
must("git", "-C", UP, "symbolic-ref", "HEAD", "refs/heads/linux-next")
must("git", "init", "-q", "-b", "linux-next", HOST)
commit("hostwork", "f", "base\n", "base")
must("git", "-C", HOST, "push", "-q", UP, "HEAD:refs/heads/linux-next")
must("git", "-c", "init.defaultBranch=master", "init", "-q", "--bare", MIRROR)
must("git", "-C", MIRROR, "remote", "add", "origin", UP)
must("git", "-C", MIRROR, "fetch", "-q", "origin", "+refs/heads/*:refs/heads/*")
local seed = run(SH, ENSURE, MIRROR, "linux-next")
local BASE = at(UP, "refs/heads/linux-next")
commit("hostwork", "f", "base\nhostwork\n", "host direct push")
must("git", "-C", HOST, "push", "-q", UP, "HEAD:refs/heads/linux-next")
local NEWUP = at(UP, "refs/heads/linux-next")
T:arm("0 PREMISE the mirror HEAD is seeded and upstream advanced", seed.code == 0 and NEWUP ~= BASE, "seed rc=" .. tostring(seed.code) .. " " .. tostring(seed.stderr))

must("git", "clone", "-q", "--no-local", "file://" .. MIRROR, S.abs .. "/agent1")
T:arm("1 STRANDED a host direct push leaves the mirror and an agent clone on the stale base",
    at(MIRROR, "refs/heads/linux-next") == BASE and at(S.abs .. "/agent1", "HEAD") == BASE, "not reproduced")

local r = reconcile()
must("git", "clone", "-q", "--no-local", "file://" .. MIRROR, S.abs .. "/agent2")
T:arm("2 HEALED one reconcile pass fast-forwards the head and a new clone is current",
    r.code == 0 and at(MIRROR, "refs/heads/linux-next") == NEWUP and at(S.abs .. "/agent2", "HEAD") == NEWUP,
    "rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))

-- An agent push the mirror accepted and has not relayed, DIVERGING from upstream.
must("git", "-C", S.abs .. "/agent2", "checkout", "-qb", "feature")
commit("agent2", "agent.txt", "agentwork\n", "agent un-relayed work")
must("git", "-C", S.abs .. "/agent2", "push", "-q", "file://" .. MIRROR, "HEAD:refs/heads/feature")
must("git", "-C", HOST, "checkout", "-qb", "feature")
commit("hostwork", "g", "upstream-divergence\n", "conflicting upstream feature")
must("git", "-C", HOST, "push", "-q", UP, "HEAD:refs/heads/feature")
local AGENT = at(MIRROR, "refs/heads/feature")
r = reconcile()
T:arm("3 KEPT a diverged un-relayed agent head survives the pass",
    AGENT ~= at(UP, "refs/heads/feature") and at(MIRROR, "refs/heads/feature") == AGENT, "rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))
T:arm("4 OTHERS linux-next is not regressed by the divergence pass", at(MIRROR, "refs/heads/linux-next") == NEWUP, at(MIRROR, "refs/heads/linux-next"))
T:finish()
