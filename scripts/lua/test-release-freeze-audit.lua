-- @trace order:1255-s4im, order:1176-9vqn, order:2380-psba
-- inputs: .github/workflows/release.yml crates/tillandsias-headless/src/main.rs images/default/lib-common.sh plan/index.yaml scripts/check-capability-row.sh scripts/check-credential-channel.sh scripts/check-plan-binary-current.sh scripts/check-resumable-claim-dirt.sh scripts/check-stranded-in-progress.sh scripts/cycle-preflight.sh scripts/hooks/pre-push-local-gate.sh scripts/hooks/pre-push-version-guard.sh scripts/land-queue.sh scripts/lib-freeze-paths.sh scripts/lua/check-ledger-distillation.lua scripts/lua/check-must-ship-rows.lua scripts/lua/test-plan-binary-probe-release-over-debug.lua scripts/plan-binary-probe.sh scripts/regenerate-cheatsheet-index.sh scripts/release-freeze.sh scripts/release-preflight.sh scripts/select-work-batch.sh scripts/verify-version-monotonic.sh scripts/with-wsl2-builder.sh scripts/wsl-plan-expert-ensure.sh VERSION lib/lua/common/ crates/tillandsias-plan/ plan/index.d/
-- @env PATH HOME
--
-- test-release-freeze-audit.lua — `release-freeze.sh audit` and release-preflight's Gate 6.
-- Ported from test-release-freeze-audit.sh (2380-psba); same nine arms.
--
-- THE PREMISE (1255-s4im, reproduced 2026-10-09): a host with no hooks pushes code into a
-- frozen branch and git accepts it, so the cut must SEE the breach from origin alone. Every
-- push here is --no-verify, standing in for that host. Hermetic: a bare remote and clones in
-- scratch; HOME / GIT_CONFIG_GLOBAL point into it, GIT_CONFIG_NOSYSTEM=1, a fixed identity,
-- and TILLANDSIAS_* / CARGO_TARGET_DIR stripped (the .sh unset CARGO_TARGET_DIR and
-- TILLANDSIAS_PLAN_BIN). The scripts under test are copied from the working tree into a
-- minimal repo whose preflight gates 1-5 pass, so Gate 6 is the only thing under test.
-- --no-local clones throughout: macOS git intermittently aborts the hardlinking clone.
--
--   1  no marker -> ok:freeze-none
--   2  frozen, unmoved -> clean moved=0; code landed BEFORE the freeze is not a breach (arm 6)
--   3  NC: a plan-only push during the freeze -> clean moved=1
--   4  a hookless CODE push during the freeze -> violation naming the commit, author, held path (exit 1)
--   5  a clone that never fetched the breach gives the identical verdict (it reads origin)
--   6  (9a) release-preflight refuses the breached cut: blocked:freeze-breached, remedy names it
--   7  reverting the breach makes the audit clean
--   8  (9b) NC: after the revert the preflight passes
--   9  (8) an unreachable remote -> refused:freeze:unreachable, exit 3 (never "clean")
--
-- GRAMMAR ok:release-freeze-audit:<n> arms | violation:release-freeze-audit:<n>-failed
--       | refused:release-freeze-audit:setup-failed

local fixture = require "common.fixture"
local T = fixture.new("release-freeze-audit")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/home"); fs.write(W.rel .. "/home/.gitconfig", "")
local ENV = { HOME = W.abs .. "/home", GIT_CONFIG_GLOBAL = W.abs .. "/home/.gitconfig", GIT_CONFIG_NOSYSTEM = "1",
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "f@example.invalid" }
local UNSET = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }
local function run(argv, cwd, stdin)
    argv.cwd, argv.env, argv.env_unset, argv.stdin, argv.timeout_ms = cwd, ENV, UNSET, stdin, 180000
    return T:run(argv)
end
local function must(argv, cwd)
    argv.cwd, argv.env, argv.env_unset = cwd, ENV, UNSET
    return T:must(argv)
