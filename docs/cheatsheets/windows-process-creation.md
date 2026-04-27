---
tags: [windows, process, createprocess, rust, tray]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags
authority: high
status: current
---

# Windows Process Creation Flags — Cheatsheet

@trace spec:podman-orchestration

## The Problem

After `FreeConsole()` in tray mode, spawning child processes with `CREATE_NO_WINDOW` can fail with **OS error 50** (`ERROR_NOT_SUPPORTED`) if the inherited stdio handles are stale/invalid.

## Root Cause

Rust's stdlib sets `STARTF_USESTDHANDLES` in the `STARTUPINFO` struct when spawning child processes. After `FreeConsole()`, the handles returned by `GetStdHandle()` become invalid. Passing invalid handles to `CreateProcessW` with `STARTF_USESTDHANDLES` causes error 50.

**Fix**: Explicitly pipe all stdio handles so `CreateProcessW` gets valid pipe handles instead of stale console handles.

## Creation Flag Reference

The following flags are used by `CreateProcess`, `CreateProcessAsUser`, `CreateProcessWithLogonW`, and `CreateProcessWithTokenW`. They apply to Windows XP / Server 2003 and later.

| Flag | Value | Behavior (parent has console) | Behavior (parent consoleless) |
|------|-------|-------------------------------|-------------------------------|
| (none) | 0 | Child inherits parent console | **Visible console window flashes** |
| `CREATE_NO_WINDOW` | 0x08000000 | Child gets hidden console | Child gets hidden console (correct) |
| `DETACHED_PROCESS` | 0x00000008 | Child has no console at all | Child has no console (stdout=NULL) |
| `CREATE_NEW_CONSOLE` | 0x00000010 | **Visible console window** | **Visible console window** |

`CREATE_NO_WINDOW`: "The process is a console application that is being run without a console window. Therefore, the console handle for the application is not set. This flag is ignored if the application is not a console application, or if it is used with either CREATE_NEW_CONSOLE or DETACHED_PROCESS."

`DETACHED_PROCESS`: "For console processes, the new process does not inherit its parent's console (the default). The new process can call the AllocConsole function at a later time to create a console." Cannot be combined with `CREATE_NEW_CONSOLE`.

`CREATE_NEW_CONSOLE`: "The new process has a new console, instead of inheriting its parent's console (the default). This flag cannot be used with DETACHED_PROCESS."

## Correct Pattern for Tray Apps

```rust
// Always use CREATE_NO_WINDOW + explicit stdio piping.
// Works both with and without a console.
#[cfg(target_os = "windows")]
{
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
}
```

Callers that need interactive stdio (e.g., `podman run -it`) **override** with `.stdin(Stdio::inherit())` etc. — those callers must NOT use `podman_cmd_sync()` anyway (they use raw `Command::new(find_podman_path())`).

## Key Rules

- **Background podman calls** (image checks, builds, container stops): use `podman_cmd()` / `podman_cmd_sync()` — CREATE_NO_WINDOW + piped stdio
- **Interactive podman calls** (`--bash`, `--github-login`): use raw `Command::new(find_podman_path())` — NO creation flags, inherited stdio
- **Never use `DETACHED_PROCESS`** for podman — stdout becomes NULL, output is silently lost after ~4KB
- **Never pass no flags from a consoleless process** — a visible console window will flash

## References

- [rprichard/win32-console-docs](https://github.com/rprichard/win32-console-docs) — empirical CreateProcess flag testing
- [Rust #101645](https://github.com/rust-lang/rust/issues/101645) — STARTF_USESTDHANDLES with invalid handles
- [MS Docs: Process Creation Flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags)

## Provenance

- https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags — Windows SDK `WinBase.h` process creation flags; `CREATE_NO_WINDOW` (0x08000000) hides console window; `DETACHED_PROCESS` (0x00000008) detaches from parent console; `CREATE_NEW_CONSOLE` (0x00000010) opens new visible console; all used by `CreateProcess` family
- **Last updated:** 2026-04-27
