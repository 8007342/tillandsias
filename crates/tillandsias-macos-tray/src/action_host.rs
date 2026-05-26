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
//!   Selector           Rust method     Slice 3 behavior
//!   -----------------  --------------  -------------------------------
//!   startVm:           start_vm        Tokio task → VzRuntime::start
//!   stopVm:            stop_vm         Tokio task → VzRuntime::stop(60s)
//!   openShell:         open_shell      eprintln stub (slice 4)
//!   githubLogin:       github_login    eprintln stub (slice 5)
//!
//! ## Ivars
//!
//! `TrayActionHostIvars` carries the host's shared state:
//!   - `runtime`: `Arc<tokio::runtime::Runtime>` — the per-process
//!     Tokio runtime used to spawn async VM work without blocking the
//!     AppKit main thread.
//!   - `vm`: `Arc<Mutex<Option<Arc<VzRuntime>>>>` — the live VM handle
//!     when `start` has succeeded, `None` otherwise. Shared with the
//!     Tokio task so it can install/take the handle around the async
//!     start/stop calls.
//!   - `vm_busy`: `Arc<Mutex<bool>>` — re-entry gate so a repeated
//!     click during an in-flight start/stop is a no-op.
//!   - `image_root`: `PathBuf` — directory under which `VzRuntime`
//!     looks for `rootfs.img` / `kernel` / `initrd`. Slice 3 just
//!     reports "not provisioned" if the files are absent; the recipe
//!     materializer (m5) eventually populates this directory.
//!
//! ## Lifetime
//!
//! Created once in `status_item::run()` and stored on the AppKit
//! thread's stack for the lifetime of `NSApplication.run`. The
//! `Retained<TrayActionHost>` is paired 1:1 with the
//! `Retained<NSStatusItem>` so they're released together when the
//! process exits.
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.ui.menu-actions@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (Phase 1 m4 sub-task B)

#![cfg(target_os = "macos")]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{declare_class, msg_send_id, mutability, ClassType, DeclaredClass};
use objc2_foundation::MainThreadMarker;

use tillandsias_vm_layer::vz::VzRuntime;
use tillandsias_vm_layer::VmRuntime;

use crate::main_thread::dispatch_to_main_thread;

/// Default vsock CID for the Tillandsias guest. Matches what the
/// in-VM headless binds; the host always connects to this CID.
const TILLANDSIAS_GUEST_CID: u32 = 3;

/// How long `VzRuntime::stop` waits for an orderly drain before
/// escalating to a force-stop. Documented in
/// `cheatsheets/runtime/tray-state-machine.md` as 60s for the
/// production tray; the spike used 30s and hit the force-path on
/// Fedora's ACPI shutdown.
const VM_STOP_DRAIN: Duration = Duration::from_secs(60);

/// State shared across the host's selector handlers. Lives inside
/// the declared class via `DeclaredClass::Ivars`.
pub struct TrayActionHostIvars {
    runtime: Arc<tokio::runtime::Runtime>,
    vm: Arc<Mutex<Option<Arc<VzRuntime>>>>,
    vm_busy: Arc<Mutex<bool>>,
    image_root: PathBuf,
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
            let ivars = self.ivars();

            // Re-entry gate: ignore the click if a start/stop is
            // already in flight. We run on the main thread; the
            // worker clears the flag via dispatch_to_main_thread.
            {
                let mut busy = ivars.vm_busy.lock().unwrap();
                if *busy {
                    eprintln!("[tillandsias-tray] Start VM: already in progress, ignoring");
                    return;
                }
                *busy = true;
            }
            // Idempotency: if we already hold a live VM handle, just
            // log and bail (without touching the busy flag race).
            if ivars.vm.lock().unwrap().is_some() {
                *ivars.vm_busy.lock().unwrap() = false;
                eprintln!("[tillandsias-tray] Start VM: VM already running, ignoring");
                return;
            }

            let runtime = ivars.runtime.clone();
            let vm_slot = ivars.vm.clone();
            let vm_busy = ivars.vm_busy.clone();
            let image_root = ivars.image_root.clone();

