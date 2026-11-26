-- @env TILLANDSIAS_INSTALLER_SRC
-- @trace spec:init-command
-- @trace order:1339-r9xv, order:1560-uam3, order:2296-9jg3
--
-- test-installer-reports-wsl-guest-shape.lua — the Windows installer REPORTS
-- the guest shape a user's .wslconfig will produce, NAMES a known-bad ratio
-- with its numbers, and writes .wslconfig only to ensure the swap and reclaim
-- keys, in one function, backup first (1560-uam3). Lua port of the .sh.
--
-- WHY THE ROW EXISTS, measured on yolanda-windows 2026-09-21: with WSL defaults
-- a 16-logical-CPU host ran its guest with ALL 16 vCPUs inside a 4.8 GiB
-- balloon (~320 MB per vCPU) and FOUR consecutive builds were killed for host
-- memory. A FOUR-core machine with processors=4 and autoMemoryReclaim=gradual
-- was never killed once. The difference was entirely configuration.
--
-- ARM 0 IS FIRST ON PURPOSE: every other arm reads the installer source, so a
-- read that fails would report the SUBJECT as broken. It is could-not-run.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installer-reports-wsl-guest-shape.lua
--        TILLANDSIAS_INSTALLER_SRC=<repo-relative path> judges another copy
-- Verdict: ok:installer-reports-wsl-guest-shape:7/7 arms
--        | violation:installer-reports-wsl-guest-shape
--        | could-not-run:wsl-guest-shape:<reason>  (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("installer-reports-wsl-guest-shape")

local function could_not_run(reason)
    out.line("  This is a MEASUREMENT FAILURE, not a verdict on the installer.")
    verdict.emit("could-not-run:wsl-guest-shape:" .. reason, 3)
end

-- ── 0 can this measure at all? ─────────────────────────────────────────────
local SRC = env.get("TILLANDSIAS_INSTALLER_SRC")
if not SRC or SRC == "" then SRC = "scripts/install-windows.ps1" end
if not fs.exists(SRC) then could_not_run("no-installer:" .. SRC) end

-- Comments are stripped: the installer QUOTES the idioms under test while
-- explaining them, and a scan that reads comments refuses the very tree that
-- satisfies it.
local src = fs.read(SRC):gsub("\r\n", "\n")
if src == "" then could_not_run("comment-strip-produced-nothing") end
if src:sub(-1) ~= "\n" then src = src .. "\n" end
local CODE = {}
for line in src:gmatch("(.-)\n") do CODE[#CODE + 1] = (line:gsub("#.*$", "")) end
T:arm("ARM 0: the installer is readable and survives comment-stripping (" .. #CODE .. " lines)", true)

local function any(...)
    for _, line in ipairs(CODE) do
        for _, p in ipairs({ ... }) do
            if line:find(p) then return true end
        end
    end
    return false
end

-- ── 1 it READS the user's .wslconfig ───────────────────────────────────────
T:arm("ARM 1: the installer references .wslconfig (pre-fix: zero mentions)", any("wslconfig"),
    "never mentioned, the pre-fix state")

-- ── 2 it DERIVES the effective shape, not just echoes the file ─────────────
local d = 0
if any("NumberOfLogicalProcessors") then d = d + 1 end
if any("TotalVisibleMemorySize") then d = d + 1 end
if any("%$EffCpus", "EffMemGiB") then d = d + 1 end
T:arm("ARM 2: it derives the effective guest shape from host CPU + memory + config (" .. d .. "/3 signals)",
    d == 3, d .. " of 3 signals (host CPUs, host memory, effective shape)")

-- ── 3 the known-bad ratio is NAMED WITH NUMBERS ────────────────────────────
T:arm("ARM 3: the warning names the ratio AND the measured failure figure", any("320 MB per vCPU"),
    "not named with its measured numbers")

-- ── 4 the [experimental] trap: autoMemoryReclaim under [wsl2] does nothing ─
local trap = false
for _, line in ipairs(CODE) do
    if line:lower():find("appending it to [wsl2] does nothing", 1, true) then trap = true end
end
T:arm("ARM 4: the [experimental] section trap is stated, not assumed", any("experimental") and trap,
    "nothing warns that autoMemoryReclaim under [wsl2] is inert")

-- ── 5 THE USER'S FILE IS WRITTEN IN ONE PLACE, BACKUP FIRST ────────────────
-- memory and processors are never written; the swap and reclaim keys are
-- ensured without asking (operator 2026-10-12, 1560-uam3). Asserted by
-- CARDINALITY: the writes in the whole file equal the writes inside
-- Invoke-WslConfigEnsure, which copies the backup before it writes.
-- Anything may stand between the verb and the path: requiring them adjacent
-- once let `Set-Content $WslCfgPath "x"` through. Inside the function the path
-- is `$Path`; outside it, `$WslCfgPath`.
local VERBS = { "Set%-Content", "Out%-File", "Add%-Content", "Move%-Item", "Remove%-Item", "WriteAllLines", "WriteAllText" }
local function verb_write(line)
    for _, v in ipairs(VERBS) do
        local _, e = line:find(v)
        local rest = e and line:sub(e + 1)
        if rest and (rest:find("$WslCfgPath", 1, true) or rest:find("%$Path%f[^%w_]")) then return true end
    end
    return false
end
local function redirect_write(line)
    local _, e = line:find("$WslCfgPath", 1, true)
    local rest = e and line:sub(e + 1)
    return rest ~= nil and (rest:find("-Value", 1, true) ~= nil or rest:find(">", 1, true) ~= nil)
end

local writes, inside, backup_at, write_at = 0, 0, nil, nil
for _, line in ipairs(CODE) do
    if verb_write(line) then writes = writes + 1 end
    if redirect_write(line) then writes = writes + 1 end
end
local n, on = 0, false
for _, line in ipairs(CODE) do
    if line:find("^function Invoke%-WslConfigEnsure") then on = true end
    if on then
        n = n + 1
        if verb_write(line) then inside = inside + 1 end
        local copy = line:find("Copy%-Item.*%$Path.*tillandsias%-bak") or line:find("Copy%-Item.*%$Path .*%-Destination %$backup")
        if copy and not backup_at then backup_at = n end
        if line:find("WriteAllLines($Path", 1, true) and not write_at then write_at = n end
        if line:find("^}") then break end
    end
end
T:arm("ARM 5: all " .. writes .. " write(s) of .wslconfig sit inside Invoke-WslConfigEnsure, after its backup copy",
    writes > 0 and writes == inside and backup_at ~= nil and write_at ~= nil and backup_at < write_at,
    writes .. " write(s), " .. inside .. " inside, backup at line " .. tostring(backup_at) .. ", write at line " .. tostring(write_at))

-- ── 6 could-not-measure is distinguished from a verdict ────────────────────
T:arm("ARM 6: the installer refuses to advise when it cannot read the host", any("could not read this host"),
    "nothing handles a failed host CPU/memory read")

T:finish{
    ok = function(passed) return "ok:installer-reports-wsl-guest-shape:" .. passed .. "/7 arms" end,
    fail = function() return "violation:installer-reports-wsl-guest-shape" end,
}
