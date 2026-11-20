-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1924-dobj, order:2106-scrt
--
-- test-prune-darwin-stale-objects.lua — fixture for
-- scripts/lua/prune-darwin-stale-objects.lua. Ported from
-- scripts/test-prune-darwin-stale-objects.sh (2106-scrt), same seven arms:
-- a loose .o group with its executable beside it is kept; a group with no
-- executable (a library, whose code is in its rlib) is pruned; nothing that
-- is not a .rcgu.o is touched; a second run prunes nothing; a build holding
-- the shared lock makes the prune skip; once it lets go the prune runs.
--
-- The holder is THIS process (scratch.lock shared) and the prune is a child
-- process, so the interlock measured is the real cross-process flock.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-prune-darwin-stale-objects.lua
-- GRAMMAR ok:prune-darwin-stale-objects:7 (exit 0) | violation:prune-darwin-stale-objects:<n>-failed (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("prune-darwin-stale-objects")

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then
    T:skip("no-plan-binary (TILLANDSIAS_SCRIPT_RUNNER_BIN or TILLANDSIAS_PLAN_BIN)")
end
local PRUNE = fixture.repo_root() .. "/scripts/lua/prune-darwin-stale-objects.lua"

local w = T:scratch()
local deps = w.leaf .. "/debug/deps"
scratch.mkdir(deps)

local exe = "demo_tests-0123456789abcdef"
local lib = "demo_lib-fedcba9876543210"
scratch.write(deps .. "/" .. exe, "")
scratch.chmod(deps .. "/" .. exe, tonumber("755", 8))
for i = 1, 3 do
    scratch.write(deps .. "/" .. exe .. ".cgu" .. i .. ".s1.rcgu.o", "")
    scratch.write(deps .. "/" .. lib .. ".cgu" .. i .. ".s1.rcgu.o", "")
end
scratch.write(deps .. "/lib" .. lib .. ".rlib", "")
scratch.write(deps .. "/" .. lib .. ".d", "")
scratch.write(deps .. "/lib" .. lib .. ".rmeta", "")

local function prune()
    local r = proc.run{ argv = { PLAN, "script", "run", PRUNE, w.abs .. "/debug/deps" }, timeout_ms = 60000 }
    return r.stdout or "", r.code
end
local function has(s, line) return text.contains(s, line) end

local o = prune()
T:arm("reports three files in one pruned group, one kept",
    has(o, "pruned:darwin-stale-objects:files=3 groups=1 kept=1\n"), o)
T:arm("the executable's own objects are kept",
    scratch.exists(deps .. "/" .. exe .. ".cgu1.s1.rcgu.o") and scratch.exists(deps .. "/" .. exe .. ".cgu3.s1.rcgu.o"))
local left = false
for _, n in ipairs((scratch.list(deps))) do
    if n:sub(1, #lib + 1) == lib .. "." and n:sub(-7) == ".rcgu.o" then left = true end
end
T:arm("the library's loose objects are pruned", not left)
T:arm("rlib, rmeta and dep-info are untouched",
    scratch.exists(deps .. "/lib" .. lib .. ".rlib") and scratch.exists(deps .. "/lib" .. lib .. ".rmeta")
    and scratch.exists(deps .. "/" .. lib .. ".d"))
o = prune()
T:arm("a second run prunes nothing", has(o, "pruned:darwin-stale-objects:files=0 groups=0 kept=1\n"), o)

-- A build that holds the shared lock makes the prune skip and keep its files.
scratch.write(deps .. "/" .. lib .. ".cgu9.s2.rcgu.o", "")
local holder = scratch.lock(w.leaf .. "/.tillandsias-prune.lock", { shared = true, timeout_ms = 1000 })
if not holder then T:refuse("setup-failed", "could not take the shared holder lock") end
o = prune()
T:arm("a concurrent shared holder makes the prune skip",
    has(o, "skipped:darwin-stale-objects:") and scratch.exists(deps .. "/" .. lib .. ".cgu9.s2.rcgu.o"), o)
holder:release()
o = prune()
T:arm("once the holder is gone the prune runs", has(o, "pruned:darwin-stale-objects:files=1 groups=1 kept=1\n"), o)

T:finish()
