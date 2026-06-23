<#
.SYNOPSIS
    Tillandsias Windows curl installer.

.DESCRIPTION
    Downloads the latest Tillandsias Windows release from GitHub, verifies the
    SHA-256 checksum, installs to %LOCALAPPDATA%\Programs\Tillandsias\ (no admin
    required), creates a Start Menu shortcut, and launches the tray to provision
    WSL2 (equivalent to `tillandsias --init` on Linux/macOS).

    Usage (paste in PowerShell or Windows Terminal):
        irm https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1 | iex

    Or with a pinned version:
        $env:TILLANDSIAS_VERSION="v0.3.260622.4"
        irm https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1 | iex

.PARAMETER NoLaunch
    Install but do not launch the tray after installing. The tray's WSL2
    provisioning (equivalent to --init) will run on next launch.

.PARAMETER LoginItem
    Register Tillandsias as a Windows startup entry (auto-start at logon).

.PARAMETER Uninstall
    Remove the installed binary and shortcuts. Leaves WSL2 distro + cache.
    Pass -Purge for full cleanup.

.PARAMETER Purge
    -Uninstall PLUS wsl --unregister tillandsias + remove cache/log dirs.
    Full "as if never installed" cleanup.

.EXAMPLE
    irm https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1 | iex
    irm https://…/install-windows.ps1 | iex  # (same URL, short form)

# @trace spec:windows-native-tray, spec:vm-provisioning-lifecycle
#>
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$LoginItem,
    [switch]$Uninstall,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$Repo       = '8007342/tillandsias'
$AppName    = 'Tillandsias'
$ExeName    = 'tillandsias-tray.exe'
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$InstalledExe  = Join-Path $InstallDir $ExeName
$StartMenuDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$ShortcutPath  = Join-Path $StartMenuDir "$AppName.lnk"
$StartupDir    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupLnk    = Join-Path $StartupDir "$AppName.lnk"

function Say   { param([string]$msg) Write-Host "  $msg" }
function SayOk { param([string]$msg) Write-Host "  $msg" -ForegroundColor Green }
function SayWn { param([string]$msg) Write-Host "  $msg" -ForegroundColor Yellow }
function Die   { param([string]$msg) Write-Host "  ERROR: $msg" -ForegroundColor Red; exit 1 }

function New-Shortcut {
    param([string]$LinkPath, [string]$Target, [string]$Arguments, [string]$WorkDir)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LinkPath)
    $sc.TargetPath       = $Target
    $sc.Arguments        = $Arguments
    $sc.WorkingDirectory = $WorkDir
    $sc.IconLocation     = "$Target,0"
    $sc.Description      = 'Tillandsias tray'
    $sc.Save()
}

# ── Uninstall / Purge ────────────────────────────────────────────────────────
if ($Uninstall -or $Purge) {
    $DataRoot = Join-Path $env:LOCALAPPDATA 'tillandsias'
    $action = if ($Purge) { 'Purging' } else { 'Uninstalling' }
    Say "$action $AppName..."
    Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($ShortcutPath, $StartupLnk)) {
        if (Test-Path $p) { Remove-Item $p -Force; Say "  removed $p" }
    }
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Say "  removed $InstallDir" }
    if ($Purge) {
        $wsl = Get-Command wsl -ErrorAction SilentlyContinue
        if ($wsl) {
            $listed = (& wsl --list --quiet 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ }
            if ($listed -contains 'tillandsias') {
                & wsl --unregister tillandsias 2>$null
                Say "  unregistered WSL distro 'tillandsias'"
            }
        }
        foreach ($d in @('cache', 'logs', 'wsl') | ForEach-Object { Join-Path $DataRoot $_ }) {
            if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Say "  removed $d" }
        }
        SayOk "Purged."
    } else {
        SayOk "Uninstalled. (Use -Purge for full cleanup including WSL distro + cache.)"
    }
    return
}

# ── Platform gates ───────────────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die "PowerShell 5+ is required. Please update via Windows Update."
}
if (-not [System.Environment]::Is64BitOperatingSystem) {
    Die "Tillandsias requires a 64-bit Windows installation."
}

# Warn if WSL2 is not installed (provisioning will fail later, better to surface now).
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wsl) {
    SayWn "WSL2 not found. Install it first: wsl --install (requires reboot)"
    SayWn "Tillandsias will install, but provisioning requires WSL2 on next launch."
}

Write-Host ""
Say "Tillandsias Installer"
Say "====================="
Say "Target: Windows x64"
Say "Install path: $InstalledExe"
Write-Host ""

# ── Resolve version and base URL ─────────────────────────────────────────────
if ($env:TILLANDSIAS_VERSION) {
    $Version = $env:TILLANDSIAS_VERSION.TrimStart('v')
    $Base = "https://github.com/$Repo/releases/download/v$Version"
    Say "Pinned to v$Version"
} else {
    $Base = "https://github.com/$Repo/releases/latest/download"
    Say "Resolving latest release..."
}

