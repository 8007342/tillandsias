//! Idiomatic terminal attach for the macOS tray.
//!
//! Two flows live here:
//!
//! 1. **Live PTY attach** (production path, terminal-attach@v2): the
//!    action-host opens a host-side `UnixPtyMaster`, `pump_io` bridges
//!    it to the in-VM forge over vsock, and this module spawns
//!    Terminal.app via `osascript "tell ... do script"` running the
//!    tray binary's own attach client (`--attach-pty <slave>
//!    --session-sock <sock>`). The client owns the window's tty (raw
//!    mode, real SIGWINCH → event-driven resize, boundary mode resets)
//!    — the terminal-management half `screen <slave>` could never
//!    carry, because a device attach is a serial line to screen
//!    (plan/issues/macos-terminal-management-audit-2026-07-27.md).
//! 2. **Stub-window fallback** (pre-VM / error UX): the action-host
//!    surfaces error context by spawning Terminal.app with an
//!    `echo '<message>'` body so the user always sees concrete
//!    feedback when the click can't reach the in-VM shell.
//!
//! `LiveInstalledTerminals` detects iTerm2 > Warp > Terminal.app via
//! `NSWorkspace::URLForApplicationWithBundleIdentifier:` (macOS-only);
//! all AppleScript formatters are pure-Rust functions so the Linux
//! dev box can run unit tests against them.
//!
//! @trace spec:macos-native-tray.lifecycle.terminal-attach@v2,
//!        spec:macos-native-tray.invariant.terminal-attach-no-ssh,
//!        cheatsheets/runtime/macos-pty-attach.md

#![allow(dead_code)]
#![allow(unused)]

/// Stable bundle identifiers for the terminals we know how to drive.
pub mod bundle_ids {
    pub const ITERM2: &str = "com.googlecode.iterm2";
    pub const WARP: &str = "dev.warp.Warp-Stable";
    pub const TERMINAL_APP: &str = "com.apple.Terminal";
}

/// Which terminal the tray decided to use for this attach.
///
/// `TerminalApp` is named after macOS's built-in Terminal.app — renaming
/// to satisfy `clippy::enum_variant_names` would lose the bundle-id
/// signal, so the lint is allowed for this enum specifically.
#[allow(clippy::enum_variant_names)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Terminal {
    ITerm2,
    Warp,
    TerminalApp,
}

impl Terminal {
    /// Bundle identifier the spawn path passes to `open -b` /
    /// `NSWorkspace::URLForApplicationWithBundleIdentifier:`.
    pub fn bundle_id(self) -> &'static str {
        match self {
            Terminal::ITerm2 => bundle_ids::ITERM2,
            Terminal::Warp => bundle_ids::WARP,
            Terminal::TerminalApp => bundle_ids::TERMINAL_APP,
        }
    }

    /// Preferred-first order. The first installed terminal wins.
    pub fn priority_order() -> [Terminal; 3] {
        [Terminal::ITerm2, Terminal::Warp, Terminal::TerminalApp]
    }
}

/// Trait the live `NSWorkspace` lookup implements, plus the test mock.
///
/// Defined as a trait so the unit tests on Linux can supply a hash-set
/// of "installed" bundle ids without touching AppKit.
pub trait InstalledTerminals {
    /// True if the macOS host has an app registered for `bundle_id`.
    fn is_installed(&self, bundle_id: &str) -> bool;
}

/// Walk the priority order and return the first installed terminal.
///
/// Returns `Terminal::TerminalApp` as the ultimate fallback because
/// `Terminal.app` ships with every macOS install. The fallback path
/// matches the spec scenario "Terminal.app fallback when iTerm2 is not
/// default".
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
pub fn detect_terminal(installed: &dyn InstalledTerminals) -> Terminal {
    for candidate in Terminal::priority_order() {
        if installed.is_installed(candidate.bundle_id()) {
            return candidate;
        }
    }
    Terminal::TerminalApp
}

/// AppleScript-quote a string by doubling embedded backslashes and double
/// quotes. AppleScript string literals are `"…"` with `\\` and `\"` as the
/// escape sequences for backslash and double-quote respectively.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
pub fn applescript_escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len() + 2);
    for c in input.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            other => out.push(other),
        }
    }
    out
}

