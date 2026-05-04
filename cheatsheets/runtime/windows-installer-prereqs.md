---
tags: [windows, wsl2, installer, hyper-v, virtualization, dism, prerequisites, hard-requirement]
languages: [powershell, bash]
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/install
  - https://learn.microsoft.com/en-us/windows/wsl/install-manual
  - https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-windows-edition-servicing-command-line-options
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# Windows installer prerequisites — WSL2 hard requirement

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:chromium-browser-isolation, spec:install-progress

**Version baseline**: Windows 10 build 19041+ / Windows 11 (any SKU including Home).
**Use when**: implementing the one-line `install.ps1` / `install.sh` curl installer's prerequisite-check prelude. WSL2 is a HARD requirement; the installer SHALL short-circuit with a clear remediation message if any check fails, BEFORE downloading the tray binary or distro tarball.

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/install> — `wsl --install`, `wsl --install --no-distribution`, automatic feature enablement, default WSL2 setting
- <https://learn.microsoft.com/en-us/windows/wsl/install-manual> — manual install sequence: dism feature enablement, kernel MSI, `wsl --set-default-version 2`
- <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements> — x64+SLAT+VT/AMD-V+DEP/NX hardware requirements
- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — `wsl --status`, `wsl --list --verbose`, `wsl --version`, `wsl --update`
- <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-windows-edition-servicing-command-line-options> — `dism.exe /online /enable-feature` semantics
- **Last updated:** 2026-04-28

## The hard-requirement matrix

Every row is a check that SHALL run before any Tillandsias artifact is downloaded. If any row reports FAIL, the installer SHALL exit non-zero with a remediation message that includes the relevant Microsoft Learn URL.

| # | Check | Pass criterion | Vendor citation (verbatim) |
|---|---|---|---|
| 1 | **Windows version** | Win 10 build ≥ 19041 OR Win 11 (any) | "You must be running Windows 10 version 2004 and higher (Build 19041 and higher) or Windows 11 to use the commands below." — `install` |
| 2 | **Architecture** | x64 (any Windows); arm64 only on Win 11 | "WSL is supported on Windows 10 Build 19041 and higher and Windows 11" — `install`. ARM64 + Win 10 has no WSL2 kernel MSI; only Win 11 ARM64 is published |
| 3 | **CPU virtualization extensions** (VT-x or AMD-V) | `systeminfo` Hyper-V Requirements → "VM Monitor Mode Extensions: Yes" | "Hardware-assisted virtualization. This is available in processors that include a virtualization option — specifically processors with Intel Virtualization Technology (Intel VT) or AMD Virtualization (AMD-V) technology." — `host-hardware-requirements` |
| 4 | **SLAT** | systeminfo Hyper-V → "Second Level Address Translation: Yes" | "A 64-bit processor with second-level address translation (SLAT). To install the Hyper-V virtualization components such as Windows hypervisor, the processor must have SLAT." — `host-hardware-requirements` |
| 5 | **DEP/NX** | systeminfo Hyper-V → "Data Execution Prevention Available: Yes" | "Hardware-enforced Data Execution Prevention (DEP) must be available and enabled. For Intel systems, this is the XD bit (execute disable bit). For AMD systems, this is the NX bit (no execute bit)." — `host-hardware-requirements` |
| 6 | **Virtualization enabled in firmware (BIOS/UEFI)** | systeminfo Hyper-V → "Virtualization Enabled In Firmware: Yes" | (same `host-hardware-requirements` page; UEFI/BIOS toggle is a host-side config, not a script-toggleable check) |
| 7 | **`VirtualMachinePlatform` Windows feature** | enabled (or installer enables it) | `dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart` — `install-manual` step 3 |
| 8 | **`Microsoft-Windows-Subsystem-Linux` Windows feature** | enabled (or installer enables it) | `dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart` — `install-manual` step 1 |
| 9 | **WSL kernel installed** | `wsl --status` reports a kernel version | "`wsl --status` … Lists information about your WSL configuration, including the default distribution and the kernel version." — `basic-commands` |
| 10 | **WSL default version is 2** | `wsl --status` reports `Default Version: 2`; otherwise installer runs `wsl --set-default-version 2` | "`wsl --set-default-version 2` … Used to set the default Linux distribution version to either WSL 1 or WSL 2." — `install-manual` |
| 11 | **RAM** | ≥ 4 GB host (8 GB recommended for Tillandsias) | "Plan for at least 4 GB of RAM. More memory is better." — `host-hardware-requirements` |

