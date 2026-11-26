-- @env PATH HOME
-- @trace order:1232-av4p, order:2390-kivc
--
-- test-stranded-plan-writes.lua — check-stranded-plan-writes.lua, run on a scratch repository
-- whose salvage ref carries ledger writes trunk lacks, names a newer write as would-change, an
-- older claim trunk moved past as superseded, leaves a write equal to trunk alone, and skips a
-- stale snapshot. Ported from the .sh of the same name (2390-kivc, the carried shell-to-lua item).
--
-- Usage: tillandsias-plan script run scripts/lua/test-stranded-plan-writes.lua
-- Verdict: ok:stranded-plan-writes-fixture:<n> arms | violation:... | could-not-run:...:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("stranded-plan-writes-fixture")
local PB = fixture.plan_binary()
if not PB then verdict.emit("could-not-run:stranded-plan-writes-fixture:no-plan-binary", 3) end
local w = T:scratch()
local R, Rr = w.abs .. "/repo", w.rel .. "/repo"
fs.mkdir(Rr .. "/scripts/lua"); fs.mkdir(Rr .. "/plan/index.d")
fs.write(Rr .. "/scripts/lua/check-stranded-plan-writes.lua", fs.read("scripts/lua/check-stranded-plan-writes.lua"))
local function row(id, order) return "    - packet_id: " .. id .. "\n      order: " .. order .. "\n      status: ready\n      title: " .. id .. "\n" end
fs.write(Rr .. "/plan/index.yaml", "plan_index:\n  packets:\n" .. row("alpha", "101-aaaa") .. row("beta", "102-bbbb") .. row("gamma", "103-cccc"))
local function status(id, value, ts, host) return "  - packet_id: " .. id .. "\n    field: status\n    value: " .. value .. "\n    ts: \"" .. ts .. "\"\n    host: " .. host .. "\n" end
fs.write(Rr .. "/plan/index.d/20260920t000000z-close-beta.yaml", "status:\n" .. status("beta", "completed", "2026-09-20T00:00:00Z", "trunkhost"))
local function g(...) return T:must{ "git", "-C", R, "-c", "user.name=f", "-c", "user.email=f@example.invalid", "-c", "commit.gpgsign=false", ... } end
g("init", "-q", "-b", "linux-next"); g("add", "-A"); g("commit", "-q", "-m", "trunk")
g("update-ref", "refs/remotes/origin/linux-next", "HEAD")
g("switch", "-q", "-c", "ref")
fs.write(Rr .. "/plan/index.d/20260925t000000z-forge.yaml", "status:\n" .. status("alpha", "implemented", "2026-09-25T00:00:00Z", "forge") .. status("gamma", "ready", "2026-09-25T00:00:00Z", "forge"))
fs.write(Rr .. "/plan/index.d/20260901t000000z-forge-claim.yaml", "status:\n" .. status("beta", "in_progress", "2026-09-01T00:00:00Z", "forge"))
g("add", "-A"); g("commit", "-q", "-m", "ref")
g("update-ref", "refs/remotes/origin/salvage/forge/x", "HEAD")
g("switch", "-q", "linux-next")
local AUDIT = "salvage-audit: branch=origin/linux-next patterns=refs/heads/salvage/*\n  salvage/forge/x\n"
    .. "    plan/index.d/20260925t000000z-forge.yaml  ref-may-be-AHEAD (predates no branch edit)\n"
    .. "    plan/index.d/20260901t000000z-forge-claim.yaml  ref-may-be-AHEAD (predates no branch edit)\n"
    .. "ok:salvage-audit:1r:1w:2f:branch=origin/linux-next\n"
fs.write(w.rel .. "/audit", AUDIT)
fs.write(w.rel .. "/audit-stale", (AUDIT:gsub("ref%-may%-be%-AHEAD %(predates no branch edit%)", "linux-next-is-AHEAD (stale snapshot)")))
-- The subject, from inside the scratch repository, with the plan binary handed to it.
local function check(audit)
    local r = proc.run{ argv = { PB, "script", "run", "scripts/lua/check-stranded-plan-writes.lua", "--", "--from", w.abs .. "/" .. audit }, cwd = R,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_REPO_ROOT = R, TILLANDSIAS_PLAN_BIN = PB }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    local last = ""
    for l in o:gmatch("[^\n]+") do last = l end
    return o, last
end
local o, last = check("audit")
T:arm("a newer ref write trunk lacks is would-change, named by order and id", text.contains(o, "stranded:would-change:101-aaaa:alpha:ref=implemented:trunk=ready:folded=implemented:"), o)
T:arm("an older ref claim trunk has moved past is superseded, not would-change", text.contains(o, "stranded:superseded:102-bbbb:beta:ref=in_progress:trunk=completed:"), o)
T:arm("a write equal to trunk is not reported", not text.contains(o, ":gamma:"), o)
T:arm("the verdict counts both kinds", last == "ok:stranded-plan-writes:1 would-change, 1 superseded, on 1 ref(s)", last)
local _, last2 = check("audit-stale")
T:arm("a stale snapshot is not a candidate", last2 == "ok:stranded-plan-writes:0 would-change, 0 superseded, on 0 ref(s)", last2)
T:finish()
