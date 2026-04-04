# Windows Process Creation Flags — Cheatsheet

@trace spec:podman-orchestration

## The Problem

After `FreeConsole()` in tray mode, spawning child processes with `CREATE_NO_WINDOW` can fail with **OS error 50** (`ERROR_NOT_SUPPORTED`) if the inherited stdio handles are stale/invalid.

## Root Cause

Rust's stdlib sets `STARTF_USESTDHANDLES` in the `STARTUPINFO` struct when spawning child processes. After `FreeConsole()`, the handles returned by `GetStdHandle()` become invalid. Passing invalid handles to `CreateProcessW` with `STARTF_USESTDHANDLES` causes error 50.

**Fix**: Explicitly pipe all stdio handles so `CreateProcessW` gets valid pipe handles instead of stale console handles.

## Creation Flag Reference

| Flag | Value | Behavior (parent has console) | Behavior (parent consoleless) |
|------|-------|-------------------------------|-------------------------------|
| (none) | 0 | Child inherits parent console | **Visible console window flashes** |
| `CREATE_NO_WINDOW` | 0x08000000 | Child gets hidden console | Child gets hidden console (correct) |
| `DETACHED_PROCESS` | 0x00000008 | Child has no console at all | Child has no console (stdout=NULL) |
| `CREATE_NEW_CONSOLE` | 0x00000010 | **Visible console window** | **Visible console window** |

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
