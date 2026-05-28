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
use objc2_app_kit::{NSMenuItem, NSStatusItem};
use objc2_foundation::MainThreadMarker;

use tillandsias_vm_layer::VmRuntime;
use tillandsias_vm_layer::vz::VzRuntime;

use crate::main_thread::dispatch_to_main_thread;

/// Send/Sync wrappers around AppKit `Retained<…>` handles so they can
/// sit in the action-host's ivars (the host is `MainThreadOnly`, but
/// ivars get cloned across threads when worker callbacks move Arcs
/// into background tasks before dispatching back to main).
///
/// SAFETY: every method on `NSStatusItem` / `NSMenuItem` MUST be
/// called from the AppKit main thread. All touches in this crate go
/// through `dispatch_to_main_thread`, so the contract holds. The
/// wrappers exist purely to satisfy `Send + Sync`.
mod appkit_handle {
    use objc2::rc::Retained;
    use objc2_app_kit::{NSMenuItem, NSStatusItem};
    pub(crate) struct StatusItemHandle(pub Retained<NSStatusItem>);
    // SAFETY: see module docstring.
    unsafe impl Send for StatusItemHandle {}
    unsafe impl Sync for StatusItemHandle {}
    pub(crate) struct StatusMenuItemHandle(pub Retained<NSMenuItem>);
    // SAFETY: see module docstring.
    unsafe impl Send for StatusMenuItemHandle {}
    unsafe impl Sync for StatusMenuItemHandle {}
    /// A retained pointer to the TrayActionHost instance itself.
    /// Used by the cloud-projects poller's menu-rebuild dispatch
    /// to call back into TrayActionHost on the main thread so it
    /// can wire `target = action_host` on each rebuilt NSMenuItem.
    /// Set once at startup via `set_self_handle`; only the .0 is
    /// dereffed inside a main-thread dispatch closure.
    pub(crate) struct TrayActionHostHandle(pub Retained<super::TrayActionHost>);
    // SAFETY: see module docstring.
    unsafe impl Send for TrayActionHostHandle {}
    unsafe impl Sync for TrayActionHostHandle {}
}

/// Apply a status-chip text update on the AppKit main thread.
/// Updates the first-row menu item's title AND the menubar icon's
/// tooltip so hover-over also reveals the live phase.
///
/// MUST be invoked from the main thread (the libdispatch contract
/// in `dispatch_to_main_thread` enforces that for closure callers).
/// Reading the Arc<Mutex<>> handles is cheap and non-blocking
/// because nothing else holds them across long sections.
fn apply_status_text_main_thread(
    text: &str,
    status_item: &Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: &Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
) {
    use objc2_foundation::NSString;
    // We're on main per the libdispatch contract.
    let mtm = unsafe { MainThreadMarker::new_unchecked() };
    let label = NSString::from_str(text);
    if let Some(handle) = status_menu_item.lock().unwrap().as_ref() {
        unsafe { handle.0.setTitle(&label) };
    }
    if let Some(handle) = status_item.lock().unwrap().as_ref()
        && let Some(button) = unsafe { handle.0.button(mtm) }
    {
        unsafe { button.setToolTip(Some(&label)) };
    }
}

/// Condensed status-line text for a live VM phase + podman readiness.
/// Drives the shared `ids::STATUS` chip (and the menubar tooltip) so
/// the menu reflects real VM health — converges with the windows-tray
/// helper of the same name (see `tillandsias-windows-tray::notify_icon::
/// vm_phase_status_text`, commit c45f23ae). Keeping the two trays'
/// phase strings byte-for-byte identical satisfies the 2026-05-27 UX
/// hard requirement that all three platforms render the same chip text
/// once the in-VM headless reports its phase. The macOS-specific
/// pre-boot phase ("Setting up Fedora Linux…") sits outside this
/// table because it has no Linux/Windows analogue.
fn vm_phase_status_text(phase: tillandsias_control_wire::VmPhase, podman_ready: bool) -> String {
    use tillandsias_control_wire::VmPhase;
    match phase {
        VmPhase::Ready if podman_ready => "\u{1F7E2} Ready".to_string(),
        VmPhase::Ready => "\u{1F7E1} Ready (podman starting\u{2026})".to_string(),
        VmPhase::Provisioning => "\u{1F535} Provisioning\u{2026}".to_string(),
        VmPhase::Starting => "\u{1F535} Starting\u{2026}".to_string(),
        VmPhase::Draining => "\u{1F7E0} Draining\u{2026}".to_string(),
        VmPhase::Stopping => "\u{1F534} Stopping\u{2026}".to_string(),
        VmPhase::Failed => "\u{1F534} VM failed".to_string(),
    }
}

