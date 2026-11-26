-- @env PATH SystemRoot TEMP TMP
-- @trace order:1420-jmp4, order:1640-rutw, order:2379-p5dq
--
-- test-installers-quiet-progress.lua — the installers draw one clean progress bar for the release download.
-- Each download block sits between two exact-once marker lines; it is cut and RUN against a stub, never
-- read for a flag. The W arms need PowerShell and are skipped by name without it: W1 Save-WithProgress
-- against a local listener, W2 the palette (PowerShell 7.2+), W3 Invoke-WebRequest's own bar silenced. A W3
-- that never reached Invoke-WebRequest is refused, never reported as a live bar (1640-rutw).
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installers-quiet-progress.lua
-- Verdict: ok:quiet-progress-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("quiet-progress-fixture")
local SH = fixture.posix_shell()
local W = T:scratch()
local function win(leaf) return W.abs:find("^%a:") and (W.abs .. "/" .. leaf):gsub("/", "\\") or (W.abs .. "/" .. leaf) end

local function cut(file, name)
    local src = "\n" .. fs.read("scripts/" .. file):gsub("\r\n", "\n") .. "\n"
    local from, to = "\n# BEGIN-" .. name .. "\n", "\n# END-" .. name .. "\n"
    local nb, ne = select(2, src:gsub(from:gsub("%-", "%%-"), "")), select(2, src:gsub(to:gsub("%-", "%%-"), ""))
    if nb ~= 1 or ne ~= 1 then T:refuse("markers", file .. ":" .. name .. ":begin=" .. nb .. ":end=" .. ne .. " — restore the BEGIN/END lines") end
    return src:sub(src:find(from, 1, true) + 1, (src:find(to, 1, true)) + #to - 1)
end
local function replaced(s, from, to)
    local a, b = s:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return s:sub(1, a - 1) .. to .. s:sub(b + 1)
end
local ASSET, DL, SUMS = cut("install.sh", "ASSET-DOWNLOAD"), cut("install-windows.ps1", "PROGRESS-DOWNLOAD"), cut("install-windows.ps1", "SUMS-DOWNLOAD")

-- install.sh: the block runs where curl is a function that prints its argv.
local function curl_argv(block)
    local r = T:run{ SH, "-s", stdin = "curl() { for a in \"$@\"; do printf 'arg:%s\\n' \"$a\"; done; }\nsay() { :; }\n"
        .. "ASSET=tillandsias-x; BINARY_TMP=/x/bin.out; RELEASE_BASE=https://example.invalid/r\n" .. block }
    local o = ("\n" .. (r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    local function has(a) return o:find("\narg:" .. a .. "\n", 1, true) ~= nil end
    return { bar = has("--progress-bar"), f = o:match("arg:([^\n]*)") ~= nil and o:match("arg:([^\n]*)"):find("^%-f") ~= nil,
        out = has("/x/bin.out"), url = has("https://example.invalid/r/tillandsias-x"), got = o:gsub("\n", " ") }
end
local c = curl_argv(ASSET)
T:arm("L1 install.sh's curl draws its one bar", c.bar, c.got)
T:arm("L1 it still fails on an HTTP error, and writes the asset it names", c.f and c.out and c.url, c.got)
c = curl_argv(replaced(ASSET, "curl -fL --progress-bar", "curl -fL"))
T:arm("L1 MUTATION without --progress-bar the raw meter is back", not c.bar and c.f, c.got)

local HARNESS = [=[
param([string]$CutDl, [string]$CutSums, [string]$Out)
$ErrorActionPreference = 'Stop'
$script:calls = New-Object System.Collections.ArrayList
function Write-Progress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete = -1, [switch]$Completed)
    [void]$script:calls.Add([pscustomobject]@{ Pct = $PercentComplete; Done = [bool]$Completed })
}
function Say { param([string]$m) }
function Log { param([string]$m) }
function Die { param([string]$m) throw "DIE: $m" }

# W3: the recorder sees its caller's $ProgressPreference, by dynamic scoping.
$script:prefs = @()
function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $script:prefs += $ProgressPreference }
$Base = 'http://127.0.0.1:1'; $Tmp = $Out
$script:w3err = ''
try { . $CutSums } catch { $script:w3err = ($_.Exception.Message -replace '\s+', ' ') }
"W3 prefs=$($script:prefs -join ',')"
if ($script:prefs.Count -eq 0) { "W3 unreached=$script:w3err" }
Remove-Item Function:\Invoke-WebRequest

# Dot-sourcing the cut also runs its real call with an empty $ZipUrl, which dies; the function and the
# palette are set before that. The recorder is reset so that call's -Completed cannot count toward W1.
try { . $CutDl } catch { }
$script:calls.Clear()
if ($PSStyle) { "W2 style=$($PSStyle.Progress.Style -replace [char]27,'ESC')" } else { "W2 skip" }
if (-not (Get-Command Save-WithProgress -CommandType Function -ErrorAction SilentlyContinue)) { "W1 missing"; exit 0 }

$payload = New-Object byte[] (3MB)
(New-Object System.Random 7).NextBytes($payload)
$listener = $null
for ($try = 0; $try -lt 20 -and -not $listener; $try++) {
    $port = Get-Random -Minimum 20000 -Maximum 60000
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    try { $l.Start(); $listener = $l } catch { }
}
if (-not $listener) { "W1 no-port"; exit 0 }
$ps = [powershell]::Create()
[void]$ps.AddScript({
    param($l, $p)
    $ctx = $l.GetContext()
    $ctx.Response.ContentLength64 = $p.Length
    $s = $ctx.Response.OutputStream
    for ($i = 0; $i -lt $p.Length; $i += 65536) { $s.Write($p, $i, [Math]::Min(65536, $p.Length - $i)); $s.Flush() }
    $ctx.Response.Close()
}).AddArgument($listener).AddArgument($payload)
$h = $ps.BeginInvoke()
$file = Join-Path $Out 'dl.bin'
Remove-Item $file -ErrorAction SilentlyContinue
try {
    Save-WithProgress -Url "http://127.0.0.1:$port/x" -OutFile $file -Activity 'Downloading Tillandsias'
} catch { "W1 error=$_" } finally {
    $listener.Stop(); $ps.Stop(); $ps.Dispose()
}
$got = if (Test-Path $file) { [System.IO.File]::ReadAllBytes($file) } else { [byte[]]@() }
$same = ($got.Length -eq $payload.Length) -and ([Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($payload))
$pcts = @($script:calls | Where-Object { $_.Pct -ge 0 } | ForEach-Object { $_.Pct } | Sort-Object -Unique)
"W1 same=$same distinct=$($pcts.Count) max=$(($pcts | Measure-Object -Maximum).Maximum) completed=$(@($script:calls | Where-Object Done).Count)"
]=]
fs.write(W.rel .. "/w.ps1", HARNESS)
fs.write(W.rel .. "/ping.ps1", "'pong'\n")
local PWSH
for _, p in ipairs{ "pwsh", "powershell" } do
    local r = not PWSH and T:run{ p, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win("ping.ps1"), timeout_ms = 60000 }
    if r and text.contains(r.stdout or "", "pong") then PWSH = p end
end
if not PWSH then
    out.line("skip:quiet-progress-fixture:W1-W3:no-powershell-on-this-host")
    T:finish()
end

-- A PowerShell cut must end in .ps1: PowerShell dot-sources nothing else.
local function installer(dl, sums)
    fs.write(W.rel .. "/dl.ps1", dl)
    fs.write(W.rel .. "/sums.ps1", sums)
    local r = T:run{ PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win("w.ps1"), "-CutDl", win("dl.ps1"),
        "-CutSums", win("sums.ps1"), "-Out", (win("."):gsub("[/\\]%.$", "")), timeout_ms = 120000 }
    local o = "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "") .. "\n"
    local same, distinct, max, done = o:match("\nW1 same=(%a+) distinct=(%d*) max=(%d*) completed=(%d*)")
    return { w1 = same ~= nil, same = same == "True", distinct = tonumber(distinct) or 0, max = max, done = tonumber(done) or 0,
        style = o:match("\nW2 ([^\n]*)"), prefs = o:match("\nW3 prefs=([^\n]*)"), unreached = o:match("\nW3 unreached=([^\n]*)"),
        got = o:gsub("\n", " "):sub(1, 400) }
end
local w = installer(DL, SUMS)
T:arm("W1 the downloaded file is byte-exact", w.same, w.got)
T:arm("W1 the bar is drawn in at least 10 steps, reaches 100 and is closed", w.distinct >= 10 and w.max == "100" and w.done >= 1, w.got)
if w.style == "skip" then
    out.line("skip:quiet-progress-fixture:W2:no-PSStyle-on-this-powershell")
else
    T:arm("W2 the bar is leaf green", w.style ~= nil and text.contains(w.style, "38;2;79;138;91m"), w.got)
end
if w.prefs == "" then
    T:refuse("W3-could-not-reach-invoke-webrequest", tostring(w.unreached) .. " — stub the helper the cut calls; this says nothing about the installer")
end
T:arm("W3 Invoke-WebRequest's own bar is silenced", w.prefs == "SilentlyContinue", w.got)
w = installer(replaced(DL, "Write-Progress -Activity $Activity -Completed", ""), replaced(SUMS, "$ProgressPreference = 'SilentlyContinue'", ""))
T:arm("W1 MUTATION a bar that is never closed fails", w.w1 and w.same and w.done == 0, w.got)
T:arm("W3 MUTATION an unsilenced Invoke-WebRequest fails", w.prefs ~= nil and w.prefs ~= "" and w.prefs ~= "SilentlyContinue", w.got)

T:finish()
