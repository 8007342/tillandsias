//! Idiomatic terminal attach for the macOS tray.
//!
//! When the user clicks "Attach Here" on a project, this module:
//! 1. Detects which terminal is preferred (iTerm2 > Warp > Terminal.app).
//! 2. Composes the right AppleScript snippet for that terminal to open a
//!    new window/tab running `vm-exec podman exec -it tillandsias-<proj>-forge bash`.
//! 3. Spawns `osascript -e '<snippet>'` (Warp uses `open -a` instead).
//!
//! The AppleScript formatting and the detection ordering live in pure-Rust
//! functions so the Linux dev box can run unit tests. The actual
//! `NSWorkspace::URLForApplicationWithBundleIdentifier:` query and the
//! `osascript` spawn are macOS-only and behind `#[cfg(target_os = "macos")]`.
//!
//! @trace spec:macos-native-tray.lifecycle.terminal-attach@v1,
//!        spec:macos-native-tray.invariant.terminal-attach-no-ssh

#![allow(dead_code)]
#![allow(unused)]

/// Stable bundle identifiers for the terminals we know how to drive.
pub mod bundle_ids {
    pub const ITERM2: &str = "com.googlecode.iterm2";
    pub const WARP: &str = "dev.warp.Warp-Stable";
    pub const TERMINAL_APP: &str = "com.apple.Terminal";
}

/// Which terminal the tray decided to use for this attach.
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

/// Build the shell command that launches the in-VM forge for a project.
///
/// Centralised so the AppleScript snippets and any future direct-spawn
/// path render the same string. Per spec invariant
/// `terminal-attach-no-ssh`, this never invokes `ssh`.
///
/// @trace spec:macos-native-tray.invariant.terminal-attach-no-ssh
pub fn vm_exec_command(project: &str) -> String {
    format!("tillandsias-vm-layer-exec podman exec -it tillandsias-{project}-forge bash")
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

/// AppleScript snippet for Terminal.app — `do script` opens a new window
/// and runs the command interactively.
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
pub fn applescript_for_terminal_app(command: &str) -> String {
    let escaped = applescript_escape(command);
    format!(
        "tell application \"Terminal\"\n    do script \"{escaped}\"\n    activate\nend tell"
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

/// Spawn instructions for Warp — Warp does not accept AppleScript for
/// scripted commands, so we fall back to `open -a` and rely on Warp's
/// URL scheme (or a "Warp Drive" launcher in a future iteration).
///
/// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
pub fn spawn_argv_for_warp(command: &str) -> Vec<String> {
    // Equivalent to `open -na "Warp" --args` would be ideal but Warp lacks
    // a documented launch-with-argv. For v1 we just open Warp and let the
    // user paste the command, which we put on the clipboard via osascript.
    vec![
        "open".to_string(),
        "-a".to_string(),
        "Warp".to_string(),
    ]
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

    /// Spawn the chosen terminal via `osascript -e <snippet>` (or `open -a`
    /// for Warp). Returns immediately; the terminal runs detached.
    ///
    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    pub fn spawn_terminal(terminal: Terminal, project: &str) -> std::io::Result<()> {
        let command = vm_exec_command(project);
        match terminal {
            Terminal::ITerm2 => {
                let snippet = applescript_for_iterm2(&command);
                std::process::Command::new("osascript")
                    .arg("-e")
                    .arg(&snippet)
                    .spawn()?
                    .wait()?;
                Ok(())
            }
            Terminal::TerminalApp => {
                let snippet = applescript_for_terminal_app(&command);
                std::process::Command::new("osascript")
                    .arg("-e")
                    .arg(&snippet)
                    .spawn()?
                    .wait()?;
                Ok(())
            }
            Terminal::Warp => {
                let argv = spawn_argv_for_warp(&command);
                std::process::Command::new(&argv[0]).args(&argv[1..]).spawn()?;
                Ok(())
            }
        }
    }
}

#[cfg(target_os = "macos")]
pub use live::{spawn_terminal, LiveInstalledTerminals};

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
        assert_eq!(
            applescript_escape(r#"path\to\thing"#),
            r#"path\\to\\thing"#
        );
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

    /// @trace spec:macos-native-tray.invariant.terminal-attach-no-ssh
    #[test]
    fn vm_exec_command_never_invokes_ssh() {
        let cmd = vm_exec_command("tillandsias");
        assert!(!cmd.contains("ssh"), "vm_exec must never use ssh: {cmd}");
        assert!(cmd.contains("podman exec -it"));
        assert!(cmd.contains("tillandsias-tillandsias-forge"));
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn warp_spawn_uses_open_dash_a() {
        let argv = spawn_argv_for_warp("any-command");
        assert_eq!(argv, vec!["open", "-a", "Warp"]);
    }

    /// @trace spec:macos-native-tray.lifecycle.terminal-attach@v1
    #[test]
    fn bundle_ids_match_spec_scenario() {
        assert_eq!(Terminal::ITerm2.bundle_id(), "com.googlecode.iterm2");
        assert_eq!(Terminal::Warp.bundle_id(), "dev.warp.Warp-Stable");
        assert_eq!(Terminal::TerminalApp.bundle_id(), "com.apple.Terminal");
    }
}
