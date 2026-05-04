//! @trace spec:tray-cli-coexistence, spec:tray-ux
//!
//! Spawn a detached child process running the tray, alongside a CLI mode.
//!
//! The child re-invokes the same `tillandsias` binary with no positional
//! arguments — i.e., bare tray mode. It detaches from the parent's process
//! group and stdio so that:
//!   - it survives the parent's exit (CLI returns to shell, tray persists),
//!   - it does not appear in `jobs` / does not get SIGHUP'd when the user
//!     closes the controlling terminal,
//!   - its stdout/stderr cannot leak into the CLI parent's log stream.
//!
//! The singleton guard inside the child (`crate::singleton::try_acquire()`)
//! handles the "tray already running" race — that child exits silently in
//! milliseconds and is not an error to surface to the user.

use std::process::{Command, Stdio};

/// Spawn a detached child process running the tray with no positional args.
///
/// Returns `Ok(())` if the spawn syscall succeeded. The child runs the same
/// `tillandsias` binary; if a tray is already running, the singleton guard
/// inside the child causes it to exit silently in milliseconds — that is
/// fine and not an error to surface.
///
/// All errors are logged with `warn!` and swallowed by the caller — the CLI
/// must not fail because the optional tray spawn failed.
///
/// @trace spec:tray-cli-coexistence
pub fn spawn_detached_tray() -> std::io::Result<()> {
    let exe = std::env::current_exe()?;
    // Strip TILLANDSIAS_NO_TRAY so the child does not inherit a force-off
    // override from the parent's environment. The parent may have it set for
    // its own reasons (or via a future `--no-tray` flag), but if we got here
    // the parent already decided to spawn the tray.
    let mut cmd = Command::new(&exe);
    cmd.env_remove("TILLANDSIAS_NO_TRAY")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    #[cfg(unix)]
    {
        // setsid: child becomes leader of its own process group, detached
        // from the parent's controlling terminal, so closing the terminal
        // (SIGHUP) does not propagate to the tray.
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                // SAFETY: setsid is async-signal-safe; we are pre-exec
                // before any Rust runtime is in this child.
                let rc = libc::setsid();
                if rc < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS — child has no console
        // and is not part of the parent's process group, so Ctrl+C in the
        // parent's terminal does not reach it.
        cmd.creation_flags(0x00000200 | 0x00000008);
    }

    match cmd.spawn() {
        Ok(child) => {
            tracing::info!(
                spec = "tray-cli-coexistence",
                pid = child.id(),
                "Tray spawned in background"
            );
            // Drop the Child handle without waiting — process is now detached.
            std::mem::drop(child);
            Ok(())
        }
        Err(e) => {
            tracing::warn!(
                spec = "tray-cli-coexistence",
                error = %e,
                "Failed to spawn tray child — continuing CLI without tray"
            );
            Err(e)
        }
    }
}
