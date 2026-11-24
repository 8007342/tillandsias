-- @trace spec:windows-native-tray, order:624-cf9f, order:2301-eny9, order:2306-3hr6
--
-- Fixture for scripts/lua/check-windows-tray-diagnose-surface.lua (order 624-cf9f).
-- Lua port of the .sh.
--
-- The check replaced eight grep-for-a-function-name litmus steps with one that
-- RUNS the tests. That is stronger only if it can be shown to fail: a guard
-- nobody has watched fail is not known to guard anything (622-rmit's own words).
-- Every verdict in its grammar is proven reachable here, including the two that
-- only occur when the toolchain is broken, because misreporting THAT was the
-- first version's bug: it named a specific test as missing when the truth was
-- that cargo never ran.
--
-- Usage: tillandsias-plan script run scripts/lua/test-windows-tray-diagnose-surface.lua
-- Verdict: ok:windows-tray-diagnose-surface:8 arms
--        | violation:windows-tray-diagnose-surface:<n>
--        | refused:windows-tray-diagnose-surface:<reason>

local fixture = require "common.fixture"
local T = fixture.new("windows-tray-diagnose-surface")
local ROOT = fixture.repo_root()
local CHECK = "scripts/lua/check-windows-tray-diagnose-surface.lua"
if not fs.exists(CHECK) then T:refuse("check-not-found", CHECK) end

-- A transcript with every pinned test passing. Generated from the real list so
-- the fixture cannot drift away from what the check demands.
local LINES, inside = {}, false
for line in (fs.read(CHECK):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    if line:find("^local PINNED_TESTS = {") then inside = true
    elseif line:find("^}") then inside = false
    elseif inside then
        local name = line:match("^    \"([a-z_]+)\",")
        if name then LINES[#LINES + 1] = "test notify_icon::tests::" .. name .. " ... ok" end
    end
end
if #LINES == 0 then T:refuse("no-pinned-tests-read", CHECK) end

-- `edit` maps a line to its replacement, or to nil to drop it.
local function transcript(edit)
    local t = {}
    for _, line in ipairs(LINES) do
        local l = line
        if edit then l = edit(line) end
        if l then t[#t + 1] = l end
    end
    t[#t + 1] = "test result: ok. 40 passed; 0 failed; 0 ignored"
    return table.concat(t, "\n")
end

local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()
local function run(output)
    fs.write(W.rel .. "/transcript", output)
    local r = T:run{ PLAN, "script", "run", CHECK, cwd = ROOT,
        env = { TRAY_DIAGNOSE_FIXTURE_FILE = W.rel .. "/transcript" } }
    return text.trim(r.stdout or ""), r.code
end

local out1 = run(transcript())
T:arm("case 1: a passing run verifies the surface",
    out1:find("ok:diagnose-surface-verified:", 1, true) == 1, out1)

-- NEGATIVE CONTROL: this is what the eight grep steps were protecting, so the
-- replacement must still catch it.
local out2, rc2 = run(transcript(function(l)
    if l:find("status_once_json_keys_pinned", 1, true) then return nil end
    return l
end))
T:arm("case 2: a missing pinned test is caught and named",
    out2 == "violation:diagnose-surface:missing-test:status_once_json_keys_pinned", out2)

-- NEGATIVE CONTROL: the grep steps could not see this at all. A test whose name
-- is present and whose body is red passed every one of them.
local out3 = run(transcript(function(l)
    if l == "test notify_icon::tests::exit_code_separates_healthy_converging_and_degraded ... ok" then
        return (l:gsub("ok$", "FAILED"))
    end
    return l
end))
T:arm("case 3: a failing pinned test is caught (the grep could not see this)",
    out3 == "violation:diagnose-surface:tests-failed:exit_code_separates_healthy_converging_and_degraded", out3)

-- Smart App Control intermittently blocks freshly built unsigned binaries.
-- Reporting that as a missing test sends the next agent hunting for a deleted
-- function that is still there.
local out4, rc4 = run("error: command failed: 'cargo': An Application Control policy has blocked this file. (os error 4551)")
T:arm("case 4: a blocked toolchain skips rather than accusing a test",
    out4 == "skip:diagnose-surface-unverifiable:windows-toolchain-blocked", out4)

local out5 = run("warning: unused import\n    Finished")
T:arm("case 5: no test results is reported as such",
    out5 == "skip:diagnose-surface-unverifiable:no-test-run", out5)

-- A skip must exit 0 so a non-Windows lane is not failed by it.
T:arm("case 6: a skip exits 0 and a violation exits non-zero",
    rc4 == 0 and rc2 ~= nil and rc2 ~= 0, "skip rc=" .. tostring(rc4) .. " violation rc=" .. tostring(rc2))

-- 2306-3hr6: the runner refusing the crate or its arguments is a red. The first
-- line is what cargo says to --lib, which the check read as an ordinary skip.
local out7, rc7 = run("error: no library targets found in package `tillandsias-windows-tray`")
T:arm("case 7: a cargo refusal is a violation, not a skip",
    out7:find("violation:diagnose-surface:runner-failed", 1, true) ~= nil and rc7 == 1, out7)

local out8 = run("error: linker `link.exe` not found\nerror: could not compile `x`")
T:arm("case 8: a host with no linker skips by name",
    out8 == "skip:diagnose-surface-unverifiable:linker-absent", out8)

T:finish()
