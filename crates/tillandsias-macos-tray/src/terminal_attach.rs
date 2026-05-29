//! Idiomatic terminal attach for the macOS tray.
//!
//! Two flows live here:
//!
//! 1. **Live PTY attach** (production path, post-slice-4c.2): the
//!    action-host opens a host-side `UnixPtyMaster`, `pump_io` bridges
//!    it to the in-VM forge over vsock, and this module spawns
//!    Terminal.app via `osascript "tell ... do script \"screen
//!    <slave>\""` — the only way to point Terminal.app at an
//!    external PTY device.
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
//! @trace spec:macos-native-tray.lifecycle.terminal-attach@v1,
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
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
pub fn applescript_for_terminal_app(command: &str) -> String {
    let escaped = applescript_escape(command);
    format!("tell application \"Terminal\"\n    do script \"{escaped}\"\n    activate\nend tell")
}

/// AppleScript that opens a Terminal.app window and attaches it to
/// the external PTY device at `slave_path` via GNU `screen`. The
/// macOS host's `UnixPtyMaster` owns the master fd; the bytes that
/// `pump_io` writes to the master surface as bytes readable on
/// `slave_path`. By running `screen <slave>` inside Terminal.app,
/// the user's keystrokes go INTO the slave (read by pump_io on the
/// master, forwarded over vsock to the in-VM shell) and the in-VM
/// shell's output comes back via pump_io → master → slave → screen
/// → Terminal.app.
///
/// This is the v0.0.1 macOS answer to "attach Terminal.app to an
/// external PTY device" — AppleScript can't do `tty=<path>; exec
/// <$tty >$tty` directly. `screen` is preinstalled on every macOS
/// since at least 10.6, so no extra dependency.
///
/// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c.2)
pub fn applescript_for_screen_attach(slave_path: &str) -> String {
    let escaped = applescript_escape(slave_path);
    format!(
        "tell application \"Terminal\"\n    do script \"screen {escaped}\"\n    activate\nend tell"
    )
}

/// AppleScript snippet for iTerm2 — Cocoa Scripting API creates a new
/// window and writes the command into the active session.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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
    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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

    /// Spawn Terminal.app and attach it to the host PTY at `slave_path`
    /// via `screen`. The attached session reads + writes the device,
    /// which on the host side is the master fd that pump_io drives
    /// against the vsock-bridged in-VM shell.
    ///
    /// macOS only; spec invariant `terminal-attach-no-ssh` honored
    /// (no SSH, no podman exec — the bytes flow via vsock + the
    /// in-VM `pty_handler` per control-wire-pty-attach §3.2).
    ///
    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c.2),
    ///        spec:macos-native-tray.invariant.terminal-attach-no-ssh
    pub fn spawn_terminal_pty_attach(slave_path: &str) -> std::io::Result<()> {
        let snippet = applescript_for_screen_attach(slave_path);
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

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn terminal_detection_returns_iterm2_preferred_when_present() {
        let host = installed(&[bundle_ids::ITERM2, bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::ITerm2);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn terminal_detection_falls_back_to_warp_when_iterm2_absent() {
        let host = installed(&[bundle_ids::WARP, bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::Warp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn terminal_detection_falls_back_to_terminal_app_when_only_default_present() {
        let host = installed(&[bundle_ids::TERMINAL_APP]);
        assert_eq!(detect_terminal(&host), Terminal::TerminalApp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn terminal_detection_falls_back_to_terminal_app_when_none_installed() {
        let host = installed(&[]);
        // Terminal.app ships with every macOS install; we never claim
        // "no terminal available".
        assert_eq!(detect_terminal(&host), Terminal::TerminalApp);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
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

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn applescript_for_iterm2_writes_text_into_current_session() {
        let command = "tillandsias-vm-layer-exec podman exec -it tillandsias-foo-forge bash";
        let snippet = applescript_for_iterm2(command);
        assert!(snippet.contains("create window with default profile"));
        assert!(snippet.contains("write text"));
        assert!(snippet.contains("tillandsias-foo-forge"));
    }

    /// Spec invariant: the live PTY attach path (slice 4c.2) connects
    /// via vsock + a host UnixPtyMaster + `screen <slave_path>` — no
    /// SSH anywhere. Asserting on `applescript_for_screen_attach`
    /// proves the user-facing osascript snippet doesn't sneak ssh in.
    ///
    /// @trace spec:macos-native-tray.invariant.terminal-attach-no-ssh
    #[test]
    fn screen_attach_never_invokes_ssh() {
        let snippet = applescript_for_screen_attach("/dev/ttys001");
        assert!(
            !snippet.contains("ssh"),
            "live PTY attach must never use ssh: {snippet}"
        );
        assert!(snippet.contains("screen /dev/ttys001"));
    }

    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c.2)
    #[test]
    fn screen_attach_wraps_slave_path_in_do_script() {
        let snippet = applescript_for_screen_attach("/dev/ttys005");
        assert!(snippet.contains("tell application \"Terminal\""));
        assert!(snippet.contains("do script \"screen /dev/ttys005\""));
        assert!(snippet.contains("activate"));
    }

    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c.2)
    #[test]
    fn screen_attach_escapes_path_with_specials() {
        // Unrealistic path with embedded quotes — verify AppleScript
        // escaping survives so the `do script` literal parses.
        let snippet = applescript_for_screen_attach(r#"/tmp/with"weird\path"#);
        assert!(snippet.contains(r#"do script "screen /tmp/with\"weird\\path""#));
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

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn bundle_ids_match_spec_scenario() {
        assert_eq!(Terminal::ITerm2.bundle_id(), "com.googlecode.iterm2");
        assert_eq!(Terminal::Warp.bundle_id(), "dev.warp.Warp-Stable");
        assert_eq!(Terminal::TerminalApp.bundle_id(), "com.apple.Terminal");
    }
}
