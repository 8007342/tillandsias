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

/// Fire a macOS Notification Center banner ("Tillandsias —
/// Provisioning error / <reason>") so the user notices a failed VM
/// boot even without hovering the menubar icon. Mirrors windows-
/// tray's `show_balloon` (commit 8992652a item 1) but implemented
/// via an `osascript -e 'display notification ...'` shell-out
/// instead of `UNUserNotificationCenter` to avoid pulling
/// `objc2-user-notifications` (which currently pins a different
/// objc2 major than the workspace) and the permission-request
/// plumbing.
///
/// Best-effort: spawn osascript detached, log any error, never
/// block. The chip text remains the authoritative failure surface;
/// the notification is purely a "look here" nudge.
fn notify_provisioning_failed(reason: &str) {
    // AppleScript single-quote-escape so a `'` in the reason doesn't
    // terminate the literal. Then wrap the whole call in another
    // outer escape layer because we pass it as -e arg.
    let escaped = applescript_escape_single_quoted(reason);
    let body = format!(
        "display notification \"{escaped}\" with title \"Tillandsias\" \
         subtitle \"Provisioning error\""
    );
    match std::process::Command::new("osascript")
        .arg("-e")
        .arg(&body)
        .spawn()
    {
        Ok(_child) => {
            // Detached — let it complete in the background. macOS
            // notifications fire near-instantly so we don't need to
            // await the child.
        }
        Err(err) => {
            eprintln!("[tillandsias-tray] notification: osascript spawn failed: {err}");
        }
    }
}

/// AppleScript double-quoted-string escaping: backslash + double-quote
/// are the only metachars we need to handle inside `"..."`. Used by
/// `notify_provisioning_failed` to embed a user-visible reason inside
/// an AppleScript literal.
fn applescript_escape_single_quoted(reason: &str) -> String {
    let mut out = String::with_capacity(reason.len());
    for c in reason.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            // Collapse newlines to spaces — AppleScript display
            // notification renders newlines as control chars.
            '\n' | '\r' => out.push(' '),
            other => out.push(other),
        }
    }
    out
}

/// Format a dispatcher `Error{code, message}` into a poller-side log
/// string. Mirrors `tillandsias-windows-tray::notify_icon::
/// describe_wire_error` (commit eddb5c00) so both trays surface
/// identical operator-visible text when Linux's `decide_route`
/// returns an Unsupported frame instead of dropping into the
/// generic "unexpected reply" path.
fn describe_wire_error(code: tillandsias_control_wire::ErrorCode, message: &str) -> String {
    if message.is_empty() {
        format!("dispatcher error {code:?}")
    } else {
        format!("dispatcher error {code:?}: {message}")
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

/// Append a non-empty `VmStatusReply.last_event` to the base chip
/// string after a Unicode MIDDLE DOT so the live chip reflects in-VM
/// activity (e.g. `🟢 Ready · forge-foo created`) rather than just
/// the phase. `None` or whitespace-only `last_event` leaves the base
/// untouched.
///
/// Mirrors `tillandsias-windows-tray::notify_icon::compose_chip_text`
/// (commit 8992652a) byte-for-byte so both trays produce identical
/// chip strings for identical `VmStatusReply` payloads.
fn compose_chip_text(base: &str, last_event: Option<&str>) -> String {
    match last_event.map(str::trim).filter(|s| !s.is_empty()) {
        Some(evt) => format!("{base} \u{00B7} {evt}"),
        None => base.to_string(),
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
) -> Result<(tillandsias_control_wire::VmPhase, bool, Option<String>), String> {
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

    if let Err(err) =
        crate::installation_uuid::deliver_credentials_and_check_handover(&mut client).await
    {
        tracing::warn!(%err, "credentials delivery / handover check failed during status poll");
    }

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
            last_event,
            ..
        } => Ok((phase, podman_ready, last_event)),
        // Linux's convergence-packet item 3 (commit 4eb0baff) wires
        // decide_route into the vsock dispatcher so requests with no
        // inner handler return Error{code, message} frames carrying
        // the dispatcher's own naming ("Unsupported: variant X not
        // wired on vsock"). Surface that explicitly instead of
        // dropping into the generic "unexpected reply" path —
        // mirrors windows-tray's eddb5c00 (item 4).
        ControlMessage::Error { code, message, .. } => Err(describe_wire_error(code, &message)),
        other => Err(format!("unexpected reply to VmStatusRequest: {other:?}")),
    }
}

/// Send a wire-level `VmShutdownRequest` to the in-VM headless so it
/// can drain podman containers + sessions BEFORE VZ tears down the
/// VM. Mirrors `tillandsias-windows-tray::wsl_lifecycle::
/// request_vm_shutdown` (commit `80eceb0b`) but uses macOS's
/// `VZVirtioSocketConnection` path via `VzRuntime::open_vsock_stream`.
///
/// Bounded by `RTT_BUDGET` (3 s) — a wedged in-VM headless cannot
/// delay Quit indefinitely; the caller follows up with VZ-level
/// `requestStop` which carries its own deadline. Returns `Err` on
/// connect/handshake/reply failures + on the dispatcher's own
/// `Error{Unsupported}` reply (which is the expected state until
/// Linux ships the vsock-side inner handler — at which point this
/// auto-upgrades with no tray change).
///
/// `drain_timeout` is encoded as the request's `drain_timeout_ms`
/// hint for the in-VM headless so it knows the host's overall
/// shutdown budget.
///
/// @trace spec:vsock-transport,
///        plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2),
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 20)
async fn request_vm_shutdown(vz: &VzRuntime, drain_timeout: Duration) -> Result<(), String> {
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::Client;

    const RTT_BUDGET: Duration = Duration::from_secs(3);

    let stream = vz
        .open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, RTT_BUDGET)
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
        body: ControlMessage::VmShutdownRequest {
            seq,
            drain_timeout_ms: drain_timeout.as_millis().min(u32::MAX as u128) as u32,
        },
    };
    let reply = client
        .request(&envelope)
        .await
        .map_err(|e| format!("VmShutdownRequest: {e}"))?;

    match reply.body {
        // Per the wire convention (other handlers' shape): an Ok
        // shutdown ack is signalled either by a tailored reply
        // variant when Linux adds one, OR — for v0.0.1 where the
        // vsock inner arm isn't shipped yet — by a clean
        // Error{Unsupported}/etc. We treat ANY non-Error reply as
        // OK so this auto-upgrades when the inner arm lands.
        ControlMessage::Error { code, message, .. } => Err(describe_wire_error(code, &message)),
        _other => Ok(()),
    }
}

