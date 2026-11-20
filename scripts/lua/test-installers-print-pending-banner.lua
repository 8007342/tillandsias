-- @trace order:1380-zmpi, order:1639-8gfw, order:2111-inst
--
-- test-installers-print-pending-banner.lua — fixture for the PENDING ACTIONS
-- banner every installer ends with (design: plan/issues/forge-memory-swap-
-- architecture-design-2026-09-26.md section 9.4). Ported from
-- scripts/test-installers-print-pending-banner.sh (2111-inst) onto the
-- scratch.* door, with the same arms. Operator, 2026-09-26: "print some big
-- text with what's pending, like a restart for windows hosts where WSL was just
-- enabled. Linux hosts should just print that sudo command."
--
-- Each installer carries its banner between two exact-once marker lines. The
-- fixture CUTS that block and RUNS it (bash for install.sh and install-macos.sh,
-- PowerShell for install-windows.ps1's formatter) against stubbed inputs.
--   0  each installer has both markers exactly once (could-not-run otherwise)
--   L1 Linux, no helper installed: PENDING: none, and NO sudo line
--   L2 Linux, helper installed, unit absent: the exact sudo line, and no "none"
--   L3 Linux, helper installed, unit present: PENDING: none
--   M1 macOS: PENDING: none, printed rather than omitted
--   E  the banner is the LAST block of each POSIX installer
--   W1 Windows formatter, no items: NOTHING (1639-8gfw)
--   W2 Windows formatter, items: one ">> " line per item, and no "none"
--   W3 Windows wiring: reboot-pending maps to RESTART REQUIRED, and the banner
--      is printed after the install's finally block
-- W1-W2 are a named skip on a host without PowerShell.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-installers-print-pending-banner.lua
-- GRAMMAR ok:pending-banner-fixture:ran=<n> skipped=<k> (exit 0) | refused:pending-banner-fixture:failed=<n> ... (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("pending-banner-fixture")

local w = T:scratch()
local SRC = {}
for _, f in ipairs({ "install.sh", "install-macos.sh", "install-windows.ps1" }) do
    local body = fs.read("scripts/" .. f)
    local nb, ne, cut, inside = 0, 0, {}, false
    for _, l in ipairs(text.lines(body)) do
        if l == "# BEGIN-PENDING-BANNER" then nb = nb + 1; inside = true end
        if inside then cut[#cut + 1] = l end
        if l == "# END-PENDING-BANNER" then ne = ne + 1; inside = false end
    end
    if nb ~= 1 or ne ~= 1 then
        T:cleanup()
        verdict.could_not_run("pending-banner-fixture",
            "markers:" .. f .. ":begin=" .. nb .. ":end=" .. ne .. " (restore the BEGIN/END-PENDING-BANNER lines in scripts/" .. f .. ")")
    end
    SRC[f] = body
    scratch.write(w.leaf .. "/" .. f .. ".cut", table.concat(cut, "\n") .. "\n")
end
T:arm("0 each installer has both banner markers exactly once", true)

local function bash(cut, env) -- -> combined output
    env.PATH = "/usr/bin:/bin"
    local r = proc.run{ argv = { "bash", w.abs .. "/" .. cut }, env = env, timeout_ms = 30000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local idir, unit = w.abs .. "/bin", w.abs .. "/tillandsias-swap@.service"
scratch.mkdir(w.leaf .. "/bin")
local function linux() return bash("install.sh.cut", { INSTALL_DIR = idir, TILLANDSIAS_SWAP_UNIT = unit }) end
local has = text.contains

local o = linux()
T:arm("L1 no helper: PENDING: none, and no sudo line for a command that is not installed",
    has(o, "PENDING: none") and not has(o, "sudo"), o)

scratch.write(w.leaf .. "/bin/tillandsias-install-swap-service", "#!/bin/sh\nexit 0\n")
scratch.chmod(w.leaf .. "/bin/tillandsias-install-swap-service", tonumber("755", 8))
o = linux()
T:arm("L2 helper, no unit: the exact sudo line under PENDING ACTIONS, and no 'none'",
    has(o, "  sudo " .. idir .. "/tillandsias-install-swap-service") and has(o, "PENDING ACTIONS")
        and not has(o, "PENDING: none"), o)

scratch.write(w.leaf .. "/tillandsias-swap@.service", "")
o = linux()
T:arm("L3 unit installed: PENDING: none", has(o, "PENDING: none"), o)

o = bash("install-macos.sh.cut", {})
T:arm("M1 macOS: a PENDING: none banner, printed rather than omitted",
    text.is_match(o, "PENDING ACTIONS") and o:find("PENDING: none", (o:find("PENDING ACTIONS", 1, true) or 1), true) ~= nil, o)

-- E: nothing prints after the banner in the POSIX installers.
for _, f in ipairs({ "install.sh", "install-macos.sh" }) do
    local last = ""
    for _, l in ipairs(text.lines(SRC[f])) do if text.trim(l) ~= "" then last = l end end
    T:arm("E " .. f .. ": the banner is the last block", last == "# END-PENDING-BANNER", "last line: " .. last)
end

-- W3: Windows wiring, from the source (the whole installer cannot run here).
local win = SRC["install-windows.ps1"]
local fin, ban = nil, nil
for i, l in ipairs(text.lines(win)) do
    if l:sub(1, 11) == "} finally {" then fin = i end
    if l:find("Format-PendingBanner -Items", 1, true) then ban = i end
end
T:arm("W3 reboot-pending maps to RESTART REQUIRED",
    has(win, "if ($WslState -eq 'reboot-pending') {") and has(win, "RESTART REQUIRED: WSL was just enabled"),
    "no reboot-pending -> RESTART REQUIRED mapping")
T:arm("W3 the banner is printed after the install's finally block", fin ~= nil and ban ~= nil and ban > fin,
    "finally=" .. tostring(fin) .. " banner=" .. tostring(ban))

-- W1-W2: the PowerShell formatter, where a PowerShell exists.
scratch.write(w.leaf .. "/runw.ps1", table.concat({
    "param([string]$Cut)", ". $Cut", '"---none---"', "Format-PendingBanner -Items @()",
    '"---items---"', "Format-PendingBanner -Items @('RESTART REQUIRED: x', 'SIGN OUT AND BACK IN: y')",
}, "\n") .. "\n")
-- Try each PowerShell by running the formatter itself; a program that is not
-- installed fails to spawn (status ~= "exited"), which is the skip.
local r
for _, c in ipairs({ "pwsh", "powershell" }) do
    if not (r and r.status == "exited") then
        r = proc.run{ argv = { c, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", w.abs .. "/runw.ps1",
            "-Cut", w.abs .. "/install-windows.ps1.cut" }, timeout_ms = 60000 }
    end
end
local skipped = 0
if r.status ~= "exited" then
    out.line("skip:pending-banner-fixture:W1-W2:no-powershell-on-this-host")
    skipped = 2
else
    local po = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    local none, items, sect = {}, {}, nil
    for _, l in ipairs(text.lines(po)) do
        if l == "---none---" then sect = none elseif l == "---items---" then sect = items
        elseif sect and text.trim(l) ~= "" then sect[#sect + 1] = l end
    end
    T:arm("W1 no items: the formatter prints nothing", #none == 0, table.concat(none, "|"))
    local n = 0
    for _, l in ipairs(items) do if l:sub(1, 5) == "  >> " then n = n + 1 end end
    T:arm("W2 two items: two '>> ' lines and no PENDING: none", n == 2 and not has(po, "PENDING: none"), table.concat(items, "|"))
end

-- The established verdict line, which build.sh's caller reads.
T:finish({
    ok = function(n) return "ok:pending-banner-fixture:ran=" .. n .. " skipped=" .. skipped end,
    fail = function(n) return "refused:pending-banner-fixture:failed=" .. n .. " ran=" .. (T.passed + n) .. " skipped=" .. skipped end,
})
