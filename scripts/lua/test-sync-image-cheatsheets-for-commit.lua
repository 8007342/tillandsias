-- @trace order:448, spec:cheatsheet-tooling, order:2340-psb5
-- @env PATH HOME
--
-- test-sync-image-cheatsheets-for-commit.lua — the order-448 commit-time cheatsheet
-- sync guard. Ported from test-sync-image-cheatsheets-for-commit.sh (2340-psb5);
-- same seven checks.
--
-- images/default/cheatsheets/ is a TRACKED copy derived from the authored tree, so an
-- authoring commit that omits it leaves every OTHER host unable to push. The guard
-- re-syncs it into the same commit.
--
--   1  a commit touching NOTHING authored is a silent no-op
--   2  a commit touching cheatsheets/ regenerates the derived tree
--   3  ... and STAGES it into the same commit (the whole point)
--   4  the committed derived copy matches the authored source
--   5  CONTROL the same commit without the guard leaves the derived copy stale, so
--      arms 2-4 measure the guard rather than agreeing with the status quo
--   6  a missing stager warns (warn:stager-missing) and still exits 0
--   7  the warning names the consequence other hosts will see
--
-- HERMETIC: a throwaway repo of the same shape, core.hooksPath pinned per-repo
-- (a global one replaces .git/hooks for every repo on the host, 964-fwvh).
--
-- GRAMMAR ok:cheatsheet-commit-sync:7 arms | violation:cheatsheet-commit-sync:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("cheatsheet-commit-sync")
local SH = fixture.posix_shell()
local W = T:scratch()
local R, RA = W.rel .. "/repo", W.abs .. "/repo"

local function git(...)
    local argv = { "git", "-C", RA }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    return T:must(argv)
end
local function write(path, body) fs.write(R .. "/" .. path, body) end
local function read(path) local ok, s = pcall(fs.read, R .. "/" .. path); return ok and s or nil end

for _, d in ipairs{ "/cheatsheets/runtime", "/images/default/cheatsheets/runtime", "/scripts" } do fs.mkdir(R .. d) end
T:must{ "git", "init", "-q", "-b", "main", RA }
git("config", "user.name", "fixture")
git("config", "user.email", "fixture@example.invalid")
git("config", "core.hooksPath", RA .. "/.git/hooks")
write("scripts/stage-image-cheatsheets.sh", '#!/usr/bin/env bash\nset -euo pipefail\nR="$(git rev-parse --show-toplevel)"\n'
    .. 'rm -rf "$R/images/default/cheatsheets"\nmkdir -p "$R/images/default/cheatsheets"\n'
    .. 'cp -r "$R/cheatsheets/." "$R/images/default/cheatsheets/"\necho "cheatsheet-image-stage:ok"\n')
T:must{ "chmod", "+x", RA .. "/scripts/stage-image-cheatsheets.sh" }
write("scripts/sync-image-cheatsheets-for-commit.sh", fs.read("scripts/sync-image-cheatsheets-for-commit.sh"))
write("cheatsheets/runtime/thing.md", "v1\n")
write("images/default/cheatsheets/runtime/thing.md", "v1\n")
write("README.md", "other\n")
git("add", "-A")
git("commit", "-qm", "baseline")

local function run_guard()
    local r = proc.run{ argv = { SH, "scripts/sync-image-cheatsheets-for-commit.sh" }, cwd = RA, timeout_ms = 60000 }
    return text.trim(r.stdout or ""), r.code, r.stderr or ""
end

-- 1 — nothing authored staged: a silent no-op.
write("README.md", "changed\n")
git("add", "README.md")
local got, rc = run_guard()
T:arm("1 an unrelated commit is a no-op", got == "skip:no-authored-cheatsheet-change" and rc == 0,
    "got '" .. got .. "' rc=" .. tostring(rc))
git("reset", "-q")

-- 2-4 — an authored edit: the derived tree is regenerated, staged, and committed in step.
write("cheatsheets/runtime/thing.md", "v2 authored\n")
git("add", "cheatsheets/runtime/thing.md")
got, rc = run_guard()
T:arm("2 an authored edit re-syncs the derived tree", got:match("^ok:cheatsheet%-image%-synced:") ~= nil,
    "got '" .. got .. "' rc=" .. tostring(rc))
local staged = text.trim(git("diff", "--cached", "--name-only", "--", "images/default/cheatsheets/").stdout or "")
T:arm("3 the derived copy is STAGED into this very commit", staged ~= "", "nothing staged under images/default/cheatsheets/")
git("commit", "-qm", "authored + derived")
T:arm("4 the committed derived copy matches the authored source",
    read("images/default/cheatsheets/runtime/thing.md") == "v2 authored\n", tostring(read("images/default/cheatsheets/runtime/thing.md")))

-- 5 — CONTROL: the same commit WITHOUT the guard leaves drift.
write("cheatsheets/runtime/thing.md", "v3 authored\n")
git("add", "cheatsheets/runtime/thing.md")
git("commit", "-qm", "authored only, guard NOT run")
T:arm("5 CONTROL without the guard the derived copy goes stale",
    read("images/default/cheatsheets/runtime/thing.md") ~= "v3 authored\n", "no drift without the guard: arms 2-4 prove nothing")

-- 6-7 — a missing stager warns loudly and never blocks.
T:must{ "mv", RA .. "/scripts/stage-image-cheatsheets.sh", RA .. "/scripts/stage-image-cheatsheets.sh.gone" }
write("cheatsheets/runtime/thing.md", "v4 authored\n")
git("add", "cheatsheets/runtime/thing.md")
local err
got, rc, err = run_guard()
T:arm("6 a missing stager warns and never blocks", got == "warn:stager-missing" and rc == 0, "got '" .. got .. "' rc=" .. tostring(rc))
T:arm("7 the warning names the push refusal other hosts will see", text.contains(err, "refuse EVERY host's push"), err:sub(1, 300))

T:finish()
