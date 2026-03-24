# Tillandsias Installer for Windows
$installDir = "$env:LOCALAPPDATA\Tillandsias"
$binPath = "$installDir\tillandsias.exe"

# Create install directory
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Download binary
$repo = "8007342/tillandsias"
$asset = "tillandsias-windows-x86_64.exe"
$url = "https://github.com/$repo/releases/latest/download/$asset"

Write-Host "Downloading Tillandsias..."
Invoke-WebRequest -Uri $url -OutFile $binPath

# Add to PATH (user level)
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if ($path -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$path;$installDir", "User")
    Write-Host "  Added to PATH"
}

# Create Start Menu shortcut
$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut("$startMenu\Tillandsias.lnk")
$shortcut.TargetPath = $binPath
$shortcut.Description = "Local development environments that just work"
$shortcut.Save()
Write-Host "  Start Menu shortcut created"

# Autostart (disabled by default — uncomment to enable)
# $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
# Set-ItemProperty -Path $regPath -Name "Tillandsias" -Value "`"$binPath`" --background"
# Write-Host "  Autostart enabled"

Write-Host ""
Write-Host "  Run: tillandsias"
