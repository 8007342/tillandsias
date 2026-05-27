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
use objc2::{ClassType, DeclaredClass, declare_class, msg_send_id, mutability};
use objc2_foundation::MainThreadMarker;

use tillandsias_vm_layer::VmRuntime;
use tillandsias_vm_layer::vz::VzRuntime;

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
            self.attach_pty(
                "Open Shell",
                tillandsias_host_shell::pty::PtyIntent::Shell,
            );
        }

        #[method(githubLogin:)]
        fn github_login(&self, _sender: Option<&AnyObject>) {
            self.attach_pty(
                "GitHub login",
                tillandsias_host_shell::pty::PtyIntent::GithubLogin,
            );
        }
    }
);

impl TrayActionHost {
    /// Shared composition body for the PTY-attach selectors
    /// (`openShell:` and `githubLogin:`). Gates on a live VM handle,
    /// spawns a Tokio worker that runs `run_pty_attach`, and
    /// dispatches the result back to the main thread to either
    /// spawn Terminal.app on the slave PTY path or pop a stub
    /// window with the error.
    ///
    /// `label` is the user-facing action name used in stderr logs
    /// and the stub fallback message. `intent` is the canonical
    /// `PtyIntent` consumed by `launch_spec`.
    fn attach_pty(&self, label: &'static str, intent: tillandsias_host_shell::pty::PtyIntent) {
        let ivars = self.ivars();
        let vz = match ivars.vm.lock().unwrap().clone() {
            Some(vz) => vz,
            None => {
                eprintln!("[tillandsias-tray] {label}: no VM running. Start VM first.");
                return;
            }
        };
        let runtime = ivars.runtime.clone();
        eprintln!("[tillandsias-tray] {label}: spawning attach worker");
        runtime.spawn(async move {
            let result = run_pty_attach(vz, intent).await;
            dispatch_to_main_thread(move || match result {
                Ok(slave_path) => {
                    eprintln!("[tillandsias-tray] {label}: PTY attached at {slave_path}");
                    if let Err(e) = crate::terminal_attach::spawn_terminal_pty_attach(&slave_path) {
                        eprintln!("[tillandsias-tray] {label}: terminal spawn failed: {e}");
                    }
                }
                Err(e) => {
                    eprintln!("[tillandsias-tray] {label} failed: {e}");
                    let stub = format!(
                        "Tillandsias — {label} could not attach. \
                             Error: {e}\n\nLive PTY attach needs a booted VM \
                             with a working in-VM headless on vsock port \
                             42420 (gated on m5 recipe-artifact fetch)."
                    );
                    let _ = crate::terminal_attach::spawn_terminal_stub_window(&stub);
                }
            });
        });
    }
}

/// Shared worker body for the PTY-attach selectors. Composes the
/// PTY-over-vsock chain: open vsock stream → handshake + framing →
/// host PTY master → PtySession::open(launch_spec(intent, ...)) →
/// pump_io. Returns the slave PTY path so the main-thread dispatch
/// can spawn Terminal.app pointed at it via `screen`.
///
/// `intent` selects the in-VM command — `Shell` for /bin/bash -l,
/// `GithubLogin` for `gh auth login`, etc. With project=None the
/// command targets the bare VM per the convergence-coordination
/// fallback (slice 5b' will surface project selection from
/// MenuStructure once it carries that state).
///
/// Each spawned tokio task (the bridge writer/reader, pump_io's two
/// halves) runs detached for v0.0.1; they unwind naturally when the
/// session closes (PTY EOF, vsock drop, or Terminal.app `screen`
/// session exits).
async fn run_pty_attach(
    vz: std::sync::Arc<VzRuntime>,
    intent: tillandsias_host_shell::pty::PtyIntent,
) -> Result<String, String> {
    use std::sync::Arc;
    use std::time::Duration;
    use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
    use tillandsias_host_shell::pty::unix::UnixPtyMaster;
    use tillandsias_host_shell::pty::{
        PtyRouter, PtySession, SessionIdAllocator, launch_spec, pump_io,
    };

    let stream = vz
        .open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
        .await
        .map_err(|e| format!("vsock connect: {e}"))?;

    let router = Arc::new(PtyRouter::new());
    let alloc = SessionIdAllocator::default();
    let (transport, _bridge_join, _wire_version) = crate::pty_vsock_bridge::connect_pty_bridge(
        stream,
        router.clone(),
        32,
        "tillandsias-macos-tray".to_string(),
        vec!["pty.attach@v1".to_string()],
    )
    .await
    .map_err(|e| format!("control-wire handshake: {e}"))?;

    let master = UnixPtyMaster::open(24, 80).map_err(|e| format!("openpty: {e}"))?;
    let slave_path = master.slave_path().to_string();

    let opts = launch_spec(&intent, None, 24, 80);
    let session = PtySession::open(Arc::new(transport), &alloc, &router, &opts)
        .map_err(|e| format!("PtyOpen: {e}"))?;

    let _pump_join = pump_io(session, master);
    Ok(slave_path)
}

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

    // First-launch flow (m5 integration): if no rootfs.img is present
    // yet, fetch the recipe-published artifact via l9's artifact-URL
    // contract before starting. The macOS tray bundles the manifest
    // at build time (include_str!) so the .app doesn't need network
    // for the manifest itself, only for the artifact bytes.
    //
    // Once a successful fetch lands, subsequent launches hit the
    // cache (download_verified short-circuits when dest sha matches)
    // so startup is fast.
    if !vz.is_provisioned() {
        eprintln!(
            "[tillandsias-tray] Start VM: rootfs.img missing at {}; \
             attempting recipe-artifact fetch",
            vz.rootfs_image_path().display()
        );
        let manifest = tillandsias_vm_layer::recipe::Manifest::from_toml(BUNDLED_MANIFEST_TOML)
            .map_err(|e| format!("bundled manifest parse: {e}"))?;
        // Per 2026-05-27 cross-host convergence vote (windows-host +
        // macOS concur): the manifest is the trust root and should
        // own the release tag alongside its pinned SHAs — pending
        // Linux/recipe addition of `[output].release_tag` +
        // `Manifest::release_tag()` accessor. Until that lands we
        // hardcode `v0.2.260526.1` to match the tag the current
        // pinned `aarch64.img` SHA corresponds to (Windows mirrors
        // this pattern via its `RECIPE_RELEASE_TAG` const). Switch
        // to `manifest.release_tag()` the moment it's available.
        let tag = RECIPE_RELEASE_TAG.to_string();
        vz.fetch_recipe_artifact(&manifest, &tag)
            .await
            .map_err(|e| {
                format!(
                    "recipe-artifact fetch failed (tag={tag}): {e}\n\n\
                 If the SHA pin is still 'pending-ci', wait for the next \
                 recipe-publish CI run + the SHA-pin commit (l9 step 5)."
                )
            })?;
        eprintln!("[tillandsias-tray] Start VM: rootfs.img fetched successfully");
    }

    vz.start().await?;
    *vm_slot.lock().unwrap() = Some(vz);
    Ok(())
}

