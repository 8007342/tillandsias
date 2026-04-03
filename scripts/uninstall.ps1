# Tillandsias Uninstaller for Windows

$installDir = "$env:LOCALAPPDATA\Tillandsias"
$uninstaller = "$installDir\uninstall.exe"

# Try NSIS uninstaller first (created by Tauri installer)
if (Test-Path $uninstaller) {
    Write-Host "Running uninstaller..."
    Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait
} else {
    # Manual cleanup fallback
    Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove Start Menu shortcut
Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk" -Force -ErrorAction SilentlyContinue

# Remove autostart registry entry
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Tillandsias" -ErrorAction SilentlyContinue

# Clean PATH entry (in case of legacy portable install)
$path = [Environment]::GetEnvironmentVariable("Path", "User")
$cleaned = ($path.Split(';') | Where-Object { $_ -ne $installDir }) -join ';'
if ($cleaned -ne $path) {
    [Environment]::SetEnvironmentVariable("Path", $cleaned, "User")
    Write-Host "  Removed from PATH"
}

Write-Host "Tillandsias uninstalled."
