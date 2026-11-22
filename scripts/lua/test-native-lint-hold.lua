-- @trace order:2112-nlrf, order:1235-rfub
--
-- test-native-lint-hold.lua — the land queue HOLDS, rather than evicts, a PR
-- whose own macOS-tray content was natively linted when its merge onto a newer
-- base (which also changed the crate) was not; and a darwin attestation REF for
-- exactly the merged subtree re-admits the same candidate with no new commit.
-- Drives the REAL scripts/check-native-lint-attested.sh and
-- scripts/attest-native-lint.sh in a scratch repo, with a stub cargo.
--
--   1 CASE 1 (base did not touch the crate): attested, rc 0 (the control)
--   2 CASE 2 without --hold: refused:native-lint:stale, rc 1 (unchanged behaviour)
--   3 CASE 2 with --hold: hold:native-lint:<pkg>:<merged-subtree>, rc 3, naming
--     exactly the merge's subtree (pre-2112: unknown arg, refused)
--   4 attest --ref --at <merge>: writes refs/attest/native-lint/<merged-subtree>
--     whose tree IS that subtree; no commit is added to the branch
--   5 the SAME candidate with --hold now passes: ok:native-lint:attested, rc 0
--   6 a forged ref (its tree is not the subtree it is named for) does not count
--   7 an author's own unattested edit still REFUSES under --hold (not a hold)
--
-- USAGE   tillandsias-plan script run scripts/lua/test-native-lint-hold.lua
-- GRAMMAR ok:native-lint-hold:7 (exit 0) | violation:native-lint-hold:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("native-lint-hold")
local ROOT = fixture.repo_root()
local PKG, CRATE = "tillandsias-macos-tray", "crates/tillandsias-macos-tray"

local r = T:scratch("repo")
local R = r.abs
scratch.mkdir(r.leaf .. "/scripts")
scratch.mkdir(r.leaf .. "/" .. CRATE .. "/src")
scratch.mkdir(r.leaf .. "/crates/other/src")
scratch.mkdir(r.leaf .. "/bin")
for _, s in ipairs({ "check-native-lint-attested.sh", "attest-native-lint.sh" }) do
    scratch.write(r.leaf .. "/scripts/" .. s, fs.read("scripts/" .. s))
end
scratch.write(r.leaf .. "/" .. CRATE .. "/src/a.rs", "a\n")
scratch.write(r.leaf .. "/" .. CRATE .. "/src/b.rs", "b\n")
scratch.write(r.leaf .. "/crates/other/src/lib.rs", "o\n")
-- The stub cargo records it ran and passes.
scratch.write(r.leaf .. "/bin/cargo", '#!/bin/sh\necho "$*" >> "' .. R .. '/cargo.argv"\nexit 0\n')
scratch.chmod(r.leaf .. "/bin/cargo", tonumber("755", 8))
scratch.write(r.leaf .. "/.gitignore", "bin/\ncargo.argv\n")

