-- @trace spec:ci-release, order:2150-vf2v
--
-- check-cycle-metrics-fixtures-pin-logs.lua — priority:build-speed.
-- A fixture that runs scripts/cycle-metrics.sh must pin every metrics log the
-- script reads. Defaulted, each one is this host's real .cache/metrics log, so
-- the fixture's cost grows with the host's history. MEASURED 2026-11-21 on
-- macuahuitl: test-token-instrument took 118 s against a 95 MB usage log and
-- 3 s with the three logs pinned to empty scratch files (lenovinha reproduced
-- 5 s -> 265 s with a 100 MB synthetic usage log).
--
-- Rule: every scripts/test-*.sh and scripts/lua/test-*.lua that names
-- cycle-metrics.sh names all of PINNED, unless EXEMPT lists it with a reason.
-- A new fixture therefore pins by default; an exemption is a reviewed line.
--
-- Usage: tillandsias-plan script run scripts/lua/check-cycle-metrics-fixtures-pin-logs.lua [-- <file>...]
-- Verdict: ok:cycle-metrics-fixtures-pin-logs:<n> checked
--        | violation:cycle-metrics-fixtures-pin-logs:<n>-unpinned (exit 1)

local NAME = "cycle-metrics-fixtures-pin-logs"
local PINNED = { "TILLANDSIAS_EXPERT_USAGE_LOG", "TILLANDSIAS_CYCLE_FLOW_LOG", "TILLANDSIAS_EXPERT_HEALTH_LOG" }

-- Each exemption says why the fixture never runs the reporting path.
local EXEMPT = {
    ["scripts/test-metrics-log-path-agreement.sh"] = "tests how the DEFAULT paths resolve; pinning would erase its subject",
    ["scripts/lua/test-cycle-flow-emit-idempotency.lua"] = "emit-only (--emit-flow, its own FLOW_LOG); never reports",
    ["scripts/lua/test-timing-record-carries-reproduced.lua"] = "emit-only (--emit-timing / --emit-timing-batch); never reports",
    ["scripts/lua/test-mcp-transport-death-trace.lua"] = "quotes the outage grep as text; never runs the script",
    ["scripts/test-tool-dispatch-lib.sh"] = "lists the script as a converted file; never runs it",
    ["scripts/lua/test-gate-step-private-metrics-fallback.lua"] = "names it in prose only; never runs it",
}

-- Explicit paths (`-- <file>...`) are checked as given, exemptions and all:
-- the litmus negative control hands it a planted unpinned fixture.
local files = {}
local args = arg or {}
if #args > 0 then
    for _, a in ipairs(args) do files[#files + 1] = a end
else
    local r = proc.run({ argv = { "git", "grep", "-l", "-F", "cycle-metrics.sh", "--",
        "scripts/test-*.sh", "scripts/lua/test-*.lua" }, timeout_ms = 30000 })
    if r.code ~= 0 and r.code ~= 1 then
        verdict.could_not_run(NAME, "git grep rc=" .. tostring(r.code))
    end
    files = text.lines(r.stdout or "")
end

local checked, bad = 0, 0
for _, f in ipairs(files) do
    if f ~= "" and not EXEMPT[f] then
        checked = checked + 1
        local body = fs.read(f)
        if body == nil then verdict.could_not_run(NAME, "unreadable:" .. f) end
        if not text.contains(body, "cycle-metrics.sh") then checked = checked - 1; goto continue end
        local missing = {}
        for _, v in ipairs(PINNED) do
            if not text.contains(body, v) then missing[#missing + 1] = v end
        end
        if #missing > 0 then
            bad = bad + 1
            out.line("REFUSED: " .. f .. " runs cycle-metrics.sh but leaves defaulted: " .. table.concat(missing, " "))
        end
    end
    ::continue::
end
if bad > 0 then
    out.line("  Pin each to an empty scratch file (see scripts/test-token-instrument.sh, order 2150-vf2v),")
    out.line("  or add the fixture to EXEMPT in this file with the reason it never reports.")
    verdict.emit("violation:" .. NAME .. ":" .. bad .. "-unpinned", 1)
end
verdict.ok(NAME, checked .. " checked")