/// Map a wire `LocalProjectEntry` ({label, guest_path,
/// last_seen_unix}) onto the shared menu `ProjectEntry` the local-
/// projects submenu renders. `ProjectEntry::path` is the in-VM
/// guest path (the VM mounts the host's `~/src/` via virtio-fs so
/// the guest path is what "Attach Here" actually targets). `ready`
/// defaults to false — per-project forge readiness isn't carried
/// by `LocalProjectsReply` yet; a future PerProjectStatusReply
/// would be the right place to populate it.
fn local_entry_to_menu(
    entry: &tillandsias_control_wire::LocalProjectEntry,
) -> tillandsias_host_shell::menu_state::ProjectEntry {
    tillandsias_host_shell::menu_state::ProjectEntry {
        name: entry.label.clone(),
        path: entry.guest_path.clone(),
        ready: false,
    }
}

/// One-shot `EnumerateLocalProjects` over the in-VM control wire.
/// Mirrors `poll_cloud_projects_once` but consumes Linux's
/// `EnumerateLocalProjects` handler (commit `05cc3a7d`) — each host
/// (including macOS) walks its in-VM mount of the host's `~/src/`
/// via virtio-fs, returning one entry per visible directory.
///
/// Returns `Vec<ProjectEntry>` mapped from `LocalProjectEntry`.
/// Best-effort: a transient wire error returns `Err(String)` so the
/// caller can log + leave the last-known list untouched.
///
/// @trace spec:host-shell-architecture,
///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 19)
async fn poll_local_projects_once(
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

    if let Err(err) =
        crate::installation_uuid::deliver_credentials_and_check_handover(&mut client).await
    {
        tracing::warn!(%err, "credentials delivery / handover check failed during local projects poll");
    }

    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::EnumerateLocalProjects { seq },
    };
    let reply = client
        .request(&envelope)
        .await
        .map_err(|e| format!("EnumerateLocalProjects: {e}"))?;

    match reply.body {
        ControlMessage::LocalProjectsReply { entries, .. } => {
            Ok(entries.iter().map(local_entry_to_menu).collect())
        }
        ControlMessage::Error { code, message, .. } => Err(describe_wire_error(code, &message)),
        other => Err(format!(
            "unexpected reply to EnumerateLocalProjects: {other:?}"
        )),
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

    if let Err(err) =
        crate::installation_uuid::deliver_credentials_and_check_handover(&mut client).await
    {
        tracing::warn!(%err, "credentials delivery / handover check failed during cloud projects poll");
    }

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
        // See poll_vm_status_once for context on the dispatcher Error
        // frame (Linux convergence-packet items 2 + 3, commits
        // aeb5499a / 4eb0baff). Surface code + message via the shared
        // describe_wire_error helper.
        ControlMessage::Error { code, message, .. } => Err(describe_wire_error(code, &message)),
        other => Err(format!(
            "unexpected reply to CloudRefreshRequest: {other:?}"
        )),
    }
}

