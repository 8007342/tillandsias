//! Win32 NotifyIcon plumbing for the Windows tray.
//!
//! Owns the message pump, the menu handler thread, and the bridge between
//! `tillandsias-host-shell` events and Win32 `Shell_NotifyIcon` updates.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]
#![allow(unused)]

/// Entry point invoked from `main`. Blocks until the user picks "Quit" on
/// the tray; returns never (`!`) because the OS message loop owns the
/// thread until then.
pub fn run() -> ! {
    todo!("@spec windows-native-tray: register Shell_NotifyIcon, spin message loop")
}
