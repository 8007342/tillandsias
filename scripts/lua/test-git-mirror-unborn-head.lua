-- @env PATH
-- @trace spec:git-mirror-service, order:2289-bxzm
--
-- test-git-mirror-unborn-head.lua — regression pin for the unborn-HEAD mirror defect
-- (2026-07-20), ported from the .sh of the same name (2289-bxzm). `git init --bare`
-- leaves HEAD -> refs/heads/master and upstream has no master, so a clone of the seeded
-- mirror exits 0 with an EMPTY tree. Offline, against the production repair helper
-- images/git/ensure-mirror-head.sh.
-- plan/issues/mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md
--
--   1 BREAK      a seeded mirror with an unborn HEAD clones to empty
--   2 PREFERRED  repair names the preferred branch and a clone checks it out
--   3 IDEMPOTENT a second run on a healthy mirror succeeds and moves nothing
--   4 FALLBACK   no preference: upstream's default (main)
--   5 SYMREF     no preference: upstream's default when it is NOT main (the .sh could
--                not tell the symref lookup from the hard-coded main)
--   6 UNSEEDED   no heads yet: exit 3, HEAD untouched
--
-- The EMAIL halves of the identity are load-bearing (830-t4qp).
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-unborn-head.lua
-- Verdict: ok:git-mirror-unborn-head:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-unborn-head")
local SH = fixture.posix_shell()
local ENSURE = fixture.repo_root() .. "/images/git/ensure-mirror-head.sh"
local S = T:scratch()
local ENV = { PATH = env.get("PATH"), HOME = S.abs, GIT_CONFIG_NOSYSTEM = "1",
    GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
local UP, WORK = S.abs .. "/up.git", S.abs .. "/work"

local function run(...) return proc.run{ argv = { ... }, env = ENV, timeout_ms = 60000 } end
local function must(...)
    local r = run(...)
    if r.code ~= 0 then T:refuse("setup-failed", table.concat({ ... }, " ") .. ": " .. tostring(r.stderr)) end
    return text.trim(r.stdout or "")
end
local function mirror(name, seed)
    local m = S.abs .. "/" .. name
    must("git", "-c", "init.defaultBranch=master", "init", "-q", "--bare", m)
    must("git", "-C", m, "remote", "add", "origin", UP)
    if seed then must("git", "-C", m, "fetch", "-q", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*") end
    return m
end
local function head(m) return must("git", "-C", m, "symbolic-ref", "HEAD") end
local function born(d) return run("git", "-C", d, "rev-parse", "--quiet", "--verify", "HEAD").code == 0 end
local function clone(m, name) run("git", "clone", "-q", "--no-local", "file://" .. m, S.abs .. "/" .. name); return S.abs .. "/" .. name end

-- Upstream: main (its default) + linux-next, NO master.
must("git", "init", "-q", "--bare", UP)
must("git", "-C", UP, "symbolic-ref", "HEAD", "refs/heads/main")
must("git", "init", "-q", "-b", "main", WORK)
fs.write(S.rel .. "/work/f", "one\n")
must("git", "-C", WORK, "add", "f"); must("git", "-C", WORK, "commit", "-q", "-m", "base")
must("git", "-C", WORK, "push", "-q", UP, "HEAD:refs/heads/main")
must("git", "-C", WORK, "commit", "-q", "--allow-empty", "-m", "work")
must("git", "-C", WORK, "push", "-q", UP, "HEAD:refs/heads/linux-next")

local m1 = mirror("mirror.git", true)
local c1 = clone(m1, "clone1")
T:arm("1 BREAK a seeded mirror with an unborn HEAD clones to empty", fs.exists(S.rel .. "/clone1/.git") and not born(c1), "not reproduced")

local e = run(SH, ENSURE, m1, "linux-next")
local c2 = clone(m1, "clone2")
T:arm("2 PREFERRED repair names the preferred branch and a clone checks it out",
    e.code == 0 and head(m1) == "refs/heads/linux-next" and born(c2) and head(c2) == "refs/heads/linux-next" and fs.exists(S.rel .. "/clone2/f"),
    "rc=" .. tostring(e.code) .. " head=" .. head(m1))
e = run(SH, ENSURE, m1, "main")
T:arm("3 IDEMPOTENT a second run on a healthy mirror succeeds and moves nothing", e.code == 0 and head(m1) == "refs/heads/linux-next", "rc=" .. tostring(e.code) .. " head=" .. head(m1))

local m2 = mirror("mirror2.git", true)
e = run(SH, ENSURE, m2)
T:arm("4 FALLBACK no preference adopts upstream's default (main)", e.code == 0 and head(m2) == "refs/heads/main", "rc=" .. tostring(e.code) .. " head=" .. head(m2))
must("git", "-C", UP, "symbolic-ref", "HEAD", "refs/heads/linux-next")
local m3 = mirror("mirror3.git", true)
e = run(SH, ENSURE, m3)
T:arm("5 SYMREF no preference adopts upstream's default when it is not main", e.code == 0 and head(m3) == "refs/heads/linux-next", "rc=" .. tostring(e.code) .. " head=" .. head(m3))

local m4 = mirror("mirror4.git", false)
e = run(SH, ENSURE, m4)
T:arm("6 UNSEEDED no heads yet is exit 3 with HEAD untouched", e.code == 3 and head(m4) == "refs/heads/master", "rc=" .. tostring(e.code) .. " head=" .. head(m4))
T:finish()
