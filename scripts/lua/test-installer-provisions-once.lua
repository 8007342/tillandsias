-- @env PATH SystemRoot TEMP TMP
-- @trace order:1565-qtuk, order:1323-5taw, spec:host-state-lifecycle, order:2367-d5gx
--
-- test-installer-provisions-once.lua — one install-windows.ps1 install provisions the guest ONCE, and
-- that once is the SOFT reset. The capability probe used to run under TILLANDSIAS_DESTRUCTIVE_RESET_OK=0,
-- which skips the wipe and still provisions, so every install provisioned twice. The reset path is cut
-- from the installer and RUN in PowerShell against a stub tray that logs what it did. Ported from the
-- .sh of the same name; arm 4 (the --help liar) came with test-installer-probes-by-attempt-not-by-help.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installer-provisions-once.lua
-- Verdict: ok:provisions-once-fixture:<n> arms | violation:...:<n>-failed
--        | skip:provisions-once-fixture:no-powershell-or-cmd-on-this-host

local fixture = require "common.fixture"
local T = fixture.new("provisions-once-fixture")
local SRC = "scripts/install-windows.ps1"
local src = fs.read(SRC):gsub("\r\n", "\n")
local at = src:find("\n# BEGIN-RESET-PROBE\n", 1, true)
local stop = at and src:find("\n    # -- Installed-Software registration", at, true)
if not stop then T:refuse("markers-missing") end
local PATH_PS1 = src:sub(at + 1, stop)
local W = T:scratch()
local function win(leaf) return (W.abs .. (leaf and ("/" .. leaf) or "")):gsub("/", "\\") end

fs.write(W.rel .. "/has-cmd.ps1", "if (Get-Command cmd.exe -ErrorAction SilentlyContinue) { exit 0 } else { exit 9 }\n")
local PWSH
for _, p in ipairs{ "powershell", "pwsh" } do
    if not PWSH then
        local r = T:run{ p, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", W.abs .. "/has-cmd.ps1", timeout_ms = 60000 }
        if r.status == "exited" and r.code == 0 then PWSH = p
        elseif r.status == "exited" and r.code == 9 then T:skip("no-powershell-or-cmd-on-this-host")
        elseif r.status ~= "spawn_failed" then T:refuse("powershell-probe", tostring(r.status) .. ":" .. tostring(r.code)) end
    end
end
if not PWSH then T:skip("no-powershell-or-cmd-on-this-host") end

-- kind=tray behaves like reset_state_once; unknown predates the flag; liar also advertises it in --help.
fs.write(W.rel .. "/tray.cmd", table.concat({ "@echo off",
    'echo call>>"%STUB_LOG%"',
    'if "%1"=="--help" goto help',
    'if "%STUB_KIND%"=="unknown" goto unknown',
    'if "%STUB_KIND%"=="liar" goto unknown',
    'if "%TILLANDSIAS_DESTRUCTIVE_RESET_OK%"=="0" goto skip',
    "echo [tillandsias] reset: SOFT",
    'echo wipe>>"%STUB_LOG%"',
    'echo provision>>"%STUB_LOG%"',
    "exit /b %STUB_EXIT%",
    ":skip",
    "echo [tillandsias] --reset-state: reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0",
    'echo provision>>"%STUB_LOG%"',
    "exit /b %STUB_EXIT%",
    ":help",
    'if not "%STUB_KIND%"=="unknown" echo   --reset-state  resets',
    "exit /b 0",
    ":unknown",
    "echo error: unknown flag --reset-state",
    "exit /b 2", "" }, "\r\n"))
fs.write(W.rel .. "/run.ps1", [=[
param([string]$Path, [string]$Exe)
function Say   { param([string]$m) "say:$m" }
function SayOk { param([string]$m) "ok:$m" }
function SayWn { param([string]$m) "warn:$m" }
function Log   { param([string]$m) "log:$m" }
function Die   { param([string]$m) "die:$m"; exit 1 }
Remove-Item Env:TILLANDSIAS_DESTRUCTIVE_RESET_OK -ErrorAction SilentlyContinue
$InstalledExe = $Exe
. $Path
"end"
]=])
local function count(s, word) return select(2, s:gsub("%f[%a]" .. word .. "%f[%A]", "")) end
local function install(kind, code, body)
    fs.write(W.rel .. "/stub.log", "")
    fs.write(W.rel .. "/path.ps1", body or PATH_PS1)
    local r = T:run{ PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win("run.ps1"), "-Path", win("path.ps1"), "-Exe", win("tray.cmd"),
        env = { PATH = env.get("PATH"), TEMP = win(), STUB_KIND = kind, STUB_EXIT = tostring(code), STUB_LOG = win("stub.log") } }
    local log = fs.read(W.rel .. "/stub.log")
    local o = "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return { calls = count(log, "call"), provisions = count(log, "provision"), wipes = count(log, "wipe"), out = o,
        got = "calls=" .. count(log, "call") .. " provisions=" .. count(log, "provision") .. " wipes=" .. count(log, "wipe") .. " " .. o:sub(1, 400) }
end
local function died(x) return x.out:find("\ndie:", 1, true) ~= nil end
local function restart(x) return x.out:find("\nwarn:[^\n]*Restart it from the Start menu") ~= nil and not died(x) end

local x = install("tray", 0)
T:arm("1 a supporting tray is provisioned once, through the SOFT reset", x.provisions == 1 and x.wipes == 1 and not died(x)
    and text.contains(x.out, "\nok:Tillandsias is ready"), x.got)
x = install("tray", 1)
T:arm("2 a failed provisioning is reported with the setup log, never retried", x.provisions == 1 and x.wipes == 1
    and x.out:find("\ndie:[^\n]*tillandsias%-setup%.log") ~= nil, x.got)
x = install("unknown", 2)
T:arm("3 a tray that rejects the flag: nothing provisioned, the restart line, no Die", x.provisions == 0 and x.calls == 1 and restart(x), x.got)
x = install("liar", 2)
T:arm("4 a tray that advertises the flag and refuses it is unsupported too", x.provisions == 0 and x.calls == 1 and restart(x), x.got)

-- MUTATION
local function mutant(from, to)
    local a, b = PATH_PS1:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return PATH_PS1:sub(1, a - 1) .. to .. PATH_PS1:sub(b + 1)
end
local CALL = '    & cmd.exe /c "`"$InstalledExe`" --reset-state'
x = install("tray", 0, mutant(CALL, '    $env:TILLANDSIAS_DESTRUCTIVE_RESET_OK = "0"\n    & cmd.exe /c "`"$InstalledExe`" --reset-state < NUL"\n'
    .. "    Remove-Item Env:TILLANDSIAS_DESTRUCTIVE_RESET_OK\n" .. CALL))
T:arm("5 MUTATION the guarded probe provisions twice", x.provisions == 2 and x.wipes == 1, x.got)
x = install("liar", 2, mutant("$HasResetState = ($ResetExit -ne 2)",
    [[$HasResetState = ((& cmd.exe /c "`"$InstalledExe`" --help" | Out-String) -match '--reset-state')]]))
T:arm("5 MUTATION a decision read from --help Dies on the liar", died(x) and not restart(x), x.got)

T:finish()