            eprintln!(
                "[tillandsias-tray] Start VM: spawning worker (image_root={})",
                image_root.display()
            );
            runtime.spawn(async move {
                let result = run_start(image_root, vm_slot).await;
                dispatch_to_main_thread(move || {
                    *vm_busy.lock().unwrap() = false;
                    match result {
                        Ok(()) => eprintln!("[tillandsias-tray] Start VM: VM is running"),
                        Err(e) => eprintln!("[tillandsias-tray] Start VM failed: {e}"),
                    }
                });
            });
        }

        #[method(stopVm:)]
        fn stop_vm(&self, _sender: Option<&AnyObject>) {
            let ivars = self.ivars();

            // Re-entry gate (shared with startVm).
            {
                let mut busy = ivars.vm_busy.lock().unwrap();
                if *busy {
                    eprintln!("[tillandsias-tray] Stop VM: already in progress, ignoring");
                    return;
                }
                *busy = true;
            }
            // No-op if no live VM handle.
            let vm_taken = ivars.vm.lock().unwrap().take();
            let Some(vm) = vm_taken else {
                *ivars.vm_busy.lock().unwrap() = false;
                eprintln!("[tillandsias-tray] Stop VM: no live VM, ignoring");
                return;
            };

            let runtime = ivars.runtime.clone();
            let vm_busy = ivars.vm_busy.clone();

            eprintln!(
                "[tillandsias-tray] Stop VM: spawning worker (drain={}s)",
                VM_STOP_DRAIN.as_secs()
            );
            runtime.spawn(async move {
                let result = vm.stop(VM_STOP_DRAIN).await;
                dispatch_to_main_thread(move || {
                    *vm_busy.lock().unwrap() = false;
                    match result {
                        Ok(()) => eprintln!("[tillandsias-tray] Stop VM: VM stopped"),
                        Err(e) => eprintln!("[tillandsias-tray] Stop VM failed: {e}"),
                    }
                });
            });
        }

        #[method(openShell:)]
        fn open_shell(&self, _sender: Option<&AnyObject>) {
            // Slice 4: open a Terminal.app window with a stub message
            // (in-VM PTY-over-vsock transport lands in slice 4b).
            // Gate on VM being up: opening a shell to a dead VM is a
            // user-facing footgun.
            let ivars = self.ivars();
            if ivars.vm.lock().unwrap().is_none() {
                eprintln!(
                    "[tillandsias-tray] Open Shell: no VM running. Start VM first."
                );
                return;
            }
            let message =
                "Tillandsias — Open Shell stub (m4 sub-task B slice 4). \
                 Per tray-convergence-coordination 2026-05-26, the canonical \
                 target is the in-VM forge podman container (not the bare \
                 VM). Slice 4b wires this window to: \
                 `podman exec -it tillandsias-<project>-forge bash` over \
                 PTY-over-vsock via the in-VM headless's pty_handler.";
            match crate::terminal_attach::spawn_terminal_stub_window(message) {
                Ok(()) => eprintln!("[tillandsias-tray] Open Shell: stub window spawned"),
                Err(e) => eprintln!("[tillandsias-tray] Open Shell failed: {e}"),
            }
        }

        #[method(githubLogin:)]
        fn github_login(&self, _sender: Option<&AnyObject>) {
            // Slice 5: opens a Terminal.app window with a stub message
            // mentioning the gh auth device-code flow. Real wiring
            // (slice 5b) attaches the window to a PtySession::open
            // launching `gh auth login` inside the in-VM forge
            // container; the device code renders in this window and
            // the resulting token lands in the in-VM vault, never on
            // the host (per spec invariant `terminal-attach-no-ssh`).
            let ivars = self.ivars();
            if ivars.vm.lock().unwrap().is_none() {
                eprintln!(
                    "[tillandsias-tray] GitHub login: no VM running. Start VM first."
                );
                return;
            }
            let message =
                "Tillandsias — GitHub login stub (m4 sub-task B slice 5). \
                 Slice 5b launches `gh auth login` inside the in-VM forge \
                 container via PTY-over-vsock; the device-code URL and \
                 paste prompt will render in this window. The resulting \
                 OAuth token is written to the in-VM vault and is never \
                 visible to the host (spec invariant `terminal-attach-no-ssh`).";
            match crate::terminal_attach::spawn_terminal_stub_window(message) {
                Ok(()) => eprintln!("[tillandsias-tray] GitHub login: stub window spawned"),
                Err(e) => eprintln!("[tillandsias-tray] GitHub login failed: {e}"),
            }
        }
    }
);

/// Worker body for `startVm:`. Constructs the VzRuntime, fails fast
/// if its required image files are missing (recipe materializer not
/// yet run), then drives `VmRuntime::start`. On success, installs the
/// `Arc<VzRuntime>` into the shared slot so subsequent `stopVm:` can
/// take it. On failure, leaves the slot empty so a retry click works.
async fn run_start(
    image_root: PathBuf,
    vm_slot: Arc<Mutex<Option<Arc<VzRuntime>>>>,
) -> Result<(), String> {
    let vz = Arc::new(VzRuntime::new(TILLANDSIAS_GUEST_CID, image_root));

    if !vz.is_provisioned() {
        return Err(format!(
            "VM image not yet materialized at {} \
             (expected rootfs.img / kernel / initrd; run the recipe \
              materializer first)",
            vz.rootfs_image_path().display()
        ));
    }

    vz.start().await?;
    *vm_slot.lock().unwrap() = Some(vz);
    Ok(())
}

impl TrayActionHost {
    /// Construct on the AppKit main thread. `mtm` proves we're on the
    /// right OS thread for the `MainThreadOnly` mutability contract.
    /// The Tokio `runtime` is shared across the process. `image_root`
    /// is where `VzRuntime` looks for the boot artifacts produced by
    /// the recipe materializer.
    pub fn new(
        mtm: MainThreadMarker,
        runtime: Arc<tokio::runtime::Runtime>,
        image_root: PathBuf,
    ) -> Retained<Self> {
        let ivars = TrayActionHostIvars {
            runtime,
            vm: Arc::new(Mutex::new(None)),
            vm_busy: Arc::new(Mutex::new(false)),
            image_root,
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

    /// run_start short-circuits with a clear error when the image
    /// root is empty (the v0.0.1 expectation until the recipe
    /// materializer populates it). This is the most common error
    /// path for first-launch users.
    #[tokio::test]
    async fn run_start_reports_unprovisioned() {
        let tmp = tempfile::tempdir().unwrap();
        let vm_slot = Arc::new(Mutex::new(None));
        let err = run_start(tmp.path().to_path_buf(), vm_slot.clone())
            .await
            .expect_err("expected unprovisioned error");
        assert!(
            err.contains("not yet materialized"),
            "unexpected error: {err}"
        );
        assert!(vm_slot.lock().unwrap().is_none(), "slot should stay empty");
    }
}