/// AppleScript that opens a Terminal.app window and echos a stub message.
/// Used by the v0.0.1 "Open Shell" action before the in-VM PTY-over-vsock
/// transport (slice 4b) lands; gives the user concrete UX feedback (a
/// new window opens with the message visible) while the underlying
/// bridge is still being built. `message` is single-quoted-then-escaped
/// for `echo` to avoid shell-injection surprises from any text we
/// surface back.
///
/// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4)
pub fn applescript_for_open_shell_stub(message: &str) -> String {
    // Escape the message for safe inclusion inside a single-quoted shell
    // string: convert each ' to '\''.
    let shell_escaped: String = message.replace('\'', "'\\''");
    // Wrap in `echo '…'; sleep N` so the window stays open long enough
    // for the user to read the message before Terminal.app's "shell
    // exited" prompt appears.
    let command =
        format!("echo '{shell_escaped}'; echo; echo '(window stays open — close with Cmd-W)'");
    applescript_for_terminal_app(&command)
}

/// AppleScript snippet for Terminal.app — `do script` opens a new window
/// and runs the command interactively.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
pub fn applescript_for_terminal_app(command: &str) -> String {
    let escaped = applescript_escape(command);
    format!("tell application \"Terminal\"\n    do script \"{escaped}\"\n    activate\nend tell")
}

/// Shell-quote `s` for a POSIX shell: wrap in single quotes, escaping any
/// embedded single quote as `'\''`. Used for paths interpolated into the
/// Terminal.app `do script` command line.
pub fn shell_single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The shell command Terminal.app runs for a live PTY attach: the tray
/// binary's own attach client on the slave device + per-session socket,
/// then the unmistakable end-of-session banner, then `exit`.
///
/// Why our own client instead of `screen <slave>` (v0.0.1..2026-07-27):
/// `screen` attached to a device path treats it as a SERIAL line — no
/// winsize concept, no SIGWINCH forwarding, no mode hygiene — so every
/// terminal-management hop died at that link (the audit's root insight:
/// the working platforms all put a real client in the window; macOS
/// didn't). The attach client owns the window's controlling tty: raw mode
/// (transparent conduit; the guest keeps ISIG and owns Ctrl+C), real
/// SIGWINCH → `TIOCSWINSZ` on the slave + an event on the session socket
/// (no polling anywhere), scoped DECRST mode reset at entry/exit, and its
/// exit is the tray's detach signal (guest child gets reaped, not leaked).
///
/// Order 269 (F-G) preserved: when the session ends the client exits, the
/// banner prints, and the wrapping shell `exit`s so close-on-clean-exit
/// Terminal profiles reclaim the window.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2,
///        plan/issues/macos-terminal-management-audit-2026-07-27.md (D1, D4)
pub fn attach_client_shell_command(exe_path: &str, slave_path: &str, sock_path: &str) -> String {
    format!(
        "{} --attach-pty {} --session-sock {}; \
         echo '[tillandsias] session ended \u{2014} you may close this window.'; exit",
        shell_single_quote(exe_path),
        shell_single_quote(slave_path),
        shell_single_quote(sock_path),
    )
}

/// AppleScript that opens a Terminal.app window running the attach client
/// against the host PTY at `slave_path` — see [`attach_client_shell_command`].
/// The macOS host's `UnixPtyMaster` owns the master fd; `pump_io` bridges
/// master ↔ vsock, the client bridges the window's tty ↔ slave.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
pub fn applescript_for_attach_client(exe_path: &str, slave_path: &str, sock_path: &str) -> String {
    applescript_for_terminal_app(&attach_client_shell_command(
        exe_path, slave_path, sock_path,
    ))
}

/// AppleScript snippet for iTerm2 — Cocoa Scripting API creates a new
/// window and writes the command into the active session.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
pub fn applescript_for_iterm2(command: &str) -> String {
    let escaped = applescript_escape(command);
    format!(
        "tell application \"iTerm\"\n    \
         create window with default profile\n    \
         tell current session of current window\n        \
         write text \"{escaped}\"\n    \
         end tell\n    \
         activate\nend tell"
    )
}