/// Manifest bundled at build time so the .app doesn't depend on the
/// repo or network presence to know its artifact-URL template + pinned
/// SHAs. The compiled-in copy is what's checked into the repo at
/// `images/vm/manifest.toml` at the commit the .app was built from.
/// Updating the manifest (e.g. SHA pin after CI run) requires a
/// rebuild of the macOS tray.
const BUNDLED_MANIFEST_TOML: &str = include_str!("../../../images/vm/manifest.toml");

/// Release tag the manifest's currently-pinned rootfs SHAs correspond
/// to. Hardcoded for v0.0.1 pending Linux addition of
/// `[output].release_tag` to `manifest.toml` + a
/// `Manifest::release_tag()` accessor — at which point both trays
/// switch to `manifest.release_tag()` (single trust root for both
/// the URL template + SHA pin + release tag).
///
/// Windows mirrors this with its own `RECIPE_RELEASE_TAG` const; the
/// two values MUST stay in sync until the manifest field lands.
///
/// @trace plan/issues/tray-convergence-coordination.md
///        "Tag-source decision — windows vote" 2026-05-27
const RECIPE_RELEASE_TAG: &str = "v0.2.260526.1";

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

    /// FULL E2E exercise of the run_start path against the LIVE
    /// release asset — `#[ignore]` because:
    ///   - it actually fetches 74 MB from a real release,
    ///   - decompresses to an 8 GB sparse `.img` (~30s),
    ///   - SHA-256-streams the decompressed bytes against the pin
    ///     (~10s more),
    ///   - and finally `vz.start()` requires the
    ///     `com.apple.security.virtualization` entitlement (only
    ///     present on the codesigned `.app` bundle, NOT on
    ///     `cargo test` binaries), so the start step always errors
    ///     in the test harness even when the fetch chain succeeds.
    ///
    /// Run manually with: `cargo test -p tillandsias-macos-tray
    /// --bin tillandsias-tray run_start_full_e2e -- --ignored
    /// --nocapture`. On 2026-05-27 this test ran to the
    /// `Start VM: rootfs.img fetched successfully` line, proving the
    /// .img.xz fetch + decompress + verify chain works end-to-end
    /// against a live release asset (Apple Silicon, Tlatoanis-MacBook-
    /// Air). The subsequent entitlement error is expected in cargo
    /// test; the codesigned .app bundle clears that gate.
    #[tokio::test]
    #[ignore = "slow (~5min), network, needs com.apple.security.virtualization entitlement (.app only)"]
    async fn run_start_full_e2e() {
        let tmp = tempfile::tempdir().unwrap();
        let vm_slot = Arc::new(Mutex::new(None));
        let result = run_start(tmp.path().to_path_buf(), vm_slot.clone()).await;
        match result {
            Err(err) => {
                assert!(
                    err.contains("recipe-artifact fetch failed"),
                    "expected fetch-failed wrapping, got: {err}"
                );
                assert!(
                    err.contains("pending-ci") || err.contains("l9 step 5"),
                    "expected user-actionable hint, got: {err}"
                );
                assert!(vm_slot.lock().unwrap().is_none(), "slot should stay empty on err");
            }
            Ok(()) => {
                // If the network + xz + start actually succeeded, the
                // VM is now running. Stop it so the test doesn't leak
                // a live VZVirtualMachine.
                if let Some(vz) = vm_slot.lock().unwrap().take() {
                    let _ = vz.stop(std::time::Duration::from_secs(60)).await;
                }
            }
        }
    }
}
