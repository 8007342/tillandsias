-- @env PATH HOME
-- @trace order:717-3bvv, order:725-bu54, order:771-wwzi, order:1247-b46r, spec:meta-orchestration, order:2347-fqm2
--
-- test-worktree-boundary-guard.lua — scripts/meta-orchestration-worktree-guard.sh names a skipped
-- snapshot as a process fault, not as a stale temp path. Ported from the .sh of the same name.
-- Everything runs in throwaway repos under target/plan-scratch.
--
--   1-5   no snapshot / missing / clean / stamp / dirty     6 a cycle can verify twice
--   7-9   a snapshot clears the stamp, retires the last boundary, and nothing else
--   10    linked worktrees keep their own boundary          11 superseded is not missing
--   12-19 every refusal says why and what clears it, and the remedy, EXECUTED, clears it
--   20    MUTATION: each rule, removed, changes an arm's answer
--
-- Usage: tillandsias-plan script run scripts/lua/test-worktree-boundary-guard.lua
-- Verdict: ok:worktree-boundary-guard:<n> arms | violation:worktree-boundary-guard:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("worktree-boundary-guard")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = ROOT .. "/scripts/meta-orchestration-worktree-guard.sh"
if not fs.exists("scripts/meta-orchestration-worktree-guard.sh") then T:refuse("guard-missing") end
local work = T:scratch()

local function guard(repo, args, subject)
    local argv = { SH, subject or GUARD }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = repo, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function git(repo, ...)
    local argv = { "git", "-C", repo.abs }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return text.trim(T:must(argv).stdout or "")
end
local function new_repo(tag)
    local r = T:git_repo(tag)
    git(r, "config", "core.autocrlf", "false")
    return r
end
local function edit(r, s) fs.write(r.rel .. "/README", fs.read(r.rel .. "/README") .. s) end
local function at(name) return work.abs .. "/" .. name end
-- The guard prints canonical paths, /c/... under MSYS.
local function canon(p)
    return text.trim(T:must{ SH, "-s", "--", p, stdin = 'cd "$1" && pwd -P\n' }.stdout or "")
end
local OK = "ok: startup worktree boundary preserved"
local function says(name, repo, want_rc, want, ...)
    local rc, o = guard(repo, { ... })
    T:arm(name, rc == want_rc and text.contains(o, want), "rc=" .. tostring(rc) .. " " .. o)
end
local function snap(repo, p)
    local rc, o = guard(repo, { "snapshot", p })
    if rc ~= 0 then T:refuse("snapshot-refused", p .. " " .. o) end
    return p
end
local function there(name) return fs.exists(work.rel .. "/" .. name) end

local R = new_repo("repo")
says("1 a skipped snapshot is named", R.abs, 3, "blocked:no-snapshot-taken", "verify", at("boundary.Wxg6hS"))
local a = snap(R.abs, at("state-a"))
says("2 a path that was never a boundary is a different fault", R.abs, 3, "blocked:boundary-state-missing", "verify", at("never"))
says("3 CONTROL an untouched tree verifies", R.abs, 0, OK, "verify", a)
local stamp = R.rel .. "/.git/boundary-verified"
local function stamped() return fs.exists(stamp) and text.trim(fs.read(stamp)) or "" end
T:arm("4 the stamp records the verified head", stamped() == git(R, "rev-parse", "HEAD"), stamped())
edit(R, "mutated by the cycle\n")
says("5 a changed tree is caught", R.abs, 1, "worktree differs from startup boundary", "verify", a)
git(R, "commit", "-qam", "the work the operator asked for after Finalization")
says("6 a cycle that did more work verifies again", R.abs, 0, OK, "verify", a)
T:arm("6 and records the NEW head", stamped() == git(R, "rev-parse", "HEAD"), stamped())
snap(R.abs, at("state-b"))
T:arm("7 a new snapshot clears the last verification", not fs.exists(stamp), stamped())
T:arm("8 and retires the previous boundary", not there("state-a"), "state-a survived")

-- A stamp that names something else must not become an arbitrary rm -rf.
local function bystander(name)
    fs.mkdir(work.rel .. "/" .. name)
    fs.write(work.rel .. "/" .. name .. "/precious.txt", "operator data\n")
    fs.write(R.rel .. "/.git/boundary-state", canon(at(name)) .. "\n")
end
bystander("bystander")
snap(R.abs, at("state-c"))
T:arm("9 a directory that is no boundary is left alone", there("bystander/precious.txt"), "deleted")

git(R, "worktree", "add", "-q", at("linked"), "-b", "linked")
local main = snap(R.abs, at("state-main"))
snap(at("linked"), at("state-linked"))
T:arm("10 a linked worktree's snapshot leaves the main boundary", there("state-main"), "retired")
T:arm("10 and keeps its own", there("state-linked"), "gone")
says("10 the main worktree still verifies", R.abs, 0, OK, "verify", main)
local old = snap(R.abs, at("super-old"))
snap(R.abs, at("super-new"))
says("11 a retired boundary is superseded, not missing", R.abs, 3, "blocked:boundary-superseded", "verify", old)
says("11 and both paths are named", R.abs, 3, "requested: " .. old, "verify", old)

