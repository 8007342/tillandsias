-- @env PATH HOME
-- @trace order:1211-q9bm, order:251, spec:ci-release, order:2331-8emp
--
-- test-long-running-view-refuses-at-completion.lua — a terminal flip that would strand
-- plan/long-running.md is refused AT THE FLIP, not at someone else's gate. Ported from the .sh
-- of the same name (2331-8emp). Each arm builds a scratch plan/ and runs the binary there.
--
--   1 a terminal flip on a LISTED multi_cycle packet is refused, and writes no fragment
--   2 NC the row absent: allowed          3 NC a non-multi_cycle packet: allowed
--   4 NC a non-terminal flip: allowed     5 the land-time check still runs in the gate
--   6 the refusal and the checker name the same moment
--
-- Usage: tillandsias-plan script run scripts/lua/test-long-running-view-refuses-at-completion.lua
-- Verdict: ok:long-running-completion:<n> arms | violation:... | could-not-run:... (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("long-running-completion")
local PLAN = fixture.plan_binary()
-- Exit 3: the gate step nominates it as its skip; exit 0 would be booked as a pass.
if PLAN == "" then verdict.emit("could-not-run:long-running-completion:no-plan-binary", 3) end
-- 245 is multi_cycle in the committed ledger; 278 is not.
local MC, PLAIN = "245", "278"
local INDEX = fs.read("plan/index.yaml")
local SCHEMA = fs.exists("plan/schema.yaml") and fs.read("plan/schema.yaml") or nil
local function flip(listed, order, status, ...)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/plan/index.d")
    fs.write(d.rel .. "/plan/index.yaml", INDEX)
    if SCHEMA then fs.write(d.rel .. "/plan/schema.yaml", SCHEMA) end
    fs.write(d.rel .. "/plan/long-running.md", "| " .. listed .. " | x | y | z | w |\n")
    local r = T:run{ PLAN, "--index", d.abs .. "/plan/index.yaml", "set-field", order, "status", status, "--evidence", "deadbeef", "--reason", "1211-q9bm fixture probe", ...,
        cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    local n = 0
    for _, f in ipairs(fs.list(d.rel .. "/plan/index.d")) do
        if f:match("%.yaml$") then n = n + 1 end
    end
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, n, "rc=" .. tostring(r.code) .. " fragments=" .. n .. " " .. o:sub(1, 400)
end
local rc, o, n, why = flip(MC, MC, "completed")
T:arm("1a a terminal flip on a listed multi_cycle packet is refused, naming the view", rc ~= 0 and text.contains(o, "still listed in"), why)
T:arm("1b the refusal writes no fragment", n == 0, why)
rc, o, n, why = flip("999999", MC, "completed")
T:arm("2 NC the row absent: allowed, and the fragment is written", rc == 0 and n > 0, why)
rc, o, n, why = flip(PLAIN, PLAIN, "completed")
T:arm("3 NC a listed packet that is not multi_cycle: allowed", rc == 0 and n > 0, why)
rc, o, n, why = flip(MC, MC, "in_progress", "--host", "fixturehost")
T:arm("4 NC a non-terminal flip on a listed packet: allowed", rc == 0 and n > 0, why)
-- A RUN, not a mention: another step names the script in a comment and its STEP_READS.
local runs = fs.read("build.sh"):find('_run_lua_decider "scripts/lua/check%-long%-running%-view%.lua"') ~= nil
for _, f in ipairs(fs.list("scripts/gate-steps.d")) do
    local name = f:match("([^/]+%.step)$")
    if name and text.contains("\n" .. fs.read("scripts/gate-steps.d/" .. name), '\nSTEP_LUA="scripts/lua/check-long-running-view.lua"') then runs = true end
end
T:arm("5 the land-time check still runs in the gate", runs, "no build.sh call or gate step runs check-long-running-view.lua")
T:arm("6 the refusal and the checker name the same moment", text.contains(fs.read("scripts/lua/check-long-running-view.lua"), "commit as the change that moved it")
    and text.contains(fs.read("crates/tillandsias-plan/src/main.rs"), "SAME COMMIT as this status change"), "one side no longer names the commit")
T:finish()
