---
title: Windows process creation flags
description: Spawning child processes on Windows without flashing console windows
tags: [windows, process, console, ui, native]
since: Win10 1809+
last_verified: 2026-04-28
authority: high
status: current
tier: pull-on-demand
sources:
  - https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags
  - https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
  - https://doc.rust-lang.org/std/os/windows/process/trait.CommandExt.html
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
---

# Windows process creation flags

@trace spec:cross-platform, spec:windows-wsl-runtime, spec:no-terminal-flicker
@cheatsheet runtime/wsl-on-windows.md, runtime/powershell.md

**Use when**: spawning native exes (`wsl.exe`, `podman.exe`, `cmd.exe`, anything that allocates a console) from a Windows GUI process or a PowerShell-backgrounded task. Without `CREATE_NO_WINDOW` each spawn flashes a console window, even with stdio redirected.

## Provenance

- [Process Creation Flags reference](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags) — Microsoft Learn (canonical CreateProcess flag table)
- [CreateProcessW API](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw) — Microsoft Learn
- [`std::os::windows::process::CommandExt`](https://doc.rust-lang.org/std/os/windows/process/trait.CommandExt.html) — Rust stdlib (the `creation_flags` extension trait)

**Last updated:** 2026-04-28

## Quick reference

| Flag | Hex | Behavior |
|------|-----|----------|
| `CREATE_NEW_CONSOLE` | `0x00000010` | Force a NEW console window even if parent has one. Default on `start /b` style spawns. |
| `CREATE_NO_WINDOW` | `0x08000000` | Suppress console window for a console-subsystem child. Use this for `wsl.exe`, `podman.exe`, etc. when launched from a GUI parent. |
| `DETACHED_PROCESS` | `0x00000008` | Like CREATE_NO_WINDOW but child has NO console at all (not even hidden). Mutually exclusive with CREATE_NEW_CONSOLE. |
| `CREATE_BREAKAWAY_FROM_JOB` | `0x01000000` | Child is not bound to the parent's job object — survives parent termination. |

## Rust pattern (Tillandsias canonical helper)

```rust
// crates/tillandsias-podman/src/lib.rs
#[cfg(target_os = "windows")]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub fn no_window_async(cmd: &mut tokio::process::Command) -> &mut tokio::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.as_std_mut().creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}
pub fn no_window_sync(cmd: &mut std::process::Command) -> &mut std::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}
```

Apply at every spawn site:

```rust
let mut cmd = tokio::process::Command::new("wsl.exe");
tillandsias_podman::no_window_async(&mut cmd);
let output = cmd.args(["--list", "--quiet"]).output().await?;
```

## When NOT to suppress

- **Foreground interactive terminals** — if you're running an attach where the user expects to see the calling terminal, the child should inherit the parent's console (default). Don't apply `CREATE_NO_WINDOW` to the entrypoint launch in a CLI attach.
- **Long-running detached daemons that need a console** — rare; use a Windows Service instead.

## When to PREFER `DETACHED_PROCESS` over `CREATE_NO_WINDOW`

- The child is a daemon you spawn and walk away from. With `DETACHED_PROCESS`, the child cannot ever inherit a TTY (cleaner). With `CREATE_NO_WINDOW`, the child has a hidden console which is "almost detached" but stdio operations still target it.

## How to verify the fix

```powershell
# Before: every wsl.exe spawn flashes a console for ~50ms.
# After: silent. You can monitor with Sysinternals Process Monitor:
procmon.exe /Filter "ProcessName is wsl.exe"
# Look at the "Process Create" events — Image flags should not include
# 0x10 (CREATE_NEW_CONSOLE).
```

Or programmatically check via WMI:

```powershell
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Select-Object ProcessId, CommandLine
```

## Pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Apply only on async or only on sync `Command` | Random surviving flickers | Have BOTH `no_window_async` and `no_window_sync` and apply at every spawn site |
| Forget on a single call site | One stubborn flicker | `git grep 'Command::new("wsl.exe")'` to find all sites; require helper |
| Apply to interactive forge launch | TUI dies (no console) | Skip CLI attach launch — that one needs the inherited terminal |
| Use `DETACHED_PROCESS` when you need stdin | Child can't read input | `CREATE_NO_WINDOW` keeps a hidden console, allows pipes |
| Forget on `tokio::process::Command` | Async spawns flicker | tokio Command exposes `as_std_mut()`; use it |

## See also

- `cheatsheets/runtime/wsl-on-windows.md` — wsl.exe semantics
- `cheatsheets/runtime/powershell.md` — Stop-Process / Start-Process equivalents
- `cheatsheets/runtime/cmd.md` — `start /b` background launching
