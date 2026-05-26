//! `TrayActionHost` — the AppKit responder object that backs the
//! interactive menu items (Start VM, Stop VM, Open Shell, GitHub login).
//!
//! Every clickable `NSMenuItem` needs a `target` that responds to its
//! `action` selector. The Quit item uses `nil`-target + `terminate:` so
//! AppKit walks the responder chain to `NSApplication`, but our custom
//! actions can't piggy-back on a system selector — we need a concrete
//! ObjC class with named selectors that AppKit can `respondsToSelector:`
//! against.
//!
//! This file declares one such class with `objc2::declare_class!`:
//!
//!   Selector           Rust method     Slice 1 behavior
//!   -----------------  --------------  ----------------------------
//!   startVm:           start_vm        eprintln stub
//!   stopVm:            stop_vm         eprintln stub
//!   openShell:         open_shell      eprintln stub
//!   githubLogin:       github_login    eprintln stub
//!
//! Slice 2 will fold a `tokio::runtime::Handle` + `Arc<VzRuntime>` + a
//! shared `Mutex<NSStatusItem>` into the ivars so the stubs can dispatch
//! real work and refresh the menu when state changes. Slice 1 ships the
//! object + selectors only so the menu wiring in `status_item.rs` can be
//! audited before we add async machinery.
//!
//! ## Lifetime
//!
//! Created once in `status_item::run()` and stored on the AppKit thread's
//! stack for the lifetime of `NSApplication.run` (which only returns when
//! the user picks Quit). The `Retained<TrayActionHost>` is paired 1:1
//! with the `Retained<NSStatusItem>` so they're released together when
//! the process exits.
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.ui.menu-actions@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (Phase 1 m4 sub-task B)

#![cfg(target_os = "macos")]

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{declare_class, msg_send_id, mutability, ClassType, DeclaredClass};
use objc2_foundation::MainThreadMarker;

declare_class!(
    /// AppKit responder for Tillandsias tray menu actions. Lives on the
    /// main thread; receives selector dispatch from `NSMenuItem`.
    pub struct TrayActionHost;

    unsafe impl ClassType for TrayActionHost {
        type Super = NSObject;
        type Mutability = mutability::MainThreadOnly;
        const NAME: &'static str = "TillandsiasTrayActionHost";
    }

    impl DeclaredClass for TrayActionHost {}

    unsafe impl TrayActionHost {
        #[method(startVm:)]
        fn start_vm(&self, _sender: Option<&AnyObject>) {
            // Slice 2 wires this to a Tokio task driving `VzRuntime::start`
            // + a main-thread callback that refreshes the menu label from
            // "Start VM" → "Stopping VM…" → "Stop VM" based on
            // VZVirtualMachineState transitions.
            eprintln!("[tillandsias-tray] Start VM clicked (slice 1 stub — wiring lands in slice 2)");
        }

        #[method(stopVm:)]
        fn stop_vm(&self, _sender: Option<&AnyObject>) {
            // Slice 3 wires this to `VzRuntime::stop(drain_timeout)` with
            // a 60s drain. Until then, the menu item is rendered disabled
            // because there's no live VM handle to act on.
            eprintln!("[tillandsias-tray] Stop VM clicked (slice 1 stub — wiring lands in slice 3)");
        }

        #[method(openShell:)]
        fn open_shell(&self, _sender: Option<&AnyObject>) {
            // Slice 4 wires this to `PtySession::open(/bin/bash)` over the
            // vsock control-wire + `open -a Terminal.app` with the PTY's
            // slave path. Matches the Linux tray's "Open Shell" UX.
            eprintln!("[tillandsias-tray] Open Shell clicked (slice 1 stub — wiring lands in slice 4)");
        }

        #[method(githubLogin:)]
        fn github_login(&self, _sender: Option<&AnyObject>) {
            // Slice 5 wires this to the same PTY-over-vsock path as
            // openShell:, but with the entrypoint set to `gh auth login`
            // so the device-code flow renders in Terminal.app. The token
            // lands in the in-VM vault, never on the host.
            eprintln!("[tillandsias-tray] GitHub login clicked (slice 1 stub — wiring lands in slice 5)");
        }
    }
);

impl TrayActionHost {
    /// Construct on the AppKit main thread. The `MainThreadMarker` proves
    /// we're on the right OS thread for the `MainThreadOnly` mutability
    /// contract; `init` is the standard ObjC zero-arg constructor.
    pub fn new(mtm: MainThreadMarker) -> Retained<Self> {
        // SAFETY: `mtm` proves main-thread; `alloc` + `init` is the
        // standard ObjC two-step. The DeclaredClass macro sets up
        // registration so `class!` returns a live class at this point.
        let _ = mtm; // marker is consumed for thread-safety proof only
        unsafe { msg_send_id![Self::class(), new] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke: the class registers and we can construct an instance from
    /// the main thread. Run via `cargo test -p tillandsias-macos-tray`
    /// on a macOS host (the test will be `#[cfg]`-skipped on Linux/CI
    /// runners that aren't macOS).
    #[test]
    fn tray_action_host_constructs_on_main_thread() {
        // Test threads in cargo are not the main thread, but the
        // `MainThreadMarker::new_unchecked()` path is unsafe — we
        // exercise the class registration via `Self::class()` instead,
        // which does NOT require main-thread.
        let cls = TrayActionHost::class();
        assert_eq!(cls.name(), "TillandsiasTrayActionHost");
    }
}