# ── Temp workspace ────────────────────────────────────────────────────────────
$Tmp = Join-Path $env:TEMP "tillandsias-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

try {
    # ── Download SHA256SUMS-windows ───────────────────────────────────────────
    $SumsUrl = "$Base/SHA256SUMS-windows"
    Say "Fetching SHA256SUMS-windows..."
    try {
        Invoke-WebRequest -Uri $SumsUrl -OutFile "$Tmp\SHA256SUMS-windows" -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Could not download SHA256SUMS-windows from $SumsUrl — check network or version."
    }

    # Find zip filename (e.g. tillandsias-tray-0.3.260622.4-windows-x64.zip)
    $SumsContent = Get-Content "$Tmp\SHA256SUMS-windows" -Raw
    $ZipName = ($SumsContent -split "`n" | Where-Object { $_ -match 'tillandsias-tray-.*-windows-x64\.zip' } |
                Select-Object -First 1 | ForEach-Object { ($_ -split '\s+')[1] }).Trim()
    if (-not $ZipName) { Die "No tillandsias-tray-*-windows-x64.zip entry in SHA256SUMS-windows." }
    Say "Asset: $ZipName"

    # ── Download zip ──────────────────────────────────────────────────────────
    $ZipUrl = "$Base/$ZipName"
    Say "Downloading $ZipUrl..."
    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile "$Tmp\$ZipName" -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Download failed: $_"
    }

    # ── Verify SHA-256 ────────────────────────────────────────────────────────
    Say "Verifying SHA-256..."
    $Expected = ($SumsContent -split "`n" | Where-Object { $_ -match [regex]::Escape($ZipName) } |
                 Select-Object -First 1 | ForEach-Object { ($_ -split '\s+')[0] }).ToLower()
    $Actual = (Get-FileHash "$Tmp\$ZipName" -Algorithm SHA256).Hash.ToLower()
    if ($Expected -ne $Actual) {
        Die "SHA-256 mismatch: expected $Expected, got $Actual"
    }
    SayOk "sha256: ok ($Expected)"

    # ── Stop running tray + back up ────────────────────────────────────────────
    Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path $InstallDir) {
        $Backup = "$InstallDir.bak"
        Remove-Item -Recurse -Force $Backup -ErrorAction SilentlyContinue
        Say "Backing up existing install to $(Split-Path $Backup -Leaf)..."
        Rename-Item $InstallDir $Backup
    }

    # ── Extract ────────────────────────────────────────────────────────────────
    Say "Extracting to $InstallDir..."
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path "$Tmp\$ZipName" -DestinationPath $InstallDir -Force
    if (-not (Test-Path $InstalledExe)) {
        Die "Extraction did not produce $InstalledExe — zip may be corrupt."
    }

    # ── Start Menu shortcut ───────────────────────────────────────────────────
    New-Shortcut -LinkPath $ShortcutPath -Target $InstalledExe -Arguments '' -WorkDir $InstallDir
    SayOk "Start Menu shortcut: $ShortcutPath"

    if ($LoginItem) {
        New-Shortcut -LinkPath $StartupLnk -Target $InstalledExe -Arguments '' -WorkDir $InstallDir
        SayOk "Startup entry: $StartupLnk"
    }

    # ── Verify installation ───────────────────────────────────────────────────
    Say "Verifying installation via --version..."
    $VerTmp = Join-Path $env:TEMP "tillandsias-ver-$([guid]::NewGuid().ToString('N')).txt"
    & cmd.exe /c "`"$InstalledExe`" --version > `"$VerTmp`" 2>nul"
    $VerExit = $LASTEXITCODE
    $VerLine = (Get-Content $VerTmp -Raw -ErrorAction SilentlyContinue) -replace '\s+$', ''
    Remove-Item $VerTmp -ErrorAction SilentlyContinue
    if ($VerExit -ne 0 -or -not $VerLine) {
        Die "tillandsias-tray --version failed (exit $VerExit); binary is broken."
    }
    SayOk $VerLine

    # ── Launch (triggers WSL2 provisioning = tillandsias --init) ─────────────
    Write-Host ""
    if (-not $NoLaunch) {
        Say "Launching Tillandsias (WSL2 provisioning = --init will run automatically)..."
        Start-Process -FilePath $InstalledExe -WorkingDirectory $InstallDir
        SayOk "Tray started. Look for the Tillandsias icon in the notification area."
        SayOk "(Right-click the icon for the menu; provisioning runs in the background.)"
    } else {
        Say "Installation complete. Run $InstalledExe to provision WSL2 (--init)."
    }
    Write-Host ""

} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
