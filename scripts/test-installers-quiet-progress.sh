#!/usr/bin/env bash
# @trace order:1420-jmp4
#
# Fixture for PRETTY INSTALLER 9/10: the installers show one clean progress
# bar for the release download instead of curl's raw 12-column meter
# (install.sh) or PowerShell 5's slow, flickering Invoke-WebRequest bar
# (install-windows.ps1).
#
# Each installer carries its download between two exact-once marker lines.
# The fixture CUTS that block and RUNS it against a stub, rather than reading
# the source for the flag: a grep for --progress-bar would pass on a comment.
#
#   0  both installers carry both markers exactly once (could-not-run otherwise)
#   L1 install.sh's download calls curl WITH --progress-bar, and still with
#      -f (fail on HTTP errors) and the output path, via a curl stub that
#      records its argv. PRE-FIX RESULT: FAILS (the bare -fL meter).
#   W1 install-windows.ps1's Save-WithProgress, run for real in PowerShell
#      against a local HTTP listener serving a known payload: the file lands
#      byte-exact, Write-Progress is called with a -PercentComplete that
#      reaches 100 and at least 10 distinct values, and the call is closed
#      with -Completed. PRE-FIX RESULT: FAILS (no such function; the download
#      was a bare Invoke-WebRequest).
#   W2 the palette: where $PSStyle exists (PowerShell 7.2+) the progress bar
#      is styled in the tillandsia leaf green, 38;2;79;138;91 (LEAF in
#      crates/tillandsias-progress-tty). Skipped by name on PowerShell 5.
#   W3 Invoke-WebRequest's own bar is silenced: every Invoke-WebRequest in the
#      script runs with $ProgressPreference = 'SilentlyContinue' in its scope.
#      Run, not read: the SUMS block is cut and executed with Invoke-WebRequest
#      shadowed by a recorder of the caller's $ProgressPreference.
#
# The W arms need PowerShell and skip by name without it.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/quiet-progress-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0; ran=0; skipped=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# ARM 0: the cuts.
cut_block() { # cut_block <file> <NAME>  -> $TMP/<file>.<NAME>.cut[.ps1]
    local src="$REPO_ROOT/scripts/$1" nb ne
    nb="$(grep -cx "# BEGIN-$2" "$src")" || true
    ne="$(grep -cx "# END-$2" "$src")" || true
    if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
        echo "could-not-run:quiet-progress-fixture:markers:$1:$2:begin=$nb:end=$ne"
        echo "fix: restore the BEGIN-$2 / END-$2 lines in scripts/$1" >&2
        exit 3
    fi
    # A PowerShell cut must end in .ps1: PowerShell dot-sources only .ps1 and
    # hands any other file to its shell association, defining nothing.
    local ext=; case "$1" in *.ps1) ext=.ps1 ;; esac
    sed -n "/^# BEGIN-$2$/,/^# END-$2$/p" "$src" > "$TMP/$1.$2.cut$ext"
}
cut_block install.sh ASSET-DOWNLOAD
cut_block install-windows.ps1 PROGRESS-DOWNLOAD
cut_block install-windows.ps1 SUMS-DOWNLOAD
ran=$((ran + 1))

# ARM L1: run install.sh's download with a curl stub that records argv.
stub="$TMP/stub"; mkdir -p "$stub"
cat > "$stub/curl" <<EOF
#!/bin/sh
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TMP/curl.argv"
exit 0
EOF
chmod +x "$stub/curl"
( PATH="$stub:$PATH"; say() { :; }; ASSET=tillandsias-x; BINARY_TMP="$TMP/bin.out"
  RELEASE_BASE=https://example.invalid/r
  . "$TMP/install.sh.ASSET-DOWNLOAD.cut" ) >/dev/null 2>&1
ran=$((ran + 1))
argv="$(cat "$TMP/curl.argv" 2>/dev/null)"
if [ -z "$argv" ]; then
    fail "L1 the download block never called curl"
else
    case "$argv" in *"--progress-bar"*) ;; *) fail "L1 curl ran without --progress-bar (the raw meter): $(printf '%s' "$argv" | tr '\n' ' ')" ;; esac
    case "$(printf '%s' "$argv" | head -1)" in -f*) ;; *) fail "L1 curl lost -f (an HTTP error would save the error page as the binary)" ;; esac
    case "$argv" in *"$TMP/bin.out"*) ;; *) fail "L1 curl no longer writes to BINARY_TMP" ;; esac
fi

PWSH="$(command -v pwsh || command -v powershell || true)"
if [ -z "$PWSH" ]; then
    echo "skip:quiet-progress-fixture:W1-W3:no-powershell-on-this-host" >&2
    skipped=$((skipped + 3))
else
    _win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
    cut_dl="$(_win "$TMP/install-windows.ps1.PROGRESS-DOWNLOAD.cut.ps1")"
    cut_sums="$(_win "$TMP/install-windows.ps1.SUMS-DOWNLOAD.cut.ps1")"
    outdir="$(_win "$TMP")"
    cat > "$TMP/w.ps1" <<'PS'
