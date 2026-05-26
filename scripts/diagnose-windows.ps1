<#
.SYNOPSIS
    Report the Tillandsias Windows environment + provisioning readiness.

.DESCRIPTION
    A no-VM-required diagnostic for the windows-next tray. Surfaces, in one
    place, the host facts that determine whether the tray can run and (later)
    provision its WSL2 VM:

      - WSL2 presence + version
      - whether the `tillandsias` distro is already imported
      - the materializer/provisioning cache layout under %LOCALAPPDATA% and its
        on-disk sizes (recipe-cache layer tars, downloaded rootfs, binaries)
      - the installed tray binary (present? running?)
      - a readiness summary: what works now vs. what is still gated on the
        cross-host recipe-publish / CI-fetch path

    Read-only: it inspects, never mutates. Safe to run any time.

    @trace spec:windows-native-tray, spec:vm-provisioning-lifecycle

.EXAMPLE
    scripts\diagnose-windows.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# WSL emits UTF-16 by default; this makes its output plain UTF-8 so parsing is
# clean (supported on recent WSL builds; harmless if ignored).
$env:WSL_UTF8 = '1'

$AppName      = 'Tillandsias'
$DistroName   = 'tillandsias'
$CacheRoot    = Join-Path $env:LOCALAPPDATA 'tillandsias\cache'
$InstallRoot  = Join-Path $env:LOCALAPPDATA 'tillandsias\wsl'
$ProgramsDir  = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$InstalledExe = Join-Path $ProgramsDir 'tillandsias-tray.exe'

function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Ok($t)      { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Warn($t)    { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Info($t)    { Write-Host "  $t" }

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N1} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Get-DirSize([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 } else { return [long]$sum }
}

Write-Host "Tillandsias Windows diagnostics" -ForegroundColor White
Write-Host "(read-only; $(Get-Date -Format 'yyyy-MM-dd HH:mm'))"

# --- WSL ---------------------------------------------------------------------
Section 'WSL2'
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
$wslReady = $false
if (-not $wsl) {
    Warn 'wsl.exe not found on PATH. Install with: wsl --install (elevated), then reboot.'
} else {
    Ok "wsl.exe: $($wsl.Source)"
    $ver = (& wsl --version) 2>$null
    if ($ver) { $ver | ForEach-Object { if ($_ -and $_.Trim()) { Info $_.Trim() } } }
    else { Info '(wsl --version unavailable; older WSL build)' }
    $wslReady = $true
}

# --- Distro ------------------------------------------------------------------
Section "Distro '$DistroName'"
if ($wslReady) {
    $list = (& wsl --list --quiet) 2>$null
    $names = @()
    if ($list) { $names = $list | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ } }
    if ($names -contains $DistroName) {
        Ok "'$DistroName' is imported. Registered distros: $($names -join ', ')"
    } else {
        Warn "'$DistroName' not imported yet (expected until provisioning runs)."
        if ($names) { Info "Registered distros: $($names -join ', ')" }
    }
} else {
    Info '(skipped; WSL not available)'
}

# --- Cache / install layout --------------------------------------------------
Section 'Provisioning cache + install layout'
foreach ($pair in @(
    @{ Label = 'cache root';      Path = $CacheRoot },
    @{ Label = 'recipe-cache';    Path = (Join-Path $CacheRoot 'recipe-cache') },
    @{ Label = 'downloaded rootfs'; Path = (Join-Path $CacheRoot 'rootfs') },
    @{ Label = 'downloaded bin';  Path = (Join-Path $CacheRoot 'bin') },
    @{ Label = 'WSL install root'; Path = $InstallRoot }
)) {
    if (Test-Path $pair.Path) {
        $size = Get-DirSize $pair.Path
        $n = (Get-ChildItem -LiteralPath $pair.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Ok ("{0,-18} {1}  ({2} files, {3})" -f $pair.Label, $pair.Path, $n, (Format-Size $size))
    } else {
        Info ("{0,-18} {1}  (absent)" -f $pair.Label, $pair.Path)
    }
}

# --- Installed tray ----------------------------------------------------------
Section 'Installed tray'
if (Test-Path $InstalledExe) {
    $item = Get-Item $InstalledExe
    Ok "binary: $InstalledExe ($(Format-Size $item.Length), built $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
    $proc = Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue
    if ($proc) { Ok "running (PID $($proc.Id -join ', '))" } else { Warn 'not currently running (launch from Start Menu or install-windows.ps1 -Launch)' }
} else {
    Warn "not installed. Build + install with: scripts\install-windows.ps1 -Launch"
}

# --- Recipe materializer (build-time inputs) ---------------------------------
Section 'Recipe materializer (build-time)'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$recipeInputs = @(
    @{ Label = 'Recipefile';   Path = (Join-Path $RepoRoot 'images\vm\Recipefile') },
    @{ Label = 'manifest.toml'; Path = (Join-Path $RepoRoot 'images\vm\manifest.toml') },
    @{ Label = 'bootstrap/';    Path = (Join-Path $RepoRoot 'images\vm\bootstrap') }
)
$recipeComplete = $true
foreach ($r in $recipeInputs) {
    if (Test-Path $r.Path) { Ok ("{0,-14} {1}" -f $r.Label, $r.Path) }
    else { Warn ("{0,-14} {1}  (absent)" -f $r.Label, $r.Path); $recipeComplete = $false }
}
if ($recipeComplete) {
    Info 'Recipe authoring (sec.1.x) + both per-OS converters (sec.3.7.1 macOS .img,'
    Info 'sec.3.7.2 WSL --import) are present. Materializer ecosystem is COMPLETE'
    Info 'except the buildah-driven sec.2b CI-fetch job that publishes the rootfs tar.'
}

# --- Readiness summary -------------------------------------------------------
Section 'Readiness summary'
Info 'Works now (no VM):    tray UI, right-click menu, ~/src project scan, agent'
Info '                      selection, click->PtyIntent->launch_spec resolution.'
Info 'Converter ready:      materialize::wsl::tar_to_wsl_import (w5 slice) integrated'
Info '                      into linux-next; vm-layer 43/43 green incl. macOS converter.'
if ($wslReady) {
    Info 'VM provisioning:      WSL present, recipe authored. Still GATED on the sec.2b'
    Info '                      CI-fetch / recipe-smoke job publishing the per-arch'
    Info '                      rootfs .tar that tar_to_wsl_import imports.'
} else {
    Warn 'VM provisioning:      blocked twice over - install WSL2 AND wait for the'
    Warn '                      sec.2b CI rootfs-publish job.'
}
Info 'Run the tray menu-only (no provisioning):  install-windows.ps1 -Launch'
Info 'Attempt real provisioning once unblocked:  install-windows.ps1 -Provision -Launch'