end
local function last(s)
    local l = ""
    for x in (s or ""):gmatch("[^\n]+") do l = x end
    return l
end
local function trim(s) return text.trim(s or "") end

-- The minimal source repo.
local R = W.abs .. "/src"
for _, d in ipairs({ "src", "src/scripts", "src/.github", "src/.github/workflows", "src/plan", "src/plan/index.d",
        "src/crates", "src/crates/x", "src/crates/x/src" }) do fs.mkdir(W.rel .. "/" .. d) end
for _, s in ipairs({ "release-freeze.sh", "lib-freeze-paths.sh", "release-preflight.sh", "plan-binary-probe.sh" }) do
    fs.write(W.rel .. "/src/scripts/" .. s, fs.read("scripts/" .. s))
end
fs.write(W.rel .. "/src/scripts/verify-version-monotonic.sh", "#!/bin/sh\nexit 0\n")
must({ SH, "-s", "--", R .. "/scripts", stdin = 'chmod +x "$1"/*.sh\n' }, ROOT)   -- fs.write drops the exec bit
fs.write(W.rel .. "/src/plan/index.yaml", "plan_index:\n  steps: []\n")
fs.write(W.rel .. "/src/.github/workflows/release.yml", "name: release\n")
fs.write(W.rel .. "/src/crates/x/src/lib.rs", "// code\n")
must({ "git", "init", "-q", "-b", "linux-next", R }, ROOT)
must({ "git", "-C", R, "add", "-A" }, ROOT)
must({ "git", "-C", R, "commit", "-q", "-m", "seed" }, ROOT)
local BARE, C, F = W.abs .. "/bare.git", W.abs .. "/coord", W.abs .. "/floor"
must({ "git", "clone", "-q", "--no-local", "--bare", R, BARE }, ROOT)
must({ "git", "clone", "-q", "--no-local", BARE, C }, ROOT)    -- the coordinator's clone
must({ "git", "clone", "-q", "--no-local", BARE, F }, ROOT)    -- a hookless floor host

local function audit(clone)
    local r = run({ SH, "scripts/release-freeze.sh", "audit", "linux-next" }, clone)
    return r.stdout or "", r.code, r.stderr or ""
end
local function floor_push(path, content, msg)
    must({ "git", "-C", F, "pull", "-q", "--no-rebase", "origin", "linux-next" }, ROOT)
    must({ SH, "-s", "--", path, content, stdin = 'mkdir -p "$(dirname "$1")"; printf "%s\\n" "$2" >> "$1"\n' }, F)
    must({ "git", "-C", F, "add", "-A" }, ROOT)
    must({ "git", "-C", F, "commit", "-q", "-m", msg }, ROOT)
    must({ "git", "-C", F, "push", "-q", "--no-verify", "origin", "linux-next" }, ROOT)
end
local function preflight()
    must({ "git", "-C", C, "pull", "-q", "--no-rebase", "origin", "linux-next" }, ROOT)
    local r = run({ SH, "scripts/release-preflight.sh" }, C)
    return r.stdout or "", r.code, r.stderr or ""
end

floor_push("crates/x/src/lib.rs", "// before the freeze", "code before the freeze")   -- arm 2's pre-freeze code

local out, rc, err = audit(C)
T:arm("1 no marker -> ok:freeze-none", rc == 0 and last(out) == "ok:freeze-none:linux-next", "rc=" .. tostring(rc) .. " out=[" .. out .. "]")

-- freeze from the coordinator's (behind) clone: set must still mark origin's tip
run({ SH, "scripts/release-freeze.sh", "set", "linux-next" }, C)
local frozen_at = trim(must({ "git", "--git-dir=" .. BARE, "rev-parse", "linux-next" }, ROOT).stdout)

out, rc = audit(C)
T:arm("2 frozen and unmoved -> clean; code that landed before the freeze is not a breach",
    rc == 0 and last(out) == "ok:freeze-audit:clean:linux-next:moved=0", "rc=" .. tostring(rc) .. " out=[" .. out .. "]")

