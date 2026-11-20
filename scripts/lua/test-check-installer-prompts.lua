-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1560-g5d9, order:1560-uam3, spec:host-state-lifecycle, order:2111-inst
--
-- test-check-installer-prompts.lua — the end-user installer prompt ratchet.
-- Ported from scripts/test-check-installer-prompts.sh (2111-inst) onto the
-- scratch.* door, with the same six arms. Operator ruling 2026-10-08: "we do
-- not ask end users to do power user stuff ... No prompts like those, we make
-- all the decisions for them".
--
-- Runs the REAL scripts/lua/check-installer-prompts.lua as a child over the
-- real tree and over scratch copies of the population
-- (TILLANDSIAS_INSTALLER_PROMPT_ROOT seam):
--   1 the real tree, at the floor                        -> ok
--   2 a `read -r -p ... [y/N]` added to install.sh       -> refused, naming file:line
--   3 a Read-Host added to install-windows.ps1           -> refused, naming file:line
--   4 a prompt quoted only in a comment                  -> ok (comments are stripped)
--   5 a scratch floor above the real count               -> ok, with the lower-the-floor note
--   6 prose "could not read this host's ... guest-shape" -> ok (a false positive
--     the first shell version had, install-windows.ps1:437, 2026-10-08)
-- Each mutant asserts its own edit landed exactly once.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-check-installer-prompts.lua
-- GRAMMAR ok:installer-prompts-fixture:6 (exit 0) | violation:installer-prompts-fixture:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("installer-prompts-fixture")

local ROOT = fixture.repo_root()
local SUT = "scripts/lua/check-installer-prompts.lua"
if not fs.exists(SUT) then T:refuse("decider-missing", SUT) end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
for _, rel in ipairs({ "target/release/tillandsias-plan", "target/debug/tillandsias-plan" }) do
    if (not PLAN or PLAN == "") and fs.exists(rel) then PLAN = ROOT .. "/" .. rel end
end
if not PLAN or PLAN == "" then T:skip("no-script-runner: rebuild it (cargo build --release -p tillandsias-plan)") end

local POP = { "scripts/install.sh", "scripts/install-macos.sh", "scripts/install-windows.ps1" }
local FLOOR = "scripts/portability/installer-prompt-floor.txt"
local CONTENT = {}
for _, p in ipairs(POP) do CONTENT[p] = fs.read(p) end
CONTENT[FLOOR] = fs.read(FLOOR)

local function copy(tag) -- a scratch copy of the population
    local d = T:scratch(tag)
    scratch.mkdir(d.leaf .. "/scripts/portability")
    for p, body in pairs(CONTENT) do scratch.write(d.leaf .. "/" .. p, body) end
    return d
end
local function guard(d) -- -> rc, out
    local env = { TILLANDSIAS_SCRIPT_RUNNER_BIN = PLAN }
    if d then env.TILLANDSIAS_INSTALLER_PROMPT_ROOT = d.abs end
    local r = proc.run{ argv = { PLAN, "script", "run", ROOT .. "/" .. SUT }, cwd = ROOT, env = env, timeout_ms = 60000 }
    return (r.status == "exited") and r.code or -1, text.trim((r.stdout or "") .. (r.stderr or ""))
end
-- Append a line and report whether it now occurs exactly once.
local function append_once(d, p, line)
    local f = d.leaf .. "/" .. p
    scratch.write(f, scratch.read(f) .. line .. "\n")
    local n = 0
    for _, l in ipairs(text.lines(scratch.read(f))) do if l == line then n = n + 1 end end
    return n == 1
end

local rc, o = guard(nil)
T:arm("1 the real tree is at the floor", rc == 0, "rc=" .. rc .. " " .. o)

local d = copy("a")
local landed = append_once(d, "scripts/install.sh", 'read -r -p "Continue? [y/N] " answer')
rc, o = guard(d)
T:arm("2 a new read -p is refused by file:line", landed and rc == 1 and text.contains(o, "scripts/install.sh:"),
    "landed=" .. tostring(landed) .. " rc=" .. rc .. " " .. o)

d = copy("b")
landed = append_once(d, "scripts/install-windows.ps1", '$x = Read-Host "Proceed"')
rc, o = guard(d)
T:arm("3 a new Read-Host is refused by file:line", landed and rc == 1 and text.contains(o, "scripts/install-windows.ps1:"),
    "landed=" .. tostring(landed) .. " rc=" .. rc .. " " .. o)

d = copy("c")
landed = append_once(d, "scripts/install.sh", '# never do: read -p "Continue? [y/N] "')
rc, o = guard(d)
T:arm("4 a commented prompt does not count", landed and rc == 0, "landed=" .. tostring(landed) .. " rc=" .. rc .. " " .. o)

-- 5: the real installers have no prompt left (1560-uam3 took the floor to 0),
-- so the scratch floor is raised to 1 instead of a prompt being removed.
d = copy("d")
scratch.write(d.leaf .. "/" .. FLOOR, "# scratch floor for arm 5\n1\n")
rc, o = guard(d)
T:arm("5 below the floor passes and asks for the floor to drop", rc == 0 and text.is_match(o, "lower.*floor"),
    "rc=" .. rc .. " " .. o)

d = copy("e")
landed = append_once(d, "scripts/install.sh", [[say "  could not read this host's CPU/memory; no guest-shape advice given."]])
rc, o = guard(d)
T:arm("6 prose with read ... -shape is not a prompt", landed and rc == 0, "landed=" .. tostring(landed) .. " rc=" .. rc .. " " .. o)

T:finish({ ok = function(n) return "ok:installer-prompts-fixture:" .. n .. " arms" end })
