<#
.SYNOPSIS
    Build (and optionally package) the Tillandsias Windows tray
    (tillandsias-tray.exe).

.DESCRIPTION
    The windows-owned parallel to scripts/build-macos-tray.sh. Compiles the
    `tillandsias-windows-tray` crate for the host MSVC target and reports the
    resulting executable path. Release by default (GUI subsystem, no console
    window); pass -DebugBuild for a console-attached build that surfaces tracing
    output for interactive debugging.

    With -Release it ALSO packages the publishable release artifacts (mirroring
    build-macos-tray.sh): a `tillandsias-tray-<version>-windows-x64.zip` (the exe
    + install-windows.ps1) plus a distinct `SHA256SUMS-windows` (so it does not
    collide with the Linux/macOS sums in the shared release), written under
    `release-artifacts/`. This absorbs the inline packaging stopgap previously in
    the release.yml `windows-release` job (tray-convergence-coordination.md ask).

    @trace spec:windows-native-tray, spec:linux-native-portable-executable

.PARAMETER DebugBuild
    Build the debug profile (keeps a console window + assertions) instead of
    release. Mutually exclusive with -Release.

.PARAMETER Release
    After a release build, stage + zip the publishable artifacts + emit
    SHA256SUMS-windows under release-artifacts/. Implies a release profile.

.PARAMETER Version
    Release version string (no leading 'v') used in the artifact name. Defaults
    to the contents of the repo-root VERSION file. Only used with -Release.

.EXAMPLE
    scripts\build-windows-tray.ps1
    scripts\build-windows-tray.ps1 -DebugBuild
    scripts\build-windows-tray.ps1 -Release
    scripts\build-windows-tray.ps1 -Release -Version 0.2.260527.1
#>
[CmdletBinding()]
param(
    [switch]$DebugBuild,
    [switch]$Release,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

if ($DebugBuild -and $Release) {
    throw "-DebugBuild and -Release are mutually exclusive (packaging needs a release build)."
}

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
# Cargo writes its progress messages ("Compiling...", "Finished...") to stderr.
# Under `$ErrorActionPreference = 'Stop'` PowerShell wraps each stderr write
# from a native exe as a NativeCommandError RemoteException, which the Stop
# trap treats as a terminating error — aborting the build mid-stream the
# moment cargo first writes "Compiling X". This is the well-known stderr-wrap
# quirk documented in skills/build-windows-tray + cheatsheets/runtime/
# windows-tray-diagnostics.md. Locally relax the preference around the cargo
# invocation, capture $LASTEXITCODE explicitly, then restore — a real cargo
# compile failure still surfaces via the exit code check below.
$prevErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & cargo @buildArgs
    $cargoExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevErrorActionPreference
}
if ($cargoExit -ne 0) { throw "cargo build failed (exit $cargoExit)" }

$exe = Join-Path $RepoRoot "target\$profileName\tillandsias-tray.exe"
if (-not (Test-Path $exe)) { throw "expected binary not found: $exe" }

Write-Host "Built: $exe" -ForegroundColor Green

if (-not $Release) {
    # Emit the path as the script's object output so callers can capture it.
    Write-Output $exe
    return
}

# --- Release packaging (mirrors build-macos-tray.sh) ---------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionFile = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path $versionFile)) {
        throw "-Release needs a version: pass -Version or provide a repo-root VERSION file."
    }
    $Version = (Get-Content $versionFile -Raw).Trim()
}
# Tolerate a leading 'v' if a caller passes a tag.
$Version = $Version.TrimStart('v')

$artifactsDir = Join-Path $RepoRoot 'release-artifacts'
New-Item -ItemType Directory -Force $artifactsDir | Out-Null

$base = "tillandsias-tray-$Version-windows-x64"
$stage = Join-Path $artifactsDir $base
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $exe (Join-Path $stage 'tillandsias-tray.exe')
# Ship the canonical operator scripts inside the release zip so users get
# the full diagnostic toolchain on extract — no need to clone the repo
# separately for tray-diagnose.ps1 / diagnose-windows.ps1. Each script
# is best-effort: a missing source path is non-fatal so the build still
# packages the core binary + installer.
$bundledScripts = @(
    'install-windows.ps1', # installer with full -Launch / -Provision / -Uninstall / -Purge lifecycle
    'tray-diagnose.ps1',   # live-runtime health check (consumes --diagnose --json)
    'diagnose-windows.ps1' # pre-tray host-facts diagnostic
)
foreach ($scriptName in $bundledScripts) {
    $src = Join-Path $RepoRoot "scripts\$scriptName"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $stage $scriptName)
    } else {
        Write-Host "  WARN: bundled script $scriptName not found at $src" -ForegroundColor Yellow
    }
}

$zip = Join-Path $artifactsDir "$base.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item -Recurse -Force $stage

# Distinct sums file so it does not collide with the Linux/macOS SHA256SUMS in
# the shared release. sha256sum format: "<hash>  <filename>".
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $artifactsDir 'SHA256SUMS-windows'
"$hash  $(Split-Path $zip -Leaf)" | Out-File -Encoding ascii -NoNewline $sums

Write-Host "Packaged: $zip" -ForegroundColor Green
Write-Host "Checksums: $sums" -ForegroundColor Green
Get-ChildItem $artifactsDir | Select-Object Name, Length | Format-Table -AutoSize | Out-Host
# Emit the zip path as the script's object output.
Write-Output $zip
