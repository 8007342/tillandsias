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
        # Event Log source registration (HKLM) — removable only from an
        # elevated shell; best-effort, silent skip otherwise. Already-logged
        # events stay in the Application log by design (they are the record).
        try {
            Remove-EventLog -Source 'Tillandsias' -ErrorAction Stop
            Say "  removed Event Log source 'Tillandsias'"
        } catch {}
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

# ── WSL platform preflight (order 324; mirrors the order-323 tray classifier) ─
# A brand-new host can be in states where the tray's first VM create can NEVER
# succeed (recipes: plan/issues/wsl2-reboot-pending-first-install-ux-2026-07-13.md):
#   absent                  wsl.exe missing or Windows ships only the stub (S1)
#   reboot-pending          VirtualMachinePlatform enabled, DISM 3010 (S2)
#   virtualization-disabled VT-x/AMD-V off in firmware (S3)
# The installer owns the restart instruction: on S2/S3 it prints the exact next
# step and does NOT auto-launch the tray, so the first impression is never a
# dead VM create. Classification parity with
# tillandsias-vm-layer wsl.rs classify_wsl_platform (order 323).
function Get-WslPlatformState {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return 'absent' }
    # cmd /c relays stderr into stdout so PS 5.1 never wraps native stderr in
    # ErrorRecords under $ErrorActionPreference='Stop'; NUL-strip tolerates
    # the UTF-16 pipe output wsl.exe emits.
    $statusOut = ''
    try { $statusOut = ((& cmd /c "wsl --status 2>&1") | Out-String) -replace "`0", '' } catch {}
    if ($LASTEXITCODE -eq 0) { return 'ok' }   # S4 healthy
    # S1: locale-stable install-URL marker, not English prose.
    if ($statusOut -match 'aka\.ms/wslinstall') { return 'absent' }
    # S3: only when BOTH firmware signals agree (half-known is not confident).
    try {
        $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if (($cs.HypervisorPresent -eq $false) -and ($cpu.VirtualizationFirmwareEnabled -eq $false)) {
            return 'virtualization-disabled'
        }
    } catch {}
    # S2: WSL app present but unhealthy + a pending servicing reboot.
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        return 'reboot-pending'
    }
    'ok'   # unclassified: the tray's own preflight (order 323) owns it
}

