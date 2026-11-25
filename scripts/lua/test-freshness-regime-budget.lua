-- @trace order:1038-d7vw, order:1083-gzqj, order:2373-f26m
--
-- test-freshness-regime-budget.lua — the freshness budget is selected by FILESYSTEM REGIME,
-- and the selection can fail. One global 15000 ms could not serve both: the same script and
-- tree took 725 ms on ext4 and 13,841 ms through MSYS over drvfs. It pins that the budgets
-- stay ORDERED and BRACKETED by those measurements, not their literals: raising the remote
-- one past the pre-fix cost would pass a full regression. Ported from the .sh (2373-f26m).
--
-- Verdict: ok:test-freshness-regime-budget:<n> | violation:freshness-regime-budget:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("freshness-regime-budget")
local SH = fixture.posix_shell()
local BUDGET = "scripts/freshness-regime-budget.sh"
if not fs.exists(BUDGET) then T:skip("absent") end
local r = T:run{ SH, BUDGET, cwd = fixture.repo_root(), env_unset = { "TILLANDSIAS_*" } }
local o = text.trim((r.stdout or "") .. (r.stderr or ""))
local ms, regime, fstype, source = o:match("^freshness%-budget: ms=(%d+) regime=(%a+) fs=([a-z0-9-]+) source=([a-z-]+)$")
local SOURCES = { findmnt = true, ["path-inference"] = true, default = true }
T:arm("the output matches the grammar the litmus step parses", ms and (regime == "native" or regime == "remote") and SOURCES[source], o)

local src = fs.read(BUDGET)
local native, remote = tonumber(src:match("\nBUDGET_NATIVE_MS=(%d+)")), tonumber(src:match("\nBUDGET_REMOTE_MS=(%d+)"))
if not (native and remote) then T:refuse("no-subject", "the BUDGET_*_MS constants moved") end
-- Measured on esme: MSYS over drvfs after the fix, the same before it, and native ext4.
local REMOTE_WORST, PREFIX_REMOTE, NATIVE_WORST = 13841, 25186, 725
T:arm("the remote budget clears its measured worst", remote > REMOTE_WORST, remote)
T:arm("the remote budget still catches the pre-fix quadratic", remote < PREFIX_REMOTE, remote)
T:arm("the native budget clears its measured worst", native > NATIVE_WORST, native)
T:arm("the native budget is tighter than the remote", native < remote, native .. " / " .. remote)

-- Every label of the classifier, mapped to the budget its arm assigns: grepping for the
-- name asks whether a filesystem is MENTIONED, not what it MAPS to, and once let a
-- collapsed classifier through.
local maps, arm_fs = {}, {}
local body = src:match('\ncase "%$fstype" in\n(.-)\nesac') or ""
for l in (body .. "\n"):gmatch("([^\n]*)\n") do
    local labels = l:match("^%s*([%w%*|_%-]+)%)")
    if labels then
        arm_fs = {}
        for f in labels:gmatch("[^|]+") do arm_fs[#arm_fs + 1] = f end
    end
    local b = not l:find("^%s*#") and l:match("BUDGET_(%a+)_MS")
    if b then for _, f in ipairs(arm_fs) do maps[f] = maps[f] or b end end
end
local bad = {}
for _, f in ipairs{ "ext4", "btrfs", "apfs" } do if maps[f] ~= "NATIVE" then bad[#bad + 1] = f .. "=" .. tostring(maps[f]) end end
for _, f in ipairs{ "9p", "drvfs", "cifs", "*" } do if maps[f] ~= "REMOTE" then bad[#bad + 1] = f .. "=" .. tostring(maps[f]) end end
T:arm("native filesystems map to the native budget; crossing and unreadable ones to the remote", #bad == 0, table.concat(bad, " "))
local want = ms and maps[fstype]
if want then
    T:arm("the live selection on this host (" .. fstype .. ") is what the classifier maps", (want == "NATIVE" and regime == "native" and tonumber(ms) == native)
        or (want == "REMOTE" and regime == "remote" and tonumber(ms) == remote), o)
else
    out.line("note: the live-selection arm was not exercised — unclassified fs '" .. tostring(fstype) .. "' on this host")
end

-- The step's own ceiling must sit above the largest budget, or the runner kills the step
-- before it can report. "Cannot read the ceiling" is not "the ceiling is too low".
local LIT = "openspec/litmus-tests/litmus-freshness-inventory-shape.yaml"
local inblk, ceiling, called = false, nil, false
for l in (fs.read(LIT) .. "\n"):gmatch("([^\n]*)\n") do
    if not l:find("^%s*#") then
        if l:find("^%s*%-%s*step:") then inblk = false end
        if l:find("freshness-regime-budget.sh", 1, true) then inblk = true; called = true end
        ceiling = ceiling or (inblk and tonumber(l:match("timeout_ms:%s*(%d+)")))
    end
end
T:arm("the litmus step invokes the budget selector", called, LIT)
T:arm("the step's timeout_ms is readable", ceiling, "none found in the selector's step of " .. LIT)
T:arm("the step's ceiling is above the largest budget", ceiling and ceiling > remote, tostring(ceiling) .. " / " .. remote)
T:finish({ ok = function(n) return "ok:test-freshness-regime-budget:" .. n end })
