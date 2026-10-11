-- @trace order:1606-25nf, spec:git-mirror-service
--
-- test-mirror-follows-rewritten-work-refs.lua — the mirror's reconcile pass
-- follows a work ref that upstream rewrote, and reports the ones it must not
-- touch, instead of serving a dead tip under heads-current.
--
-- MEASURED 2026-10-11: work/1590-j20f served c42a22b29 to every forge while
-- upstream and the mirror's tracking twin held 337dc0df9 (landed), and the
-- published state read heads-current. The reconcile fetch is non-forced by
-- design (order 449: never clobber un-relayed agent commits), so a rebase or
-- amend upstream was refused and nothing said so.
--
-- THE RULING (coordinator, on the row): a diverged work/* head is moved to its
-- twin when every commit in `head ^twin` is reachable from the twin's current
-- or any reflogged value (upstream once held all of it); otherwise it is left
-- alone and published as diverged. Twin reflogs are enabled by the reconcile
-- pass, with an explicit expiry.
--
-- Every arm builds a scratch upstream and mirror (file:// only) and runs the
-- repo's own images/git/reconcile-exported-heads.sh and publish-sync-state.sh:
--   1 FOLLOW      upstream amends work/x: post-fix the mirror serves the new
--                 tip within one pass and prints the follow line; pre-fix (the
--                 1606 blocks stripped) it keeps the old tip under heads-current
--   2 UNRELAYED   the mirror head carries a commit upstream never held: it is
--                 NOT clobbered, prints diverged:...:unrelayed-commits, and the
--                 whole-mirror state is heads-diverged with a marker naming it
--   3 NO HISTORY  a rewrite that predates the twin reflog (reflogs off when the
--                 twin last moved): diverged:...:no-twin-history, nothing moved
--   4 SCOPE       the pass prints compared/followed/diverged counts
--
-- Terminal line: ok:mirror-follows-rewritten-work-refs-fixture:<n> or
-- refused:mirror-follows-rewritten-work-refs-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-follows-rewritten-work-refs.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/mirror-follow-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/tools")
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local RECONCILE = fs.read("images/git/reconcile-exported-heads.sh") or ""
local PUBLISH = fs.read("images/git/publish-sync-state.sh") or ""
local function strip(src, tag)
    return (src:gsub("# BEGIN%-" .. tag .. "\n.-# END%-" .. tag .. "\n", ""))
end
local PRE_RECONCILE = strip(strip(RECONCILE, "1606%-REFLOG"), "1606%-FOLLOW")
local PRE_PUBLISH = strip(PUBLISH, "1606%-DIVERGED")
if PRE_RECONCILE == RECONCILE or PRE_PUBLISH == PUBLISH then
    bad("premise: the BEGIN/END-1606 blocks were not found in the mirror scripts")
    proc.run({ argv = { "rm", "-rf", S } })
    verdict.emit("refused:mirror-follows-rewritten-work-refs-fixture:" .. failed, 1)
end
fs.write(REL .. "/tools/reconcile.sh", RECONCILE)
fs.write(REL .. "/tools/reconcile-pre.sh", PRE_RECONCILE)
fs.write(REL .. "/tools/publish.sh", PUBLISH)
fs.write(REL .. "/tools/publish-pre.sh", PRE_PUBLISH)

local ENV = { GIT_CONFIG_NOSYSTEM = "1", HOME = S, GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid", ENSURE_HEAD = "/nonexistent" }
local function git(dir, args)
    local argv = { "git", "-C", dir }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = ENV, timeout_ms = 30000 })
    return r.code == 0, text.trim(r.stdout or ""), r.stderr or ""
end
local function sh(tool, dir)
    local r = proc.run({ argv = { "sh", S .. "/tools/" .. tool, dir }, env = ENV, timeout_ms = 60000 })
    return (r.stdout or "") .. (r.stderr or "")
end
local function rev(dir, ref) local _, o = git(dir, { "rev-parse", "--verify", "--quiet", ref }); return o end

-- pair(name, reflog_at_seed): an upstream with work/x at c1, a source clone,
-- and a mirror seeded by one reconcile pass (with or without twin reflogs).
local function pair(name, seed_tool)
    local d = S .. "/" .. name
    fs.mkdir(REL .. "/" .. name)
    git(d, { "init", "-q", "--bare", "up.git" })
    git(d, { "init", "-q", "-b", "work/x", "src" })
    fs.write(REL .. "/" .. name .. "/src/f", "c1\n")
    git(d .. "/src", { "add", "f" }); git(d .. "/src", { "commit", "-qm", "c1" })
    git(d .. "/src", { "push", "-q", d .. "/up.git", "HEAD:refs/heads/work/x" })
    git(d, { "init", "-q", "--bare", "mirror.git" })
    git(d .. "/mirror.git", { "remote", "add", "origin", d .. "/up.git" })
    if seed_tool then
        sh(seed_tool, d .. "/mirror.git")
    else
        -- No reconcile at seed: the twin moves with reflogs off (bare default).
        git(d .. "/mirror.git", { "fetch", "-q", "origin", "refs/heads/*:refs/heads/*" })
        git(d .. "/mirror.git", { "fetch", "-q", "origin" })
    end
    return d
end
local function amend_upstream(d)
    fs.write(S:sub(#ROOT + 2) .. "/" .. d:match("[^/]+$") .. "/src/f", "c1-amended\n")
    git(d .. "/src", { "commit", "-q", "--amend", "-am", "c1 amended" })
    git(d .. "/src", { "push", "-q", "-f", d .. "/up.git", "HEAD:refs/heads/work/x" })
    return rev(d .. "/src", "HEAD")
end

-- 1: FOLLOW, pre-fix and post-fix in one run.
local post = pair("follow", "reconcile.sh")
local pre = pair("follow-pre", "reconcile-pre.sh")
local old_post, old_pre = rev(post .. "/mirror.git", "refs/heads/work/x"), rev(pre .. "/mirror.git", "refs/heads/work/x")
local new_post, new_pre = amend_upstream(post), amend_upstream(pre)
local o_post = sh("reconcile.sh", post .. "/mirror.git")
local o_pre = sh("reconcile-pre.sh", pre .. "/mirror.git")
local v_pre = sh("publish-pre.sh", pre .. "/mirror.git")
local served_post, served_pre = rev(post .. "/mirror.git", "refs/heads/work/x"), rev(pre .. "/mirror.git", "refs/heads/work/x")
if served_pre == old_pre and served_pre ~= new_pre and has(v_pre, "sync-state:heads-current:") then
    ok("pre-fix: the mirror keeps the dead tip " .. old_pre:sub(1, 9) .. " under heads-current")
else bad("pre-fix did not reproduce the stale tip: served=" .. served_pre:sub(1, 9) .. " verdict=" .. text.trim(v_pre)) end
if served_post == new_post and has(o_post, "sync:work-ref-followed-upstream:work/x:" .. old_post .. ".." .. new_post) then
    ok("post-fix: the rewrite is followed within one pass (" .. old_post:sub(1, 9) .. ".." .. new_post:sub(1, 9) .. ")")
else bad("post-fix did not follow: served=" .. served_post:sub(1, 9) .. " out=" .. o_post:sub(1, 300)) end

-- 2: UNRELAYED, never clobbered, reported diverged and named.
local u = pair("unrelayed", "reconcile.sh")
git(u .. "/src", { "checkout", "-q", "-b", "agent" })
fs.write(REL .. "/unrelayed/src/g", "agent work\n")
git(u .. "/src", { "add", "g" }); git(u .. "/src", { "commit", "-qm", "un-relayed agent commit" })
git(u .. "/src", { "push", "-q", u .. "/mirror.git", "HEAD:refs/heads/work/x" })
local agent_tip = rev(u .. "/src", "HEAD")
git(u .. "/src", { "checkout", "-q", "work/x" })
amend_upstream(u)
local o_u = sh("reconcile.sh", u .. "/mirror.git")
local v_u = sh("publish.sh", u .. "/mirror.git")
local marker = rev(u .. "/mirror.git", "refs/tillandsias/diverged/work/x")
if rev(u .. "/mirror.git", "refs/heads/work/x") == agent_tip and has(o_u, "diverged:work/x:unrelayed-commits")
    and has(v_u, "sync-state:heads-diverged:") and marker == agent_tip then
    ok("an un-relayed head is NOT clobbered: diverged:work/x:unrelayed-commits, heads-diverged, marker at " .. agent_tip:sub(1, 9))
else bad("unrelayed: head=" .. rev(u .. "/mirror.git", "refs/heads/work/x"):sub(1, 9) .. " out=" .. o_u:sub(1, 200) .. " verdict=" .. text.trim(v_u)) end

-- 3: NO HISTORY, the bootstrap state: a rewrite that predates the twin reflog.
local n = pair("nohist", nil)
local n_old = rev(n .. "/mirror.git", "refs/heads/work/x")
amend_upstream(n)
git(n .. "/mirror.git", { "fetch", "-q", "origin" }) -- the twin moves, still with reflogs off
local o_n = sh("reconcile.sh", n .. "/mirror.git")
if rev(n .. "/mirror.git", "refs/heads/work/x") == n_old and has(o_n, "diverged:work/x:no-twin-history") then
    ok("with no twin history the rewrite reports diverged:work/x:no-twin-history and nothing moves")
else bad("no-history: head=" .. rev(n .. "/mirror.git", "refs/heads/work/x"):sub(1, 9) .. " out=" .. o_n:sub(1, 200)) end

-- 4: SCOPE counts.
if has(o_post, "sync:work-refs:compared=1 followed=1 diverged=0") and has(o_u, "sync:work-refs:compared=1 followed=0 diverged=1")
    and has(o_n, "sync:work-refs:compared=1 followed=0 diverged=1") then
    ok("each pass prints its scope (compared/followed/diverged)")
else bad("scope lines missing: follow=" .. (o_post:match("sync:work%-refs:[^\n]*") or "?") .. " unrelayed=" .. (o_u:match("sync:work%-refs:[^\n]*") or "?")) end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:mirror-follows-rewritten-work-refs-fixture:" .. passed, 0) end
verdict.emit("refused:mirror-follows-rewritten-work-refs-fixture:" .. failed, 1)
