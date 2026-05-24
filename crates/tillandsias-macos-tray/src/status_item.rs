//! AppKit `NSStatusItem` plumbing for the macOS tray.
//!
//! Owns the AppKit run loop, the `NSMenu` instance, and the bridge between
//! `tillandsias-host-shell` events and `NSStatusItem.button.title`.
//!
//! @trace spec:macos-native-tray

#![allow(dead_code)]
#![allow(unused)]

/// Entry point invoked from `main`. Blocks until the user picks "Quit" on
/// the menu; returns never (`!`) because the AppKit run loop owns the
/// thread until then.
pub fn run() -> ! {
    todo!("@spec macos-native-tray: spin AppKit run loop, attach NSStatusItem")
}