/// One-shot VmStatus poll over the in-VM control wire. Mirrors
/// `tillandsias-windows-tray::notify_icon::refresh_vm_status` but
/// drives the macOS-specific vsock path:
///
///   1. `VzRuntime::open_vsock_stream` (which uses
///      `VZVirtioSocketDevice.connectToPort:` under the hood) to get
///      an `AsyncRead + AsyncWrite` stream into the guest's port 42420.
///   2. Wrap the stream in `Client::from_stream` so the standard
///      Hello/HelloAck + request/recv code paths drive it.
///   3. Send a `VmStatusRequest` and expect a `VmStatusReply`.
///
/// Returns the `(phase, podman_ready)` pair so the caller can render
/// it via `vm_phase_status_text` + `apply_status_text_main_thread`.
/// Best-effort: a transient wire error is returned as `Err(String)` so
/// the caller can log + leave the last-known chip text untouched
/// (matching the windows-tray policy of "transient error → no chip
/// update"). The 5 s timeout covers connect + handshake + reply.
///
/// @trace spec:vsock-transport,
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4)
async fn poll_vm_status_once(
    vz: &VzRuntime,
) -> Result<(tillandsias_control_wire::VmPhase, bool), String> {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let connect_timeout = Duration::from_secs(5);
    let stream = vz
        .open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, connect_timeout)
        .await
        .map_err(|e| format!("vsock connect: {e}"))?;

    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: TILLANDSIAS_GUEST_CID,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );

    client
        .handshake()
        .await
        .map_err(|e| format!("control-wire handshake: {e}"))?;

    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: client.allocate_seq(),
        body: ControlMessage::VmStatusRequest {
            seq: client.allocate_seq(),
        },
    };
    let reply = client
        .request(&envelope)
        .await
        .map_err(|e| format!("VmStatusRequest: {e}"))?;

    match reply.body {
        ControlMessage::VmStatusReply {
            phase,
            podman_ready,
            ..
        } => Ok((phase, podman_ready)),
        other => Err(format!("unexpected reply to VmStatusRequest: {other:?}")),
    }
}

/// Map a wire `CloudProjectEntry` ({label, owner, repo,
/// default_branch}) onto the shared menu `ProjectEntry` the cloud-
/// projects submenu renders. `ProjectEntry::path` is the `owner/repo`
/// slug per its doc; `ready` is always false for cloud projects
/// (they have no in-VM forge container). Mirrors windows-tray's
/// `cloud_entry_to_menu` (commit b0cdcdee) byte-for-byte so both
/// trays produce identical ProjectEntry rows from the same wire
/// reply.
fn cloud_entry_to_menu(
    entry: &tillandsias_control_wire::CloudProjectEntry,
) -> tillandsias_host_shell::menu_state::ProjectEntry {
    tillandsias_host_shell::menu_state::ProjectEntry {
        name: entry.label.clone(),
        path: format!("{}/{}", entry.owner, entry.repo),
        ready: false,
    }
}