$WslState = Get-WslPlatformState
$NoLaunchReason = ''
switch ($WslState) {
    'absent' {
        # windows-260722-1: don't just instruct — RUN the idempotent install
        # right here (operator directive 2026-07-22: "make sure our curl
        # install ends with the idempotent wsl --install"). wsl.exe raises
        # its own UAC prompt when elevation is needed; declining or failing
        # degrades to the old warn-only behavior. Afterward re-classify: a
        # healthy platform allows auto-launch; anything else suppresses it
        # (the old arm auto-launched into a provisioning attempt that could
        # never succeed — the field "crash loop" report of 2026-07-22).
        SayWn "WSL is not installed. Running the one-time platform install now"
        SayWn "(idempotent; you may see a Windows approval prompt)..."
        try {
            & wsl --install --no-distribution 2>&1 | ForEach-Object { Say "  $($_ -replace "`0", '')" }
        } catch {
            SayWn "wsl --install did not complete ($_)."
        }
        $WslState = Get-WslPlatformState
        switch ($WslState) {
            'ok' { SayOk "WSL platform ready." }
            'reboot-pending' {
                SayWn "WSL2 requires a restart to finish installing."
                SayWn "NEXT: 1) restart Windows   2) launch Tillandsias from the Start Menu."
                $NoLaunchReason = 'restart Windows first, then launch Tillandsias from the Start Menu'
            }
            default {
                SayWn "WSL is still not available. Install it manually with:"
                SayWn "  wsl --install --no-distribution"
                SayWn "(restart Windows if the installer asks), then launch Tillandsias."
                $NoLaunchReason = 'install WSL2 (wsl --install --no-distribution) first, then launch Tillandsias'
            }
        }
    }
    'reboot-pending' {
        SayWn "WSL2 requires a restart to finish installing."
        SayWn "NEXT: 1) restart Windows   2) launch Tillandsias from the Start Menu."
        $NoLaunchReason = 'restart Windows first, then launch Tillandsias from the Start Menu'
    }
    'virtualization-disabled' {
        SayWn "Hardware virtualization is disabled on this machine."
        SayWn "NEXT: enable VT-x/AMD-V in BIOS/UEFI, then launch Tillandsias."
        $NoLaunchReason = 'enable virtualization in BIOS/UEFI first, then launch Tillandsias'
    }
}
if ($NoLaunchReason -and -not $NoLaunch) {
    $NoLaunch = $true
    SayWn "Auto-launch disabled for this install ($WslState): the tray's first VM create cannot succeed yet."
}

# ── Hyper-V Administrators membership (order 312) ───────────────────────────
# The tray's hvsocket VM lookup (hcsdiag) requires an ENABLED membership in
# Administrators or 'Hyper-V Administrators' (BUILTIN SID S-1-5-32-578) —
# standard-user installs can otherwise never connect to the VM (masked for
# months by elevated dev shells). Offer a one-time elevated group-add.
# SIDs, not names: group names are localized ("Administrateurs Hyper-V").
# IsInRole, not token-group scan: it correctly ignores deny-only (UAC-
# filtered) memberships, matching what hcsdiag actually enforces.
function Test-HcsAccess {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-32-578') {
        $role = New-Object Security.Principal.SecurityIdentifier($sid)
        if ($principal.IsInRole($role)) { return $true }
    }
    return $false
}
# ── Windows Event Log source (@trace spec:windows-event-logging) ────────────
# The tray relays INFO/WARN/ERROR to the Application Event Log so failures are
# discoverable in Event Viewer. The relay works WITHOUT registration (events
# render inside Event Viewer's generic wrapper); registering the source under
# HKLM (admin-only) makes them render clean. Never block install on this.
function Test-EventSourceRegistered {
    Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Tillandsias'
}
$RegisterEventSourceCmd = "try { New-EventLog -LogName Application -Source Tillandsias -ErrorAction Stop } catch {}"
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not (Test-EventSourceRegistered)) {
    if ($IsElevated) {
        Invoke-Expression $RegisterEventSourceCmd
        if (Test-EventSourceRegistered) { SayOk "Registered Event Log source 'Tillandsias'." }
    } else {
        # Non-elevated: piggyback on the Hyper-V group-add UAC prompt below if
        # it runs; otherwise leave the (fully functional) unregistered mode.
        Say "Event Log source not registered (optional; events still reach Event Viewer)."
    }
}

if (-not (Test-HcsAccess)) {
    SayWn "Your account is not in 'Hyper-V Administrators' - Tillandsias cannot"
    SayWn "reach its VM without it (https://aka.ms/hcsadmin)."
    $doAdd = $true
    if ([Environment]::UserInteractive -and -not $env:TILLANDSIAS_NO_GROUP_ADD) {
        $resp = Read-Host "  Add your user to Hyper-V Administrators now? (one admin approval) [Y/n]"
        if ($resp -match '^[nN]') { $doAdd = $false }
    } elseif ($env:TILLANDSIAS_NO_GROUP_ADD) {
        $doAdd = $false
    }
    if ($doAdd) {
        $me = "${env:USERDOMAIN}\${env:USERNAME}"
        try {
            # Single UAC prompt does double duty: group-add + (best-effort)
            # Event Log source registration, so we never ask for admin twice.
            Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
                '-NoProfile', '-Command',
                "Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '$me'; $RegisterEventSourceCmd"
            ) -ErrorAction Stop
            if (Test-HcsAccess) {
                SayOk "Membership active."
            } else {
                SayOk "Added to Hyper-V Administrators. SIGN OUT AND BACK IN before launching Tillandsias (new logon token required)."
            }
        } catch {
            SayWn "Group add declined or failed ($_). Fix later from an elevated PowerShell:"
            SayWn "  Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '$me'"
        }
    } else {
        SayWn "Skipped. Fix later from an elevated PowerShell:"
        SayWn "  Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '<your DOMAIN\username>'"
    }
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
        if ($NoLaunchReason) {
            SayWn "Reminder: $NoLaunchReason."
        }
    }
    Write-Host ""

} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
