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
    irm https://.../install-windows.ps1 | iex  # (same URL, short form)

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
# ORDER 1171-ccf2. The headless probe binary ships beside the tray and installs
# beside it. It is NOT added to PATH: that is a permanent change to state the
# platform does not own, made on every install, and the capability probe reaches
# it through the install directory instead (host-capability-probe.sh's
# _windows_install_candidate). Best-effort on install -- a release that predates
# 1171-ccf2 carries no such file and must still install its tray.
$HeadlessName  = 'tillandsias.exe'
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
$InstalledExe  = Join-Path $InstallDir $ExeName
$StartMenuDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$ShortcutPath  = Join-Path $StartMenuDir "$AppName.lnk"
$StartupDir    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupLnk    = Join-Path $StartupDir "$AppName.lnk"

# -- Resolve the release channel FIRST (order 1369-sjbc) ----------------------
# Release channels (plan order 305 stable, 621-* unstable):
#   stable   (default) -> /releases/latest/download - newest PROMOTED release.
#   unstable           -> /releases/download/unstable - a rolling prerelease the
#                         release workflow re-points at EVERY daily build.
# `iex`-piped invocations cannot take parameters, so the channel is selected via
# the environment: $env:TILLANDSIAS_CHANNEL='unstable' before the pipe.
#
# ORDER 1369-sjbc. The DEFAULT is the channel of the release this copy was
# published in: the release job rewrites the next line in the copy it uploads
# to `unstable` (scripts/stage-unstable-installers.sh), because a script cannot
# see the URL it was fetched from. Before that, `irm .../unstable/...| iex`
# with no variable set silently installed STABLE and still ran the reset.
# Keep the line exactly as written; the rewrite refuses unless it matches once.
$DefaultChannel = 'stable'
if ($env:TILLANDSIAS_CHANNEL) {
    $Channel = $env:TILLANDSIAS_CHANNEL
    $ChannelSource = 'TILLANDSIAS_CHANNEL'
} else {
    $Channel = $DefaultChannel
    $ChannelSource = 'default of this installer copy'
}
switch ($Channel) {
    'stable'   { $ChannelBase = "https://github.com/$Repo/releases/latest/download" }
    'unstable' { $ChannelBase = "https://github.com/$Repo/releases/download/unstable" }
    default    { throw "Unknown TILLANDSIAS_CHANNEL '$Channel' (want stable or unstable)" }
}

# ORDER 1369-sjbc. Resolved channel, its source and base URL, printed before
# anything is downloaded and long before the reset, so a mismatch can still be
# stopped. TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 stops here (fixture seam).
$ResolvedBase = if ($env:TILLANDSIAS_VERSION) { "https://github.com/$Repo/releases/download/v$($env:TILLANDSIAS_VERSION.TrimStart('v'))" } else { $ChannelBase }
Write-Host "  resolved-channel: $Channel ($ChannelSource) base: $ResolvedBase"
if ($env:TILLANDSIAS_INSTALL_RESOLVE_ONLY -eq '1') { return }
# windows-260722-3: the tray (and thus its child processes, e.g. the WSL
# keepalive) must NEVER run with the INSTALL dir as CWD -- children that
# outlive a hard-killed tray hold the directory handle and block the next
# update's backup/replace (observed live: orphaned wsl.exe pinning the exe
# dir). Launch and shortcuts point at the data root instead.
$DataRootDir   = Join-Path $env:LOCALAPPDATA 'tillandsias'
New-Item -ItemType Directory -Force -Path $DataRootDir | Out-Null

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

