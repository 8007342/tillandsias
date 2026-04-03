# Local Windows build + install for development.
# Builds debug, installs to %LOCALAPPDATA%\Tillandsias, prunes old forge images.
#
# Usage: .\build-local.ps1 [-Release]
#
# @trace spec:cross-platform

param([switch]$Release)

$installDir = "$env:LOCALAPPDATA\Tillandsias"

# Kill running instance
Stop-Process -Name tillandsias-tray -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Build
if ($Release) {
    Write-Host "Building release..." -ForegroundColor Cyan
    cargo build --release -p tillandsias-tray
    $bin = "target\release\tillandsias-tray.exe"
} else {
    Write-Host "Building debug..." -ForegroundColor Cyan
    cargo build -p tillandsias-tray
    $bin = "target\debug\tillandsias-tray.exe"
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

$version = Get-Content VERSION
Write-Host "Version: $version" -ForegroundColor Green

# Install
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item $bin "$installDir\tillandsias-tray.exe" -Force
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
Write-Host "Done. Run: tillandsias-tray.exe --init" -ForegroundColor Green
Write-Host "  or: tillandsias-tray.exe"