-- 12-19, in a repo of its own so the stamps above cannot satisfy or spoil them.
local A = new_repo("arepo")
local function afford(name, rc_want, token, why, remedy, ...)
    local rc, o = guard(A.abs, { ... })
    T:arm(name, rc == rc_want and text.contains(o, token) and text.contains("\n" .. o, "\n  why: ")
        and text.contains(o, "\n  remedy: ") and text.contains(o, why) and text.contains(o, remedy),
        "rc=" .. tostring(rc) .. " " .. o)
end
local function clears(name, want, ...) says(name .. ": the remedy clears it", A.abs, 0, want, ...) end
local CMD = "meta-orchestration-worktree-guard.sh "

afford("12 no snapshot", 3, "blocked:no-snapshot-taken", "no snapshot was taken in this checkout",
    CMD .. "snapshot <a new directory outside this worktree>", "verify", at("previous-cycle"))
clears("12 no snapshot (snapshot)", "", "snapshot", at("a1"))
clears("12 no snapshot (verify)", OK, "verify", at("a1"))
local a1 = canon(at("a1"))
afford("13 a missing boundary names the recorded one", 3, "blocked:boundary-state-missing:" .. a1,
    "is not a boundary this worktree recorded", CMD .. "verify " .. a1, "verify", at("never"))
clears("13 a missing boundary", OK, "verify", a1)
scratch.rm(work.leaf .. "/a1")
afford("14 a boundary that is gone too", 3, "blocked:boundary-state-missing:" .. a1, a1 .. " is gone too",
    "snapshot into a new directory", "verify", at("never"))
clears("14 a gone boundary (snapshot)", "", "snapshot", at("a2"))
clears("14 a gone boundary (verify)", OK, "verify", at("a2"))
afford("15 a state dir inside the worktree", 2, "error: boundary state must live outside the worktree",
    "is inside the worktree", "outside this worktree", "snapshot", A.abs .. "/inside-state")
clears("15 a state dir inside the worktree", "", "snapshot", at("a3"))
afford("16 an initialized state dir", 2, "error: boundary state already initialized", "already holds a boundary",
    "a new, empty directory", "snapshot", at("a3"))
clears("16 an initialized state dir", "", "snapshot", at("a4"))
local a4 = canon(at("a4"))
fs.mkdir(work.rel .. "/not-written-by-snapshot")
afford("17 a directory snapshot never wrote", 2, "error: invalid boundary state", "snapshot did not write it",
    CMD .. "verify " .. a4, "verify", at("not-written-by-snapshot"))
clears("17 a directory snapshot never wrote", OK, "verify", a4)
edit(A, "the cycle edited this\n")
afford("18 a differing tree names the path", 1, "error: worktree differs from startup boundary", "README",
    "commit them", "verify", a4)
git(A, "commit", "-qam", "the cycle's own edit")
clears("18 a differing tree", OK, "verify", a4)
T:must{ "git", "init", "-q", A.abs .. "/nested" }
T:must{ "git", "-C", A.abs .. "/nested", "-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture",
    "commit", "-q", "--allow-empty", "-m", "nested" }
afford("19 a nested repository", 2, "is unsupported: nested/", "cannot capture", "move it out of the worktree", "snapshot", at("a5"))
T:must{ SH, "-s", "--", A.abs .. "/nested", at("nested-out"), stdin = 'mv "$1" "$2"\n' }
clears("19 a nested repository", "", "snapshot", at("a6"))

-- MUTATION. Every rm below stays inside this fixture's scratch.
local src = fs.read("scripts/meta-orchestration-worktree-guard.sh"):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local x, y = src:find(from, 1, true)
    if not x then T:refuse("mutation-anchor-missing", name) end
    fs.write(work.rel .. "/" .. name .. ".sh", src:sub(1, x - 1) .. to .. src:sub(y + 1))
    return at(name .. ".sh")
end
bystander("victim")
guard(R.abs, { "snapshot", at("m1") }, mutant("anydir", ' \\\n                && -f "$previous_dir/repo-root" && -d "$previous_dir/startup" ]]', " ]]"))
T:arm("20 MUTATION without the boundary check the bystander is deleted", not there("victim"), "victim survived")
local common = mutant("common", "git_dir=\"$(git rev-parse --git-dir 2>/dev/null)\"",
    'git_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"')
guard(R.abs, { "snapshot", at("m2") }, common)
local made = there("m2")
guard(at("linked"), { "snapshot", at("m3") }, common)
T:arm("20 MUTATION a stamp in the common dir lets a worktree retire the main boundary", made and not there("m2"),
    "made=" .. tostring(made))
local B = new_repo("brepo")
local rcm, om = guard(B.abs, { "verify", at("nothing") }, mutant("nostamp", '-z "$stamp" || ! -f "$stamp"', '-z "$stamp"'))
T:arm("20 MUTATION without the stamp test a skipped snapshot is not named",
    rcm ~= 0 and not text.contains(om, "blocked:no-snapshot-taken"), om)

T:finish()
