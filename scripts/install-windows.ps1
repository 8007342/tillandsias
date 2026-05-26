<#
.SYNOPSIS
    Build + install the Tillandsias tray locally for interactive testing.

.DESCRIPTION
    The windows-owned parallel to scripts/install-macos.sh. Unlike the macOS
    installer (which curls a published release artifact), this builds from the
    local checkout -- there is no published Windows release yet -- and installs
    into the user profile (no admin required):

      %LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe   (+ assets)

    It then creates a Start Menu shortcut and (optionally) a startup entry, and
    can launch the tray immediately.

    DEV-MODE DEFAULT: the shortcut + -Launch pass `--no-provision`, so the tray
    comes up clean (no Fedora rootfs download, no `wsl --import`) and the menu
    is immediately exercisable. The WSL provisioning path is still gated on the
    cross-host vm-recipe-provisioning decision; pass -Provision to opt in once a
    VM can boot.

    @trace spec:windows-native-tray, spec:vm-provisioning-lifecycle

.PARAMETER Launch
    Start the tray after installing.

.PARAMETER Startup
    Also install a shortcut into the user's Startup folder (auto-start on logon).

.PARAMETER Provision
    Drive real WSL provisioning on launch (omit `--no-provision`). Default is
    dev/menu-only mode.

.PARAMETER DebugBuild
    Install the debug build (console window + tracing output) instead of release.

.PARAMETER Uninstall
    Remove the installed binary, the install directory, and all shortcuts.

.EXAMPLE
    scripts\install-windows.ps1 -Launch
    scripts\install-windows.ps1 -Startup -Launch
    scripts\install-windows.ps1 -DebugBuild -Launch        # console + logs
    scripts\install-windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Launch,
    [switch]$Startup,
    [switch]$Provision,
    [switch]$DebugBuild,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$AppName       = 'Tillandsias'
$ExeName       = 'tillandsias-tray.exe'
$InstallDir    = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$InstalledExe  = Join-Path $InstallDir $ExeName
$StartMenuDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$ShortcutPath  = Join-Path $StartMenuDir "$AppName.lnk"
$StartupDir    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupLnk    = Join-Path $StartupDir "$AppName.lnk"

function New-Shortcut {
    param([string]$LinkPath, [string]$Target, [string]$Arguments, [string]$WorkDir)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LinkPath)
    $sc.TargetPath       = $Target
    $sc.Arguments        = $Arguments
    $sc.WorkingDirectory = $WorkDir
    $sc.IconLocation     = "$Target,0"
    $sc.Description       = 'Tillandsias tray'
    $sc.Save()
}

# --- Uninstall --------------------------------------------------------------
if ($Uninstall) {
    Write-Host "Uninstalling $AppName..." -ForegroundColor Cyan
    # Stop a running instance first so the exe isn't locked.
    Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($ShortcutPath, $StartupLnk)) {
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "  removed $p" }
    }
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Write-Host "  removed $InstallDir" }
    Write-Host "Uninstalled." -ForegroundColor Green
    return
}

# --- Build ------------------------------------------------------------------
$buildScript = Join-Path $PSScriptRoot 'build-windows-tray.ps1'
$builtExe = & $buildScript -DebugBuild:$DebugBuild | Select-Object -Last 1
if (-not (Test-Path $builtExe)) { throw "build did not produce an exe: $builtExe" }

# --- Install (copy exe + assets) --------------------------------------------
Write-Host "Installing to $InstallDir..." -ForegroundColor Cyan
# Stop a running instance so the copy doesn't fail on a locked file.
Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $builtExe $InstalledExe -Force
# The icon is embedded in the exe via build.rs; copy the manifest assets too so
# a future provisioning path can find the pinned manifest beside the binary.
$assetSrc = Join-Path $RepoRoot 'crates\tillandsias-windows-tray\assets\provisioning-manifest.json'
if (Test-Path $assetSrc) { Copy-Item $assetSrc (Join-Path $InstallDir 'provisioning-manifest.json') -Force }

# --- Shortcuts --------------------------------------------------------------
$launchArgs = if ($Provision) { '' } else { '--no-provision' }
New-Shortcut -LinkPath $ShortcutPath -Target $InstalledExe -Arguments $launchArgs -WorkDir $InstallDir
Write-Host "  Start Menu shortcut: $ShortcutPath" -ForegroundColor Green
if ($Startup) {
    New-Shortcut -LinkPath $StartupLnk -Target $InstalledExe -Arguments $launchArgs -WorkDir $InstallDir
    Write-Host "  Startup shortcut:    $StartupLnk" -ForegroundColor Green
}

$mode = if ($Provision) { 'provisioning ENABLED' } else { 'dev mode (--no-provision)' }
Write-Host "Installed $AppName ($mode)." -ForegroundColor Green

# --- Launch -----------------------------------------------------------------
if ($Launch) {
    Write-Host "Launching..." -ForegroundColor Cyan
    if ([string]::IsNullOrEmpty($launchArgs)) {
        Start-Process -FilePath $InstalledExe -WorkingDirectory $InstallDir
    } else {
        Start-Process -FilePath $InstalledExe -ArgumentList $launchArgs -WorkingDirectory $InstallDir
    }
    Write-Host "Tray started. Look for the Tillandsias icon in the notification area" -ForegroundColor Green
    Write-Host "(you may need to click the overflow chevron). Right-click it for the menu." -ForegroundColor Green
}
