-- @trace order:1449-4qqu, order:1565-qtuk, order:2254-y7rp
--
-- test-installer-reset-probe.lua — install-windows.ps1's --reset-state probe
-- (gate step 570; the Lua port of scripts/test-installer-reset-probe.sh).
-- The installer carries the probe between two exact-once marker lines; this
-- cuts that block and RUNS it in PowerShell against stub trays (.cmd files,
-- which the probe's cmd.exe line runs like the real exe), then reads
-- $HasResetState.
--
-- SINCE 1565-qtuk THE PROBE IS THE SOFT RESET CALL ITSELF: $HasResetState
-- means "the parser took the flag" (anything but exit 2), and a non-zero
-- verdict of a reset that RAN is the installer's Die, not "this tray predates
-- the flag".
--   markers each exactly once (could-not-run otherwise, exit 3)
--   A unknown flag: prints a refusal, exit 2        -> unsupported
--   B flag accepted, re-init FAILED: exit 1         -> SUPPORTED
--     (RED before 1449-4qqu: read as "predates --reset-state")
--   C flag accepted, re-init ok: exit 0             -> supported
--   D some other failure, no skip line, exit 1      -> SUPPORTED since 1565-qtuk
--     (reading it as "old tray" hides it behind a restart hint)
--
-- Needs PowerShell (powershell or pwsh) AND cmd.exe; skips by name without.
--
-- Verdict: ok:reset-probe-fixture:4 | refused:reset-probe-fixture:failed=<n>
--   | skip:reset-probe-fixture:no-powershell-or-cmd-on-this-host
--   | could-not-run:reset-probe-fixture:markers:begin=<n>:end=<n>
--   | could-not-run:reset-probe-fixture:powershell-probe:<status>:<code>
local fixture = require "common.fixture"
local V = require "common.verdict"
local T = fixture.new("reset-probe-fixture")

local BEGIN, END = "# BEGIN-RESET-PROBE", "# END-RESET-PROBE"
local nb, ne, inside, block = 0, 0, false, {}
-- A CRLF checkout carries the same block.
for line in (fs.read("scripts/install-windows.ps1"):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    if line == BEGIN then nb = nb + 1; inside = true end
    if inside then block[#block + 1] = line end
    if line == END then ne = ne + 1; inside = false end
end
if nb ~= 1 or ne ~= 1 then
    V.emit("could-not-run:reset-probe-fixture:markers:begin=" .. nb .. ":end=" .. ne, 3)
end

local S = T:scratch()
local function win(leaf) return ((S.abs .. (leaf and ("/" .. leaf) or "")):gsub("/", "\\")) end

-- The probe is a script FILE: the runner refuses a shell command string. Only
-- an absent program (spawn_failed) or an absent cmd.exe (exit 9) is the skip;
-- anything else is could-not-run, or a refusal here would read as green.
fs.write(S.rel .. "/has-cmd.ps1", "if (Get-Command cmd.exe -ErrorAction SilentlyContinue) { exit 0 } else { exit 9 }\n")
local PWSH
for _, p in ipairs({ "powershell", "pwsh" }) do
    if not PWSH then
        local r = T:run{ p, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", S.abs .. "/has-cmd.ps1", timeout_ms = 60000 }
        if r.status == "exited" and r.code == 0 then PWSH = p
        elseif r.status == "exited" and r.code == 9 then T:skip("no-powershell-or-cmd-on-this-host")
        elseif r.status ~= "spawn_failed" then
            T:cleanup()
            V.emit("could-not-run:reset-probe-fixture:powershell-probe:" .. tostring(r.status)
                .. ":" .. tostring(r.code or r.why), 3)
        end
    end
end
if not PWSH then T:skip("no-powershell-or-cmd-on-this-host") end

fs.write(S.rel .. "/probe.ps1", table.concat(block, "\n") .. "\n")

local function stub(name, line, code)
    fs.write(S.rel .. "/" .. name .. ".cmd",
        "@echo off\r\necho " .. line .. "\r\nexit /b " .. code .. "\r\n")
end
local SKIP = "[tillandsias] --reset-state: reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0"
    .. " - reprovisioning through the platform's plain init instead."
stub("unknown", "error: unknown flag --reset-state", 2)
stub("failed", SKIP, 1)
stub("ok", SKIP, 0)
stub("other", "panicked at something unrelated", 1)

-- $InstalledExe is the stub; the probe's log goes to $env:TEMP, set to scratch.
fs.write(S.rel .. "/run.ps1", [=[
param([string]$Probe, [string]$Exe)
function Say { param([string]$m) }
function SayWn { param([string]$m) }
$InstalledExe = $Exe
. $Probe
"has=$HasResetState"
]=])

local function expect(name, want, label)
    local r = T:run{ PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win("run.ps1"),
        "-Probe", win("probe.ps1"), "-Exe", win(name .. ".cmd"), env = { TEMP = win() } }
    local got
    for line in ((r.stdout or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
        if line:find("^has=") then got = line end
    end
    T:arm(label, got == "has=" .. want, "expected has=" .. want .. ", got '" .. (got or "no result") .. "' status="
        .. tostring(r.status) .. " code=" .. tostring(r.code) .. " " .. text.trim(r.stderr or ""))
end
expect("unknown", "False", "A unknown flag is unsupported")
expect("failed", "True", "B flag accepted, re-init failed, is SUPPORTED")
expect("ok", "True", "C flag accepted, re-init ok, is supported")
expect("other", "True", "D a failure of a reset that ran is SUPPORTED (the installer Dies on it)")

T:finish{ ok = function(n) return "ok:reset-probe-fixture:" .. n end,
    fail = function(n) return "refused:reset-probe-fixture:failed=" .. n end }