/// One-shot CloudRefreshRequest over the in-VM control wire. Mirrors
/// `tillandsias-windows-tray::notify_icon::refresh_cloud_projects`
/// (commit b0cdcdee) but drives the macOS-specific vsock path via
/// `VzRuntime::open_vsock_stream`. Reuses the standard
/// `Client::from_stream` + handshake + request path slice 4
/// introduced.
///
/// Returns the mapped `Vec<ProjectEntry>` so the caller can write it
/// into the held `MenuState.cloud_projects` and re-render the menu.
/// Best-effort: a transient wire error / unauthenticated `gh` in the
/// VM returns `Err(String)` so the caller can log + leave the last-
/// known cloud list untouched (matches windows-tray's policy).
///
/// 5 s overall timeout (connect + handshake + reply) — `gh repo list`
/// inside the VM is the slowest input but Linux's e1a190d4 caches
/// the underlying calls; if it still races the timeout the user just
/// sees the prior list.
///
/// @trace spec:host-shell-architecture,
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 8a)
async fn poll_cloud_projects_once(
    vz: &VzRuntime,
) -> Result<Vec<tillandsias_host_shell::menu_state::ProjectEntry>, String> {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    let connect_timeout = Duration::from_secs(5);
    let stream = vz
        .open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, connect_timeout)
        .await
        .map_err(|e| format!("vsock connect: {e}"))?;

    let mut client = Client::from_stream(
        Box::new(stream),
        Transport::Vsock {
            cid: TILLANDSIAS_GUEST_CID,
            port: CONTROL_WIRE_VSOCK_PORT,
        },
    );
    client
        .handshake()
        .await
        .map_err(|e| format!("control-wire handshake: {e}"))?;

    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::CloudRefreshRequest { seq },
    };
    let reply = client
        .request(&envelope)
        .await
        .map_err(|e| format!("CloudRefreshRequest: {e}"))?;

    match reply.body {
        ControlMessage::CloudRefreshReply { projects, .. } => {
            Ok(projects.iter().map(cloud_entry_to_menu).collect())
        }
        other => Err(format!(
            "unexpected reply to CloudRefreshRequest: {other:?}"
        )),
    }
}

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
    /// The NSStatusItem the action host's tooltip updates apply to.
    /// Set once at startup via `attach_status_handles`; stays `None`
    /// only briefly between TrayActionHost::new and the subsequent
    /// attach call from `status_item::run`.
    status_item: Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    /// The first-row "status chip" NSMenuItem whose `title` reflects
    /// the current lifecycle phase. Held directly so `set_status_text`
    /// just calls `setTitle:` on it (cheaper + simpler than rebuilding
    /// the whole menu). Set alongside `status_item`.
    status_menu_item: Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
    /// Current first-row status text. Stored for any future
    /// non-AppKit consumer (logs, tests). The actual UI source of
    /// truth is `status_menu_item.title`; we keep this string in
    /// sync so off-thread reads stay safe.
    status_text: Arc<Mutex<String>>,
    /// Held menu-state snapshot. Updated by the poller tasks when
    /// they learn the in-VM truth (cloud_projects from
    /// `poll_cloud_projects_once`; eventually podman_ready + login).
    /// Slice 8b stages this for slice 8c's menu re-render path.
    menu_state: Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    /// `Retained<TrayActionHost>` to self, populated once via
    /// `set_self_handle` right after construction. Held so the
    /// cloud-projects poller's rebuild dispatch can re-bind every
    /// new NSMenuItem's `target` back to the live action host
    /// without needing a Retained<Self> threaded through Send-able
    /// closures (which doesn't work — Retained<TrayActionHost>
    /// isn't Send because of the UnsafeCell layout). Wrapping in
    /// `TrayActionHostHandle` is the safe seam.
    self_handle: Arc<Mutex<Option<appkit_handle::TrayActionHostHandle>>>,
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
            // Thin selector wrapper around the shared boot path. The
            // menu item that triggers this selector is on its way out
            // (slice 3 of the auto-start UX redesign — the user
            // doesn't manually drive VM lifecycle), but keeping the
            // selector alive lets the existing Start VM menu item +
            // any external `[host startVm:]` callers still work
            // during the transition.
            self.boot_vm_async("Start VM");
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

        #[method(quitWithDrain:)]
        fn quit_with_drain(&self, _sender: Option<&AnyObject>) {
            let ivars = self.ivars();

            // User-visible feedback: chip immediately flips to Stopping.
            // The tooltip mirrors so even with the menu closed the
            // menubar icon hover surface reflects the drain.
            self.set_status_text("\u{1F534} Stopping\u{2026}");

            // Take the live VM out of the slot so a stray retry click
            // can't double-stop. If there's no VM (e.g. user quits
            // before boot completes), we still proceed to exit(0) —
            // Quit must always terminate the app.
            let vm_taken = ivars.vm.lock().unwrap().take();

            // Mark busy so concurrent click paths skip out fast — the
            // drain task never clears this; exit(0) ends the process.
            *ivars.vm_busy.lock().unwrap() = true;

            let runtime = ivars.runtime.clone();

            eprintln!(
                "[tillandsias-tray] Quit: draining (timeout={}s)",
                VM_STOP_DRAIN.as_secs()
            );
            runtime.spawn(async move {
                if let Some(vm) = vm_taken {
                    match vm.stop(VM_STOP_DRAIN).await {
                        Ok(()) => {
                            eprintln!("[tillandsias-tray] Quit: VM drained cleanly")
                        }
                        Err(e) => {
                            eprintln!("[tillandsias-tray] Quit: drain failed: {e}")
                        }
                    }
                } else {
                    eprintln!("[tillandsias-tray] Quit: no live VM, skipping drain");
                }
                // Bypass AppKit cleanup — the only critical shutdown
                // step for v0.0.1 is the VM drain above. NSApplication
                // doesn't own state we need to flush; the Tokio
                // runtime is fine to abandon (we're about to call
                // exit(0) anyway). Future revisions can route this
                // through NSApplicationDelegate::applicationShouldTerminate
                // + NSTerminateLater for a cleaner AppKit handshake.
                std::process::exit(0);
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

        /// Generic shared-MenuStructure click dispatcher. Every menu
        /// item built from the shared `MenuStructure` (except Quit,
        /// which uses the responder-chain `terminate:`) has its
        /// `action = sel!(trayAction:)` + `target = action_host` +
        /// `representedObject = NSString::from_str(spec.id)`. On
        /// click, AppKit delivers `sender = NSMenuItem`; we read the
        /// id string, resolve to `MenuAction` via the shared
        /// `menu_action::resolve` table, and dispatch — mirroring
        /// `tillandsias-windows-tray::notify_icon::dispatch_action`.
        #[method(trayAction:)]
        fn tray_action(&self, sender: Option<&AnyObject>) {
            use objc2::msg_send_id;
            use objc2_app_kit::NSMenuItem;
            use objc2_foundation::NSString;

            let Some(sender) = sender else { return };
            let item: &NSMenuItem = unsafe { &*(sender as *const AnyObject).cast() };
            // SAFETY: representedObject returns Option<Retained<NSObject>>.
            // We set it to an NSString at menu-build time, so the downcast
            // is safe for our menu items. msg_send_id! handles the +0/+1
            // retain conventions correctly for `representedObject`.
            let rep: Option<Retained<NSString>> =
                unsafe { msg_send_id![item, representedObject] };
            let id_owned = match rep {
                Some(s) => s.to_string(),
                None => return,
            };
            self.dispatch_menu_action(&id_owned);
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
    on_phase: &(dyn Fn(&str) + Send + Sync),
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
        vz.fetch_recipe_artifact(&manifest, &tag, on_phase)
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
            status_item: Arc::new(Mutex::new(None)),
            status_menu_item: Arc::new(Mutex::new(None)),
            menu_state: Arc::new(Mutex::new({
                let mut s = tillandsias_host_shell::menu_state::MenuState::initial();
                s.target = tillandsias_host_shell::menu_state::TargetSurface::MacosTray;
                s
            })),
            self_handle: Arc::new(Mutex::new(None)),
            status_text: Arc::new(Mutex::new(
                "\u{1F535} Setting up Fedora Linux\u{2026}".to_string(),
            )),
        };
        // SAFETY: `mtm` proves main-thread; allocation + init is the
        // standard ObjC two-step. `set_ivars` populates the declared
        // class ivars before init runs.
        let this = mtm.alloc::<Self>().set_ivars(ivars);
        unsafe { msg_send_id![super(this), init] }
    }

    /// Resolve a menu-item id to its `MenuAction` and dispatch.
    /// Mirrors `tillandsias-windows-tray::notify_icon::dispatch_action`
    /// so the per-host implementations of the shared menu agree on
    /// what each item does.
    ///
    /// Slice scope (this iter): handle the items Windows actually
    /// has a side-effect for today (Retry, Open URLs, Open Log), log
    /// the others honestly (don't pretend Attach/GithubLogin work
    /// without the in-VM headless + status state). Subsequent
    /// slices add SelectAgent + menu re-render, Quit drain, and the
    /// real Attach/Maintain/GithubLogin PTY path once the macOS tray
    /// holds enough state to identify the active project.
    pub fn dispatch_menu_action(&self, id: &str) {
        use tillandsias_host_shell::menu_action::{self, MenuAction};

        let action = menu_action::resolve(id);
        eprintln!("[tillandsias-tray] click: id={id} action={action:?}");
        match action {
            MenuAction::Quit => {
                // The menu's Quit item already wires `terminate:`
                // directly (responder chain → NSApplication), so this
                // arm typically isn't reached. Defensive log only.
                eprintln!("[tillandsias-tray] Quit dispatched via trayAction (unexpected)");
            }
            MenuAction::Retry => {
                // Mirror Windows: re-trigger provisioning. boot_vm_async
                // is idempotent + busy-gated, so a click while already
                // booting is a no-op.
                self.boot_vm_async("Retry");
            }
            MenuAction::OpenLog => {
                // Open ~/Library/Logs/Tillandsias/tray.log (or its
                // parent if the file isn't yet written). Best-effort:
                // shell out to `open` so the user's default text editor
                // takes over. Mirrors Windows's `open_log_file`.
                if let Some(home) = std::env::var_os("HOME") {
                    let log_dir = std::path::PathBuf::from(home).join("Library/Logs/Tillandsias");
                    let _ = std::fs::create_dir_all(&log_dir);
                    let _ = std::process::Command::new("open").arg(&log_dir).spawn();
                }
            }
            MenuAction::OpenObservatorium | MenuAction::OpenOpenCodeWeb => {
                // Same gating as Windows today: no URL exists until the
                // VM + router are up (gui-passthrough is v2 per the
                // macos-tray spec). Log + skip; the menu items also
                // come in with `enabled=false` from
                // `menu_disabled_v2::render`, so this arm shouldn't be
                // reachable in practice — defensive only.
                eprintln!("[tillandsias-tray] {action:?}: no URL yet (gui-passthrough is v2)");
            }
            MenuAction::SelectAgent(agent) => {
                // TODO(slice): mutate held MenuState + re-render the
                // menu so the checkmark moves. Mirrors Windows's
                // `apply_menu_action_state`. Stubbed for now — clicking
                // updates stderr but the menu doesn't visually change.
                eprintln!(
                    "[tillandsias-tray] SelectAgent({agent:?}): TODO wire MenuState + rerender"
                );
            }
            MenuAction::Attach {
                ref scope,
                ref name,
            }
            | MenuAction::Maintain {
                ref scope,
                ref name,
            } => {
                // TODO(slice): build a PtyIntent + project from the
                // click, run attach_pty against the in-VM forge for
                // that project. Needs MenuState ownership + a way to
                // resolve "active project" from a click. Stubbed.
                eprintln!(
                    "[tillandsias-tray] {action:?} (scope={scope:?}, name={name:?}): \
                     TODO wire to attach_pty"
                );
            }
            MenuAction::GithubLogin => {
                // Top-level GitHub login. Same gate as Attach —
                // needs the in-VM headless to be Ready. Defer to the
                // existing `attach_pty(GithubLogin)` path, which
                // already logs "no VM running" cleanly when the VM
                // isn't up yet.
                self.attach_pty(
                    "GitHub login",
                    tillandsias_host_shell::pty::PtyIntent::GithubLogin,
                );
            }
            MenuAction::CloudOverflow | MenuAction::Inert => {
                // Informational / overflow placeholders. No action.
            }
        }
    }

    /// Stash AppKit handles so subsequent `set_status_text` calls
    /// can update the first-row chip + the tooltip in-place. Called
    /// once from `status_item::run` right after both handles exist.
    /// Must be invoked from the main thread (`MainThreadOnly`
    /// contract on `TrayActionHost`).
    pub fn attach_status_handles(
        &self,
        status_item: Retained<NSStatusItem>,
        status_menu_item: Retained<NSMenuItem>,
    ) {
        let ivars = self.ivars();
        *ivars.status_item.lock().unwrap() = Some(appkit_handle::StatusItemHandle(status_item));
        *ivars.status_menu_item.lock().unwrap() =
            Some(appkit_handle::StatusMenuItemHandle(status_menu_item));
    }

    /// Stash a Retained handle to `self` so off-thread workers (the
    /// cloud-projects poller's rebuild dispatch) can re-borrow it on
    /// the main thread to call methods like `build_menu_item` that
    /// need `&TrayActionHost` for `setTarget:`. Call once from
    /// `status_item::run` right after `TrayActionHost::new`.
    pub fn set_self_handle(&self, this: Retained<Self>) {
        *self.ivars().self_handle.lock().unwrap() = Some(appkit_handle::TrayActionHostHandle(this));
    }

    /// Update the first-row status chip + the menubar tooltip to
    /// `text`. Records the string in `ivars.status_text` and
    /// dispatches an AppKit `setTitle:` / `setToolTip:` call on the
    /// main thread. Fire from any thread; the AppKit work happens
    /// on main.
    ///
    /// Slice 2 scope: macOS-local lifecycle phases the host owns —
    /// Provisioning, Booting, Ready, Error. Once the in-VM headless
    /// reports its own status over vsock (ControlMessage::VmStatus
    /// subscription), those will feed into the same path.
    pub fn set_status_text(&self, text: impl Into<String>) {
        let ivars = self.ivars();
        let text = text.into();
        *ivars.status_text.lock().unwrap() = text.clone();
        let status_item = ivars.status_item.clone();
        let status_menu_item = ivars.status_menu_item.clone();
        dispatch_to_main_thread(move || {
            apply_status_text_main_thread(&text, &status_item, &status_menu_item);
        });
    }

    /// Shared boot-the-VM path. Called by the `startVm:` selector AND
    /// directly from `status_item::run()` on app launch so the user
    /// never has to manually click Start VM (the lifecycle is
    /// automatic; the menu chip — slice 2 — reflects current state).
    ///
    /// `label` is the user-facing action name used in stderr logs so
    /// the auto-launch path and any legacy menu-click path stay
    /// distinguishable while we still have both.
    ///
    /// Safe to call multiple times: the busy gate + handle-already-
    /// installed check make repeat calls no-ops.
    pub fn boot_vm_async(&self, label: &str) {
        let ivars = self.ivars();

        // Re-entry gate: ignore the call if a start/stop is already
        // in flight. We run on the main thread; the worker clears
        // the flag via dispatch_to_main_thread.
        {
            let mut busy = ivars.vm_busy.lock().unwrap();
            if *busy {
                eprintln!("[tillandsias-tray] {label}: already in progress, ignoring");
                return;
            }
            *busy = true;
        }
        // Idempotency: if we already hold a live VM handle, just log
        // and bail (without touching the busy flag race).
        if ivars.vm.lock().unwrap().is_some() {
            *ivars.vm_busy.lock().unwrap() = false;
            eprintln!("[tillandsias-tray] {label}: VM already running, ignoring");
            return;
        }

        let runtime = ivars.runtime.clone();
        let vm_slot = ivars.vm.clone();
        let vm_busy = ivars.vm_busy.clone();
        let image_root = ivars.image_root.clone();
        let label_owned = label.to_string();
        let label_done = label_owned.clone();

        // Status chip: show that we've started. The Provisioning phase
        // bundles fetch + decompress + verify + boot until the
        // in-VM headless's vsock handshake completes (slice gates on
        // that signal). Granularity will increase when we wire
        // `download_verified::on_progress` (next slice).
        self.set_status_text("\u{1F535} Setting up Fedora Linux\u{2026}");

        // Clone the Arc-based status handles so the completion callback
        // can update the chip from the main-thread dispatch without
        // needing a Retained<Self> (which isn't Send). The closure
        // re-runs `apply_status_text_main_thread` on the main thread
        // exactly like `set_status_text` would.
        let status_text_slot = ivars.status_text.clone();
        let status_item_slot = ivars.status_item.clone();
        let status_menu_item_slot = ivars.status_menu_item.clone();
        let menu_state_slot = ivars.menu_state.clone();
        let self_handle_slot = ivars.self_handle.clone();

        eprintln!(
            "[tillandsias-tray] {label_owned}: spawning worker (image_root={})",
            image_root.display()
        );
        // Phase callback: each call to on_phase("Downloading rootfs")
        // etc. dispatches an `apply_status_text_main_thread` so the
        // user sees the chip update during a cold first launch
        // (74 MB download → xz decompress → SHA-256 verify). Subsequent
        // launches hit the rootfs.img cache and the phase callback
        // never fires.
        let phase_status_text = status_text_slot.clone();
        let phase_status_item = status_item_slot.clone();
        let phase_status_menu_item = status_menu_item_slot.clone();
        let on_phase: Box<dyn Fn(&str) + Send + Sync> = Box::new(move |phase: &str| {
            let text = format!("\u{1F535} {phase}\u{2026}");
            let text_for_dispatch = text.clone();
            let status_text = phase_status_text.clone();
            let status_item = phase_status_item.clone();
            let status_menu_item = phase_status_menu_item.clone();
            dispatch_to_main_thread(move || {
                *status_text.lock().unwrap() = text_for_dispatch.clone();
                apply_status_text_main_thread(&text_for_dispatch, &status_item, &status_menu_item);
            });
        });

        runtime.spawn(async move {
            let result = run_start(image_root, vm_slot.clone(), on_phase.as_ref()).await;

            // On success, snapshot the Arc<VzRuntime> for the poller
            // BEFORE handing ownership to the dispatch closure. On
            // failure, the slot stays empty and the poller is skipped.
            let vz_for_poller: Option<Arc<VzRuntime>> = match &result {
                Ok(()) => vm_slot.lock().unwrap().as_ref().cloned(),
                Err(_) => None,
            };

            // Initial post-boot chip text. Mirrors Windows' framing:
            // Starting until the in-VM headless replies via VmStatus.
            let initial_text = match &result {
                Ok(()) => {
                    eprintln!("[tillandsias-tray] {label_done}: VM is running");
                    vm_phase_status_text(tillandsias_control_wire::VmPhase::Starting, false)
                }
                Err(e) => {
                    eprintln!("[tillandsias-tray] {label_done} failed: {e}");
                    format!("\u{1F534} {e}")
                }
            };

            // Stage Arcs for the initial dispatch (these clones get
            // consumed; the originals stay for the poller spawn).
            let initial_status_text_slot = status_text_slot.clone();
            let initial_status_item_slot = status_item_slot.clone();
            let initial_status_menu_item_slot = status_menu_item_slot.clone();
            let initial_text_for_dispatch = initial_text.clone();
            dispatch_to_main_thread(move || {
                *vm_busy.lock().unwrap() = false;
                *initial_status_text_slot.lock().unwrap() = initial_text_for_dispatch.clone();
                apply_status_text_main_thread(
                    &initial_text_for_dispatch,
                    &initial_status_item_slot,
                    &initial_status_menu_item_slot,
                );
            });

            // Live status: kick off the 30s VmStatus poller. Holds
            // the Arc<VzRuntime> for its lifetime; the task lives for
            // the app lifetime (no cancellation in v0.0.1 — the Tokio
            // runtime drop on process exit takes it down).
            if let Some(vz) = vz_for_poller {
                spawn_vm_status_poller(
                    vz,
                    status_text_slot,
                    status_item_slot,
                    status_menu_item_slot,
                    menu_state_slot,
                    self_handle_slot,
                );
            }
        });
    }
}

/// Spawn the 30s VmStatus poller. Mirrors windows-tray's
/// `spawn_provisioning` Ready branch (commit c45f23ae): every 30s,
/// call `poll_vm_status_once`, render the result through
/// `vm_phase_status_text`, and patch the chip via a main-thread
/// dispatch. A transient wire error leaves the last-known chip text
/// untouched (matching the windows policy).
///
/// Lives outside the impl so the spawned task only captures Arcs +
/// the VzRuntime handle (no Retained<Self> bookkeeping). The task
/// runs for the lifetime of the Tokio runtime — process exit takes
/// it down via runtime drop.
///
/// @trace spec:vsock-transport,
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 5)
/// Rebuild the NSMenu on the AppKit main thread from the held
/// MenuState and swap it in via `NSStatusItem.setMenu:`. Re-attaches
/// `status_menu_item` to the new first-row item (the chip), since
/// the old NSMenuItem instance is replaced by a fresh one inside
/// the new menu and any future `setTitle:` calls must target the
/// new instance.
///
/// MUST be invoked on the main thread (the libdispatch contract in
/// `dispatch_to_main_thread` enforces that for callers).
///
/// If `self_handle` hasn't been populated (i.e. someone forgot to
/// call `set_self_handle` from `status_item::run`), the rebuild is
/// skipped with a log line — better than panicking the AppKit
/// thread mid-loop.
///
/// @trace spec:macos-native-tray.ui.menu-parity@v1,
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 8c)
fn rebuild_menu_main_thread(
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    status_item: &Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: &Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
    self_handle: &Arc<Mutex<Option<appkit_handle::TrayActionHostHandle>>>,
) {
    use tillandsias_host_shell::menu_state as menu_state_mod;
    let mtm = unsafe { MainThreadMarker::new_unchecked() };

    let state_snapshot: menu_state_mod::MenuState = menu_state.lock().unwrap().clone();
    let structure = menu_state_mod::build(&state_snapshot);

    let host_guard = self_handle.lock().unwrap();
    let Some(host_handle) = host_guard.as_ref() else {
        eprintln!("[tillandsias-tray] menu-rebuild: self_handle not set, skipping");
        return;
    };
    let host: &TrayActionHost = &host_handle.0;

    let (menu, new_status_row) =
        crate::status_item::build_menu_with_status_row(mtm, &structure, host);

    if let Some(item_handle) = status_item.lock().unwrap().as_ref() {
        unsafe { item_handle.0.setMenu(Some(&menu)) };
    }
    if let Some(row) = new_status_row {
        *status_menu_item.lock().unwrap() = Some(appkit_handle::StatusMenuItemHandle(row));
    }
}

