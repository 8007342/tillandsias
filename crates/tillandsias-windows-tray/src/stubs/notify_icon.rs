//! Linux compile-stub for the Windows notify-icon module.
//!
//! Mirrors the Win32 module's public surface so that any portable callers
//! (tests + smoke binaries) can refer to it without `cfg(target_os)`
//! sprinkling. Functions return errors or no-ops.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]

/// Win32 message ID we'd use on Windows for tray callbacks. Carried in the
/// stub so any cross-platform consumer can name it without `cfg` gates.
pub const WM_TRAYICON: u32 = 0x8001; // WM_APP + 1

/// Run the Win32 NotifyIcon message loop. On Linux this prints a notice
/// and returns; the harness in `main.rs` is the actual exit path.
pub fn run() -> ! {
    eprintln!(
        "tillandsias-windows-tray::notify_icon::run() invoked on Linux — \
         this module is Windows-only at runtime"
    );
    std::process::exit(1);
}
