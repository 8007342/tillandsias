<#
.SYNOPSIS
    One-shot Tillandsias tray health check consuming `tillandsias-tray
    --diagnose --json`.

.DESCRIPTION
    Runs the installed (or local-build) tray with `--diagnose --json`, parses
    the machine-readable report, and prints a colorized PASS / FAIL line per
    check. A real consumer that demonstrates the JSON schema's utility -- the
    same JSON can be uploaded to a support endpoint or fed into a richer
    dashboard.

    Distinct from `diagnose-windows.ps1` (a no-VM-required pre-tray host-facts
    diagnostic). This one assumes the tray binary exists and queries its own
    `--diagnose` instead of re-implementing the checks.

    Search order for `tillandsias-tray.exe` (first match wins):
      1. -ExePath argument (if provided).
      2. %LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe
         (the path scripts\install-windows.ps1 installs to).
      3. `Get-Command tillandsias-tray.exe` (PATH).
      4. <repo>\target\release\tillandsias-tray.exe (dev build).
      5. <repo>\target\debug\tillandsias-tray.exe   (dev build).

    Exit codes mirror the tray's `--diagnose` contract:
      0 - distro registered AND control wire reachable AND phase Ready.
      2 - degraded (the tool ran end-to-end but at least one check failed).
      1 - could not locate or invoke tillandsias-tray.exe.

    @trace spec:windows-native-tray

.PARAMETER ExePath
    Explicit path to tillandsias-tray.exe. Overrides the default search order.

.EXAMPLE
    scripts\tray-diagnose.ps1
    scripts\tray-diagnose.ps1 -ExePath C:\path\to\tillandsias-tray.exe
#>
[CmdletBinding()]
param(
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'

function Resolve-TrayExe {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "specified -ExePath not found: $Explicit"
    }
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\Tillandsias\tillandsias-tray.exe'
    if (Test-Path $installed) { return $installed }
    $onPath = Get-Command 'tillandsias-tray.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($prof in @('release','debug')) {
        $candidate = Join-Path $repoRoot "target\$prof\tillandsias-tray.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    throw "tillandsias-tray.exe not found. Install via scripts\install-windows.ps1, build via scripts\build-windows-tray.ps1, or pass -ExePath."
}

function Write-Check {
    param([string]$Label, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host '  PASS ' -NoNewline -ForegroundColor Green
    } else {
        Write-Host '  FAIL ' -NoNewline -ForegroundColor Red
    }
    if ($Detail) { Write-Host "$Label : $Detail" } else { Write-Host $Label }
}

# --- run + parse ---------------------------------------------------------------
$exe = Resolve-TrayExe -Explicit $ExePath
Write-Host 'tillandsias-tray health check'
Write-Host '============================='
Write-Host "Using exe: $exe"
Write-Host

# NOTE: the release tray is a GUI-subsystem binary; PowerShell's `&` capture of
# its stdout is unreliable (large writes from `println!` can be silently
# dropped). cmd.exe handles native stdio directly, so we route through it via
# a temp file. See cheatsheets/runtime/windows-tray-diagnostics.md.
$tmp = Join-Path $env:TEMP "tray-diagnose-$([guid]::NewGuid().ToString('N')).json"
& cmd.exe /c "`"$exe`" --diagnose --json > `"$tmp`" 2>nul"
$trayExit = $LASTEXITCODE
$raw = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
Remove-Item $tmp -ErrorAction SilentlyContinue
if (-not $raw) {
    Write-Host "FAIL : --diagnose --json produced no output (exit $trayExit)" -ForegroundColor Red
    exit 1
}
try {
    $report = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "FAIL : --diagnose --json output is not valid JSON ($_)" -ForegroundColor Red
    exit 1
}

