-- @env PATH HOME
-- @trace spec:meta-orchestration, spec:methodology-accountability, order:974-uk95, order:2326-b52d
--
-- test-mo-full-record-precedes-marker.lua — a valid MO-FULL marker is not printable unless
-- THIS cycle wrote its durable ledger record. Ported from the .sh of the same name
-- (2326-b52d). It reproduces the measured sequence (lenovinha 2026-09-03): `record` refused on
-- an unpushed HEAD, the retry loop landed the work without re-running it, and `self` printed
-- COMPLETE, correctly, with no ledger line for the cycle.
--
-- The ledger line names the WORK head, never the head holding the ledger commit: appending it
-- moves HEAD. So arm 5 asserts that the recorded head is an ANCESTOR of the attested one.
--
-- Usage: tillandsias-plan script run scripts/lua/test-mo-full-record-precedes-marker.lua
-- Verdict: ok:mo-full-record-precedes-marker:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("mo-full-record-precedes-marker")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local remote, repo, b = T:scratch("remote"), T:git_repo(), T:scratch("boundary")
T:must{ "git", "init", "-q", "--bare", remote.abs }
local function git(...) return text.trim(T:must{ "git", "-C", repo.abs, ... }.stdout) end
local function commit(file, message)
    if file then fs.write(repo.rel .. "/" .. file, message .. "\n") end
    git("add", "."); git("commit", "-q", "-m", message)
    return git("rev-parse", "HEAD")
end
git("switch", "-q", "-c", "work"); git("remote", "add", "origin", remote.abs); git("push", "-q", "origin", "work")
local LEDGER, LREL = repo.abs .. "/ledger.md", repo.rel .. "/ledger.md"

local function run(script, args, disposition)
    local argv = { SH, "-s", "--", ROOT .. "/scripts/" .. script }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = repo.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        stdin = "unset ${!MO_FULL_@}\nexport MO_FULL_HOST=fixture-host" .. (disposition and " MO_FULL_DISPOSITION=" .. disposition or "") .. '\nexec bash "$@" </dev/null\n' }
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local boundary = 0
local function snapshot() boundary = boundary + 1; run("meta-orchestration-worktree-guard.sh", { "snapshot", b.abs .. "/" .. boundary }) end
local function verify() run("meta-orchestration-worktree-guard.sh", { "verify", b.abs .. "/" .. boundary }) end
local function attest(...) local _, o = run("mo-full-attest.sh", { ... }); return o end
local function self_() return attest("self", "5") end
local function record() return attest("record", LEDGER, "5") end
local function ledger() return fs.exists(LREL) and fs.read(LREL) or "" end
local function complete(o, head) return o == "MO-FULL: COMPLETE " .. head .. " work " .. head end
local NONE = "wrote no durable ledger record"

snapshot()
local work = commit("work.txt", "the cycle's work")
-- Finalization verifies the boundary BEFORE recording, or that precondition masks the case.
verify()
local o = record()
T:arm("1 record refuses an unpushed HEAD and leaves no ledger", text.contains(o, "not durably on origin") and ledger() == "", o)
git("push", "-q", "origin", "work"); verify()
o = self_()
T:arm("2 THE DEFECT: landed without a record, the marker refuses", text.contains(o, NONE), o)
o = record()
T:arm("3 record after the push succeeds and names the work head", complete(o, work) and text.contains(ledger(), work), o)
local terminal = commit(nil, "record(mo-full)")
git("push", "-q", "origin", "work"); verify()
o = self_()
T:arm("4 the terminal marker prints for the head that holds the ledger", complete(o, terminal), o)
T:arm("5 the ledger names the work head, an ancestor of the attested one, and never the terminal head", work ~= terminal
    and not text.contains(ledger(), terminal) and T:run{ "git", "-C", repo.abs, "merge-base", "--is-ancestor", work, terminal }.code == 0, ledger())
snapshot()
commit("more.txt", "second cycle work"); git("push", "-q", "origin", "work"); verify()
o = self_()
T:arm("6 a previous cycle's record does not license this cycle's marker", text.contains(o, NONE), o)
local _, blocked = run("mo-full-attest.sh", { "self", "5" }, "BLOCKED")
T:arm("7 BLOCKED needs no record", blocked:sub(1, 16) == "MO-FULL: BLOCKED", blocked)
T:finish()
