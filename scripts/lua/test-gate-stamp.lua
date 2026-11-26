-- @trace spec:methodology-accountability, order:695-nvnd, order:930-i6x4, order:940-f77j, order:2368-efqj
--
-- test-gate-stamp.lua — scripts/gate-stamp.sh in a scratch repository. The stamp can fail
-- two ways, both expensive: too strict (it refused any tree with a DELETED tracked entry,
-- so a compacting cycle ran the slowest step twice), or too loose (it stamps a tree it did
-- not measure). 2 and 5 are load-bearing: accepting deletions must not become accepting
-- anything. Ported from the .sh (2368-efqj).
--
--   0 a clean tree hashes
--   1 a deletion-only tree stamps and verifies
--   2 NEGATIVE a modified tracked file is stale
--   3 a deletion is MEASURED: the stamp moves, and comes back when the files do
--   4 the restored tree does not inherit the deletion-era stamp
--   5 NEGATIVE a tracked path that is neither file nor symlink refuses (the token is issued
--     first, or the refusal reached would be the token's)
--   6 compact, gate once, commit: the push-time check still passes
--   7 plan fast-lane files never stale a stamp (930-i6x4), committed or not
--   8 NEGATIVE the base ledger and code still do
--
-- Verdict: ok:gate-stamp:<n> arms | violation:gate-stamp:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-stamp")
local SH = fixture.posix_shell()
local STAMP = fixture.repo_root() .. "/scripts/gate-stamp.sh"
local d = T:git_repo("repo")
local function git(...)
    local argv = { "git", "-C", d.abs }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return T:must(argv)
end
local function put(p, s) fs.write(d.rel .. "/" .. p, s) end
local function rm(...) for _, p in ipairs({ ... }) do T:must{ "rm", "-f", d.abs .. "/" .. p } end end
local function stamp(verb)
    local r = T:run{ SH, STAMP, verb, cwd = d.abs, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" } }
    return text.trim(r.stdout or ""), r.code, r.stderr or ""
end
-- Stands in for the gate, which alone issues the one-shot token `write` requires.
local function issue()
    put(".git/tillandsias-gate-pass-token", "version 1\ndigest " .. (stamp("compute")) .. "\ndispatch check\nissued now\n")
end
local function ck(name, want, got) T:arm(name, want == got, got) end
local STALE, FRESH = "stale:tree-changed-since-gate", "ok:gate-fresh"

git("config", "core.autocrlf", "false") -- the stamp hashes worktree BYTES
fs.mkdir(d.rel .. "/plan/index.d"); fs.mkdir(d.rel .. "/docs")
put("f.txt", "seed\n"); put("docs/folded-a.txt", "packets: []\n"); put("docs/folded-b.txt", "packets: []\n")
git("add", "-A"); git("commit", "-qm", "base")
local base, rc, err = stamp("compute")
T:arm("0 a clean tree hashes", rc == 0 and base ~= "", "rc=" .. tostring(rc) .. " " .. err)

rm("docs/folded-a.txt", "docs/folded-b.txt"); issue()
ck("1 a deletion-only tree stamps", "ok:gate-stamped", (stamp("write")))
ck("1 and verifies", FRESH, (stamp("verify")))
put("f.txt", "seed\nchanged\n")
ck("2 NEGATIVE a modified tracked file is refused", STALE, (stamp("verify")))
git("checkout", "-q", "--", "f.txt")
local deleted = stamp("compute")
T:arm("3 a deletion changes the stamp", deleted ~= "" and deleted ~= base, deleted)
git("checkout", "-q", "--", "docs/folded-a.txt", "docs/folded-b.txt")
ck("3 restoring the files restores it", base, (stamp("compute")))
ck("4 the restored tree does not inherit the deletion-era stamp", STALE, (stamp("verify")))

issue(); rm("f.txt"); fs.mkdir(d.rel .. "/f.txt")
local o
o, rc = stamp("write")
T:must{ "rmdir", d.abs .. "/f.txt" }; git("checkout", "-q", "--", "f.txt")
T:arm("5 NEGATIVE a non-file, non-symlink entry refuses", rc ~= 0 and o == "stale:cannot-write-stamp", "rc=" .. tostring(rc) .. " " .. o)

rm("docs/folded-a.txt", "docs/folded-b.txt"); issue()
ck("6 the compacting cycle stamps once", "ok:gate-stamped", (stamp("write")))
git("add", "-A"); git("commit", "-qm", "compact")
ck("6 the stamp survives the commit of the deletions", FRESH, (stamp("verify")))

issue()
ck("7 a stamp is written before the sibling burst", "ok:gate-stamped", (stamp("write")))
for _, p in ipairs{ "plan/index.d", "plan/loop_status.d", "plan/mo-full-attestations.d" } do fs.mkdir(d.rel .. "/" .. p) end
put("plan/index.d/20260902t000000z-sibling.yaml", "events: []\n")
put("plan/loop_status.d/20260902t000000z-sibling.md", "## Cycle\n")
put("plan/mo-full-attestations.d/sibling.md", "MO-FULL: COMPLETE 0 main 0\n")
ck("7 untracked fast-lane files leave it fresh", FRESH, (stamp("verify")))
git("add", "-A"); git("commit", "-qm", "burst")
ck("7 a committed fast-lane burst leaves it fresh", FRESH, (stamp("verify")))

put("plan/index.yaml", "packets: []\n")
ck("8 NEGATIVE a plan/index.yaml change is stale", STALE, (stamp("verify")))
rm("plan/index.yaml")
ck("8 removing it restores freshness", FRESH, (stamp("verify")))
put("f.txt", "seed\nchanged\n")
ck("8 NEGATIVE a code change is stale", STALE, (stamp("verify")))
T:finish()
