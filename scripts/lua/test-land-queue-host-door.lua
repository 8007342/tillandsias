-- @trace order:2118-tpmy, spec:ci-release
-- @env PATH HOME TILLANDSIAS_PLAN_BIN
--
-- test-land-queue-host-door.lua — litmus:land-queue-host-door-names-its-cause.
-- Operator 2026-11-20 (P11): the landing queue asks scripts/lua/land-queue-host-door.lua
-- before every candidate, and a host problem is could-not-run:host:<cause> —
-- never an eviction. Each cause is forced through the door's own seams
-- (floors, meminfo, the dirs df reads, the checkout root), and one arm per
-- cause asserts its token and exit code 3; the healthy host answers ok (0).
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-host-door.lua
-- Verdict: ok:land-queue-host-door:<n> arms | violation:land-queue-host-door:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("land-queue-host-door")
local ROOT = fixture.repo_root()
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")

-- A scratch checkout with a staged sidecar, so only the forced cause fails.
local R = T:git_repo("checkout")
fs.mkdir(R.rel .. "/images/router")
fs.write(R.rel .. "/images/router/tillandsias-router-sidecar", "sidecar\n")
local M = T:scratch("meminfo")
-- one file per (total, free): the default and an override must not share one
local function meminfo(total, free)
    local name = "meminfo-" .. total .. "-" .. free
    fs.write(M.rel .. "/" .. name, "MemTotal: 16000000 kB\nSwapTotal: " .. total .. " kB\nSwapFree: " .. free .. " kB\n")
    return M.abs .. "/" .. name
end

local function door(extra)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"),
        TILLANDSIAS_HOST_DOOR_ROOT = R.abs, TILLANDSIAS_HOST_DOOR_TMP_DIR = R.abs,
        TILLANDSIAS_HOST_DOOR_MEMINFO = meminfo(1000, 900),
        TILLANDSIAS_HOST_DOOR_DISK_GB = "0", TILLANDSIAS_HOST_DOOR_TMP_GB = "0" }
    for k, v in pairs(extra or {}) do e[k] = v end
    local argv = { PLAN or "tillandsias-plan", "script", "run", ROOT .. "/scripts/lua/land-queue-host-door.lua" }
    argv.env = e
    argv.cwd = ROOT
    local r = T:run(argv)
    return text.trim(r.stdout or ""), r.code
end

local v, c = door()
T:arm("a healthy host answers ok:host-door (exit 0)", text.starts_with(v, "ok:host-door:") and c == 0, v .. " rc=" .. tostring(c))

v, c = door{ TILLANDSIAS_HOST_DOOR_DISK_GB = "99999999" }
T:arm("disk under the floor is could-not-run:host:disk-low (exit 3)",
    text.starts_with(v, "could-not-run:host:disk-low:") and c == 3, v .. " rc=" .. tostring(c))

v, c = door{ TILLANDSIAS_HOST_DOOR_TMP_GB = "99999999" }
T:arm("/tmp under the floor is could-not-run:host:tmp-low (exit 3)",
    text.starts_with(v, "could-not-run:host:tmp-low:") and c == 3, v .. " rc=" .. tostring(c))

v, c = door{ TILLANDSIAS_HOST_DOOR_MEMINFO = meminfo(1000, 100) }
T:arm("swap 10% free under a 25% floor is could-not-run:host:swap-low (exit 3)",
    text.starts_with(v, "could-not-run:host:swap-low:") and c == 3, v .. " rc=" .. tostring(c))

v, c = door{ TILLANDSIAS_HOST_DOOR_MEMINFO = meminfo(0, 0) }
T:arm("a host with no swap configured is not refused for swap", text.starts_with(v, "ok:host-door:"), v)

-- The sidecar: only on Linux (the door asks uname, as the gate's staging does).
local uname = T:run{ "uname", "-s" }
if text.trim(uname.stdout or "") == "Linux" then
    T:run{ "rm", "-f", R.abs .. "/images/router/tillandsias-router-sidecar" }
    v, c = door()
    T:arm("an unstaged router sidecar is could-not-run:host:sidecar-missing (exit 3)",
        text.starts_with(v, "could-not-run:host:sidecar-missing:") and c == 3, v .. " rc=" .. tostring(c))
    v = door{ TILLANDSIAS_HOST_DOOR_REQUIRE_SIDECAR = "0" }
    T:arm("TILLANDSIAS_HOST_DOOR_REQUIRE_SIDECAR=0 skips the sidecar check", text.starts_with(v, "ok:host-door:"), v)
    fs.write(R.rel .. "/images/router/tillandsias-router-sidecar", "sidecar\n")
end

-- A worktree git already knows is gone (its directory removed behind git's back).
local WT = R.abs .. "/../" .. R.leaf .. "-gone-wt"
T:must{ "git", "-C", R.abs, "worktree", "add", "-q", "--detach", WT }
T:run{ "rm", "-rf", WT }
v, c = door()
T:arm("a prunable worktree is could-not-run:host:stale-worktrees (exit 3)",
    text.starts_with(v, "could-not-run:host:stale-worktrees:") and c == 3, v .. " rc=" .. tostring(c))
T:run{ "git", "-C", R.abs, "worktree", "prune" }
v = door()
T:arm("after git worktree prune the door answers ok again", text.starts_with(v, "ok:host-door:"), v)

T:finish()
