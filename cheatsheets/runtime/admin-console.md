---
tags: [admin, windows, uac, runas, sudo, powershell, cmd]
languages: [batch, powershell]
since: 10
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/sudo/
  - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/runas
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
---

# Admin / elevated console on Windows

@trace spec:cross-platform

**Use when**: a Windows operation fails with "access denied" or
"administrator privileges required", or you need to install a driver,
register a service, or modify a system path. Most Tillandsias dev
operations run as a normal user — elevation is rare and should be
deliberate.

## Provenance

- <https://learn.microsoft.com/en-us/windows/sudo/> — `sudo for Windows` overview, modes, configuration. Shipped in Windows 11 23H2+.
- <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/runas> — `runas` switches, `/user:`, `/savecred`, `/profile`.
- **Last updated:** 2026-04-28

## When admin IS needed

| Task | Why |
|---|---|
| `wsl --install` (first time) | enables the WSL Windows feature; touches the kernel registration |
| Installing **drivers** (GPU, USB, virtualisation) | kernel-mode signing checks |
| Installing / removing a **Windows service** (`sc create`, `sc delete`) | service control manager is privileged |
| Modifying **HKLM** registry keys (machine-wide settings) | requires SYSTEM or admin token |
| Writing under `%ProgramFiles%`, `%ProgramData%`, `C:\Windows` | NTFS ACLs |
| `setx /M` (machine-wide env var) | writes HKLM\SYSTEM\...\Environment |
| Opening **privileged ports** (<1024) without firewall rule pre-grant | listen-port reservation |
| `bcdedit`, `dism`, `sfc`, `chkdsk /F` on system drive | system-state mutation |
| Hyper-V VM management (some commands) | hypervisor APIs |

## When admin is NOT needed (most dev work)

| Task | Runs as user |
|---|---|
| `cargo build`, `cargo test`, `cargo run` | yes |
| `podman` against `podman machine` (after machine is set up) | yes |
| `git`, `gh`, `npm`, `pip`, `uv`, `pnpm` | yes |
| `tillandsias --init` (builds images inside `podman machine`) | yes |
| Writing under `%LOCALAPPDATA%`, `%APPDATA%`, `%USERPROFILE%` | yes |
| `setx FOO bar` (user-scope env var) | yes |
| Listening on ports ≥ 1024 | yes |
| Creating files in your repo, your home dir | yes |

If you're being prompted for UAC during normal Tillandsias dev, something
is wrong — investigate before approving.

## Detecting whether you're already elevated

```bat
:: cmd.exe — exit code 0 if elevated, non-zero if not.
:: S-1-16-12288 = Mandatory Label\High Mandatory Level (admin token).
whoami /groups | findstr /C:"S-1-16-12288" >nul
if %ERRORLEVEL%==0 (echo elevated) else (echo NOT elevated)
```

```powershell
# PowerShell — boolean check.
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"$elevated"   # True or False
```

Use this guard at the top of any script that requires elevation, so you
fail fast with a useful message instead of a cryptic ACL error 200 lines
in.

## Elevating from a non-admin shell

### `runas` — classic, prompts for password (no UAC dialog)

```bat
runas /user:Administrator "cmd /k"
runas /user:%COMPUTERNAME%\Administrator "powershell -NoProfile"
runas /user:DOMAIN\admin /savecred "myinstaller.exe"
```

`/savecred` caches credentials in Credential Manager. **Avoid** on shared
machines — anyone in the same session can replay the cached creds via
another `runas /savecred`.

### `Start-Process -Verb RunAs` — UAC prompt (PowerShell)

```powershell
# Re-launch self as admin (UAC dialog appears):
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-File', $PSCommandPath

# Run a single elevated command and wait for it:
Start-Process -FilePath 'wsl.exe' -ArgumentList '--install' -Verb RunAs -Wait
```

This triggers the standard UAC consent dialog. Use this in installer
scripts that must elevate halfway through. The new process inherits
**none** of the parent's variables — pass everything via `-ArgumentList`
or env vars set with `setx` first.

### `sudo` — Windows 11 23H2+ native sudo

```powershell
# Inline mode — runs in the current console, prompts UAC, returns to your shell:
sudo --inline winget install RedHat.Podman

# New-window mode (default) — opens a separate elevated console:
sudo wsl --install

# Disabled mode — admin accidentally enabled? Check:
sudo --status
```

Modes (set in **Settings → System → For developers → Enable sudo**):

| Mode | Behaviour |
|---|---|
| **Disabled** | `sudo` not available |
| **In a new window** | spawns a new admin console (default; safest) |
| **With input disabled** | runs inline, but no stdin is forwarded to the elevated child |
| **Inline** | runs inline with full I/O forwarding (closest to Linux `sudo`) |

`sudo --inline` is the right choice for scripted use; the other modes
break pipes. Note `sudo` is per-user on Windows and **does not** consult
`/etc/sudoers` — every invocation produces a UAC prompt. **Last
updated: 2026-04-28**.

## Common pitfalls

- **UAC strips inherited env / mapped drives** — an elevated child does NOT see your user's mapped network drives or session-only env vars. `setx` first if the elevated process needs them.
- **`runas /user:Administrator` requires the built-in Administrator account to be enabled** — disabled by default since Windows 10. Use `Start-Process -Verb RunAs` (which elevates the **current** account) instead.
- **`sudo` ≠ Linux sudo** — every invocation prompts UAC; there is no timestamp cache, no `/etc/sudoers`, no `NOPASSWD`. Don't write loops that call `sudo` repeatedly.
- **`sudo` modes affect script reliability** — if a teammate has "in a new window" mode, your `sudo --inline` script fails differently than yours does. Document the required mode (or detect via `sudo --status` and bail with a clear message).
- **Detection via `net session`** — older guides recommend `net session` to detect elevation. It works but is slow (talks to LanmanServer) and emits to stderr on failure. Prefer the `whoami /groups` SID check above.
- **`Start-Process -Verb RunAs` returns immediately** — without `-Wait`, your script continues while the elevated child still runs. Race conditions follow. Always pass `-Wait` when subsequent steps depend on the elevated work.
- **Elevation does NOT cross WSL boundary** — running `sudo` inside WSL invokes Linux sudo (against the WSL distro's `/etc/sudoers`), not Windows UAC. Conversely, an elevated cmd.exe that runs `wsl bash` enters WSL as the **default WSL user**, not root.

## See also

- `runtime/cmd.md` — non-elevated cmd-line basics; this file is the elevation layer on top.
- `runtime/wsl-on-windows.md` — WSL install requires admin (one-time); day-to-day WSL use does not.
- `runtime/windows-native-dev-build.md` — Tillandsias dev install on Windows; runs entirely as user.