## The canonical install sequence (vendor-quoted)

The installer's "happy path" — what to run when prerequisites 1-6 pass and 7-10 are missing:

```powershell
# Enable required Windows features (admin elevation required)
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# Install WSL kernel + set v2 default; --no-distribution skips the bundled Ubuntu
wsl --install --no-distribution
wsl --set-default-version 2
wsl --update
```

`wsl --install` is the **modern unified path** (Microsoft Learn `install` page): *"You must be running Windows 10 version 2004 and higher (Build 19041 and higher) or Windows 11 to use the commands below. … `wsl --install`."* On systems already on a recent enough build, `wsl --install --no-distribution` does feature-enablement + kernel-install in one step, replacing the manual `dism` sequence above. The `dism` invocations are kept here as the **fallback path** for builds where `wsl --install` isn't available or fails — the dism approach is documented at `install-manual`.

`wsl --set-default-version 2` is documented at `install-manual` step 6: *"Open PowerShell and run this command to set WSL 2 as the default version when installing a new Linux distribution: `wsl --set-default-version 2`"*.

`wsl --update` keeps the kernel current; per `basic-commands`: *"Update the WSL Linux kernel to the latest version available."*

**Reboot requirement**: enabling `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` requires a reboot **before** `wsl --install` can complete kernel install. The `--norestart` dism flag suppresses the auto-reboot so the installer can ask the user politely. After reboot, the user re-runs the installer and the prereq check now sees the features enabled and proceeds.

## PowerShell detection block (the installer's prelude)

