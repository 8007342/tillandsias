# Tillandsias Uninstaller for Windows

# Remove binary
Remove-Item -Path "$env:LOCALAPPDATA\Tillandsias" -Recurse -Force -ErrorAction SilentlyContinue
# Remove Start Menu shortcut
Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk" -Force -ErrorAction SilentlyContinue
# Remove autostart
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Tillandsias" -ErrorAction SilentlyContinue
# Remove PATH entry
$path = [Environment]::GetEnvironmentVariable("Path", "User")
$path = ($path.Split(';') | Where-Object { $_ -ne "$env:LOCALAPPDATA\Tillandsias" }) -join ';'
[Environment]::SetEnvironmentVariable("Path", $path, "User")
Write-Host "Tillandsias uninstalled."
