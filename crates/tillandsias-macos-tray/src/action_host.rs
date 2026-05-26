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
//!   Selector           Rust method     Slice 2 behavior
//!   -----------------  --------------  ----------------------------
//!   startVm:           start_vm        spawn tokio task → main-thread dispatch
//!   stopVm:            stop_vm         eprintln stub (slice 3)
//!   openShell:         open_shell      eprintln stub (slice 4)
//!   githubLogin:       github_login    eprintln stub (slice 5)
//!
//! ## Ivars
//!
//! `TrayActionHostIvars` carries the host's shared state:
//!   - `runtime`: `Arc<tokio::runtime::Runtime>` — the per-process
//!     Tokio runtime used to spawn async VM work without blocking the
//!     AppKit main thread. The host clones the Arc when spawning so
//!     the runtime outlives each individual task.
//!   - `vm_busy`: `Arc<Mutex<bool>>` — gate flag so repeated Start VM
//!     clicks don't overlap. Slice 3 will replace this with a richer
//!     `Arc<Mutex<Option<Arc<VzRuntime>>>>` once we hold a live VM
//!     handle worth referencing.
//!
//! ## Lifetime
//!
//! Created once in `status_item::run()` and stored on the AppKit
//! thread's stack for the lifetime of `NSApplication.run` (which only
//! returns when the user picks Quit). The `Retained<TrayActionHost>`
//! is paired 1:1 with the `Retained<NSStatusItem>` so they're released
//! together when the process exits.
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.ui.menu-actions@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (Phase 1 m4 sub-task B)

#![cfg(target_os = "macos")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{declare_class, msg_send_id, mutability, ClassType, DeclaredClass};
use objc2_foundation::MainThreadMarker;

use crate::main_thread::dispatch_to_main_thread;

/// State shared across the host's selector handlers. Lives inside
/// the declared class via `DeclaredClass::Ivars`.
pub struct TrayActionHostIvars {
    runtime: Arc<tokio::runtime::Runtime>,
    vm_busy: Arc<Mutex<bool>>,
}

declare_class!(
    /// AppKit responder for Tillandsias tray menu actions. Lives on
    /// the main thread; receives selector dispatch from `NSMenuItem`.
    pub struct TrayActionHost;

    unsafe impl ClassType for TrayActionHost {
        type Super = NSObject;
        type Mutability = mutability::MainThreadOnly;
        const NAME: &'static str = "TillandsiasTrayActionHost";
    }

    impl DeclaredClass for TrayActionHost {
        type Ivars = TrayActionHostIvars;
    }

    unsafe impl TrayActionHost {
        #[method(startVm:)]
        fn start_vm(&self, _sender: Option<&AnyObject>) {
            // Lock-check the busy flag from the main thread (we're in
            // the ObjC dispatch, which AppKit invokes on main). If
            // already busy, ignore the click; otherwise mark busy and
            // spawn a worker.
            let ivars = self.ivars();
            {
                let mut busy = ivars.vm_busy.lock().unwrap();
                if *busy {
                    eprintln!("[tillandsias-tray] Start VM: already in progress, ignoring");
                    return;
                }
                *busy = true;
            }

            // Clone the Arcs we'll hand into the Tokio task. The
            // runtime stays alive as long as any clone exists; the
            // busy mutex is shared with the main thread so the
            // completion callback can clear it.
            let runtime = ivars.runtime.clone();
            let vm_busy = ivars.vm_busy.clone();

            eprintln!("[tillandsias-tray] Start VM: spawning worker (slice 2 — placeholder sleep)");
            runtime.spawn(async move {
                // Slice 3 replaces this sleep with the real
                // VzRuntime::new(...).start().await call. The sleep
                // is here so slice 2's commit demonstrates the full
                // round-trip (main → tokio → main) without yet
                // taking on VzRuntime's failure modes.
                tokio::time::sleep(Duration::from_millis(300)).await;

                // Hop back to the AppKit main thread to log
                // completion and clear the busy flag. In slice 3+
                // this callback also refreshes the status item title
                // and re-renders the menu to reflect the new state.
                dispatch_to_main_thread(move || {
                    *vm_busy.lock().unwrap() = false;
                    eprintln!(
                        "[tillandsias-tray] Start VM: worker returned (slice 2 stub); back on main"
                    );
                });
            });
        }

        #[method(stopVm:)]
        fn stop_vm(&self, _sender: Option<&AnyObject>) {
            // Slice 3 wires this to `VzRuntime::stop(drain_timeout)`
            // with a 60s drain. Until then, the menu item is
            // unconditionally present (UI gating to "disable when no
            // live VM" is a slice 3 concern too).
            eprintln!(
                "[tillandsias-tray] Stop VM clicked (slice 2 stub — wiring lands in slice 3)"
            );
        }

        #[method(openShell:)]
        fn open_shell(&self, _sender: Option<&AnyObject>) {
            // Slice 4 wires this to `PtySession::open(/bin/bash)`
            // over the vsock control-wire + `open -a Terminal.app`
            // with the PTY's slave path. Matches Linux tray UX.
            eprintln!(
                "[tillandsias-tray] Open Shell clicked (slice 2 stub — wiring lands in slice 4)"
            );
        }

        #[method(githubLogin:)]
        fn github_login(&self, _sender: Option<&AnyObject>) {
            // Slice 5 wires this to the same PTY-over-vsock path as
            // openShell:, but with the entrypoint set to
            // `gh auth login` so the device-code flow renders in
            // Terminal.app. The token lands in the in-VM vault,
            // never on the host.
            eprintln!(
                "[tillandsias-tray] GitHub login clicked (slice 2 stub — wiring lands in slice 5)"
            );
        }
    }
);

impl TrayActionHost {
    /// Construct on the AppKit main thread. `mtm` proves we're on the
    /// right OS thread for the `MainThreadOnly` mutability contract.
    /// The Tokio `runtime` is shared across the process so the host
    /// can `runtime.spawn(...)` worker tasks for VM lifecycle calls.
    pub fn new(
        mtm: MainThreadMarker,
        runtime: Arc<tokio::runtime::Runtime>,
    ) -> Retained<Self> {
        let ivars = TrayActionHostIvars {
            runtime,
            vm_busy: Arc::new(Mutex::new(false)),
        };
        // SAFETY: `mtm` proves main-thread; allocation + init is the
        // standard ObjC two-step. `set_ivars` populates the declared
        // class ivars before init runs.
        let this = mtm.alloc::<Self>().set_ivars(ivars);
        unsafe { msg_send_id![super(this), init] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke: the class registers under the expected ObjC name. Does
    /// NOT require main-thread (only touches `Self::class()`), so it
    /// runs from cargo's test threads.
    #[test]
    fn tray_action_host_class_registers() {
        let cls = TrayActionHost::class();
        assert_eq!(cls.name(), "TillandsiasTrayActionHost");
    }
}
