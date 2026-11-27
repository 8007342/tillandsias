-- @env PATH HOME
-- @trace order:1427-r2d2, order:2288-vx6k, spec:ci-release
--
-- test-pre-push-deletion-only.lua — a push that only DELETES remote refs
-- transfers no tree, so the local tree's gate stamp must not decide it; the
-- protected refs stay exactly as guarded. Ported from the .sh of the same name
-- (2288-vx6k); same four arms.
--
-- Hermetic: a bare scratch remote plus a working copy with the REAL hook as its
-- .git/hooks/pre-push (core.hooksPath pinned, since a forge sets a global one).
-- The refs are seeded before the hook is installed; every arm then pushes
-- through it from a DIRTY tree that has never been stamped.
--
--   1 RELEASE  deleting release/* from a dirty, unstamped tree is ADMITTED (pre-fix: FAILS)
--   2 SALVAGE  deleting salvage/* is still REFUSED, naming 874-w2gc
--   3 MIXED    a mixed push (one update + one delete) still demands the stamp
--   4 TRUNK    deleting linux-next is still gated
--
-- Usage: tillandsias-plan script run scripts/lua/test-pre-push-deletion-only.lua
-- Verdict: ok:pre-push-deletion-only:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("pre-push-deletion-only")
local ROOT = fixture.repo_root()
local S = T:scratch()
local BARE, WC = S.abs .. "/bare.git", S.abs .. "/wc"
local ENV = { PATH = env.get("PATH"), HOME = env.get("HOME"), GIT_TERMINAL_PROMPT = "0" }
local function git(...)
    local argv = { "git", "-C", WC, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = WC, env = ENV, timeout_ms = 60000 }
    if r.code ~= 0 then T:refuse("setup-failed", table.concat(argv, " ") .. ": " .. tostring(r.stderr)) end
    return r
end
local function push(...)
    local argv = { "git", "-C", WC, "push", "origin" }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = WC, env = ENV, timeout_ms = 300000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function has(ref)
    local r = T:run{ "git", "ls-remote", BARE, "refs/heads/" .. ref, env = ENV }
    return text.trim(r.stdout or "") ~= ""
end
local function w(p, s) fs.mkdir((S.rel .. "/wc/" .. p):match("^(.*)/[^/]*$")); fs.write(S.rel .. "/wc/" .. p, s) end

T:must{ "git", "init", "-q", "--bare", BARE }
T:must{ "git", "init", "-q", "-b", "linux-next", WC }
git("remote", "add", "origin", BARE)
git("config", "core.hooksPath", ".git/hooks")
git("config", "core.autocrlf", "false")
w("scripts/hooks/pre-push-local-gate.sh", fs.read("scripts/hooks/pre-push-local-gate.sh"))
for _, f in ipairs{ "gate-stamp.sh", "plan-binary-probe.sh", "common.sh" } do
    if fs.exists("scripts/" .. f) then
        w("scripts/" .. f, fs.read("scripts/" .. f))
        T:must{ "chmod", "+x", WC .. "/scripts/" .. f }
    end
end
w("plan/index.yaml", "packets: []\n"); fs.mkdir(S.rel .. "/wc/plan/index.d")
w("crates/demo/main.rs", "fn main() {}\n")
git("add", "-A"); git("commit", "-q", "-m", "base")
local REL1, REL2, SALV = "release/version-bump-0.0.1", "release/version-bump-0.0.2", "salvage/fixture/20260927-x"
for _, r in ipairs{ "linux-next", REL1, REL2, SALV } do push("linux-next:refs/heads/" .. r) end
T:arm("0 PREMISE the four refs are on the scratch remote", has("linux-next") and has(REL1) and has(REL2) and has(SALV), "a seed push did not land")
w(".git/hooks/pre-push", '#!/bin/sh\nexec bash scripts/hooks/pre-push-local-gate.sh "$@"\n')
T:must{ "chmod", "+x", WC .. "/.git/hooks/pre-push", WC .. "/scripts/hooks/pre-push-local-gate.sh" }
-- The dirt: an ungated code edit, never stamped (the cut's relay-merge state).
w("crates/demo/main.rs", "fn main() { let _dirty = 1; }\n")

local rc, o = push("--delete", REL1)
T:arm("1 RELEASE deleting release/* from a dirty, unstamped tree is admitted", rc == 0 and not has(REL1), "rc=" .. tostring(rc) .. " " .. o:sub(-400))
rc, o = push("--delete", SALV)
T:arm("2 SALVAGE deleting salvage/* is still refused, naming 874-w2gc",
    rc ~= 0 and has(SALV) and text.contains(o, "874-w2gc"), "rc=" .. tostring(rc) .. " present=" .. tostring(has(SALV)) .. " " .. o:sub(-400))
git("commit", "-q", "-am", "an ungated change")
rc, o = push("HEAD:refs/heads/feature-mixed", ":refs/heads/" .. REL2)
T:arm("3 MIXED a mixed update+delete push still demands the stamp (nothing moved)",
    rc ~= 0 and has(REL2) and not has("feature-mixed"), "rc=" .. tostring(rc) .. " " .. o:sub(-400))
rc, o = push("--delete", "linux-next")
T:arm("4 TRUNK deleting linux-next is still gated", rc ~= 0 and has("linux-next"), "rc=" .. tostring(rc) .. " " .. o:sub(-400))
T:finish()
