//! @trace spec:tray-cli-coexistence
//!
//! Desktop-environment detection for tray-aware CLI modes.
//!
//! When invoked from a graphical session, CLI modes (`tillandsias /path`,
//! `tillandsias --debug`) spawn the tray icon in addition to running their
//! foreground behaviour. On headless hosts (no `DISPLAY` / `WAYLAND_DISPLAY`
//! on Linux, server builds elsewhere) the tray spawn is skipped and the CLI
//! behaves exactly as it does today.

/// Returns true if the current process is invoked in a graphical session
/// where a tray icon would be visible.
///
/// Honored signals:
///   - `TILLANDSIAS_NO_TRAY=1` — explicit override, always returns false.
///   - Linux: `DISPLAY` non-empty OR `WAYLAND_DISPLAY` non-empty.
///   - macOS: always true (Cocoa always present in the user session that
///     spawned a Terminal/iTerm).
///   - Windows: always true (no headless mode in this CLI; Server Core
///     users will not see a tray either way).
///
/// @trace spec:tray-cli-coexistence
pub fn has_graphical_session() -> bool {
    // Explicit override — CI escape hatch, always wins.
    if env_nonempty("TILLANDSIAS_NO_TRAY") {
        return false;
    }

    #[cfg(target_os = "linux")]
    {
        env_nonempty("DISPLAY") || env_nonempty("WAYLAND_DISPLAY")
    }

    #[cfg(target_os = "macos")]
    {
        true
    }

    #[cfg(target_os = "windows")]
    {
        true
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        false
    }
}

/// Returns true if `name` is set in the environment AND non-empty.
/// Empty-string env vars are treated as unset (matches X11 / Wayland convention).
fn env_nonempty(name: &str) -> bool {
    std::env::var(name).map(|v| !v.is_empty()).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // Env-var tests cannot run in parallel because std::env::set_var /
    // remove_var mutates a process-wide table. Without serialisation, two
    // tests racing on `TILLANDSIAS_NO_TRAY` or `DISPLAY` produce flaky
    // results. We grab a static mutex in every test that touches env vars.
    //
    // (The cleaner fix is `serial_test`, but we don't want to add a
    // dev-dependency for one module.)
    static TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn override_env_forces_false() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: tests are serialised by TEST_MUTEX so no other thread
        // can observe a torn env table.
        unsafe {
            std::env::set_var("TILLANDSIAS_NO_TRAY", "1");
        }
        assert!(!has_graphical_session(), "override must force false");
        unsafe {
            std::env::remove_var("TILLANDSIAS_NO_TRAY");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_with_display_returns_true() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            std::env::remove_var("TILLANDSIAS_NO_TRAY");
            std::env::set_var("DISPLAY", ":0");
        }
        assert!(
            has_graphical_session(),
            "linux with DISPLAY=:0 must return true"
        );
        unsafe {
            std::env::remove_var("DISPLAY");
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_no_display_returns_false() {
        let _guard = TEST_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            std::env::remove_var("TILLANDSIAS_NO_TRAY");
            std::env::remove_var("DISPLAY");
            std::env::remove_var("WAYLAND_DISPLAY");
        }
        assert!(
            !has_graphical_session(),
            "linux without DISPLAY/WAYLAND_DISPLAY must return false"
        );
    }
}