/// One-shot GithubLoginStatusRequest over the in-VM control wire. Mirrors
/// `tillandsias-windows-tray::notify_icon::refresh_github_login` but
/// drives the macOS-specific vsock path via `VzRuntime::open_vsock_stream`.
///
/// Returns the mapped `GithubLoginState` so the caller can write it into the
/// held `MenuState.login` and re-render the menu.
/// Best-effort: a transient wire error / Error{Unsupported} returns `Err(String)`
/// so the caller can log + leave the last-known login state untouched (matches
/// windows-tray's policy).
async fn poll_github_login_once(
    vz: &VzRuntime,
) -> Result<tillandsias_host_shell::menu_state::GithubLoginState, String> {
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

    if let Err(err) =
        crate::installation_uuid::deliver_credentials_and_check_handover(&mut client).await
    {
        tracing::warn!(%err, "credentials delivery / handover check failed during github login poll");
    }

    let seq = client.allocate_seq();
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq,
        body: ControlMessage::GithubLoginStatusRequest { seq },
    };
    let reply = client
        .request(&envelope)
        .await
        .map_err(|e| format!("GithubLoginStatusRequest: {e}"))?;

    match reply.body {
        ControlMessage::GithubLoginStatusReply {
            logged_in, handle, ..
        } => {
            if logged_in {
                Ok(
                    tillandsias_host_shell::menu_state::GithubLoginState::LoggedIn {
                        handle: handle.unwrap_or_default(),
                    },
                )
            } else {
                Ok(tillandsias_host_shell::menu_state::GithubLoginState::LoggedOut)
            }
        }
        ControlMessage::Error { code, message, .. } => Err(describe_wire_error(code, &message)),
        other => Err(format!(
            "unexpected reply to GithubLoginStatusRequest: {other:?}"
        )),
    }
}

/// Default vsock CID for the Tillandsias guest. Matches what the
/// in-VM headless binds; the host always connects to this CID.
const TILLANDSIAS_GUEST_CID: u32 = 3;

