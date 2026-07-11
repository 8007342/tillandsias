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

    Guest-binary embed (order 190 windows half / order 282): before compiling,
    any non-empty staged guest headless under `target-guest/` (the
    scripts/build-guest-binaries.sh staging contract) is copied per-arch into
    `crates/tillandsias-windows-tray/assets/` so `include_bytes!` embeds it and
    fresh WSL guests skip the release-download fetch (no version skew). When a
    staged binary is absent the build.rs zero-byte placeholder stays, keeping
    the in-VM fetch-headless network fallback for that arch. Artifact transport
    onto a Windows host, any of: (a) build inside the local WSL distro with a
    rustup musl toolchain and `install` the binary into `target-guest/`;
    (b) copy `target-guest/` from a Linux checkout (CI nightly or sibling
    host); (c) let the guest fetch the published release (the fallback this
    embed demotes).

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

# --- Stage guest headless binaries into assets/ (order 190 windows half) ------
# Embed per HOST arch (order 282): a WSL2 guest always matches the Windows
# host architecture, so only that one staged binary from target-guest/ (the
# scripts/build-guest-binaries.sh staging contract) is copied into the
# crate's assets/ for include_bytes! embedding. The other arch's asset is
# reset to the zero-byte placeholder (absent-asset = in-VM fetch-headless
# fallback) so a stale copy can't bloat the exe by ~40MB. Copy only when
# content differs so incremental cargo builds don't recompile for an
# unchanged asset.
$assetsDir = Join-Path $RepoRoot 'crates\tillandsias-windows-tray\assets'
New-Item -ItemType Directory -Force $assetsDir | Out-Null
$hostGuestArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$guestArches = @('x86_64', 'aarch64')
foreach ($guestArch in $guestArches) {
    $guestBin = "tillandsias-headless-$guestArch-unknown-linux-musl"
    $stagedGuest = Join-Path $RepoRoot "target-guest\$guestBin"
    $assetGuest = Join-Path $assetsDir $guestBin
    if ($guestArch -ne $hostGuestArch) {
        if ((Test-Path $assetGuest) -and ((Get-Item $assetGuest).Length -gt 0)) {
            [System.IO.File]::WriteAllBytes($assetGuest, @())
            Write-Host "Reset non-host-arch guest asset to placeholder: $guestBin" -ForegroundColor DarkGray
        }
        continue
    }
    if ((Test-Path $stagedGuest) -and ((Get-Item $stagedGuest).Length -gt 0)) {
        $srcHash = (Get-FileHash $stagedGuest -Algorithm SHA256).Hash
        $dstHash = ''
        if ((Test-Path $assetGuest) -and ((Get-Item $assetGuest).Length -gt 0)) {
            $dstHash = (Get-FileHash $assetGuest -Algorithm SHA256).Hash
        }
        if ($srcHash -eq $dstHash) {
            Write-Host "Guest binary already staged (unchanged): $guestBin" -ForegroundColor DarkGray
        } else {
            Copy-Item $stagedGuest $assetGuest -Force
            Write-Host "Staged guest binary into assets ($hostGuestArch host): $guestBin" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  WARN: no staged guest binary at target-guest\$guestBin for this host arch - embedded asset stays empty; fresh guests fall back to fetching the latest release (version skew possible). Stage with scripts/build-guest-binaries.sh (see .DESCRIPTION for Windows transport options)." -ForegroundColor Yellow
    }
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
    'install-windows.ps1', # curl installer (parity with install.sh / install-macos.sh)
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
