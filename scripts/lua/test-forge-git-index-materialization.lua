-- @env PATH HOME
-- @trace spec:git-mirror-service, spec:forge-hot-cold-split, spec:litmus-framework, order:425, order:2288-s2na
--
-- test-forge-git-index-materialization.lua — fixture for ensure_forge_git_index
-- (order 425), ported from the .sh of the same name (2288-s2na); same five cases.
--
-- An absent .git/index is a DATA-LOSS path. The host-side facade builder cannot
-- run `git read-tree` when the launching host has no git (WSL2 and VZ guests ship
-- none). With no index every tracked file is BOTH staged-deleted and untracked,
-- and `git commit -am` commits the deletion of the whole tree while the working
-- tree still looks right; the mirror relays that commit to GitHub.
--
--   1 PRESENT  an existing index is left alone
--   2 ABSENT   an absent index is materialised from HEAD
--   3 HAZARD   WITHOUT the guard the commit empties HEAD (the load-bearing
--              negative control); WITH it every file survives
--   4 NONREPO  a path that is not a repo is a no-op
--   5 NOHEAD   a repo with no commit yet is a no-op
--
-- Only the function under test is loaded: sourcing all of lib-common.sh would run
-- forge-container setup that must not execute on a build host.
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-git-index-materialization.lua
-- Verdict: ok:forge-git-index-materialization:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("forge-git-index-materialization")
local SH = fixture.posix_shell()
local LIB = fs.read("images/default/lib-common.sh")
local fn = ("\n" .. LIB):match("\n(ensure_forge_git_index%(%).-\n}\n)")
if not fn then T:refuse("no-subject", "ensure_forge_git_index() is not in images/default/lib-common.sh") end

local function ensure(dir)
    return proc.run{ argv = { SH, "-s", "--", dir }, timeout_ms = 30000,
        stdin = "trace_lifecycle() { :; }\n" .. fn .. 'ensure_forge_git_index "$1" </dev/null\n' }
end
local function git(d, ...) return T:run{ "git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t", ... } end
local function repo(name)
    local r = T:git_repo(name)
    for _, f in ipairs{ "a", "b", "c" } do fs.write(r.rel .. "/" .. f .. ".txt", "content-" .. f .. "\n") end
    git(r.abs, "add", "."); git(r.abs, "commit", "-qm", "init")
    return r
end
local function drop_index(r) T:must{ "rm", "-f", r.abs .. "/.git/index" } end
local function files(r) return text.trim(git(r.abs, "ls-tree", "--name-only", "HEAD").stdout or "") end
local function index_digest(r) return (T:run{ "git", "hash-object", "--no-filters", r.abs .. "/.git/index" }.stdout or "") end

local r1 = repo("present")
local before = index_digest(r1)
local e = ensure(r1.abs)
T:arm("1 PRESENT an existing index is left alone", e.code == 0 and before ~= "" and index_digest(r1) == before, "rc=" .. tostring(e.code) .. " " .. (e.stderr or ""))

local r2 = repo("absent"); drop_index(r2)
e = ensure(r2.abs)
T:arm("2 ABSENT an absent index is materialised from HEAD", e.code == 0 and fs.exists(r2.rel .. "/.git/index"), "rc=" .. tostring(e.code) .. " " .. (e.stderr or ""))

local r3 = repo("hazard"); drop_index(r3)
git(r3.abs, "commit", "-qam", "unguarded")
local hazard = files(r3)
local r4 = repo("guarded"); drop_index(r4)
e = ensure(r4.abs)
git(r4.abs, "commit", "-qam", "guarded")
local guarded = files(r4)
T:arm("3 HAZARD the unguarded commit empties HEAD and the guarded one keeps every file",
    hazard == "" and e.code == 0 and text.contains(guarded, "a.txt") and text.contains(guarded, "b.txt") and text.contains(guarded, "c.txt"),
    "unguarded [" .. hazard .. "] guarded [" .. guarded .. "] rc=" .. tostring(e.code))

e = ensure(r4.abs .. "-not-a-repo")
T:arm("4 NONREPO a path that is not a repo is a no-op", e.code == 0, "rc=" .. tostring(e.code) .. " " .. (e.stderr or ""))
local d = T:scratch("nohead")
T:must{ "git", "init", "-q", d.abs }
e = ensure(d.abs)
T:arm("5 NOHEAD a repo with no commit yet is a no-op", e.code == 0 and not fs.exists(d.rel .. "/.git/index"), "rc=" .. tostring(e.code) .. " " .. (e.stderr or ""))
T:finish()