/// Status-chip text the wire-degradation branch of
/// `spawn_vm_status_poller` writes when `poll_vm_status_once` fails
/// (handshake / connect / request error). Pinned as a `const` —
/// not an inline literal — because `tillandsias-windows-tray::
/// notify_icon::mark_wire_unreachable` writes the SAME string. If
/// either tray drifts (e.g. someone localises one side or changes
/// the emoji), the cross-tray UX-parity invariant silently
/// breaks. The unit test
/// `wire_unreachable_chip_text_pinned` asserts the exact byte
/// sequence (`🔴 + space + Wire unreachable`, U+1F534 + " Wire
/// unreachable" = 22 bytes).
const WIRE_UNREACHABLE_CHIP_TEXT: &str = "\u{1F534} Wire unreachable";

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
                    // Two-step graceful shutdown (mirrors windows-tray
                    // 80eceb0b Q2). Step 1: wire-level
                    // VmShutdownRequest so the in-VM headless gets a
                    // chance to drain podman containers + their
                    // sessions BEFORE VZ tears down the VM. Bounded
                    // 3s wire RTT so a wedged headless can't delay
                    // Quit indefinitely; we then fall through to
                    // VZ.requestStop which carries its own
                    // VM_STOP_DRAIN deadline. On vsock today the
                    // in-VM dispatcher routes per the matrix but no
                    // inner VmShutdownRequest handler exists yet, so
                    // the reply is Error{Unsupported} which we log at
                    // info as expected. When linux adds the vsock
                    // inner arm this auto-upgrades with NO tray code
                    // change.
                    match request_vm_shutdown(&vm, VM_STOP_DRAIN).await {
                        Ok(()) => eprintln!(
                            "[tillandsias-tray] Quit: in-VM headless acked shutdown request"
                        ),
                        Err(e) => eprintln!(
                            "[tillandsias-tray] Quit: in-VM shutdown request: {e} \
                             (proceeding to VZ.requestStop)"
                        ),
                    }
                    // Step 2: VZ-level stop (existing path). Drains
                    // VM_STOP_DRAIN waiting for state=Stopped then
                    // escalates to force-stop.
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
                None,
            );
        }

        #[method(githubLogin:)]
        fn github_login(&self, _sender: Option<&AnyObject>) {
            self.attach_pty(
                "GitHub login",
                tillandsias_host_shell::pty::PtyIntent::GithubLogin,
                None,
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
    /// `PtyIntent` consumed by `launch_spec`. `project` (m10): when
    /// `Some(p)`, `launch_spec` wraps the in-VM command with `podman
    /// exec -it tillandsias-<p>-forge …` so the PTY lands inside the
    /// project's forge container (cross-host agreement: the user's
    /// files + dev tooling live in the forge, not on the bare VM).
    /// When `None`, the bare-VM command runs — the deliberate
    /// VM-debug escape hatch for `Shell` + the user-level path for
    /// `GithubLogin`. See `tillandsias_host_shell::pty::intent_for_action`
    /// for the canonical `MenuAction` → `(intent, project)` mapping.
    fn attach_pty(
        &self,
        label: &'static str,
        intent: tillandsias_host_shell::pty::PtyIntent,
        project: Option<String>,
    ) {
        let ivars = self.ivars();
        let vz = match ivars.vm.lock().unwrap().clone() {
            Some(vz) => vz,
            None => {
                eprintln!("[tillandsias-tray] {label}: no VM running. Start VM first.");
                return;
            }
        };
        let runtime = ivars.runtime.clone();
        eprintln!("[tillandsias-tray] {label}: spawning attach worker (project={project:?})");
        runtime.spawn(async move {
            let result = run_pty_attach(vz, intent, project).await;
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
/// `GithubLogin` for `gh auth login`, etc. `project` (m10): when
/// `Some(p)`, `launch_spec` wraps the command in `podman exec -it
/// tillandsias-<p>-forge …` so it lands inside that project's forge
/// container; when `None`, the bare-VM command runs (Shell = VM-debug
/// escape; GithubLogin = user-level pre-attach).
///
/// Each spawned tokio task (the bridge writer/reader, pump_io's two
/// halves) runs detached for v0.0.1; they unwind naturally when the
/// session closes (PTY EOF, vsock drop, or Terminal.app `screen`
/// session exits).
async fn run_pty_attach(
    vz: std::sync::Arc<VzRuntime>,
    intent: tillandsias_host_shell::pty::PtyIntent,
    project: Option<String>,
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

    let opts = launch_spec(&intent, project.as_deref(), 24, 80);
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

    // First-launch flow (m9 Fedora pivot): if no rootfs.img is present
    // yet, fetch Fedora's official Cloud qcow2 via the bundled manifest
    // and convert it to the raw disk image VZ boots. The macOS tray
    // bundles the manifest at build time (include_str!) so the .app
    // doesn't need network for the manifest itself, only for the image.
    //
    // Once a successful fetch lands, subsequent launches hit the
    // cache (download_verified short-circuits when dest sha matches)
    // so startup is fast.
    if !vz.is_provisioned() {
        eprintln!(
            "[tillandsias-tray] Start VM: rootfs.img missing at {}; \
             attempting Fedora Cloud image fetch",
            vz.rootfs_image_path().display()
        );
        let manifest = tillandsias_vm_layer::recipe::Manifest::from_toml(BUNDLED_MANIFEST_TOML)
            .map_err(|e| format!("bundled manifest parse: {e}"))?;
        vz.fetch_fedora_cloud_image(&manifest, on_phase)
            .await
            .map_err(|e| {
                format!(
                    "Fedora Cloud image fetch failed: {e}\n\n\
                     Install qemu (`brew install qemu`) if conversion failed, \
                     then retry Start VM."
                )
            })?;
        eprintln!("[tillandsias-tray] Start VM: Fedora Cloud image ready");
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

pub(crate) const FEDORA_BASELINE: &str = "fedora-44";

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
                // m11: mutate held MenuState via `apply_menu_action_state`
                // (mirror of windows-tray's `apply_menu_action_state` at
                // notify_icon.rs:1674), then trigger an immediate NSMenu
                // rebuild on the main thread so the checkmark moves on
                // the current click. Unlike windows's HMENU which the
                // system re-paints on next hover, an NSMenu is built
                // once and stays static until `setMenu:` swaps it —
                // so explicit rebuild here is required for visible UX.
                //
                // `apply_menu_action_state` is a no-op (returns false)
                // when the agent is unchanged, so spamming the same
                // agent doesn't churn the menu.
                let changed = {
                    let mut state = match self.ivars().menu_state.lock() {
                        Ok(g) => g,
                        Err(_) => {
                            eprintln!("[tillandsias-tray] SelectAgent: menu_state poisoned");
                            return;
                        }
                    };
                    apply_menu_action_state(&mut state, &action)
                };
                if changed {
                    eprintln!("[tillandsias-tray] SelectAgent({agent:?}): updated + rebuilding");
                    let ivars = self.ivars();
                    let menu_state = ivars.menu_state.clone();
                    let status_item = ivars.status_item.clone();
                    let status_menu_item = ivars.status_menu_item.clone();
                    let self_handle = ivars.self_handle.clone();
                    dispatch_to_main_thread(move || {
                        rebuild_menu_main_thread(
                            &menu_state,
                            &status_item,
                            &status_menu_item,
                            &self_handle,
                        );
                    });
                } else {
                    eprintln!("[tillandsias-tray] SelectAgent({agent:?}): already selected");
                }
            }
            MenuAction::Attach { .. } | MenuAction::Maintain { .. } => {
                // m10: resolve (intent, project) via the shared
                // `intent_for_action` table — same canonical mapping
                // windows-tray uses (notify_icon.rs:1604
                // `launch_open_shell_terminal`). Attach maps to
                // `Agent(<selected_agent>)`; Maintain maps to `Shell`;
                // both carry the project name as `Some(p)` so
                // `launch_spec` wraps the command in `podman exec -it
                // tillandsias-<p>-forge …` against the in-VM forge.
                // `selected_agent` is read from the held
                // `MenuState.selected_agent` (the same slot the
                // SelectAgent arm will eventually mutate).
                let agent = self
                    .ivars()
                    .menu_state
                    .lock()
                    .map(|s| s.selected_agent)
                    .unwrap_or_else(|_| {
                        tillandsias_host_shell::menu_state::MenuState::initial().selected_agent
                    });
                if let Some((intent, project)) =
                    tillandsias_host_shell::pty::intent_for_action(&action, agent)
                {
                    let label: &'static str = match action {
                        MenuAction::Attach { .. } => "Attach",
                        MenuAction::Maintain { .. } => "Maintain",
                        _ => unreachable!(),
                    };
                    self.attach_pty(label, intent, project);
                } else {
                    eprintln!("[tillandsias-tray] {action:?}: no PTY intent (unexpected)");
                }
            }
            MenuAction::GithubLogin => {
                // Top-level GitHub login. Same gate as Attach —
                // needs the in-VM headless to be Ready. Defer to the
                // existing `attach_pty(GithubLogin)` path, which
                // already logs "no VM running" cleanly when the VM
                // isn't up yet. project=None: `gh auth login` is
                // user-level so it runs in the bare VM pre-attach.
                self.attach_pty(
                    "GitHub login",
                    tillandsias_host_shell::pty::PtyIntent::GithubLogin,
                    None,
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
                    // Surface the failure via a Notification Center
                    // banner so the user notices even without hovering
                    // the menubar icon (Action Center carries the most-
                    // recent banner across screen-locks too). Mirrors
                    // windows-tray's show_balloon (commit 8992652a
                    // item 1). Best-effort: a failed osascript shell-
                    // out is logged + ignored, the chip is the
                    // authoritative surface.
                    notify_provisioning_failed(e);
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

// (orphaned doc-block from an earlier refactor; the canonical
// docstring for `spawn_vm_status_poller` lives at the function
// itself further down. Converted from `///` to `//` so clippy's
// `empty_line_after_doc_comments` lint stays happy in the gap
// between the next two functions.)
//
// Spawn the 30s VmStatus poller. Mirrors windows-tray's
// `spawn_provisioning` Ready branch (commit c45f23ae): every 30s,
// call `poll_vm_status_once`, render the result through
// `vm_phase_status_text`, and patch the chip via a main-thread
// dispatch. A transient wire error leaves the last-known chip text
// untouched (matching the windows policy).
//
// @trace spec:vsock-transport,
//        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 5)

/// Apply the state-mutating effect of a menu action to the held
/// `MenuState`. Currently only `SelectAgent` mutates state (sets
/// `selected_agent`); returns `true` if `state` was actually changed
/// — `false` for an idempotent re-select of the same agent or for
/// any other action variant.
///
/// Mirrors windows-tray's `apply_menu_action_state` at
/// `notify_icon.rs:1674` byte-for-shape so the cross-tray state-
/// mutation contract is symmetric. Factored out of the dispatcher
/// so the rule is unit-testable without driving AppKit.
///
/// @trace spec:macos-native-tray.ui.menu-parity@v1
fn apply_menu_action_state(
    state: &mut tillandsias_host_shell::menu_state::MenuState,
    action: &tillandsias_host_shell::menu_action::MenuAction,
) -> bool {
    use tillandsias_host_shell::menu_action::MenuAction;
    match action {
        MenuAction::SelectAgent(agent) if state.selected_agent != *agent => {
            state.selected_agent = *agent;
            true
        }
        _ => false,
    }
}

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
            // Cloud + local projects: first tick + every 10 ticks.
            // The cadence rationale (slower than VmStatus) is in the
            // cloud-poll docstring — gh repo list / local fs scan are
            // both slow-changing relative to phase. Local goes first
            // because `~/src/` walks are virtually free vs `gh`.
            let mut rebuild_needed = false;
            if tick.is_multiple_of(10) {
                match poll_local_projects_once(&vz).await {
                    Ok(projects) => {
                        let new_count = projects.len();
                        let mut guard = menu_state.lock().unwrap();
                        if guard.local_projects != projects {
                            guard.local_projects = projects;
                            rebuild_needed = true;
                            eprintln!(
                                "[tillandsias-tray] local-projects: \
                                 menu_state updated ({} entries)",
                                new_count
                            );
                        }
                        drop(guard);
                    }
                    Err(e) => {
                        eprintln!("[tillandsias-tray] local-projects poll: {e}");
                    }
                }
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
                match poll_github_login_once(&vz).await {
                    Ok(login_state) => {
                        let mut guard = menu_state.lock().unwrap();
                        if guard.login != login_state {
                            guard.login = login_state;
                            rebuild_needed = true;
                            eprintln!(
                                "[tillandsias-tray] github-login: \
                                 menu_state updated"
                            );
                        }
                        drop(guard);
                    }
                    Err(e) => {
                        eprintln!("[tillandsias-tray] github-login poll: {e}");
                    }
                }
            }

            tokio::time::sleep(Duration::from_secs(30)).await;
            tick = tick.wrapping_add(1);

            match poll_vm_status_once(&vz).await {
                Ok((phase, podman_ready, last_event)) => {
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
                    let base = vm_phase_status_text(phase, podman_ready);
                    let text = compose_chip_text(&base, last_event.as_deref());
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
                    // Mid-session wire failure (headless crash, VM
                    // terminated externally, lost handshake). Without
                    // an explicit chip update the user would see the
                    // last-known Ready forever. Mirrors windows-tray
                    // `mark_wire_unreachable` (commit d2cf10f0):
                    //   1. clear podman_ready so per-project actions
                    //      correctly re-gate off after the rebuild
                    //   2. flip the chip to "🔴 Wire unreachable"
                    //      (byte-identical to windows)
                    //   3. trigger a rebuild so the menu re-renders
                    //      the now-gated state
                    // The next successful poll restores phase +
                    // podman naturally — bounded chip flicker only on
                    // actual error ticks, no flapping when the wire
                    // is steady-state ok or steady-state broken.
                    eprintln!("[tillandsias-tray] vm-status poll: {e}");
                    {
                        let mut guard = menu_state.lock().unwrap();
                        if guard.podman_ready {
                            guard.podman_ready = false;
                            rebuild_needed = true;
                        }
                    }
                    let text = WIRE_UNREACHABLE_CHIP_TEXT.to_string();
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

    /// `applescript_escape_single_quoted` defangs the AppleScript
    /// double-quoted-string metacharacters (`\` and `"`) and
    /// collapses newlines to spaces. Guards against
    /// `notify_provisioning_failed` accidentally crafting a script
    /// that breaks out of the literal.
    #[test]
    fn applescript_escape_handles_metas_and_newlines() {
        assert_eq!(applescript_escape_single_quoted("plain"), "plain");
        assert_eq!(
            applescript_escape_single_quoted("has \"quotes\""),
            "has \\\"quotes\\\""
        );
        assert_eq!(applescript_escape_single_quoted("has\\back"), "has\\\\back");
        // Newlines collapse to spaces.
        assert_eq!(applescript_escape_single_quoted("two\nlines"), "two lines");
        assert_eq!(
            applescript_escape_single_quoted("carriage\rreturn"),
            "carriage return"
        );
        // Combined: a realistic error string.
        assert_eq!(
            applescript_escape_single_quoted(
                "recipe-artifact fetch failed: \"rootfs.img\" missing"
            ),
            "recipe-artifact fetch failed: \\\"rootfs.img\\\" missing"
        );
    }

    /// `WIRE_UNREACHABLE_CHIP_TEXT` is the byte-identical chip
    /// string both macOS and windows trays emit on wire failure
    /// (slice 21 / windows commit d2cf10f0). Drift-protection
    /// litmus: if a future refactor changes the emoji or wording
    /// on either side, the cross-tray UX-parity invariant silently
    /// breaks — operators get different text on the same failure
    /// class. This test asserts the exact byte sequence so any
    /// such drift fails the build here AND in the windows-tray
    /// suite (which would need a corresponding test added when
    /// they adopt this pattern).
    #[test]
    fn wire_unreachable_chip_text_pinned() {
        // Exact bytes: U+1F534 (LARGE RED CIRCLE = 4 bytes UTF-8)
        // + ' ' (U+0020 = 1 byte) + "Wire unreachable" (16 bytes).
        // Total = 21 bytes. Pin both the byte length and the
        // expanded string literal so a partial typo (e.g. dropping
        // the space, or swapping the emoji codepoint) is caught.
        assert_eq!(
            WIRE_UNREACHABLE_CHIP_TEXT.as_bytes(),
            "\u{1F534} Wire unreachable".as_bytes()
        );
        assert_eq!(WIRE_UNREACHABLE_CHIP_TEXT.len(), 21);
        // Emoji codepoint is the LARGE RED CIRCLE specifically (not
        // BLACK CIRCLE FOR RECORD U+23FA or any other red glyph).
        // Windows tray's mark_wire_unreachable uses the exact same
        // codepoint — keep these in lockstep.
        let first_char = WIRE_UNREACHABLE_CHIP_TEXT.chars().next().unwrap();
        assert_eq!(first_char, '\u{1F534}');
    }

    /// `describe_wire_error` pins the operator-visible format of a
    /// dispatcher Error frame so both trays surface identical text.
    /// Mirrors the windows-tray test
    /// `describe_wire_error_includes_code_and_message` (commit
    /// eddb5c00) — divergence would fail either suite.
    #[test]
    fn describe_wire_error_includes_code_and_message() {
        use tillandsias_control_wire::ErrorCode;
        let s = describe_wire_error(ErrorCode::Unsupported, "variant X not wired on vsock");
        assert!(s.contains("Unsupported"), "code missing: {s}");
        assert!(
            s.contains("variant X not wired on vsock"),
            "message missing: {s}"
        );
    }

    /// An empty message must not leave a dangling colon (e.g.
    /// `"dispatcher error Internal: "`). Pins the empty-message
    /// branch so a future refactor doesn't accidentally append the
    /// colon unconditionally.
    #[test]
    fn describe_wire_error_no_trailing_colon_on_empty_message() {
        use tillandsias_control_wire::ErrorCode;
        let s = describe_wire_error(ErrorCode::Internal, "");
        assert!(s.contains("Internal"), "code missing: {s}");
        assert!(!s.ends_with(':'), "trailing colon: {s}");
        assert!(!s.contains(": "), "spurious colon-space: {s}");
    }

    /// `compose_chip_text` appends a non-empty `last_event` after a
    /// MIDDLE DOT so the live chip surfaces in-VM activity. Mirrors
    /// the windows-tray test `compose_chip_text_appends_last_event`
    /// (commit 8992652a) — divergence between the two trays' chip
    /// composition would fail either suite.
    #[test]
    fn compose_chip_text_appends_last_event() {
        let base = "\u{1F7E2} Ready";
        // None: base unchanged.
        assert_eq!(compose_chip_text(base, None), base);
        // Empty: base unchanged (whitespace trim ⇒ empty ⇒ None).
        assert_eq!(compose_chip_text(base, Some("")), base);
        assert_eq!(compose_chip_text(base, Some("   ")), base);
        // Non-empty: MIDDLE DOT + event appended.
        assert_eq!(
            compose_chip_text(base, Some("forge-foo created")),
            "\u{1F7E2} Ready \u{00B7} forge-foo created"
        );
        // Surrounding whitespace on event is trimmed.
        assert_eq!(
            compose_chip_text(base, Some("  forge-bar started  ")),
            "\u{1F7E2} Ready \u{00B7} forge-bar started"
        );
    }

    /// `local_entry_to_menu` translates a Linux-side
    /// `LocalProjectEntry` (commit `05cc3a7d` — label + guest_path +
    /// last_seen_unix) into the shared menu `ProjectEntry`
    /// (name + path + ready). Path is the in-VM guest_path because
    /// that's what "Attach Here" passes to the in-VM exec call.
    /// Ready defaults to false until a per-project status reply
    /// lands.
    #[test]
    fn local_entry_maps_label_to_name_and_guest_path() {
        let wire = tillandsias_control_wire::LocalProjectEntry {
            label: "tillandsias".to_string(),
            guest_path: "/host-mnt/src/tillandsias".to_string(),
            last_seen_unix: 1_700_000_000,
        };
        let menu = local_entry_to_menu(&wire);
        assert_eq!(menu.name, "tillandsias");
        assert_eq!(menu.path, "/host-mnt/src/tillandsias");
        assert!(!menu.ready, "local entry ready defaults to false");
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
    /// m11: `apply_menu_action_state` mutates `MenuState.selected_agent`
    /// when a `SelectAgent` click carries a different agent than the
    /// currently-held one; returns `false` (no-op) when the agent is
    /// unchanged or the action is not `SelectAgent`. Mirrors windows-
    /// tray's `apply_menu_action_state` behaviour at notify_icon.rs:1674.
    #[test]
    fn apply_menu_action_state_mutates_only_on_agent_change() {
        use tillandsias_host_shell::menu_action::MenuAction;
        use tillandsias_host_shell::menu_state::{MenuState, SelectedAgent};

        let mut state = MenuState::initial();
        let initial_agent = state.selected_agent;

        // Idempotent: re-selecting the current agent is a no-op.
        assert!(
            !apply_menu_action_state(&mut state, &MenuAction::SelectAgent(initial_agent)),
            "re-selecting current agent must not mutate state"
        );
        assert_eq!(state.selected_agent, initial_agent);

        // Different agent flips state + returns true.
        let other_agent = if initial_agent == SelectedAgent::OpenCode {
            SelectedAgent::Claude
        } else {
            SelectedAgent::OpenCode
        };
        assert!(
            apply_menu_action_state(&mut state, &MenuAction::SelectAgent(other_agent)),
            "switching agent must return true"
        );
        assert_eq!(state.selected_agent, other_agent);

        // Other actions don't touch agent state.
        assert!(
            !apply_menu_action_state(&mut state, &MenuAction::Quit),
            "Quit must not mutate menu state"
        );
        assert!(
            !apply_menu_action_state(&mut state, &MenuAction::GithubLogin),
            "GithubLogin must not mutate menu state"
        );
        assert_eq!(state.selected_agent, other_agent, "state unchanged");
    }

    /// m10: pin the dispatcher's `Attach`/`Maintain` arm contract — every
    /// click on a per-project menu row resolves via the shared
    /// `intent_for_action` table to a `(PtyIntent, Some(project))` tuple
    /// that `attach_pty` threads into `launch_spec`, producing a forge-
    /// container-wrapped argv (`podman exec -it tillandsias-<p>-forge …`)
    /// rather than a bare-VM shell. A future refactor of either
    /// `intent_for_action` or the dispatcher's resolve path that lost
    /// the project would silently dump users into the wrong shell.
    ///
    /// The host-shell crate already byte-pins `launch_spec`'s wrapping
    /// behaviour for `project=Some` (`launch_spec_wraps_in_forge_podman_
    /// exec_when_project_given` at pty/mod.rs:632). This macOS-side test
    /// pins the LINK: the macOS dispatcher invokes `intent_for_action`
    /// with the right arguments to produce a non-None project.
    #[test]
    fn attach_action_resolves_to_project_via_intent_for_action() {
        use tillandsias_host_shell::menu_action::{MenuAction, ProjectScope};
        use tillandsias_host_shell::menu_state::SelectedAgent;
        use tillandsias_host_shell::pty::{PtyIntent, intent_for_action};

        let action = MenuAction::Attach {
            scope: ProjectScope::Local,
            name: "myproj".to_string(),
        };
        let (intent, project) = intent_for_action(&action, SelectedAgent::OpenCode)
            .expect("Attach must yield Some((intent, project))");
        assert!(
            matches!(intent, PtyIntent::Agent(SelectedAgent::OpenCode)),
            "Attach must map to Agent(<selected_agent>), got: {intent:?}"
        );
        assert_eq!(
            project.as_deref(),
            Some("myproj"),
            "Attach must thread the project name into launch_spec"
        );

        let maintain = MenuAction::Maintain {
            scope: ProjectScope::Local,
            name: "myproj".to_string(),
        };
        let (m_intent, m_project) = intent_for_action(&maintain, SelectedAgent::OpenCode)
            .expect("Maintain must yield Some((intent, project))");
        assert!(
            matches!(m_intent, PtyIntent::Shell),
            "Maintain must map to Shell (forge-shell, not agent)"
        );
        assert_eq!(
            m_project.as_deref(),
            Some("myproj"),
            "Maintain must thread the project name into launch_spec"
        );

        // GithubLogin remains project-less (gh auth login is user-level
        // pre-attach — runs in the bare VM, not the forge container).
        let github = MenuAction::GithubLogin;
        let (g_intent, g_project) =
            intent_for_action(&github, SelectedAgent::OpenCode).expect("GithubLogin yields Some");
        assert!(matches!(g_intent, PtyIntent::GithubLogin));
        assert_eq!(g_project, None, "GithubLogin must NOT thread a project");
    }

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
