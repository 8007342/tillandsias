-- @trace spec:init-command, order:1276-2hc6, order:2080-8i25
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- test-windows-host-lane-refusal-controls.lua (ported from the .sh): the two
-- sabotages that show scripts/lua/test-windows-host-lane-refusal.lua goes red
-- for the RIGHT reason. A guard nobody has watched fail is not known to guard.
--   control-1 REMOVED: the refusal call is disabled -> red, "does not call"
--   control-2 MOVED:   the refusal sits below report_runtime_lane -> red on
--                      position, while the text arms stay green (it isolates
--                      position rather than going red everywhere)
-- Each sabotage asserts its own edit landed: a no-op sabotage reads exactly
-- like a passing guard.
-- Verdict: ok:windows-host-lane-refusal-controls:2/2 (0) | violation:… (1)
local SRC = "crates/tillandsias-headless/src/main.rs"
local FIXTURE = "scripts/lua/test-windows-host-lane-refusal.lua"
if not fs.exists(SRC) then verdict.emit("blocked:controls:no-source:" .. SRC, 1) end
if not fs.exists(FIXTURE) then verdict.emit("blocked:controls:no-fixture:" .. FIXTURE, 1) end
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then
    verdict.could_not_run("windows-host-lane-refusal-controls", "no-plan-binary — set TILLANDSIAS_PLAN_BIN")
end

local original = fs.read(SRC)
local stamp = time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local D = "target/plan-scratch/host-lane-controls-" .. stamp
fs.mkdir(D)
local CALL = "    if let Some(refusal) = windows_host_lane_refusal() {"
local LANE = '    report_runtime_lane("--init", debug);'
local problems = {}
local function run(path)
    -- OS is cleared so the behavioural arm (which RUNS --init) stays out of a
    -- sabotage run: these controls are about the structural arms.
    local r = proc.run({ argv = { BIN, "script", "run", FIXTURE }, env = { TILLANDSIAS_HEADLESS_SRC = path, OS = "" }, timeout_ms = 60000 })
    return (r.stdout or "") .. "\n" .. (r.stderr or ""), r.code
end

-- control-1: remove the refusal call.
local removed, nrem = original:gsub(CALL:gsub("%p", "%%%0"), "    if false {", 1)
if nrem ~= 1 then
    problems[#problems + 1] = "control-1-sabotage-changed-nothing"
else
    fs.write(D .. "/removed.rs", removed)
    local out, code = run(D .. "/removed.rs")
    if code == 0 then problems[#problems + 1] = "control-1-fixture-passed-a-source-with-no-refusal-call"
    elseif not text.contains(out, "does not call windows_host_lane_refusal") then problems[#problems + 1] = "control-1-red-for-the-wrong-reason"
    else log.raw("ok: control-1 red when the refusal call is removed") end
end

-- control-2: move the 3-line refusal block below report_runtime_lane.
local src_lines = text.lines(original)
local moved, skip, got, done = {}, 0, false, false
for _, l in ipairs(src_lines) do
    if l == CALL and not got then
        skip = 2; got = true
    elseif skip > 0 then
        skip = skip - 1
    else
        moved[#moved + 1] = l
        if l == LANE and got and not done then
            moved[#moved + 1] = CALL
            moved[#moved + 1] = "        return Err(refusal);"
            moved[#moved + 1] = "    }"
            done = true
        end
    end
end
local moved_src = table.concat(moved, "\n") .. "\n"
if not (got and done) or moved_src == original then
    problems[#problems + 1] = "control-2-sabotage-changed-nothing:got=" .. tostring(got) .. ":done=" .. tostring(done)
else
    fs.write(D .. "/moved.rs", moved_src)
    local out, code = run(D .. "/moved.rs")
    if code == 0 then problems[#problems + 1] = "control-2-a-refusal-below-lane-selection-passed"
    elseif not text.contains(out, "comes AFTER") then problems[#problems + 1] = "control-2-red-for-the-wrong-reason"
    elseif not text.contains(out, "ok: the refusal names the working command") then problems[#problems + 1] = "control-2-text-arms-went-red-too"
    else log.raw("ok: control-2 red on position while the text arms stay green") end
end

if #problems > 0 then
    verdict.emit("violation:windows-host-lane-refusal-controls:" .. table.concat(problems, ","), 1)
end
verdict.emit("ok:windows-host-lane-refusal-controls:2/2", 0)
