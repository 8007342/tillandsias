-- @trace spec:meta-orchestration, order:1247-b46r
--
-- test-meta-orchestration-dirty-tree-safety.lua — PORTED from
-- test-meta-orchestration-dirty-tree-safety.sh (1247-b46r carry, shell-to-lua).
-- Pins the order-341 startup worktree boundary: a dirty-start blocked cycle
-- writes disposable diagnostics only under its external boundary directory,
-- the guard verifies the operator's tracked and untracked bytes unchanged,
-- refuses once a startup byte changes, and verifies again once it is put
-- back; and the skill text and the image copy path that carry the rule are
-- still there.
--
--   tillandsias-plan script run scripts/lua/test-meta-orchestration-dirty-tree-safety.lua
--
-- Success prints the .sh's line unchanged, so both litmus specs keep
-- matching it:
--   PASS: blocked cycle preserved startup tracked and untracked bytes
--
-- Deliberate differences from the .sh:
--   * every check runs and each failure prints its own FAIL: line; the .sh
--     died silently under set -e at the first one (only the tamper check
--     said why);
--   * the scratch repo lives under target/plan-scratch (fs.write is
--     repo-confined; target/ is ignored, so the real checkout never sees it),
--     and git runs with HOME pointed into it, so no global git config of
--     this host leaks into the fixture.

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
if ROOT == "" then verdict.could_not_run("meta-orchestration-dirty-tree-safety", "not inside a git checkout") end
local GUARD = ROOT .. "/scripts/meta-orchestration-worktree-guard.sh"
local REL = "target/plan-scratch/meta-orchestration-dirty-tree-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local SB = ROOT .. "/" .. REL
local REPO, STATE = SB .. "/repo", SB .. "/boundary"
local ENV = { PATH = "/usr/bin:/bin:/usr/local/bin", HOME = SB .. "/home" }

local failures = {}
local function fail(msg) failures[#failures + 1] = msg end
local function run(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd or REPO, env = ENV, timeout_ms = 60000 })
    local rc = (r.status == "exited") and r.code or -1
    return rc, text.trim(r.stdout or ""), r.stderr or ""
end
local function git(...) return run({ "git", ... }) end
local function guard(...) return run({ "bash", GUARD, ... }) end
local function hash(path) local _, h = git("hash-object", "--no-filters", "--", path); return h end
local function finish()
    proc.run({ argv = { "rm", "-rf", SB } })
end

for _, d in ipairs({ "", "/home", "/repo", "/repo/plan", "/repo/plan/issues" }) do fs.mkdir(REL .. d) end
git("init", "-q")
git("config", "user.name", "fixture")
git("config", "user.email", "fixture@example.invalid")
fs.write(REL .. "/repo/tracked.txt", "committed\n")
fs.write(REL .. "/repo/.gitignore", "ignored.tmp\n")
git("add", "tracked.txt", ".gitignore")
local seeded = git("commit", "-qm", "baseline")
if seeded ~= 0 then
    finish()
    verdict.could_not_run("meta-orchestration-dirty-tree-safety", "could not seed the scratch repo")
end

-- The operator's startup state: a tracked edit and an untracked packet.
fs.write(REL .. "/repo/tracked.txt", "operator tracked edit\n")
fs.write(REL .. "/repo/plan/issues/operator packet.md", "operator untracked packet\n")
local tracked_before = hash("tracked.txt")
local untracked_before = hash("plan/issues/operator packet.md")

local rc, o, e = guard("snapshot", STATE)
if rc ~= 0 then fail("snapshot refused a dirty start (rc=" .. rc .. "): " .. o .. e) end

-- A dirty-start blocked cycle may write disposable diagnostics only outside the
-- shared checkout. It performs no checkout, restore, reset, clean, or unlink in
-- the worktree before verifying the startup boundary.
fs.write(REL .. "/boundary/tmp/probe.log", "preflight diagnostic only\n")
rc, o, e = guard("verify", STATE)
if rc ~= 0 then fail("verify refused an untouched dirty start (rc=" .. rc .. "): " .. o .. e) end

if hash("tracked.txt") ~= tracked_before then fail("the tracked startup edit changed") end
if hash("plan/issues/operator packet.md") ~= untracked_before then fail("the untracked startup packet changed") end

fs.write(REL .. "/repo/tracked.txt", "tampered during blocked exit\n")
rc = guard("verify", STATE)
if rc == 0 then fail("guard accepted changed startup bytes") end
fs.write(REL .. "/repo/tracked.txt", "operator tracked edit\n")
rc, o, e = guard("verify", STATE)
if rc ~= 0 then fail("verify refused once the startup bytes were put back (rc=" .. rc .. "): " .. o .. e) end

-- The rule's carriers: the skill text, and the image path that copies it.
local skill = fs.read("skills/meta-orchestration/SKILL.md") or ""
for _, want in ipairs({
    "git status --porcelain=v1 -z --untracked-files=all",
    "Never run broad `git clean`, `git checkout --`",
    "must never delete or restore worktree paths",
    "dirty-start preflight refusal is not a work cycle",
    "host/orchestrator can file it durably",
}) do
    if not text.contains(skill, want) then fail("skills/meta-orchestration/SKILL.md no longer says: " .. want) end
end
if not text.contains(fs.read("scripts/build-image.sh") or "", 'cp -rp "$ROOT/skills" "$IMAGE_DIR/skills"') then
    fail("scripts/build-image.sh no longer copies the canonical skills into the image")
end

finish()
if #failures > 0 then
    for _, f in ipairs(failures) do out.line("FAIL: " .. f) end
    verdict.emit("violation:meta-orchestration-dirty-tree-safety:" .. #failures, 1)
end
out.line("PASS: blocked cycle preserved startup tracked and untracked bytes")
verdict.emit("ok:meta-orchestration-dirty-tree-safety", 0)