param([string]$CutDl, [string]$CutSums, [string]$Out)
$ErrorActionPreference = 'Stop'
$script:calls = New-Object System.Collections.ArrayList
function Write-Progress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete = -1, [switch]$Completed)
    [void]$script:calls.Add([pscustomobject]@{ Pct = $PercentComplete; Done = [bool]$Completed })
}
function Say { param([string]$m) }
function Die { param([string]$m) throw "DIE: $m" }

# W3 first, independent of W1: run the SUMS block with Invoke-WebRequest
# recording the caller's $ProgressPreference.
$script:prefs = @()
function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    # The caller's value, by dynamic scoping: a function sees the variables of
    # the scope that called it.
    $script:prefs += $ProgressPreference }
$Base = 'http://127.0.0.1:1'; $Tmp = $Out
try { . $CutSums } catch { }
"W3 prefs=$($script:prefs -join ',')"
Remove-Item Function:\Invoke-WebRequest

# Dot-sourcing the cut also runs its real call with an empty $ZipUrl, which
# dies; the function and the palette are set before that line. Reset the
# recorder so that call's -Completed cannot count toward W1.
try { . $CutDl } catch { }
$script:calls.Clear()
if ($PSStyle) { "W2 style=$($PSStyle.Progress.Style -replace [char]27,'ESC')" } else { "W2 skip" }
if (-not (Get-Command Save-WithProgress -CommandType Function -ErrorAction SilentlyContinue)) {
    "W1 missing"; exit 0
}

# A local listener serving 3 MiB with a Content-Length. Stopped in finally,
# so a failing download can never leave PowerShell waiting on it.
$payload = New-Object byte[] (3MB)
(New-Object System.Random 7).NextBytes($payload)
$port = Get-Random -Minimum 20000 -Maximum 60000
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
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
try {
    Save-WithProgress -Url "http://127.0.0.1:$port/x" -OutFile $file -Activity 'Downloading Tillandsias'
} catch { "W1 error=$_" } finally {
    $listener.Stop(); $ps.Stop(); $ps.Dispose()
}
$got = if (Test-Path $file) { [System.IO.File]::ReadAllBytes($file) } else { [byte[]]@() }
$same = ($got.Length -eq $payload.Length) -and ([Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($payload))
$pcts = @($script:calls | Where-Object { $_.Pct -ge 0 } | ForEach-Object { $_.Pct } | Sort-Object -Unique)
"W1 same=$same distinct=$($pcts.Count) max=$(($pcts | Measure-Object -Maximum).Maximum) completed=$(@($script:calls | Where-Object Done).Count)"
PS
    wout="$("$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(_win "$TMP/w.ps1")" -CutDl "$cut_dl" -CutSums "$cut_sums" -Out "$outdir" 2>&1 | tr -d '\r')"
    ran=$((ran + 1))
    w1="$(printf '%s\n' "$wout" | grep '^W1 ' || true)"
    if [ -z "$w1" ]; then
        fail "W1 Save-WithProgress did not run: $(printf '%s' "$wout" | tail -3 | tr '\n' ' ')"
    else
        same="$(printf '%s' "$w1" | sed -n 's/.*same=\([A-Za-z]*\).*/\1/p')"
        distinct="$(printf '%s' "$w1" | sed -n 's/.*distinct=\([0-9]*\).*/\1/p')"
        max="$(printf '%s' "$w1" | sed -n 's/.*max=\([0-9]*\).*/\1/p')"
        comp="$(printf '%s' "$w1" | sed -n 's/.*completed=\([0-9]*\).*/\1/p')"
        [ "$same" = "True" ] || fail "W1 the downloaded file is not byte-exact ($w1)"
        [ "${distinct:-0}" -ge 10 ] || fail "W1 fewer than 10 distinct percent values ($w1)"
        [ "${max:-0}" = "100" ] || fail "W1 progress never reached 100 ($w1)"
        [ "${comp:-0}" -ge 1 ] || fail "W1 the progress bar was never closed with -Completed ($w1)"
    fi
    ran=$((ran + 1))
    case "$(printf '%s\n' "$wout" | grep '^W2 ')" in
        "W2 skip") echo "skip:quiet-progress-fixture:W2:no-PSStyle-on-this-powershell" >&2; skipped=$((skipped + 1)); ran=$((ran - 1)) ;;
        *"38;2;79;138;91m"*) ;;
        *) fail "W2 the progress bar is not styled leaf green: $(printf '%s\n' "$wout" | grep '^W2 ')" ;;
    esac
    ran=$((ran + 1))
    w3="$(printf '%s\n' "$wout" | grep '^W3 ' || true)"
    case "$w3" in
        "W3 prefs=SilentlyContinue") ;;
        *) fail "W3 Invoke-WebRequest ran with its own progress bar live: ${w3:-no W3 line}" ;;
    esac
fi

if [ "$fails" -gt 0 ]; then
    echo "refused:quiet-progress-fixture:failed=$fails ran=$ran skipped=$skipped"
    exit 1
fi
echo "ok:quiet-progress-fixture:ran=$ran skipped=$skipped"