```powershell
function Test-Tillandsias-WslPrereqs {
    [CmdletBinding()]
    param([switch]$Quiet)

    # @trace spec:install-progress, spec:windows-wsl-runtime, spec:cross-platform
    # @cheatsheet runtime/windows-installer-prereqs.md
    # SHALL short-circuit BEFORE downloading any Tillandsias artifact.

    $errors = @()

    # 1. Windows version
    $os = [System.Environment]::OSVersion.Version
    $build = [int]((Get-CimInstance Win32_OperatingSystem).BuildNumber)
    if ($os.Major -eq 10 -and $build -lt 19041) {
        $errors += "Windows 10 build $build < 19041. WSL2 requires 19041+. Update Windows: https://aka.ms/wslinstall"
    }
    if ($os.Major -lt 10) {
        $errors += "Windows version $($os) is too old. WSL2 requires Win 10 build 19041+ or Win 11."
    }

    # 2. Architecture
    $arch = (Get-CimInstance Win32_ComputerSystem).SystemType
    if ($arch -match "ARM64" -and $os.Major -eq 10) {
        $errors += "Windows 10 ARM64 has no WSL2 kernel MSI. Upgrade to Windows 11 ARM64."
    }
    if ($arch -notmatch "x64|AMD64|ARM64") {
        $errors += "Architecture '$arch' not supported (x64 or arm64 required)."
    }

    # 3-6. Hyper-V hardware capabilities — single systeminfo invocation
    $sysinfo = systeminfo.exe 2>$null
    $required = @{
        "VM Monitor Mode Extensions"        = "VT-x / AMD-V"
        "Second Level Address Translation"  = "SLAT (EPT/NPT)"
        "Data Execution Prevention Available" = "DEP / NX bit"
        "Virtualization Enabled In Firmware" = "BIOS/UEFI virtualization"
    }
    foreach ($key in $required.Keys) {
        $line = $sysinfo | Select-String -Pattern "^\s*$key\s*:\s*(\S+)" | Select-Object -First 1
        if (-not $line -or $line.Matches[0].Groups[1].Value -ne "Yes") {
            $errors += "$($required[$key]) not available. https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements"
        }
    }

    # 11. RAM (advisory — warn but don't block at 4 GB; block below 4)
    $ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($ram_gb -lt 4) {
        $errors += "Only $ram_gb GB RAM. WSL2 requires ≥4 GB; Tillandsias recommends ≥8 GB."
    } elseif ($ram_gb -lt 8 -and -not $Quiet) {
        Write-Warning "Only $ram_gb GB RAM. Tillandsias recommends ≥8 GB for the forge + inference + browser stack."
    }

    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host "Tillandsias installer cannot proceed:" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "  ✗ $e" -ForegroundColor Red }
        Write-Host ""
        Write-Host "See: https://learn.microsoft.com/en-us/windows/wsl/install" -ForegroundColor Yellow
        return $false
    }

    # 7-8. Required Windows features (idempotent enable; user reboot needed if newly enabled)
    $features = @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")
    $needs_reboot = $false
    foreach ($f in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
        if ($state -ne "Enabled") {
            if (-not $Quiet) { Write-Host "Enabling Windows feature: $f" -ForegroundColor Cyan }
            dism.exe /online /enable-feature /featurename:$f /all /norestart | Out-Null
            $needs_reboot = $true
        }
    }
    if ($needs_reboot) {
        Write-Host ""
        Write-Host "REBOOT REQUIRED" -ForegroundColor Yellow
        Write-Host "Windows features were enabled. Reboot, then re-run the installer." -ForegroundColor Yellow
        return $false
    }

    # 9-10. WSL kernel installed and v2 default?
    $wsl_status = wsl.exe --status 2>$null
    if (-not $wsl_status) {
        if (-not $Quiet) { Write-Host "Installing WSL kernel (no distribution)..." -ForegroundColor Cyan }
        wsl.exe --install --no-distribution
        wsl.exe --update
    }
    $wsl_status = wsl.exe --status 2>$null
    # Default version 2 — `wsl --set-default-version 2` is idempotent
    wsl.exe --set-default-version 2 | Out-Null

    return $true
}

if (-not (Test-Tillandsias-WslPrereqs)) { exit 1 }
```

## Common pitfalls

- **`systeminfo` is slow** (5-10 s on a fresh boot). Cache the output and reuse for all four Hyper-V Requirements checks; do NOT re-invoke systeminfo per row. The skeleton above gets this right.
- **`Get-WindowsOptionalFeature` requires admin** to read state on some SKUs. Run the installer as admin (`Start-Process powershell -Verb RunAs`) — `dism` modifications below ALSO require admin.
- **`wsl --status` exit code is unreliable** as a "WSL is installed" indicator; some Windows builds return 0 even when the kernel isn't present. Match output content (`-match "Default Version"`), don't rely on `$LASTEXITCODE` alone.
- **`wsl --install --no-distribution` on a system without features enabled** may return exit 0 but actually fail silently — Microsoft's recommendation since `install` page is to enable the two dism features explicitly first as belt-and-suspenders.
- **VirtualBox < 7.0 conflicts with VirtualMachinePlatform.** Not a Microsoft Learn citation, but a documented compatibility issue. If `VBoxManage.exe` is in PATH and reports < 7.0, warn the user; mitigation is upgrade-VBox or accept Hyper-V will deactivate VBox-VT-x.
- **Nested virtualization** (running inside a cloud VM or another hypervisor): Microsoft only documents it works on Intel Cascade Lake+ / AMD EPYC 2nd gen+. Cloud images vary. The installer cannot reliably auto-detect; warn-but-don't-block.
- **The reboot loop**: if the user runs the installer, gets "REBOOT REQUIRED", reboots, re-runs, and STILL gets the message — the dism enable failed silently. Have the installer surface the dism exit code on the second pass.
- **WSL on Windows Home is supported**, despite Windows Sandbox NOT being supported on Home. WSL2 + Tillandsias should work on Home. (Windows Sandbox cheatsheet excludes Home; this one does NOT — verify your messaging on the Tillandsias landing page reflects this.)
- **`dism /norestart` does not mean "reboot is optional"** — it means "do not auto-reboot". The features ARE staged for activation but won't take effect until the next reboot. The installer must instruct the user to reboot, not assume features are active.

