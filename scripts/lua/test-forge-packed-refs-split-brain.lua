-- @trace spec:git-mirror-service, spec:forge-hot-cold-split, spec:litmus-framework
-- @trace order:2207-vswc
--
-- test-forge-packed-refs-split-brain.lua — PORTED from
-- test-forge-packed-refs-split-brain.sh (2207-vswc), same cases, same lines.
-- Fixture for the packed-refs split-brain (order 432).
--
-- The forge gitdir facade bind-mounts objects/ and refs/ (live, shared) but
-- used to COPY packed-refs (point-in-time). A host-side `git gc` packs every
-- loose ref into the host's packed-refs and DELETES the loose ref files.
-- refs/ is shared so the container's view empties, and its stale packed-refs
-- copy predates the gc, so the refs exist in neither place. With HEAD on an
-- unresolvable branch the container sees tracked files as UNTRACKED, and a
-- commit creates an ORPHANED ROOT COMMIT.
--
-- Case 1 REPRODUCES the hazard with a copied packed-refs; case 2 proves a
-- shared one prevents it; case 3 proves a commit after the gc keeps its
-- ancestry. If case 1 stops reproducing, git's repack behaviour changed —
-- verify that directly before weakening anything here. Scratch lives under
-- target/plan-scratch; every commit carries its identity on the command line.
--
-- Verdict: `PASS: forge packed-refs split-brain fixture (order 432)` then
-- ok:forge-packed-refs-split-brain:3 | FAIL: <why> then
-- violation:forge-packed-refs-split-brain:<case>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/packed-refs-" .. tostring(time.now_ms())
local WORK = root .. "/" .. rel
local function cleanup() proc.run{ argv = { "find", WORK, "-delete" }, timeout_ms = 60000 } end
local function fail(msg, slug)
    log.raw("FAIL: " .. msg .. "\n")
    cleanup()
    verdict.emit("violation:forge-packed-refs-split-brain:" .. slug, 1)
end
if not proc.run{ argv = { "git", "--version" } }.ok then
    out.line("SKIP: git unavailable")
    verdict.skip("forge-packed-refs-split-brain:git-unavailable")
end

local ID = { "-c", "user.email=t@t", "-c", "user.name=t" }
local function git(dir, args, e)
    local a = { "git" }
    if dir then a[#a + 1] = "-C"; a[#a + 1] = dir end
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, env = e, timeout_ms = 60000 }
end
local function cat(args) local t = {} for _, l in ipairs(ID) do t[#t + 1] = l end
    for _, l in ipairs(args) do t[#t + 1] = l end return t end

local function build(d, mode)
    proc.run{ argv = { "mkdir", "-p", d .. "/host", d .. "/facade" } }
    git(d .. "/host", { "init", "-q", "." })
    fs.write(rel .. d:sub(#WORK + 1) .. "/host/f.txt", "a\n")
    git(d .. "/host", { "add", "." })
    git(d .. "/host", cat({ "commit", "-qm", "init" }))
    git(d .. "/host", { "branch", "feature-x" })
    git(d .. "/host", { "pack-refs", "--all" })
    proc.run{ argv = { "cp", d .. "/host/.git/HEAD", d .. "/facade/HEAD" } }
    proc.run{ argv = { "ln", "-s", "../host/.git/objects", d .. "/facade/objects" } }
    proc.run{ argv = { "ln", "-s", "../host/.git/refs", d .. "/facade/refs" } }
    if mode == "share" then
        proc.run{ argv = { "ln", "-s", "../host/.git/packed-refs", d .. "/facade/packed-refs" } }
    else
        proc.run{ argv = { "cp", d .. "/host/.git/packed-refs", d .. "/facade/packed-refs" } }
    end
end
local function resolves(facade, ref)
    return git(nil, { "rev-parse", "--verify", ref }, { GIT_DIR = facade }).ok
end

-- --- case 1: NEGATIVE CONTROL — copied packed-refs loses refs on host gc ---
local C = WORK .. "/copy"
build(C, "copy")
if not resolves(C .. "/facade", "feature-x") then
    fail("case1 setup: container must resolve feature-x before gc", "case1-setup")
end
-- A new loose ref created after the facade copy is exactly what a session does.
git(C .. "/host", { "branch", "feature-y" })
git(C .. "/host", { "gc", "--quiet", "--prune=now" })
if resolves(C .. "/facade", "feature-y") then
    fail("case1: expected the COPIED packed-refs to lose the post-copy ref (hazard not reproduced)", "case1")
end
out.line("case 1 ok: copied packed-refs LOSES refs after a host gc (hazard reproduced)")

-- --- case 2: shared packed-refs survives the same sequence ----------------
local S = WORK .. "/share"
build(S, "share")
git(S .. "/host", { "branch", "feature-y" })
git(S .. "/host", { "gc", "--quiet", "--prune=now" })
if not resolves(S .. "/facade", "feature-x") then
    fail("case2: shared packed-refs must still resolve feature-x after gc", "case2-x")
end
if not resolves(S .. "/facade", "feature-y") then
    fail("case2: shared packed-refs must see the post-facade ref after gc", "case2-y")
end
out.line("case 2 ok: shared packed-refs survives a host gc")

-- --- case 3: ancestry is preserved, not orphaned --------------------------
fs.write(rel .. "/share/host/f.txt", "a\nb\n")
local fe = { GIT_DIR = S .. "/facade", GIT_WORK_TREE = S .. "/host" }
git(nil, { "add", "f.txt" }, fe)
git(nil, cat({ "commit", "-qm", "post-gc" }), fe)
local depth = tonumber(text.trim(git(nil, { "rev-list", "--count", "HEAD" }, fe).stdout or "")) or 0
if depth < 2 then
    fail("case3: commit after gc orphaned history (depth " .. depth .. ", expected >=2)", "case3")
end
out.line("case 3 ok: commit after a host gc keeps its ancestry (depth " .. depth .. ")")

cleanup()
out.line("PASS: forge packed-refs split-brain fixture (order 432)")
verdict.ok("forge-packed-refs-split-brain:3")
