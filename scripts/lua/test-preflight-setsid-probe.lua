-- @trace spec:build-script-architecture, order:1352-vmbc, order:2282-asxn
--
-- test-preflight-setsid-probe.lua — order 1352-vmbc, ported from the .sh of the
-- same name (2282-asxn); same four arms, same verdict words.
--
-- WHAT IT PROTECTS. `./build.sh --preflight` ran every guard under `setsid`
-- unconditionally. `setsid` is util-linux. MEASURED on macOS before the fix:
--     ./build.sh: line 316: exec: setsid: not found
--     refused:preflight:ran=0 skipped=3 failed=108 wall=26s
-- and 108 identical launch failures read as 108 refusals. After:
--     refused:preflight:ran=94 skipped=16 failed=1 isolation=none-no-setsid
--
-- WHY SOURCE SHAPE. The live run is 150 s, which a front-door step cannot be;
-- this pins that the pieces producing it cannot be removed silently.
--   1 PROBE      the runner asks whether setsid exists and caches it. Keyed on
--                the ASSIGNMENT: `command -v setsid` also occurs in the summary
--                line, and that looser needle did not red when the probe went
--   2 FALLBACK   a branch runs the guard WITHOUT setsid (1384-bqhy: as the
--                runner array, which is bash unless the guard is .lua)
--   3 NAMED      BOTH summary lines carry the isolation mode, anchored on the
--                verdict prefix and the variable (1353-ryhq moved the body)
--   4 RATIONALE  the measured reason setsid is there survives
--   5 MUTANTS    each arm's needle removed from a copy of build.sh reds that arm
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-setsid-probe.lua
-- Verdict: ok:preflight-setsid-probe:<n> arms | violation:preflight-setsid-probe:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("preflight-setsid-probe")
local SRC = fs.read("build.sh")

local function has(s, x) return s:find(x, 1, true) ~= nil end
local function line_with(s, prefix, var)
    for _, l in ipairs(text.lines(s)) do
        local a = l:find(prefix, 1, true)
        if a and l:find(var, a, true) then return true end
    end
    return false
end
local PROBE = '_PF_SETSID=setsid; else _PF_SETSID=""'
local BARE = 'cd "$SCRIPT_DIR" && exec "${_runner[@]}"'
local RUNNER = 'local -a _runner=(bash "$_p")'
local WHY = "setsid + background makes pid == pgid"
local ARMS = {
    { "1 PROBE the guard runner probes for setsid", function(s) return has(s, PROBE) end, { PROBE } },
    { "2 FALLBACK a branch runs the guard without setsid", function(s) return has(s, BARE) and has(s, RUNNER) end, { BARE, RUNNER } },
    { "3 NAMED both summary lines name the isolation mode", function(s)
        return line_with(s, 'echo "ok:preflight:', "$_pf_iso") and line_with(s, 'echo "refused:preflight:', "$_pf_iso")
    end, { 'echo "ok:preflight:', 'echo "refused:preflight:' } },
    { "4 RATIONALE the measured reason for setsid survives", function(s) return has(s, WHY) end, { WHY } },
}
local toothless = {}
for _, a in ipairs(ARMS) do
    T:arm(a[1], a[2](SRC), "not found in build.sh")
    for _, needle in ipairs(a[3]) do
        local cut = SRC:gsub(needle:gsub("%p", "%%%0"), "")
        if a[2](cut) then toothless[#toothless + 1] = a[1]:sub(1, 1) .. ":" .. needle end
    end
end
T:arm("5 MUTANTS each needle removed reds its arm", #toothless == 0, table.concat(toothless, " | "))
T:finish()