local ENV = {
    PATH = R .. "/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@x", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@x",
    TILLANDSIAS_NATIVE_LINT_PLATFORM = "darwin",
    GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1",
}
local function git(...)
    local argv = { "git", "-C", R, "-c", "commit.gpgsign=false" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local x = proc.run{ argv = argv, env = ENV, timeout_ms = 30000 }
    if x.code ~= 0 then T:refuse("setup-failed", table.concat(argv, " ") .. ": " .. (x.stderr or "")) end
    return text.trim(x.stdout or "")
end
local function sh(script, ...) -- -> rc, stdout, stderr
    local argv = { "bash", R .. "/scripts/" .. script }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local x = proc.run{ argv = argv, cwd = R, env = ENV, timeout_ms = 60000 }
    return (x.status == "exited") and x.code or -1, x.stdout or "", x.stderr or ""
end
local function edit(p, s) scratch.write(r.leaf .. "/" .. p, s) end

git("init", "-q", "-b", "main")
git("add", "-A"); git("commit", "-qm", "base")
-- The candidate edits the crate and attests it the established way (trailer).
git("switch", "-q", "-c", "work")
edit(CRATE .. "/src/a.rs", "a2\n"); git("commit", "-qam", "candidate: edit a")
local arc = sh("attest-native-lint.sh")
if arc ~= 0 then T:refuse("setup-failed", "attest-native-lint.sh rc=" .. arc) end
local cand = git("rev-parse", "HEAD")

-- CASE 1: base advances OUTSIDE the crate; the queue checks the merge.
git("switch", "-q", "main")
edit("crates/other/src/lib.rs", "o2\n"); git("commit", "-qam", "trunk: other")
local t1 = git("rev-parse", "HEAD")
git("switch", "-q", "--detach", t1); git("merge", "-q", "--no-edit", "work")
local rc, o = sh("check-native-lint-attested.sh", "--base", t1, "--hold")
T:arm("1 CASE 1 (base did not touch the crate): attested", rc == 0 and text.contains(o, "ok:native-lint:attested:" .. PKG), "rc=" .. rc .. " " .. o)

-- CASE 2: base advances INSIDE the crate (b.rs).
git("switch", "-q", "main")
edit(CRATE .. "/src/b.rs", "b2\n"); git("commit", "-qam", "trunk: crate b")
local t2 = git("rev-parse", "HEAD")
git("switch", "-q", "--detach", t2); git("merge", "-q", "--no-edit", "work")
local merge = git("rev-parse", "HEAD")
local merged_tree = git("rev-parse", "HEAD:" .. CRATE)
rc, o = sh("check-native-lint-attested.sh", "--base", t2)
T:arm("2 CASE 2 without --hold: still refused as stale", rc == 1 and text.contains(o, "refused:native-lint:stale:" .. PKG), "rc=" .. rc .. " " .. o)
rc, o = sh("check-native-lint-attested.sh", "--base", t2, "--hold")
T:arm("3 CASE 2 with --hold: HOLD naming exactly the merged subtree, rc 3",
    rc == 3 and text.trim(o) == "hold:native-lint:" .. PKG .. ":" .. merged_tree, "rc=" .. rc .. " " .. o)

-- The darwin host services the hold: lint that merge's content, write the ref.
local before = git("rev-parse", "work")
local back = git("rev-parse", "HEAD")
local arc2, ao = sh("attest-native-lint.sh", "--ref", "--at", merge)
local ref = "refs/attest/native-lint/" .. merged_tree
local reftree = git("rev-parse", "--verify", "--quiet", ref .. "^{tree}")
T:arm("4 attest --ref --at <merge>: the ref's tree IS the merged subtree; no branch commit; checkout restored",
    arc2 == 0 and text.contains(ao, "ok:attest-native-lint:ref:" .. PKG .. "=" .. merged_tree) and reftree == merged_tree
        and git("rev-parse", "work") == before and git("rev-parse", "HEAD") == back,
    "rc=" .. arc2 .. " " .. ao .. " reftree=" .. reftree)

rc, o = sh("check-native-lint-attested.sh", "--base", t2, "--hold")
T:arm("5 the SAME candidate now passes on the ref, no new commit", rc == 0 and text.contains(o, "ok:native-lint:attested:" .. PKG),
    "rc=" .. rc .. " " .. o)

-- 6: a forged ref — named for the merged subtree, pointing at another tree.
git("update-ref", "-d", ref)
local forged = git("commit-tree", git("rev-parse", cand .. ":" .. CRATE), "-m",
    "forged\n\nNative-Lint: x darwin " .. CRATE .. "=" .. merged_tree .. " clippy-all-targets-D-warnings")
git("update-ref", ref, forged)
rc, o = sh("check-native-lint-attested.sh", "--base", t2, "--hold")
T:arm("6 a forged ref whose tree is not its name does not count (still a hold)", rc == 3, "rc=" .. rc .. " " .. o)
git("update-ref", "-d", ref)

-- 7: the author edits the crate AFTER attesting — their own unlinted content.
git("switch", "-q", "work")
edit(CRATE .. "/src/a.rs", "a3\n"); git("commit", "-qam", "candidate: unattested edit")
git("switch", "-q", "--detach", t2); git("merge", "-q", "--no-edit", "work")
rc, o = sh("check-native-lint-attested.sh", "--base", t2, "--hold")
T:arm("7 an author's own unattested edit still REFUSES under --hold", rc == 1 and text.contains(o, "refused:native-lint:stale:" .. PKG),
    "rc=" .. rc .. " " .. o)

T:finish()