## bash equivalent (for `install.sh` cygwin/git-bash fallback)

For users running curl-pipe-bash from Git Bash or Cygwin on Windows. Most prereq checks must still happen via `powershell.exe -Command` since they're Windows-specific:

```bash
#!/usr/bin/env bash
# @trace spec:install-progress, spec:windows-wsl-runtime, spec:cross-platform
# @cheatsheet runtime/windows-installer-prereqs.md
set -euo pipefail

# Detect host OS — if not Windows, this script's WSL2 prereqs don't apply.
case "$OSTYPE" in
  msys*|cygwin*|win32*)
    ;;
  *)
    echo "This installer's WSL2 prereq check applies only to Windows. Skipping."
    exit 0
    ;;
esac

# Delegate to PowerShell for the actual checks.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
  iex (irm https://github.com/8007342/tillandsias/releases/latest/download/install-prereqs.ps1)
"
```

## See also

- `runtime/wsl-on-windows.md` — `wsl --import` semantics, drvfs gotchas
- `runtime/wsl-mount-points.md` — drvfs ownership reporting (irrelevant once `/mnt/c` is disabled)
- `runtime/wsl2-isolation-boundary.md` — what crosses the WSL2 boundary (planned)
- `runtime/fedora-minimal-wsl2.md` — building the tillandsias distro (planned)
- `runtime/podman-in-wsl2.md` — podman quirks under WSL2 (planned)

## Pull on Demand

### Source

This cheatsheet documents the hard-requirement checks that the Tillandsias Windows installer must perform before downloading any artifacts. Covers hardware (VT-x, SLAT, DEP/NX), OS version (Win 10 19041+), and Windows feature enablement (VirtualMachinePlatform, Microsoft-Windows-Subsystem-Linux).

### Materialize recipe

```bash
#!/bin/bash
# WSL2 prerequisite validation for Tillandsias on Windows
# @trace spec:install-progress, spec:windows-wsl-runtime

# Run PowerShell-based checks (hardware, OS version, features)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
  # Hardware checks via systeminfo
  \$sysinfo = systeminfo.exe
  \$vt = \$sysinfo | Select-String 'VM Monitor Mode Extensions.*Yes'
  \$slat = \$sysinfo | Select-String 'Second Level Address Translation.*Yes'
  \$dep = \$sysinfo | Select-String 'Data Execution Prevention.*Yes'
  
  if (-not \$vt -or -not \$slat -or -not \$dep) {
    Write-Host 'Hardware requirements not met' -ForegroundColor Red
    exit 1
  }
  
  # Enable required features
  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
  
  # Install WSL kernel
  wsl.exe --install --no-distribution
  wsl.exe --set-default-version 2
  wsl.exe --update
"
```

### Generation guidelines

This cheatsheet is hand-curated and tracked in-repo. Regenerate after:
1. Changes to wsl.exe command flags or behavior
2. Updates to DISM feature names
3. New Windows builds that affect minimum OS requirement (19041)
4. Changes to Hyper-V hardware requirements

### License

License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) Content derived from Microsoft Learn (public documentation).
Last materialized: 2026-05-03
