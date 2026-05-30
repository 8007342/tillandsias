# build-windows-tray — 2026-05-29

**Branch:** windows-next @ `f66e9fcc` (then FF'd local to `707871c4` from linux-next)
**FF result:** pulled 34 commits from linux-next (slice 30 architectural-invariants + m10/m11 + forge tooling).
**Build:** `Finished release profile [optimized] target(s) in 47.16s` — clean.
**Install:** `3968000 -> 6326272` bytes (May 25 → May 29) at `%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe`.
**--diagnose --json exit:** `2` (degraded — VM idled out, expected on a cold day-loop).
**Version:** `0.1.0`
**Manifest pin:** `a28cabe7c9df`
**Distro registered:** `true`
**Wire reachable:** `false` (phase=`null`, podman_ready=`null`; expected — no keepalive between loop fires).

## Findings

- **PowerShell `& scripts\install-windows.ps1` mis-wraps cargo stderr.** When
  invoked through the PowerShell tool the install script's nested
  `& scripts\build-windows-tray.ps1` call exits exit-code 1 immediately on
  cargo's `Compiling …` / `Finished` stderr lines (interpreted as
  `NativeCommandError` due to the wrapper's `$ErrorActionPreference = 'Stop'`).
  Workaround documented in `skills/build-windows-tray/SKILL.md`: invoke `cargo build`
  + `Copy-Item` directly. **Follow-up worth filing:** add a `-SkipBuild` flag to
  `install-windows.ps1` so this skill can call the script for the
  install-semantic side (shortcut creation, autostart wiring) without retripping
  the build's stderr handling.

- **File-in-use on copy.** A running installed tray locked
  `tillandsias-tray.exe` (May 25 vintage) until the loop killed it. The skill
  now does `Stop-Process … -Force; Start-Sleep 2` before the copy — 2 s is the
  empirical lower bound on Windows file-handle release after process exit.

## No cross-host escalation needed
