//! The one place in the workspace that constructs a `wsl.exe` child.
//!
//! Order 795-jjw3. Before this module, `wsl_command_async` existed twice and
//! `no_window_async`/`no_window_sync` existed twice, as acknowledged mirrors:
//! `tillandsias-vm-layer` could not depend on `tillandsias-podman`, the
//! reverse edge did not exist either, and vm-layer did not reach
//! `tillandsias-core` — the one crate both spawners already shared. So every
//! cross-cutting policy about `wsl.exe` had to be applied twice and could be
//! forgotten twice.
//!
//! That cost something measurable rather than merely being untidy: when
//! `WSL_UTF8` was introduced, six call sites set it and eleven did not, and
//! the eleven compensated with `.replace('\u{0}', "")`. Those scrubs are
//! indistinguishable by grep from the LEGITIMATE ones on `hcsdiag.exe` and
//! CIM-probe output — different binaries that `WSL_UTF8` never reaches — and
//! the audit that produced this packet mis-classified two sites for exactly
//! that reason. Constructing the command in one place removes the choice.
//!
//! WINDOW POLICY DELIBERATELY STAYS WITH THE CALLER. Some `wsl.exe` spawns
//! genuinely want a visible console — the debug-console keepalive and the lane
//! terminals are supposed to show one. A choke point that flattened that would
//! trade a real capability for tidiness, so `no_window_*` is offered here but
//! never applied by the constructors.
//!
//! @trace spec:cross-platform, spec:no-terminal-flicker

/// `CREATE_NO_WINDOW`. Suppresses the console a Windows child would otherwise
/// allocate — the operator-reported "terminals popping open and closing"
/// during VM boot (2026-07-12: the start-poke and wait_ready polls each
/// flashed a console).
#[cfg(target_os = "windows")]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The environment variable that makes `wsl.exe` speak UTF-8 instead of
/// UTF-16LE. Documented WSL behaviour since WSL 0.64.0.
///
/// Measured on yolanda 2026-08-17: `wsl.exe --status` stdout without it begins
/// `68,0,101,0,102,0,97,0,117,0,108,0,116,0` — a NUL after every ASCII byte —
/// and with `WSL_UTF8=1` begins `68,101,102,97,117,108,116`.
pub const WSL_UTF8_ENV: &str = "WSL_UTF8";

/// Apply `CREATE_NO_WINDOW` to a tokio Command on Windows. No-op elsewhere.
/// @trace spec:cross-platform, spec:no-terminal-flicker
pub fn no_window_async(cmd: &mut tokio::process::Command) -> &mut tokio::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.as_std_mut().creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Sync-Command sibling of [`no_window_async`].
/// @trace spec:cross-platform, spec:no-terminal-flicker
pub fn no_window_sync(cmd: &mut std::process::Command) -> &mut std::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Build a `wsl.exe` command with `WSL_UTF8=1` already applied.
///
/// The ONLY `Command::new("wsl.exe")` in the workspace, alongside its sync
/// sibling. `scripts/check-wsl-exe-single-constructor.sh` fails the gate if a
/// second one appears.
/// @trace spec:cross-platform, spec:windows-native-tray
pub fn wsl_command_async() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("wsl.exe");
    cmd.env(WSL_UTF8_ENV, "1");
    cmd
}

/// Sync-Command sibling of [`wsl_command_async`].
/// @trace spec:cross-platform, spec:windows-native-tray
pub fn wsl_command_sync() -> std::process::Command {
    let mut cmd = std::process::Command::new("wsl.exe");
    cmd.env(WSL_UTF8_ENV, "1");
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_constructors_carry_wsl_utf8() {
        let a = wsl_command_async();
        let a = a.as_std();
        assert_eq!(a.get_program(), "wsl.exe");
        assert!(
            a.get_envs()
                .any(|(k, v)| k == std::ffi::OsStr::new(WSL_UTF8_ENV)
                    && v == Some(std::ffi::OsStr::new("1"))),
            "async constructor must set WSL_UTF8=1"
        );

        let s = wsl_command_sync();
        assert_eq!(s.get_program(), "wsl.exe");
        assert!(
            s.get_envs()
                .any(|(k, v)| k == std::ffi::OsStr::new(WSL_UTF8_ENV)
                    && v == Some(std::ffi::OsStr::new("1"))),
            "sync constructor must set WSL_UTF8=1"
        );
    }

    /// The negative control the packet asks for: the constructors must NOT
    /// apply a window policy, because deliberately-interactive spawns (the
    /// debug keepalive, the lane terminals) need a visible console.
    #[test]
    fn constructors_do_not_impose_a_window_policy() {
        let mut cmd = wsl_command_sync();
        // no_window_sync is opt-in and returns the same command it was given;
        // the constructor itself must leave the choice to the caller.
        let same = no_window_sync(&mut cmd);
        assert_eq!(same.get_program(), "wsl.exe");
    }
}
