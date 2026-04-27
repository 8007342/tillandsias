# Local Windows build + install for development.
# Builds debug, installs to %LOCALAPPDATA%\Tillandsias, prunes old forge images.
#
# Usage: .\build-local.ps1 [-Release]
#
# @trace spec:cross-platform

param([switch]$Release)

$installDir = "$env:LOCALAPPDATA\Tillandsias"

# Kill running instance
Stop-Process -Name tillandsias -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# @trace spec:opencode-web-session-otp, spec:cross-platform
# Stage the pre-built tillandsias-router-sidecar so src-tauri/build.rs's
# include_bytes!("../../images/router/tillandsias-router-sidecar") finds
# it before cargo enters the tray crate. The helper is idempotent — fast
# no-op when the binary is fresher than every source file. Without this
# step, cargo panics on Windows just like it does on Linux/macOS.
$scriptDir = $PSScriptRoot
Write-Host "Staging router sidecar..." -ForegroundColor Cyan
$bashExe = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bashExe) {
    Write-Host "bash not found in PATH — install Git for Windows or run scripts/build-sidecar.sh under WSL." -ForegroundColor Red
    exit 1
}
& bash "$scriptDir\scripts\build-sidecar.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Host "build-sidecar.sh failed." -ForegroundColor Red
    exit 1
}

# Build
if ($Release) {
    Write-Host "Building release..." -ForegroundColor Cyan
    cargo build --release -p tillandsias
    $bin = "target\release\tillandsias.exe"
} else {
    Write-Host "Building debug..." -ForegroundColor Cyan
    cargo build -p tillandsias
    $bin = "target\debug\tillandsias.exe"
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

$version = Get-Content VERSION
Write-Host "Version: $version" -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item $bin "$installDir\tillandsias.exe" -Force
Write-Host "Installed to $installDir"

# Remove ALL forge images so the next launch triggers a fresh forge build
Write-Host "Pruning forge images..."
$images = podman images --format '{{.Repository}}:{{.Tag}}' 2>$null | Where-Object { $_ -match 'tillandsias-forge' }
foreach ($img in $images) {
    if ($img) { podman rmi $img 2>$null | Out-Null }
}

# Clear build hash cache
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\tillandsias\build-hashes" -ErrorAction SilentlyContinue
Remove-Item -Force "$env:TEMP\tillandsias-build\build-forge.lock" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Run: tillandsias.exe --init" -ForegroundColor Green
Write-Host "  or: tillandsias.exe"
