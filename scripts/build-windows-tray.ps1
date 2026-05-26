<#
.SYNOPSIS
    Build the Tillandsias Windows tray binary (tillandsias-tray.exe).

.DESCRIPTION
    The windows-owned parallel to scripts/build-macos-tray.sh. Compiles the
    `tillandsias-windows-tray` crate for the host MSVC target and reports the
    resulting executable path. Release by default (GUI subsystem, no console
    window); pass -Debug for a console-attached build that surfaces tracing
    output for interactive debugging.

    @trace spec:windows-native-tray

.PARAMETER DebugBuild
    Build the debug profile (keeps a console window + assertions) instead of
    release.

.EXAMPLE
    scripts\build-windows-tray.ps1
    scripts\build-windows-tray.ps1 -DebugBuild
#>
[CmdletBinding()]
param(
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

# Repo root = parent of this script's directory.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# Ensure cargo is on PATH (matches the project's session convention).
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo not found on PATH. Install Rust (https://rustup.rs) or add %USERPROFILE%\.cargo\bin."
}

$profileName = if ($DebugBuild) { 'debug' } else { 'release' }
$buildArgs = @('build', '-p', 'tillandsias-windows-tray')
if (-not $DebugBuild) { $buildArgs += '--release' }

Write-Host "Building tillandsias-tray ($profileName)..." -ForegroundColor Cyan
& cargo @buildArgs
if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }

$exe = Join-Path $RepoRoot "target\$profileName\tillandsias-tray.exe"
if (-not (Test-Path $exe)) { throw "expected binary not found: $exe" }

Write-Host "Built: $exe" -ForegroundColor Green
# Emit the path as the script's object output so callers can capture it.
Write-Output $exe