fn spawn_vm_status_poller(
    vz: Arc<VzRuntime>,
    status_text: Arc<Mutex<String>>,
    status_item: Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
    menu_state: Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    self_handle: Arc<Mutex<Option<appkit_handle::TrayActionHostHandle>>>,
) {
    tokio::spawn(async move {
        // Tick counter for the cloud-projects cadence. Matches windows-
        // tray's "first tick + every 10 ticks" pattern (commit
        // b0cdcdee) — first poll happens before the initial 30 s sleep,
        // subsequent polls every ~5 min (10 * 30 s = 300 s). gh repo
        // list is a slower-changing input than VmStatus so we don't
        // need every-tick granularity.
        let mut tick: u32 = 0;
        loop {
            // Cloud projects: first tick + every 10 ticks.
            let mut rebuild_needed = false;
            if tick.is_multiple_of(10) {
                match poll_cloud_projects_once(&vz).await {
                    Ok(projects) => {
                        let new_count = projects.len();
                        let mut guard = menu_state.lock().unwrap();
                        if guard.cloud_projects != projects {
                            guard.cloud_projects = projects;
                            rebuild_needed = true;
                            eprintln!(
                                "[tillandsias-tray] cloud-projects: \
                                 menu_state updated ({} entries)",
                                new_count
                            );
                        }
                        drop(guard);
                    }
                    Err(e) => {
                        eprintln!("[tillandsias-tray] cloud-projects poll: {e}");
                    }
                }
            }

            tokio::time::sleep(Duration::from_secs(30)).await;
            tick = tick.wrapping_add(1);

            match poll_vm_status_once(&vz).await {
                Ok((phase, podman_ready)) => {
                    // Reflect podman_ready into the held MenuState so
                    // the menu rebuild flips per-project action gating
                    // (`Attach Here` etc.). Same pattern windows-tray
                    // uses. A change here triggers the same rebuild
                    // dispatch the cloud-projects branch uses.
                    {
                        let mut guard = menu_state.lock().unwrap();
                        if guard.podman_ready != podman_ready {
                            guard.podman_ready = podman_ready;
                            rebuild_needed = true;
                        }
                    }
                    let text = vm_phase_status_text(phase, podman_ready);
                    let text_for_dispatch = text.clone();
                    let chip_status_text = status_text.clone();
                    let chip_status_item = status_item.clone();
                    let chip_status_menu_item = status_menu_item.clone();
                    dispatch_to_main_thread(move || {
                        *chip_status_text.lock().unwrap() = text_for_dispatch.clone();
                        apply_status_text_main_thread(
                            &text_for_dispatch,
                            &chip_status_item,
                            &chip_status_menu_item,
                        );
                    });
                }
                Err(e) => {
                    // Best-effort: log + leave last-known chip text.
                    eprintln!("[tillandsias-tray] vm-status poll: {e}");
                }
            }

            // If either cloud_projects or podman_ready changed this
            // iteration, rebuild the NSMenu on the main thread so
            // the menu reflects the new state. Note: the rebuild
            // happens AFTER the chip dispatch — they're independent
            // main-thread tasks and the chip update doesn't depend
            // on the new menu being installed.
            if rebuild_needed {
                let rebuild_menu_state = menu_state.clone();
                let rebuild_status_item = status_item.clone();
                let rebuild_status_menu_item = status_menu_item.clone();
                let rebuild_self_handle = self_handle.clone();
                dispatch_to_main_thread(move || {
                    rebuild_menu_main_thread(
                        &rebuild_menu_state,
                        &rebuild_status_item,
                        &rebuild_status_menu_item,
                        &rebuild_self_handle,
                    );
                });
            }
        }
    });
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

    /// `cloud_entry_to_menu` produces the byte-identical `ProjectEntry`
    /// shape windows-tray produces from the same wire input (commit
    /// b0cdcdee), so the cross-platform menu submenu rows agree on
    /// (name, path, ready) without either tray drifting.
    #[test]
    fn cloud_entry_maps_to_owner_slash_repo_slug() {
        let wire = tillandsias_control_wire::CloudProjectEntry {
            label: "tillandsias".to_string(),
            owner: "8007342".to_string(),
            repo: "tillandsias".to_string(),
            default_branch: "main".to_string(),
        };
        let menu = cloud_entry_to_menu(&wire);
        assert_eq!(menu.name, "tillandsias");
        assert_eq!(menu.path, "8007342/tillandsias");
        assert!(!menu.ready, "cloud projects have no in-VM forge yet");
    }

    /// The live status line distinguishes VM phases + podman readiness,
    /// so the shared `ids::STATUS` chip reflects real VM health
    /// (Ready vs podman-starting vs draining/failed) rather than a
    /// single static "Ready". Mirrors the windows-tray test in
    /// `notify_icon::tests::vm_phase_status_text_reflects_phase_and_podman`
    /// — keeping the two assertions identical guards the cross-platform
    /// UX-parity invariant.
    #[test]
    fn vm_phase_status_text_reflects_phase_and_podman() {
        use tillandsias_control_wire::VmPhase;
        assert!(vm_phase_status_text(VmPhase::Ready, true).contains("Ready"));
        // Ready-with-podman is visibly distinct from Ready-without-podman.
        assert_ne!(
            vm_phase_status_text(VmPhase::Ready, true),
            vm_phase_status_text(VmPhase::Ready, false)
        );
        assert!(
            vm_phase_status_text(VmPhase::Draining, true)
                .to_lowercase()
                .contains("drain")
        );
        assert!(
            vm_phase_status_text(VmPhase::Failed, false)
                .to_lowercase()
                .contains("fail")
        );
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
        let result = run_start(tmp.path().to_path_buf(), vm_slot.clone(), &|_| {}).await;
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
                assert!(
                    vm_slot.lock().unwrap().is_none(),
                    "slot should stay empty on err"
                );
            }
            Ok(()) => {
                // If the network + xz + start actually succeeded, the
                // VM is now running. Take the Arc out of the slot
                // BEFORE awaiting so we don't hold the std::sync Mutex
                // across an `.await` (clippy::await_holding_lock).
                let vz_taken = vm_slot.lock().unwrap().take();
                if let Some(vz) = vz_taken {
                    let _ = vz.stop(std::time::Duration::from_secs(60)).await;
                }
            }
        }
    }
}
