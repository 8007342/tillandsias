-- @trace order:1500-gu5r, order:1518-8p5k, order:2181-dlcp, spec:ci-release
-- @env PATH HOME TILLANDSIAS_PREFLIGHT_TIMEOUT TILLANDSIAS_DOOR_DECIDER_DIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-deciders-within-door-deadline.lua — the push deciders that used to
-- outlive the preflight door's 5 s deadline each finish inside it, run exactly
-- as the door runs a guard: its own session (setsid), stdin closed, a 5 s
-- bound. Ported from the .sh of the same name (order 2181-dlcp); same
-- population, same per-decider lines, same outcome.
--
-- Measured on yoga 2026-09-29 before -> after: check-bash-dialect 14.5 -> 3.7 s,
-- check-terminology 19 -> 0.1 s, check-all-fragments-intact 14.3 -> 0.6 s,
-- check-carry-forward 13 -> <1 s, check-plan-binary-probe-usage 6.0 -> 0.5 s.
-- A decider that hits the bound fails BY NAME with its measured time, so a
-- regression names the guard that grew instead of reddening the door's budget.
--
-- ORDER 1518-8p5k (coordinator ruling 2026-09-30): check-groundtruth-regime-
-- invariance is DECLARED, not timed. Its floor is one live synthesis, a host
-- property, and it carries `# preflight: gate-only-decider — <reason>` so the
-- door names it instead of deadline-skipping it. It must not drop out of this
-- list in silence: its declaration is ASSERTED, and removing it turns this red.
--
-- Usage: tillandsias-plan script run scripts/lua/test-deciders-within-door-deadline.lua
-- Verdicts:
--   ok:deciders-within-door-deadline:<n>/<n>                     exit 0
--   violation:deciders-within-door-deadline:<ok>/<n>             exit 1

local NAME = "deciders-within-door-deadline"
local DEADLINE = env.get("TILLANDSIAS_PREFLIGHT_TIMEOUT")
if DEADLINE == nil or DEADLINE == "" then DEADLINE = "5" end
local DECIDERS = { "check-bash-dialect", "check-terminology", "check-all-fragments-intact",
    "check-carry-forward", "check-plan-binary-probe-usage" }
local DECLARED = { "check-groundtruth-regime-invariance" }
local DIR = env.get("TILLANDSIAS_DOOR_DECIDER_DIR")
if DIR == nil or DIR == "" then DIR = "scripts" end

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then PLAN = "tillandsias-plan" end
local E = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local function run(argv, ms) return proc.run({ argv = argv, env = E, timeout_ms = ms or 60000 }) end
-- Probe setsid by running it: proc.run denies `sh -c`, so a `command -v`
-- probe through sh reads "absent" on every host and silently drops the
-- session the door runs each guard in.
local setsid = run({ "setsid", "--version" }).status == "exited"
out.line("note: setsid=" .. tostring(setsid))

local fail, n = 0, 0
for _, d in ipairs(DECIDERS) do
    n = n + 1
    -- 1384-ddua: a ported decider is scripts/lua/<d>.lua on the one runner.
    local argv = { "timeout", "-k", "1", DEADLINE }
    if setsid then argv[#argv + 1] = "setsid" end
    if fs.exists("scripts/lua/" .. d .. ".lua") then
        for _, a in ipairs({ PLAN, "script", "run", "scripts/lua/" .. d .. ".lua" }) do argv[#argv + 1] = a end
    else
        for _, a in ipairs({ "bash", "scripts/" .. d .. ".sh" }) do argv[#argv + 1] = a end
    end
    local t0 = time.now_ms()
    local r = run(argv, (tonumber(DEADLINE) + 5) * 1000)
    local took = math.floor((time.now_ms() - t0) / 1000)
    if r.code == 124 or r.code == 137 then
        log.raw("FAIL: " .. d .. " outlived the " .. DEADLINE .. "s door deadline (" .. took .. "s) — the door would skip it, not refuse")
        fail = fail + 1
    else
        out.line("ok:   " .. d .. " finished inside the door deadline (" .. took .. "s, rc=" .. tostring(r.code) .. ")")
    end
end

local hooks = ""
for _, h in ipairs(fs.list("scripts/hooks") or {}) do hooks = hooks .. (fs.read("scripts/hooks/" .. h) or "") end
for _, d in ipairs(DECLARED) do
    n = n + 1
    local decl = nil
    local lines = text.lines(fs.read(DIR .. "/" .. d .. ".sh") or "")
    for i = 1, math.min(40, #lines) do
        local m = lines[i]:match("^# preflight: gate%-only%-decider%s*(.*)$")
        if m then decl = m:gsub("^—%s*", ""):gsub("^%-%s*", ""); break end
    end
    if decl == nil or decl == "" then
        log.raw("FAIL: " .. d .. " is neither timed nor declared — it lost its '# preflight: gate-only-decider — <reason>' line, so the door would deadline-skip it in silence (1518-8p5k)")
        fail = fail + 1
    elseif text.contains(hooks, d .. ".sh") then
        log.raw("FAIL: " .. d .. " declares gate-only-decider but a pre-push hook runs it; the door ignores the declaration and deadline-skips it (1518-8p5k)")
        fail = fail + 1
    else
        out.line("ok:   " .. d .. " is declared gate-only-decider (the door names it; the gate runs it): " .. decl)
    end
end
if fail > 0 then verdict.emit("violation:" .. NAME .. ":" .. (n - fail) .. "/" .. n, 1) end
verdict.ok(NAME, n .. "/" .. n)
