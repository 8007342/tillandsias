-- @trace order:2267-6ss8
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- inputs: scripts/lua/check-gate-step-not-also-inline.lua scripts/lua/test-gate-step-not-also-inline.lua build.sh scripts/gate-steps.d/
--
-- test-gate-step-not-also-inline.lua — check-gate-step-not-also-inline.lua on
-- scratch copies of build.sh and scripts/gate-steps.d/.
--   1 LIVE     today's tree: no script runs both inline and as a step
--   2 MUTANT   the inline test-land-queue.sh block re-added (the 2026-09-28 ..
--              2266-4w3c duplicate of step 286) -> refused, naming the
--              script and the step. PRE-FIX: no guard saw it.
--   3 LUA      an inline _run_lua_decider duplicating a STEP_LUA step -> refused
--   4 COMMENT  a commented-out inline line is not a run -> passes
--
-- Verdict: ok:gate-step-not-also-inline-fixture:<n> arms | violation:…:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-step-not-also-inline-fixture")
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = fixture.plan_binary() end
if PLAN == "" then verdict.could_not_run("gate-step-not-also-inline-fixture", "no plan binary") end
local ROOT = fixture.repo_root()
local BUILD = fs.read("build.sh")
local STEPS = {}
for _, f in ipairs(fs.list(ROOT .. "/scripts/gate-steps.d")) do
    local name = f:match("([^/]+)$")
    if name:match("%.step$") then STEPS[name] = fs.read("scripts/gate-steps.d/" .. name) end
end
local W = T:scratch("inline")
local n = 0
-- check(extra): the decider over a copy of the tree with `extra` appended to
-- build.sh's --check branch (inserted after its opening line).
local function check(extra)
    n = n + 1
    local rel, abs = W.rel .. "/t" .. n, W.abs .. "/t" .. n
    fs.mkdir(rel .. "/scripts/gate-steps.d")
    local b = BUILD
    if extra then
        local open = 'if [[ "$FLAG_CHECK" == true ]]; then\n'
        local i = b:find(open, 1, true)
        assert(i, "build.sh has no --check branch opening")
        b = b:sub(1, i + #open - 1) .. extra .. b:sub(i + #open)
    end
    fs.write(rel .. "/build.sh", b)
    for name, body in pairs(STEPS) do fs.write(rel .. "/scripts/gate-steps.d/" .. name, body) end
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-gate-step-not-also-inline.lua" }, cwd = ROOT,
        env = { TILLANDSIAS_GATE_STEP_INLINE_ROOT = abs }, timeout_ms = 60000 }
    return r, (r.stdout or "") .. (r.stderr or "")
end

local r1, o1 = check(nil)
T:arm("1 LIVE no script runs both inline and as a gate step on this tree",
    r1.status == "exited" and r1.code == 0 and o1:find("ok:gate-step-not-also-inline:", 1, true) ~= nil, o1:sub(1, 300))

local LQ = '    _step "Checking test-land-queue (1316-bnzt, 1255-s4im; ~14s)..."\n'
    .. '    if ! _run bash "$SCRIPT_DIR/scripts/test-land-queue.sh" 2>&1; then\n'
    .. '        _error "scripts/test-land-queue.sh failed"\n        exit 1\n    fi\n'
local r2, o2 = check(LQ)
T:arm("2 MUTANT the inline test-land-queue.sh block re-added is refused, naming the script and step 286",
    r2.status == "exited" and r2.code ~= 0
        and o2:find("violation:gate-step-not-also-inline:scripts/test-land-queue.sh: gate step 286-", 1, true) ~= nil,
    "rc=" .. tostring(r2.code) .. " " .. o2:sub(1, 300))

-- 3: a Lua step's script run inline by _run_lua_decider
local lua_step
for name, body in pairs(STEPS) do
    local s = body:match('\nSTEP_LUA="([^"]+)"') or body:match('^STEP_LUA="([^"]+)"')
    if s and (not lua_step or name < lua_step[1]) then lua_step = { name, s } end
end
local r3, o3 = check('    if ! _run_lua_decider "' .. lua_step[2] .. '" 2>&1; then\n        exit 1\n    fi\n')
T:arm("3 LUA an inline _run_lua_decider duplicating a STEP_LUA step is refused",
    r3.status == "exited" and r3.code ~= 0
        and o3:find("violation:gate-step-not-also-inline:" .. lua_step[2] .. ": gate step " .. lua_step[1], 1, true) ~= nil,
    "rc=" .. tostring(r3.code) .. " " .. o3:sub(1, 300))

local r4, o4 = check('    # if ! _run bash "$SCRIPT_DIR/scripts/test-land-queue.sh" 2>&1; then\n')
T:arm("4 COMMENT a commented-out inline line is not a run",
    r4.status == "exited" and r4.code == 0, "rc=" .. tostring(r4.code) .. " " .. o4:sub(1, 300))

T:finish()