// ---------------------------------------------------------------------------
// macOS-only: live NSWorkspace lookup + osascript spawn.
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod live {
    use super::*;
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::{NSString, NSURL};

    /// Live implementation backed by `NSWorkspace`.
    ///
    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    pub struct LiveInstalledTerminals;

    impl InstalledTerminals for LiveInstalledTerminals {
        fn is_installed(&self, bundle_id: &str) -> bool {
            // SAFETY: NSWorkspace.sharedWorkspace returns a +0 singleton.
            unsafe {
                let workspace = NSWorkspace::sharedWorkspace();
                let ns_bundle = NSString::from_str(bundle_id);
                let url: Option<Retained<NSURL>> =
                    workspace.URLForApplicationWithBundleIdentifier(&ns_bundle);
                url.is_some()
            }
        }
    }

    /// Spawn a Terminal.app window that displays `message` and waits
    /// for the user to close it (Cmd-W). Detects the best terminal
    /// via `LiveInstalledTerminals` (iTerm2 > Warp > Terminal.app)
    /// and uses the matching AppleScript formatter. Returns
    /// immediately; the spawned `osascript` waits for the AppleScript
    /// to apply (a few hundred ms) before exiting.
    ///
    /// Used by the v0.0.1 Open Shell + GitHub login menu actions as
    /// placeholder UX before the in-VM PTY-over-vsock transport
    /// lands (slice 4b). The same helper backs both actions; the
    /// caller picks the message content.
    ///
    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slices 4, 5)
    pub fn spawn_terminal_stub_window(message: &str) -> std::io::Result<()> {
        let snippet = match detect_terminal(&LiveInstalledTerminals) {
            Terminal::ITerm2 => applescript_for_iterm2(&format!(
                "echo '{}' && echo && echo '(close with Cmd-W)'",
                message.replace('\'', "'\\''"),
            )),
            Terminal::Warp => {
                // Warp doesn't honor osascript snippets; open the app
                // and let the user paste the next step. For the stub
                // message we just open Warp.
                std::process::Command::new("open")
                    .arg("-a")
                    .arg("Warp")
                    .spawn()?;
                return Ok(());
            }
            Terminal::TerminalApp => applescript_for_open_shell_stub(message),
        };
        std::process::Command::new("osascript")
            .arg("-e")
            .arg(&snippet)
            .spawn()?;
        Ok(())
    }

    /// Spawn Terminal.app running the tray binary's attach client on the
    /// host PTY at `slave_path`, reporting geometry events on the
    /// per-session socket at `sock_path`. The window's tty is owned by
    /// the client (raw mode + SIGWINCH); on the host side the master fd
    /// is what pump_io drives against the vsock-bridged in-VM shell.
    ///
    /// macOS only; spec invariant `terminal-attach-no-ssh` honored
    /// (no SSH, no podman exec — the bytes flow via vsock + the
    /// in-VM `pty_handler` per control-wire-pty-attach §3.2).
    ///
    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2,
    ///        spec:macos-native-tray.invariant.terminal-attach-no-ssh
    pub fn spawn_terminal_pty_attach(slave_path: &str, sock_path: &str) -> std::io::Result<()> {
        let exe = std::env::current_exe()?;
        let exe = exe.to_str().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "tray executable path is not valid UTF-8",
            )
        })?;
        let snippet = applescript_for_attach_client(exe, slave_path, sock_path);
        std::process::Command::new("osascript")
            .arg("-e")
            .arg(&snippet)
            .spawn()?;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub use live::{LiveInstalledTerminals, spawn_terminal_pty_attach, spawn_terminal_stub_window};

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Mock backing the `InstalledTerminals` trait for unit tests.
    struct MockInstalled(HashSet<String>);
    impl InstalledTerminals for MockInstalled {
        fn is_installed(&self, bundle_id: &str) -> bool {
            self.0.contains(bundle_id)
        }
    }
    fn installed(ids: &[&str]) -> MockInstalled {
        MockInstalled(ids.iter().map(|s| (*s).to_string()).collect())
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn terminal_detection_returns_iterm2_preferred_when_present() {
        let host = installed(&[bundle_ids::ITERM2, bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::ITerm2);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn terminal_detection_falls_back_to_warp_when_iterm2_absent() {
        let host = installed(&[bundle_ids::WARP, bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::Warp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn terminal_detection_falls_back_to_terminal_app_when_only_default_present() {
        let host = installed(&[bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::TerminalApp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn terminal_detection_falls_back_to_terminal_app_when_none_installed() {
        let host = installed(&[]);
        // Terminal.app ships with every macOS install; we never claim
        // "no terminal available".
        assert_eq!(detect_terminal(&host), Terminal::TerminalApp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn applescript_escape_doubles_backslashes_and_quotes() {
        assert_eq!(applescript_escape(r#"no specials"#), "no specials");
        assert_eq!(applescript_escape(r#"with "quotes""#), r#"with \"quotes\""#);
        assert_eq!(applescript_escape(r#"path\to\thing"#), r#"path\\to\\thing"#);
        assert_eq!(
            applescript_escape(r#"mixed "back\slash""#),
            r#"mixed \"back\\slash\""#
        );
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn apple_script_for_terminal_app_escapes_quotes_correctly() {
        let command = r#"echo "hello world""#;
        let snippet = applescript_for_terminal_app(command);
        // The literal in the do-script line must be backslash-escaped
        // double quotes, otherwise AppleScript fails to parse.
        assert!(snippet.contains(r#"do script "echo \"hello world\"""#));
        assert!(snippet.contains("tell application \"Terminal\""));
        assert!(snippet.contains("activate"));
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn applescript_for_iterm2_writes_text_into_current_session() {
        let command = "tillandsias-vm-layer-exec podman exec -it tillandsias-foo-forge bash";
        let snippet = applescript_for_iterm2(command);
        assert!(snippet.contains("create window with default profile"));
        assert!(snippet.contains("write text"));
        assert!(snippet.contains("tillandsias-foo-forge"));
    }

    /// Spec invariant: the live PTY attach path connects via vsock + a
    /// host UnixPtyMaster + the tray's own attach client in the window —
    /// no SSH anywhere. Asserting on `applescript_for_attach_client`
    /// proves the user-facing osascript snippet doesn't sneak ssh in.
    ///
    /// @trace spec:macos-native-tray.invariant.terminal-attach-no-ssh
    #[test]
    fn attach_client_never_invokes_ssh() {
        let snippet = applescript_for_attach_client(
            "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray",
            "/dev/ttys001",
            "/tmp/tillandsias-pty-1.sock",
        );
        assert!(
            !snippet.contains("ssh"),
            "live PTY attach must never use ssh: {snippet}"
        );
        assert!(snippet.contains("--attach-pty '/dev/ttys001'"));
    }

    /// terminal-attach@v2: the window runs OUR client — no `screen`, no
    /// `stty` seed hack (the client owns geometry via SIGWINCH events).
    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn attach_client_replaces_screen_and_stty() {
        let cmd = attach_client_shell_command("/usr/local/bin/tray", "/dev/ttys005", "/tmp/s.sock");
        assert!(
            !cmd.contains("screen ") && !cmd.contains("stty "),
            "screen/stty must be gone from the attach command: {cmd}"
        );
        assert!(cmd.contains("--attach-pty '/dev/ttys005'"));
        assert!(cmd.contains("--session-sock '/tmp/s.sock'"));
        // The client must run before the banner (it IS the session).
        let client_at = cmd.find("--attach-pty").expect("client present");
        let banner_at = cmd.find("session ended").expect("banner present");
        assert!(client_at < banner_at, "client must precede banner: {cmd}");
    }

    /// The do-script envelope survives paths with shell/AppleScript
    /// specials: single quotes are shell-escaped (`'\''`), then the whole
    /// command is AppleScript-escaped (backslashes doubled, quotes escaped).
    #[test]
    fn attach_client_escapes_paths_with_specials() {
        assert_eq!(shell_single_quote("/plain/path"), "'/plain/path'");
        assert_eq!(shell_single_quote("with'quote"), r#"'with'\''quote'"#);
        let snippet = applescript_for_attach_client(
            "/Applications/My App.app/Contents/MacOS/tray",
            "/dev/ttys005",
            "/tmp/tillandsias sock's.sock",
        );
        // Space-bearing exe path stays inside one shell word.
        assert!(snippet.contains("'/Applications/My App.app/Contents/MacOS/tray'"));
        assert!(snippet.contains("tell application \"Terminal\""));
        assert!(snippet.contains("activate"));
    }

    /// Order 269 (F-G) pin: session end must be unmistakable — the
    /// window prints a banner and the wrapping shell exits (so
    /// close-on-exit Terminal profiles reclaim the window) instead of
    /// stranding the operator at a dead prompt.
    #[test]
    fn attach_client_ends_with_banner_and_exit() {
        let snippet =
            applescript_for_attach_client("/usr/local/bin/tray", "/dev/ttys005", "/tmp/s");
        assert!(
            snippet.contains("session ended"),
            "end-of-session banner missing: {snippet}"
        );
        assert!(
            snippet.contains("; exit\""),
            "wrapping shell must exit after the client ends: {snippet}"
        );
    }

    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4)
    #[test]
    fn open_shell_stub_quotes_message_safely() {
        let snippet = applescript_for_open_shell_stub("hi 'there'");
        // The shell-escape sequence `'\''` is then AppleScript-escaped
        // (backslashes doubled), so the literal in the final snippet
        // shows as `'\\''` per single-quote in the original message.
        assert!(
            snippet.contains("hi '\\\\''there'\\\\''"),
            "expected shell+applescript-escaped single quotes; got: {snippet}"
        );
        // And it MUST go through the Terminal.app envelope so the user
        // gets a visible window.
        assert!(snippet.contains("tell application \"Terminal\""));
        assert!(snippet.contains("do script"));
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v2
    #[test]
    fn bundle_ids_match_spec_scenario() {
        assert_eq!(Terminal::ITerm2.bundle_id(), "com.googlecode.iterm2");
        assert_eq!(Terminal::Warp.bundle_id(), "dev.warp.Warp-Stable");
        assert_eq!(Terminal::TerminalApp.bundle_id(), "com.apple.Terminal");
    }
}