# -- Uninstall / Purge --------------------------------------------------------
if ($Uninstall -or $Purge) {
    $DataRoot = Join-Path $env:LOCALAPPDATA 'tillandsias'
    $action = if ($Purge) { 'Purging' } else { 'Uninstalling' }
    Say "$action $AppName..."
    Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @($ShortcutPath, $StartupLnk)) {
        if (Test-Path $p) { Remove-Item $p -Force; Say "  removed $p" }
    }
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Say "  removed $InstallDir" }
    # windows-260722-3: Installed-Software entry + every Tillandsias
    # tray-icon settings entry go with the app (uninstall AND purge -- a
    # removed app must vanish from Settings surfaces entirely).
    $UninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tillandsias'
    if (Test-Path $UninstKey) { Remove-Item $UninstKey -Recurse -Force -ErrorAction SilentlyContinue; Say "  removed Installed-Software entry" }
    try {
        $nis = 'HKCU:\Control Panel\NotifyIconSettings'
        if (Test-Path $nis) {
            Get-ChildItem $nis | ForEach-Object {
                $p = (Get-ItemProperty -Path $_.PSPath -Name 'ExecutablePath' -ErrorAction SilentlyContinue).ExecutablePath
                if ($p -and ($p -like '*tillandsias-tray.exe')) {
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    Say "  removed tray-icon settings entry: $p"
                }
            }
        }
    } catch {}
    # Empty leftover Start Menu folders (WSL distro registration creates
    # per-distro folders that `wsl --unregister` leaves behind).
    foreach ($d in @('tillandsias', 'tillandsias-build') | ForEach-Object { Join-Path $StartMenuDir $_ }) {
        if ((Test-Path $d) -and -not (Get-ChildItem $d -ErrorAction SilentlyContinue)) {
            Remove-Item $d -Force -ErrorAction SilentlyContinue; Say "  removed empty $d"
        }
    }
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
        # 803-49re: unregistering the distro destroys the guest Vault, which
        # makes the host's copy of THAT vault's identity worse than useless
        # -- the tray delivers it into the next guest unconditionally, the
        # stale share fails to authenticate, and GitHub login is permanently
        # broken. Purging the distro without these is not a purge.
        #
        # The clearing itself moved to scripts/clear-vault-host-credentials.ps1
        # because it was here and ONLY here, while there are two purge paths --
        # see that file for what the second one was still doing on 2026-09-02.
        . (Join-Path $PSScriptRoot 'clear-vault-host-credentials.ps1')
        Clear-TillandsiasVaultHostCredentials -Say { param($m) Say $m }
        # Event Log source registration (HKLM) -- removable only from an
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

# -- Platform gates -----------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Die "PowerShell 5+ is required. Please update via Windows Update."
}
if (-not [System.Environment]::Is64BitOperatingSystem) {
    Die "Tillandsias requires a 64-bit Windows installation."
}

# -- WSL platform preflight (order 324; mirrors the order-323 tray classifier) -
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
        # windows-260722-1: don't just instruct -- RUN the idempotent install
        # right here (operator directive 2026-07-22: "make sure our curl
        # install ends with the idempotent wsl --install"). wsl.exe raises
        # its own UAC prompt when elevation is needed; declining or failing
        # degrades to the old warn-only behavior. Afterward re-classify: a
        # healthy platform allows auto-launch; anything else suppresses it
        # (the old arm auto-launched into a provisioning attempt that could
        # never succeed -- the field "crash loop" report of 2026-07-22).
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