floor_push("plan/index.d/claim.yaml", "x: 1", "plan only, during the freeze")
out, rc = audit(C)
T:arm("3 NC: a plan-only push during the freeze -> clean",
    rc == 0 and last(out) == "ok:freeze-audit:clean:linux-next:moved=1", "rc=" .. tostring(rc) .. " out=[" .. out .. "]")

floor_push("crates/x/src/lib.rs", "// during the freeze", "code during the freeze")
local breach_full = trim(must({ "git", "-C", F, "rev-parse", "HEAD" }, ROOT).stdout)
out, rc, err = audit(C)
local breach = out:match("\nbreach:linux%-next:([0-9a-f]+):") or out:match("^breach:linux%-next:([0-9a-f]+):")
local resolved = breach and trim(run({ "git", "-C", F, "rev-parse", breach }, ROOT).stdout) or ""
local lines = {}
for l in out:gmatch("[^\n]+") do lines[l] = true end
T:arm("4 a hookless code push during the freeze -> violation naming the commit, its author and the held path (exit 1)",
    rc == 1 and breach ~= nil and resolved == breach_full
        and lines["breach:linux-next:" .. tostring(breach) .. ":fixture:code during the freeze"]
        and lines["held:crates/x/src/lib.rs"]
        and last(out):find("^violation:freeze%-breached:linux%-next:commits=1:held%-paths=1:frozen%-at=") ~= nil
        and err:find("  remedy: ", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " out=[" .. out .. "] err=[" .. err .. "]")
local coord_verdict = last(out)

local L = W.abs .. "/late"
must({ "git", "clone", "-q", "--no-local", BARE, L }, ROOT)
must({ "git", "-C", L, "reset", "-q", "--hard", frozen_at }, ROOT)
must({ "git", "-C", L, "update-ref", "refs/remotes/origin/linux-next", frozen_at }, ROOT)
out, rc = audit(L)
T:arm("5 a clone whose refs predate the breach gives the identical verdict — it reads origin",
    rc == 1 and last(out) == coord_verdict, "rc=" .. tostring(rc) .. " got [" .. last(out) .. "] want [" .. coord_verdict .. "]")

local pf, prc, pferr = preflight()
T:arm("6 (9a) release-preflight refuses the breached cut (blocked:freeze-breached, exit 1) and its remedy names the commit",
    prc == 1 and last(pf) == "blocked:freeze-breached" and breach ~= nil
        and pferr:find("remedy: revert the breach (git revert " .. breach, 1, true) ~= nil,
    "rc=" .. tostring(prc) .. " out=[" .. pf .. "] err=[" .. pferr:sub(-600) .. "]")

must({ "git", "-C", F, "revert", "--no-edit", "HEAD" }, ROOT)
must({ "git", "-C", F, "push", "-q", "--no-verify", "origin", "linux-next" }, ROOT)
out, rc = audit(C)
T:arm("7 after reverting the breach the audit reads clean — the remedy clears it",
    rc == 0 and last(out):find("^ok:freeze%-audit:clean:linux%-next:moved=") ~= nil, "rc=" .. tostring(rc) .. " out=[" .. out .. "]")

pf, prc, pferr = preflight()
T:arm("8 (9b) NC: after the revert the preflight passes",
    prc == 0 and last(pf) ~= "blocked:freeze-breached", "rc=" .. tostring(prc) .. " out=[" .. pf .. "] err=[" .. pferr:sub(-600) .. "]")

must({ "git", "-C", C, "remote", "set-url", "origin", W.abs .. "/nowhere.git" }, ROOT)
out, rc = audit(C)
T:arm("9 (8) an unreachable remote -> refused:freeze:unreachable (exit 3), never 'clean'",
    rc == 3 and last(out):find("^refused:freeze:unreachable:") ~= nil, "rc=" .. tostring(rc) .. " out=[" .. out .. "]")

T:finish()