# --- checks --------------------------------------------------------------------
$failures = 0
Write-Host 'Identity:'
Write-Check 'version           ' $true $report.version
$commit = if ($report.build_commit) { $report.build_commit } else { '(unknown)' }
Write-Check 'build commit      ' $true $commit
$installPath = if ($report.install_path) { $report.install_path } else { '(unknown)' }
Write-Check 'install path      ' $true $installPath
$logSizeDetail = if ($null -ne $report.log_size_bytes) { "$($report.log_path) ($($report.log_size_bytes) bytes)" } else { $report.log_path }
Write-Check 'log file exists   ' $report.log_exists $logSizeDetail
if (-not $report.log_exists) { $failures++ }

Write-Host "`nWindows host:"
# Surface OS + WSL versions for triage. Locale-as-is — the bracketed
# version payload is invariant across locales.
$osVersion = if ($report.os_version) { $report.os_version } else { '(not detected)' }
Write-Check 'OS version        ' $true $osVersion
$wslVersion = if ($report.wsl_version) { $report.wsl_version } else { '(not detected)' }
Write-Check 'WSL version       ' ([bool]$report.wsl_version) $wslVersion
if (-not $report.wsl_version) { $failures++ }
Write-Check 'wt.exe present    ' $report.wt_present
if (-not $report.wt_present) { $failures++ }
Write-Check 'distro registered ' $report.distro_registered $report.distro
if (-not $report.distro_registered) { $failures++ }
# distro_running flips frequently because WSL2 idles VMs down; it's NOT a
# failure when false. Surface as informational.
$runDetail = if ($report.distro_running) { 'yes (VM up)' } else { 'no (idled -- normal when no tray session keepalives the VM)' }
Write-Check 'distro running    ' $true $runDetail

Write-Host "`nRecipe / artifact:"
Write-Check 'release tag       ' $true $report.release_tag
$pin = $report.manifest_pin_x86_64_tar_xz
$pinDetail = if ($pin) { "x86_64.tar $pin..." } else { '(not found)' }
Write-Check 'manifest pin      ' ([bool]$pin) $pinDetail
if (-not $pin) { $failures++ }

Write-Host "`nControl wire:"
$wireOk = $report.wire.reachable -and ($report.wire.phase -eq 'Ready') -and $report.wire.podman_ready
Write-Check 'reachable         ' $report.wire.reachable
Write-Check 'phase Ready       ' ($report.wire.phase -eq 'Ready') $report.wire.phase
Write-Check 'podman ready      ' ([bool]$report.wire.podman_ready)
if (-not $wireOk) {
    $failures++
    if ($report.wire.error) {
        Write-Host "  -> error: $($report.wire.error)" -ForegroundColor Yellow
    }
}

# Recent log activity (sourced from the in-report recent_log_tail field —
# 20 lines max). Useful for triaging "tray was up earlier and went south"
# scenarios. If the operator wants more, `tillandsias-tray --logs --tail N`
# dumps the full log to stdout.
if ($report.recent_log_tail -and $report.recent_log_tail.Count -gt 0) {
    Write-Host "`nRecent log activity (last $($report.recent_log_tail.Count) line(s) of tray.log):"
    foreach ($line in $report.recent_log_tail) {
        Write-Host "  $line" -ForegroundColor DarkGray
    }
}

Write-Host
# Surface BOTH verdicts: the binary's --diagnose exit (which gates on the
# strict wire-readiness invariant: distro registered + wire reachable +
# phase Ready) AND the script's own classification (which gates on the
# wider host-machinery invariant: + WSL + wt.exe + manifest pin). The
# two can disagree — the script is intentionally stricter — and showing
# both lets an operator see WHY.
$binVerdict = switch ($trayExit) {
    0 { 'HEALTHY' }
    2 { 'DEGRADED' }
    default { "UNKNOWN (exit $trayExit)" }
}
Write-Host "Binary --diagnose exit: $trayExit ($binVerdict)" -ForegroundColor DarkGray
if ($failures -eq 0) {
    Write-Host 'Script verdict: HEALTHY (0 failures)' -ForegroundColor Green
    exit 0
} else {
    Write-Host "Script verdict: DEGRADED ($failures failure(s)) - run 'tillandsias-tray --provision-once' to provision" -ForegroundColor Yellow
    exit 2
}