# -- WSL2 guest shape report (order 1339-r9xv) -------------------------------
# THE PLATFORM PREFLIGHT ABOVE ANSWERS "CAN WSL RUN AT ALL". This answers a
# different question it never asked: WHAT SHAPE OF GUEST will .wslconfig give
# the user, and is that shape one that can build.
#
# MEASURED, not theorised (yolanda-windows 2026-09-21). On a 16-logical-CPU
# host with 15.16 GiB, WSL defaults produced a guest holding ALL 16 vCPUs
# inside a 4.8 GiB balloon -- roughly 320 MB per vCPU -- and FOUR consecutive
# builds were killed for host memory. The same gates on a FOUR-core machine
# with `processors=4` (100% of that host) and `autoMemoryReclaim=gradual` were
# never killed once. The more capable machine was the unreliable one, and the
# difference was entirely configuration.
#
# THIS BLOCK REPORTS AND OFFERS. IT NEVER WRITES .wslconfig SILENTLY. That
# file is the user's and may carry settings for work that has nothing to do
# with us; writing it behind their back would be a worse defect than the one
# being fixed. Same consent discipline the destructive reset already follows.
$WslCfgPath = Join-Path $env:USERPROFILE '.wslconfig'
$HostLogicalCpus = 0
$HostMemGiB = 0
try {
    $HostLogicalCpus = [int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
    $HostMemGiB = [math]::Round((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).TotalVisibleMemorySize / 1MB, 2)
} catch {}

if ($HostLogicalCpus -le 0) {
    # COULD-NOT-MEASURE IS NOT A VERDICT. Say so rather than reporting a shape
    # derived from a host reading we do not have.
    SayWn "  wsl-shape: could not read this host's CPU/memory; no guest-shape advice given."
} else {
    $CfgProcessors = ''
    $CfgMemory = ''
    $CfgReclaim = ''
    if (Test-Path $WslCfgPath) {
        foreach ($line in (Get-Content $WslCfgPath -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if ($t -match '^processors\s*=\s*(\S+)')       { $CfgProcessors = $Matches[1] }
            elseif ($t -match '^memory\s*=\s*(\S+)')        { $CfgMemory = $Matches[1] }
            elseif ($t -match '^autoMemoryReclaim\s*=\s*(\S+)') { $CfgReclaim = $Matches[1] }
        }
    }
    # WSL defaults when a key is absent: all logical CPUs, and (modern WSL2)
    # 50% of host RAM. State the DERIVED shape, not the file's contents --
    # the user cannot compute this and it is the whole point of the report.
    $EffCpus = if ($CfgProcessors -match '^\d+$') { [int]$CfgProcessors } else { $HostLogicalCpus }
    $EffMemGiB = 0.0
    if ($CfgMemory -match '^(\d+(?:\.\d+)?)\s*GB$') { $EffMemGiB = [double]$Matches[1] }
    elseif ($CfgMemory -match '^(\d+)\s*MB$')         { $EffMemGiB = [math]::Round([double]$Matches[1] / 1024, 2) }
    else { $EffMemGiB = [math]::Round($HostMemGiB / 2, 2) }

    Say "  wsl-shape: guest will take $EffCpus vCPU(s) of $HostLogicalCpus and about $EffMemGiB GiB of $HostMemGiB GiB."
    if (-not (Test-Path $WslCfgPath)) { Say "  wsl-shape: no .wslconfig found; these are WSL defaults." }

    # THE KNOWN-BAD RATIO, NAMED WITH ITS NUMBERS. A generality here would be
    # useless: the user needs to see their own figures next to the measured
    # failure to know whether it applies to them.
    $MbPerCpu = 0
    if ($EffCpus -gt 0) { $MbPerCpu = [int](($EffMemGiB * 1024) / $EffCpus) }
    $RatioBad = ($EffCpus -ge 8 -and $MbPerCpu -gt 0 -and $MbPerCpu -lt 700)
    $ReclaimOff = ($CfgReclaim -eq '')

    if ($RatioBad -or $ReclaimOff) {
        Write-Host ""
        SayWn "  Your WSL2 guest is shaped in a way that has killed builds on a host like this."
        if ($RatioBad) {
            SayWn "    $EffCpus vCPUs sharing $EffMemGiB GiB is about $MbPerCpu MB per vCPU."
            SayWn "    Measured: ~320 MB per vCPU killed four consecutive builds on a 16-core host."
        }
        if ($ReclaimOff) {
            SayWn "    autoMemoryReclaim is not set, so the guest never returns memory to Windows."
        }
        SayWn "  Recommended .wslconfig for this host (processors = ALL of them, not a copied number):"
        Write-Host ""
        Say "    [wsl2]"
        Say "    memory=8GB"
        Say "    processors=$HostLogicalCpus"
        Say ""
        Say "    [experimental]"
        Say "    autoMemoryReclaim=gradual"
        Write-Host ""
        SayWn "  autoMemoryReclaim lives under [experimental]; appending it to [wsl2] does nothing."
        SayWn "  Edit $WslCfgPath yourself, then run: wsl --shutdown"
        SayWn "  This installer does not modify that file -- it is yours and may hold other settings."
        Write-Host ""
    }
}

# -- Hyper-V Administrators membership (order 312) ---------------------------
# The tray's hvsocket VM lookup (hcsdiag) requires an ENABLED membership in
# Administrators or 'Hyper-V Administrators' (BUILTIN SID S-1-5-32-578) --
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
# -- Windows Event Log source (@trace spec:windows-event-logging) ------------
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

# -- Resolve version and base URL ---------------------------------------------
# The channel itself is resolved at the top of this script (order 1369-sjbc),
# before any host-side step runs; $Channel and $ChannelBase are set there.

if ($env:TILLANDSIAS_VERSION) {
    $Version = $env:TILLANDSIAS_VERSION.TrimStart('v')
    $Base = "https://github.com/$Repo/releases/download/v$Version"
    Say "Pinned to v$Version"
} else {
    $Base = $ChannelBase
    Say "Channel: $Channel"
    if ($Channel -eq 'unstable') {
        Say "  !! UNSTABLE channel - newest daily build, NOT promoted to stable."
        Say "     Expect breakage. Clear TILLANDSIAS_CHANNEL for the stable build."
    }
    Say "Resolving latest release..."
}

# -- Temp workspace ------------------------------------------------------------
$Tmp = Join-Path $env:TEMP "tillandsias-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

try {
    # -- Download SHA256SUMS-windows -------------------------------------------
    $SumsUrl = "$Base/SHA256SUMS-windows"
    Say "Fetching SHA256SUMS-windows..."
    try {
        Invoke-WebRequest -Uri $SumsUrl -OutFile "$Tmp\SHA256SUMS-windows" -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Could not download SHA256SUMS-windows from $SumsUrl -- check network or version."
    }

    # Find zip filename (e.g. tillandsias-tray-0.3.260622.4-windows-x64.zip)
    $SumsContent = Get-Content "$Tmp\SHA256SUMS-windows" -Raw
    $ZipName = ($SumsContent -split "`n" | Where-Object { $_ -match 'tillandsias-tray-.*-windows-x64\.zip' } |
                Select-Object -First 1 | ForEach-Object { ($_ -split '\s+')[1] }).Trim()
    if (-not $ZipName) { Die "No tillandsias-tray-*-windows-x64.zip entry in SHA256SUMS-windows." }
    Say "Asset: $ZipName"

    # -- Download zip ----------------------------------------------------------
    $ZipUrl = "$Base/$ZipName"
    Say "Downloading $ZipUrl..."
    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile "$Tmp\$ZipName" -UseBasicParsing -ErrorAction Stop
    } catch {
        Die "Download failed: $_"
    }

    # -- Verify SHA-256 --------------------------------------------------------
    Say "Verifying SHA-256..."
    $Expected = ($SumsContent -split "`n" | Where-Object { $_ -match [regex]::Escape($ZipName) } |
                 Select-Object -First 1 | ForEach-Object { ($_ -split '\s+')[0] }).ToLower()
    $Actual = (Get-FileHash "$Tmp\$ZipName" -Algorithm SHA256).Hash.ToLower()
    if ($Expected -ne $Actual) {
        Die "SHA-256 mismatch: expected $Expected, got $Actual"
    }
    SayOk "sha256: ok ($Expected)"

    # -- Stop running tray + back up --------------------------------------------
    Get-Process -Name 'tillandsias-tray' -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path $InstallDir) {
        $Backup = "$InstallDir.bak"
        Remove-Item -Recurse -Force $Backup -ErrorAction SilentlyContinue
        Say "Backing up existing install to $(Split-Path $Backup -Leaf)..."
        Rename-Item $InstallDir $Backup
    }

    # -- Extract ----------------------------------------------------------------
    Say "Extracting to $InstallDir..."
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path "$Tmp\$ZipName" -DestinationPath $InstallDir -Force
    if (-not (Test-Path $InstalledExe)) {
        Die "Extraction did not produce $InstalledExe -- zip may be corrupt."
    }
    # ORDER 1171-ccf2. Expand-Archive already places everything the zip carries,
    # so the headless probe binary needs no copy step -- only a word about
    # whether it arrived. Best-effort and NEVER fatal: a release cut before
    # 1171-ccf2 carries no tillandsias.exe and must still install its tray.
    # Said out loud because its ABSENCE is the condition that left a Windows
    # host unable to publish a capability row at all, and silence is what made
    # that hard to see.
    $InstalledHeadless = Join-Path $InstallDir $HeadlessName
    if (Test-Path $InstalledHeadless) {
        Say "  capability probe binary: $InstalledHeadless"
    } else {
        Say "  note: this release carries no $HeadlessName; the capability probe will have no runnable binary at this locus (1171-ccf2)"
    }

    # -- Start Menu shortcut ---------------------------------------------------
    New-Shortcut -LinkPath $ShortcutPath -Target $InstalledExe -Arguments '' -WorkDir $DataRootDir
    SayOk "Start Menu shortcut: $ShortcutPath"

    if ($LoginItem) {
        New-Shortcut -LinkPath $StartupLnk -Target $InstalledExe -Arguments '' -WorkDir $DataRootDir
        SayOk "Startup entry: $StartupLnk"
    }

    # -- Verify installation ---------------------------------------------------
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

    # -- Verify the install bits via --diagnose --json (order 1258-8wfb) ------
    # RESTORED. Added by d7bfcdd9f (2026-05-28), extended by 567009f68
    # (build_commit) and a9163cdaa (os_version / wsl_version), and removed by
    # 6cdaa8ac2 (2026-06-23) inside a wholesale installer rewrite that kept the
    # --version layer above and dropped this one. The litmus step guarding it
    # then reported PASS for three months, because its seven-conjunct grep
    # chain was adjudicated on NON-EMPTY OUTPUT instead of exit code: the first
    # conjunct matched, printed a line, and the step passed while five of the
    # seven returned rc=1. Do not weaken that step back to non-empty output.
    #
    # THIS CHECKS THE INSTALL, NOT THE PROVISIONING, and that distinction is
    # the only reason it can run here at all. From exit_code_from() in
    # crates/tillandsias-windows-tray/src/notify_icon.rs:
    #   exit 0 = re-install over an already-provisioned tray (phase Ready).
    #   exit 3 = distro registered and wire reachable, guest still converging.
    #            Explicitly not a failure.
    #   exit 2 = first install: the binary works and the distro is not
    #            provisioned yet, because --init has not run. THIS IS THE
    #            EXPECTED RESULT ON A CLEAN MACHINE and must not fail anything.
    #   exit 1 = the binary did not produce a verdict at all. exit_code_from()
    #            never returns 1, so this means crashed or unlaunchable: the
    #            install bits really are broken.
    # FAILING ON ANY NON-ZERO WOULD FAIL EVERY FIRST INSTALL. That is why the
    # test below is -eq 1 and not -ne 0, and why changing it needs this comment
    # read first.
    #
    # Ordering (agreed with yolanda for 1286-4437): this runs BEFORE anything
    # destructive, so a broken binary aborts here and never gets as far as
    # resetting a distro. The post-reprovision readiness check belongs to that
    # order, not to this one.
    #
    # Captured through cmd.exe for the same reason as --version above: the
    # release tray is GUI-subsystem and PowerShell's direct stdout capture is
    # unreliable for large writes.
    Say "Verifying install bits via --diagnose --json..."
    $DiagTmp = Join-Path $env:TEMP "tillandsias-install-diag-$([guid]::NewGuid().ToString('N')).json"
    & cmd.exe /c "`"$InstalledExe`" --diagnose --json > `"$DiagTmp`" 2>nul"
    $DiagExit = $LASTEXITCODE
    $DiagJson = Get-Content $DiagTmp -Raw -ErrorAction SilentlyContinue
    Remove-Item $DiagTmp -ErrorAction SilentlyContinue
    if ($DiagExit -eq 1) {
        Die "tillandsias-tray --diagnose --json hard-failed (exit $DiagExit); install bits broken."
    }
    if ($DiagJson) {
        try {
            $DiagReport = $DiagJson | ConvertFrom-Json -ErrorAction Stop
            $DiagCommit = if ($DiagReport.build_commit) { $DiagReport.build_commit } else { '(unknown)' }
            $DiagOsVer  = if ($DiagReport.os_version)   { $DiagReport.os_version }   else { '(not detected)' }
            $DiagWslVer = if ($DiagReport.wsl_version)  { $DiagReport.wsl_version }  else { '(not detected -- run wsl --install)' }
            SayOk "diagnose: version=$($DiagReport.version) commit=$DiagCommit (--diagnose exit $DiagExit)"
            SayOk "host:     OS=$DiagOsVer; WSL=$DiagWslVer"
        } catch {
            SayWn "--diagnose ran (exit $DiagExit) but its JSON did not parse; the binary may still be sound."
        }
    } else {
        SayWn "--diagnose ran (exit $DiagExit) but captured no JSON output."
    }

    # -- Reset and reprovision the local state (order 1286-4437) --------------
    # THE OPERATOR'S RULING: an irm|iex install is also the REPAIR for a broken
    # local state, so the install resets and reprovisions rather than leaving a
    # wedged guest in place. Ephemeral AND idempotent.
    #
    # WHY IT IS HERE AND NOT EARLIER. esme's --diagnose check above certifies
    # the INSTALL BITS and Dies on exit 1, so a binary that cannot run aborts
    # BEFORE anything is destroyed. This block certifies the RESULT. Two
    # verdicts, two subjects, and the order is the safety property: never
    # destroy on the strength of a binary you have not proven runnable.
    #
    # SYNCHRONOUS, AND THE INSTALLER EXITS WITH ITS STATUS. Measured on yolanda
    # 2026-09-20 across two smokes of v56.9.19.2: before this, the installer
    # ended by Start-Process'ing the tray and exiting 0 while provisioning ran
    # in the background, so it could not fail on a failed provision. A success
    # code that cannot fail is worse than an honest deferral, because it tells
    # the operator nothing is wrong.
    #
    # THE BINARY OWNS THE OPT-OUT. TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 is the one
    # documented affordance and --reset-state honors it itself, announcing the
    # skip and provisioning the existing state. This script therefore calls the
    # flag UNCONDITIONALLY and never reads that variable: one decision, one
    # place, so the installer and the binary cannot disagree.
    #
    # cmd.exe /c is the same wrapper the --version and --diagnose checks above
    # use, and for the same reason: the tray is a GUI-subsystem binary, so a
    # bare call does not wait and records no exit status (see the OUTPUT NOTE
    # in `tillandsias-tray.exe --help`).
    Write-Host ""
    # CAPABILITY PROBE BEFORE THE CALL, and it is not belt-and-braces. This
    # installer always DOWNLOADS the tray, and TILLANDSIAS_VERSION can pin an
    # older tag -- which is exactly what the release smoke does. A tray from
    # before 1286-4437 does not know --reset-state and exits 2 with
    # "unknown flag", so an unconditional call would turn every pinned-older
    # install into a hard failure at a step that did not exist when that tag
    # shipped.
    #
    # PROBE BY ATTEMPT, NOT BY ADVERTISEMENT (order 1323-5taw). This asked
    # `--help` whether the flag existed, which is defeated by exactly the
    # defect it was written to survive: a binary whose --help MENTIONS a flag
    # its parser REJECTS. That binary is not hypothetical -- v56.9.20.1's
    # published Linux headless does precisely this (its allow-list at
    # crates/tillandsias-headless/src/main.rs:612-651 carries no entry, and
    # pirria's install died on `Unsupported option: --reset-state`,
    # install_exit=2). Against such a tray the --help probe answers YES, the
    # installer proceeds, and it Dies on the exit 2 the probe existed to avoid.
    #
    # So attempt the flag and read the OUTCOME. The attempt is non-destructive
    # BY CONSTRUCTION: TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 is the flag's own
    # documented opt-out, honoured inside the binary, so a supporting tray
    # announces the skip and provisions the existing state (exit 0) while a
    # tray that does not know the flag refuses with "unknown flag" (exit 2).
    # That distinguishes a parser that honours the flag from a --help that
    # merely mentions it, which is the fleet's standing rule for stale
    # binaries: probe a refusal by asking for the refusal.
    #
    # NOT a version comparison: that would have to know which tag first
    # carried the flag and would be wrong for any build off that line.
    $ProbeLog = Join-Path $env:TEMP "tillandsias-reset-probe.log"
    & cmd.exe /c "set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0&& `"$InstalledExe`" --reset-state > `"$ProbeLog`" 2>&1"
    $ProbeExit = $LASTEXITCODE
    $ProbeOut = if (Test-Path $ProbeLog) { (Get-Content $ProbeLog -Raw) } else { "" }
    Remove-Item $ProbeLog -Force -ErrorAction SilentlyContinue
    # Exit 0 means the parser accepted it. An unknown-flag refusal is exit 2
    # and names itself; anything else is treated as unsupported too, because a
    # probe that cannot get a clean acceptance must not authorise a
    # destructive call.
    $HasResetState = ($ProbeExit -eq 0)
    if (-not $HasResetState) {
        SayWn "  probe: --reset-state not usable on this tray (exit $ProbeExit)."
        if ($ProbeOut) { SayWn ("  probe said: " + (($ProbeOut -split "`n")[0]).Trim()) }
    }
    if (-not $HasResetState) {
        SayWn "this tray predates --reset-state (order 1286-4437); skipping the state reset."
        SayWn "  the install is complete, but a broken local state was NOT repaired."
        SayWn "  install a release that carries --reset-state to get the repair."
    }
    if ($HasResetState) {
    Say "Resetting local state and reprovisioning (--reset-state)..."
    Say "  preserved: tillandsias-vm-uuid (the installation identity)"
    Say "  destroyed: the WSL2 distro and its disk, the two host vault credentials, the download cache"
    Say "  set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 to skip the destructive half"
    $ResetLog = Join-Path $env:TEMP "tillandsias-reset-state.log"
    & cmd.exe /c "`"$InstalledExe`" --reset-state > `"$ResetLog`" 2>&1"
    $ResetExit = $LASTEXITCODE
    if (Test-Path $ResetLog) {
        Get-Content $ResetLog | ForEach-Object { Write-Host "  $_" }
        Remove-Item $ResetLog -Force -ErrorAction SilentlyContinue
    }
    if ($ResetExit -ne 0) {
        Die "tillandsias-tray --reset-state failed (exit $ResetExit); the local state was not reprovisioned."
    }
    SayOk "reset-state: provisioned and ready (exit $ResetExit)"
    }

    # -- Installed-Software registration (windows-260722-3) -------------------
    # ONE idempotent HKCU key, SAME name every install: DisplayVersion is
    # updated in place, so Settings > Apps always shows exactly the latest
    # release and repeated updates can never accumulate entries. -Uninstall /
    # -Purge remove it. Publisher carries the macron via a codepoint so this
    # file stays pure ASCII (PS5.1 encoding gate, litmus-pinned).
    $InstalledVersion = ($VerLine -split '\s+')[1]
    $Publisher = "Tlato$([char]0x0101)ni"
    $UninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tillandsias'
    try {
        New-Item -Path $UninstKey -Force | Out-Null
        Set-ItemProperty -Path $UninstKey -Name 'DisplayName'     -Value 'Tillandsias'
        Set-ItemProperty -Path $UninstKey -Name 'DisplayVersion'  -Value $InstalledVersion
        Set-ItemProperty -Path $UninstKey -Name 'Publisher'       -Value $Publisher
        Set-ItemProperty -Path $UninstKey -Name 'InstallLocation' -Value $InstallDir
        Set-ItemProperty -Path $UninstKey -Name 'DisplayIcon'     -Value $InstalledExe
        Set-ItemProperty -Path $UninstKey -Name 'UninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\install-windows.ps1`" -Uninstall"
        Set-ItemProperty -Path $UninstKey -Name 'QuietUninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\install-windows.ps1`" -Purge"
        Set-ItemProperty -Path $UninstKey -Name 'NoModify' -Value 1 -Type DWord
        Set-ItemProperty -Path $UninstKey -Name 'NoRepair' -Value 1 -Type DWord
        $sizeKb = [int]((Get-Item $InstalledExe).Length / 1KB)
        Set-ItemProperty -Path $UninstKey -Name 'EstimatedSize' -Value $sizeKb -Type DWord
        SayOk "Registered in Installed Software (v$InstalledVersion)."
    } catch {
        SayWn "Installed-Software registration failed ($_) - continuing."
    }

    # -- Tray-icon settings hygiene (windows-260722-3) ------------------------
    # Windows keys 'Taskbar corner / Other system tray icons' entries by
    # executable path. Old installs at other paths (or deleted binaries)
    # leave dead entries that read as duplicates. Drop every
    # tillandsias-tray.exe entry whose path is NOT the canonical installed
    # exe or whose target no longer exists.
    try {
        $nis = 'HKCU:\Control Panel\NotifyIconSettings'
        if (Test-Path $nis) {
            Get-ChildItem $nis | ForEach-Object {
                $p = (Get-ItemProperty -Path $_.PSPath -Name 'ExecutablePath' -ErrorAction SilentlyContinue).ExecutablePath
                if ($p -and ($p -like '*tillandsias-tray.exe') -and (($p -ne $InstalledExe) -or -not (Test-Path $p))) {
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    Say "  removed stale tray-icon entry: $p"
                }
            }
        }
    } catch {}

    # -- Launch (triggers WSL2 provisioning = tillandsias --init) -------------
    Write-Host ""
    if (-not $NoLaunch) {
        Say "Launching Tillandsias (WSL2 provisioning = --init will run automatically)..."
        Start-Process -FilePath $InstalledExe -WorkingDirectory $DataRootDir
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
