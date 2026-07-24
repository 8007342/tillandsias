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

use std::collections::HashSet;
use std::io;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::OnceLock;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject};
use objc2::{ClassType, DeclaredClass, declare_class, msg_send_id, mutability};
use objc2_app_kit::{NSMenuItem, NSStatusItem};
use objc2_foundation::MainThreadMarker;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use tillandsias_control_wire::guest_transport::{GuestEndpoint, GuestTransport};
use tillandsias_secure_channel::{EncryptedStream, HopId, channel_psk, client_handshake};
use tillandsias_vm_layer::VmRuntime;
use tillandsias_vm_layer::vz::VzRuntime;

use crate::guest_binary::stage_embedded_guest_binary;
use crate::main_thread::dispatch_to_main_thread;
use tillandsias_host_shell::menu_state::{BOOT_STATUS_TEXT, clamp_tray_status_chip};

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
        // Tooltip carries the build version + status so a hover confirms both
        // (parity with windows-tray `compose_tooltip`). The menu row shows the
        // bare chip; the tooltip prefixes "Tillandsias <version>".
        let tooltip = NSString::from_str(&format!(
            "Tillandsias {}\n{}",
            tillandsias_secure_channel::workspace_version(),
            text
        ));
        unsafe { button.setToolTip(Some(&tooltip)) };
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

/// Fire the guest crash-loop Notification Center banner — the single
/// most-important tray notification (order 250 ultra-minimal UX: "the
/// guest is crash-looping, reset it"). Mirrors windows-tray's
/// `show_balloon(..., BalloonSeverity::Error)` crash-loop toast in
/// title/body framing, delivered through the SAME osascript mechanism
/// as `notify_provisioning_failed` (a subprocess spawn — no AppKit, so
/// no main-thread dispatch needed; safe from any thread). Best-effort:
/// the chip carries the same verdict authoritatively.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
fn notify_crash_loop(reason: &str) {
    let escaped = applescript_escape_single_quoted(reason);
    let body = format!(
        "display notification \"{escaped}\" with title \"Tillandsias\" \
         subtitle \"Guest crash-loop\""
    );
    match std::process::Command::new("osascript")
        .arg("-e")
        .arg(&body)
        .spawn()
    {
        Ok(_child) => {}
        Err(err) => {
            eprintln!("[tillandsias-tray] crash-loop notification: osascript spawn failed: {err}");
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
    let text = match last_event.map(str::trim).filter(|s| !s.is_empty()) {
        Some(evt) => format!("{base} \u{00B7} {evt}"),
        None => base.to_string(),
    };
    clamp_tray_status_chip(text)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SecureControlWireMode {
    Off,
    On,
}

fn secure_control_wire_mode() -> Result<SecureControlWireMode, String> {
    static MODE: OnceLock<Result<SecureControlWireMode, String>> = OnceLock::new();
    MODE.get_or_init(|| match std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE") {
        Ok(raw) if raw.eq_ignore_ascii_case("on") => Ok(SecureControlWireMode::On),
        Ok(raw) if raw.eq_ignore_ascii_case("off") || raw.is_empty() => {
            Ok(SecureControlWireMode::Off)
        }
        Ok(raw) => Err(format!(
            "TILLANDSIAS_SECURE_CONTROL_WIRE must be 'on' or 'off' (got {raw:?})"
        )),
        Err(std::env::VarError::NotPresent) => Ok(SecureControlWireMode::Off),
        Err(err) => Err(format!("TILLANDSIAS_SECURE_CONTROL_WIRE: {err}")),
    })
    .clone()
}

type GuestWireStream = Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>;

enum ControlWireStream {
    Plain(GuestWireStream),
    Secure(Box<EncryptedStream<GuestWireStream>>),
}

impl AsyncRead for ControlWireStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_read(cx, out),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_read(cx, out),
        }
    }
}

impl AsyncWrite for ControlWireStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_write(cx, buf),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_flush(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

async fn open_control_wire_stream(
    vz: &VzRuntime,
    port: u32,
    timeout: Duration,
) -> Result<ControlWireStream, String> {
    let endpoint = GuestEndpoint::MacVz { port };
    let stream = tokio::time::timeout(timeout, vz.open_stream(&endpoint))
        .await
        .map_err(|_| format!("MacVz GuestTransport open timed out after {timeout:?}"))?
        .map_err(|e| format!("vsock connect: {e}"))?;

    match secure_control_wire_mode()? {
        SecureControlWireMode::Off => Ok(ControlWireStream::Plain(stream)),
        SecureControlWireMode::On => {
            let psk = channel_psk(
                tillandsias_secure_channel::workspace_version(),
                tillandsias_control_wire::WIRE_VERSION,
                HopId::HostGuest,
            );
            let secure = client_handshake(stream, &psk)
                .await
                .map_err(|e| format!("secure control wire handshake failed: {e}"))?;
            Ok(ControlWireStream::Secure(Box::new(secure)))
        }
    }
}

/// One-shot VmStatus poll over the in-VM control wire. Mirrors
/// `tillandsias-windows-tray::notify_icon::refresh_vm_status` but
/// drives the macOS-specific facade path:
///
///   1. `GuestTransport::open_stream(GuestEndpoint::MacVz { port })` to
///      get an `AsyncRead + AsyncWrite` stream into the guest's port 42420.
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
    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, connect_timeout).await?;

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
/// `GuestTransport` backend over `VZVirtioSocketConnection`.
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

    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, RTT_BUDGET).await?;

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
    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, connect_timeout).await?;

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
/// (commit b0cdcdee) but drives the macOS-specific `GuestTransport`
/// backend over VZ virtio-vsock. Reuses the standard
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
    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, connect_timeout).await?;

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
/// drives the macOS-specific `GuestTransport` backend over VZ virtio-vsock.
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
    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, connect_timeout).await?;

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
/// sequence (windows-260722-5 Tlatoāni-approved wording: U+1F7E0
/// LARGE ORANGE CIRCLE + " Reconnecting to your workspace…").
const WIRE_UNREACHABLE_CHIP_TEXT: &str = "\u{1F7E0} Reconnecting to your workspace\u{2026}";

/// Curated chip shown after the VM process starts, while the host waits for the
/// in-VM headless to answer on vsock (spec vm-provisioning-lifecycle
/// ux.condensed-status "Connecting…"). Distinct from
/// `WIRE_UNREACHABLE_CHIP_TEXT`, which is a *mid-session* loss after the guest
/// was already ready.
const CONNECTING_CHIP_TEXT: &str = "\u{1F535} Connecting\u{2026}";

/// How long `VzRuntime::stop` waits for an orderly drain before
/// escalating to a force-stop. Documented in
/// `cheatsheets/runtime/tray-state-machine.md` as 60s for the
/// production tray; the spike used 30s and hit the force-path on
/// Fedora's ACPI shutdown.
const VM_STOP_DRAIN: Duration = Duration::from_secs(60);

type ProjectLaunchSet = Arc<Mutex<HashSet<String>>>;

/// Per-project lease held while a project PTY launch is in flight.
/// Dropping it clears the slot so a retry can proceed after success or
/// failure.
struct ProjectLaunchLease {
    in_flight: ProjectLaunchSet,
    project: String,
}

impl Drop for ProjectLaunchLease {
    fn drop(&mut self) {
        if let Ok(mut in_flight) = self.in_flight.lock() {
            in_flight.remove(&self.project);
        }
    }
}

fn try_acquire_project_launch(
    in_flight: &ProjectLaunchSet,
    project: &str,
) -> Option<ProjectLaunchLease> {
    let mut guard = in_flight.lock().ok()?;
    if !guard.insert(project.to_string()) {
        return None;
    }
    Some(ProjectLaunchLease {
        in_flight: in_flight.clone(),
        project: project.to_string(),
    })
}

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
    /// Project names with an in-flight Attach/Maintain launch.
    /// Prevents a same-project double-click from spawning two competing
    /// guest launch flows.
    project_launches: ProjectLaunchSet,
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
        let project_launch_lease = match project.as_deref() {
            Some(project_name) => {
                match try_acquire_project_launch(&ivars.project_launches, project_name) {
                    Some(lease) => Some(lease),
                    None => {
                        eprintln!(
                            "[tillandsias-tray] {label}: project launch already in progress \
                             for {project_name:?}; ignoring duplicate click"
                        );
                        return;
                    }
                }
            }
            None => None,
        };
        eprintln!("[tillandsias-tray] {label}: spawning attach worker (project={project:?})");
        runtime.spawn(async move {
            let result = run_pty_attach(vz, intent, project).await;
            dispatch_to_main_thread(move || {
                let _project_launch_lease = project_launch_lease;
                match result {
                    Ok(slave_path) => {
                        eprintln!("[tillandsias-tray] {label}: PTY attached at {slave_path}");
                        if let Err(e) =
                            crate::terminal_attach::spawn_terminal_pty_attach(&slave_path)
                        {
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

    let stream =
        open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30)).await?;

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

    // Window-resize forwarding. The guest child starts at the 24x80 default
    // above; once Terminal.app + `screen` attach to the slave, the operator's
    // REAL terminal size (and every later resize) lands on the shared PTY
    // winsize. The tray is a GUI process with no controlling tty, so it never
    // receives SIGWINCH — read the master winsize locally and relay changes to
    // the guest so the child TUI repaints at the true size instead of clipping
    // at 24x80. This is a cheap LOCAL ioctl, not a guest round-trip: it only
    // touches the wire (one `PtyResize`) on an actual change. The detached
    // handles outlive the `pump_io` move below; the loop ends when the master
    // fd closes or the transport drops (session over).
    {
        let winsize_reader = master.winsize_reader();
        let resize_sender = session.resize_sender();
        tokio::spawn(async move {
            let mut last: (u16, u16) = (24, 80);
            loop {
                tokio::time::sleep(Duration::from_millis(400)).await;
                match winsize_reader.get() {
                    Ok(size) if size != last && size.0 > 0 && size.1 > 0 => {
                        last = size;
                        if resize_sender.resize(size.0, size.1).is_err() {
                            break; // transport gone → session ended
                        }
                    }
                    Ok(_) => {}
                    Err(_) => break, // master fd closed → session ended
                }
            }
        });
    }

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
    match stage_embedded_guest_binary() {
        Ok(Some(dest)) => {
            eprintln!(
                "[tillandsias-tray] staged embedded guest binary at {}",
                dest.display()
            );
        }
        Ok(None) => {
            eprintln!(
                "[tillandsias-tray] no embedded guest binary resource found; falling back to fetch"
            );
        }
        Err(err) => {
            return Err(format!("stage embedded guest binary: {err}"));
        }
    }
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

    // Host-visible boot phases (parity with windows-tray's StartingVm/
    // Connecting reports): the guest OS boot + first vsock-agent handshake is a
    // multi-second (longer when cold) window that was previously silent on the
    // chip. Emit the curated phases so the status keeps moving instead of
    // looking stalled.
    on_phase("Starting Fedora Linux");
    vz.start().await?;
    on_phase("Connecting");
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
            status_text: Arc::new(Mutex::new(BOOT_STATUS_TEXT.to_string())),
            project_launches: Arc::new(Mutex::new(HashSet::new())),
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
            MenuAction::OpenObservatorium
            | MenuAction::OpenOpenCodeWeb
            | MenuAction::ProjectObservatorium { .. }
            | MenuAction::ProjectOpenCodeWeb { .. } => {
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
                // windows-260719-2: flip the menu to the transitional
                // "Logging in…" state IMMEDIATELY — a purely local signal,
                // before any wire round-trip. An NSMenu is static until
                // rebuilt, so trigger the rebuild explicitly (we are on the
                // main thread here, same as the SelectAgent arm's rebuild).
                // The confirming probe (LoginStatePush / login poll) maps
                // only to LoggedIn/LoggedOut via map_login_state, so a
                // confirmed reply always clears this: success renders the
                // logged-in body, an invalid/missing token falls back to
                // the actionable GitHub Login leaf.
                let flipped = {
                    let mut state = self.ivars().menu_state.lock().unwrap();
                    if state.login
                        == tillandsias_host_shell::menu_state::GithubLoginState::LoggedOut
                    {
                        state.login =
                            tillandsias_host_shell::menu_state::GithubLoginState::LoggingIn;
                        true
                    } else {
                        false
                    }
                };
                if flipped {
                    // Anchor the login grace window (see apply_login_state) so the
                    // prompt confirm-poll doesn't revert this fresh LoggingIn to
                    // LoggedOut before the user finishes the interactive paste.
                    mark_login_started();
                    let ivars = self.ivars();
                    dispatch_rebuild(
                        &ivars.menu_state,
                        &ivars.status_item,
                        &ivars.status_menu_item,
                        &ivars.self_handle,
                    );
                }
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
            // NOTE: there is deliberately NO menu arm for the guest reset —
            // the `reset-guest` leaf was an UNAPPROVED UX surface, removed
            // by operator order 2026-07-22 (tray-ux "UX curation
            // governance"). The reset stays reachable via the `--reset-guest`
            // CLI verb (`diagnose::reset_guest_main`), never a menu click.
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
        let text = clamp_tray_status_chip(text.into());
        *ivars.status_text.lock().unwrap() = text.clone();
        // Keep MenuState's status row in sync so a menu rebuild during this
        // phase doesn't snap the chip back to a stale label (parity with
        // apply_vm_status, which already syncs it on the poll/push path).
        if let Ok(mut guard) = ivars.menu_state.lock() {
            guard.status_text = text.clone();
        }
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
        self.set_status_text(BOOT_STATUS_TEXT);

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
        let phase_menu_state = menu_state_slot.clone();
        let on_phase: Box<dyn Fn(&str) + Send + Sync> = Box::new(move |phase: &str| {
            let text = format!("\u{1F535} {phase}\u{2026}");
            let text_for_dispatch = text.clone();
            let status_text = phase_status_text.clone();
            let status_item = phase_status_item.clone();
            let status_menu_item = phase_status_menu_item.clone();
            // Sync MenuState so a mid-provision rebuild keeps this live phase
            // instead of snapping back to the initial boot label.
            if let Ok(mut guard) = phase_menu_state.lock() {
                guard.status_text = text.clone();
            }
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
                    // The VM process is up; we're now waiting for the in-VM
                    // headless to answer on vsock. Show "Connecting…" (not a
                    // static "Starting…") so the boot→ready window reads as
                    // active progress, not a stall. The poller/push flips this
                    // to the live VmPhase the moment the guest replies.
                    CONNECTING_CHIP_TEXT.to_string()
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
                    clamp_tray_status_chip(format!("\u{1F534} {e}"))
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

    /// Intentional EPHEMERAL RESET (windows-260717-4): stop the running VM
    /// (bounded drain), delete the provisioned boot artifacts via
    /// `VzRuntime::wipe_provisioned_artifacts` (rootfs.img — and with it the
    /// in-VM vault — plus vmlinuz/initramfs.img), clear the persisted
    /// crash-loop state (a fresh guest has a fresh history), then re-enter
    /// the exact same `boot_vm_async` path a first launch uses — which
    /// reprovisions from scratch because `is_provisioned()` is now false.
    /// Destructive BY DESIGN per the operator's ephemeral doctrine; the only
    /// cost is one re-authentication.
    ///
    /// Mirrors the `stopVm:` worker shape (busy gate, take-the-handle, tokio
    /// worker, main-thread completion dispatch); the completion re-borrows
    /// the action host through `self_handle` — the same seam the menu
    /// rebuild dispatch uses — to call `boot_vm_async` on the main thread.
    ///
    /// Known benign interplay: the status poller/push listener spawned by
    /// the previous boot hold their own `Arc<VzRuntime>` and keep polling
    /// the stopped VM until process exit (no cancellation in v1); their wire
    /// errors leave last-known state untouched, and the fresh boot spawns
    /// its own poller which owns the chip from then on.
    ///
    /// NOTE: no menu path reaches this worker any more — the `Reset Guest…`
    /// leaf was removed by operator order 2026-07-22 (tray-ux "UX curation
    /// governance"). Retained (dead-code-allowed) as the stop→wipe→reboot
    /// worker for future RUNTIME wiring (e.g. the cross-platform bounded
    /// auto-reset policy in control-wire); the manual affordance today is
    /// the `--reset-guest` CLI verb (`diagnose::reset_guest_main`).
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    #[allow(dead_code)]
    pub fn reset_guest_async(&self) {
        let ivars = self.ivars();

        // Re-entry gate (shared with startVm/stopVm).
        {
            let mut busy = ivars.vm_busy.lock().unwrap();
            if *busy {
                eprintln!("[tillandsias-tray] Reset guest: already in progress, ignoring");
                return;
            }
            *busy = true;
        }
        let vm_taken = ivars.vm.lock().unwrap().take();

        let runtime = ivars.runtime.clone();
        let vm_busy = ivars.vm_busy.clone();
        let image_root = ivars.image_root.clone();
        let self_handle = ivars.self_handle.clone();

        eprintln!(
            "[tillandsias-tray] Reset guest: discarding the local guest and its cached \
             credentials (everything lives in the cloud — you'll re-authenticate once)"
        );
        self.set_status_text("\u{267B}\u{FE0F} Resetting guest\u{2026}");

        runtime.spawn(async move {
            if let Some(vm) = vm_taken {
                if let Err(e) = vm.stop(VM_STOP_DRAIN).await {
                    eprintln!(
                        "[tillandsias-tray] Reset guest: stop failed ({e}); wiping anyway \
                         (a wedged guest is the reset use-case)"
                    );
                }
            }
            // File-only wipe; the CID is irrelevant here (path accessors only).
            let vz = VzRuntime::new(TILLANDSIAS_GUEST_CID, image_root);
            let wipe = vz.wipe_provisioned_artifacts();
            if wipe.is_ok() {
                // Fresh guest ⇒ fresh crash-loop history for --diagnose.
                let _ = std::fs::remove_file(crate::diagnose::crashloop_state_path());
            }
            dispatch_to_main_thread(move || {
                *vm_busy.lock().unwrap() = false;
                match wipe {
                    Ok(()) => {
                        let guard = self_handle.lock().unwrap();
                        if let Some(host) = guard.as_ref() {
                            eprintln!(
                                "[tillandsias-tray] Reset guest: wipe complete — \
                                 reprovisioning from scratch"
                            );
                            host.0.boot_vm_async("Reset guest");
                        } else {
                            eprintln!(
                                "[tillandsias-tray] Reset guest: self_handle not set; \
                                 wipe done but reboot must be triggered manually"
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("[tillandsias-tray] Reset guest: wipe failed: {e}");
                    }
                }
            });
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

// True while the dedicated push subscription (order 155 slices 1+2) is
// connected and delivering frames. Gates the steady-state fallback polls:
// while the push stream is healthy, `VmStatusRequest` is never sent (SC-07)
// and the 10-tick `GithubLoginStatusRequest`/`CloudRefreshRequest` polls are
// suppressed too (slice 2 — all three topics ride this one connection);
// when the stream drops, the tick loop resumes polling until the listener
// resubscribes. Grew out of windows-tray's `VM_STATUS_PUSH_HEALTHY`
// (b6ca3290, VmStatus-only) — windows adopts the widened gate in its own
// slice 2 so the two trays keep structurally identical stream architectures.
//
// Slice 3 (SC-16): the signal is a shared watch-backed
// [`tillandsias_host_shell::subscription_health::SubscriptionHealth`]
// (created in `spawn_vm_status_poller`, written by `run_push_listener`) —
// not an `AtomicBool` the tick loop re-reads after each sleep. The tick
// loop selects on the health transition, so a subscription drop triggers
// an immediate fallback poll round instead of surfacing up to 300s later
// on the 10-tick login/cloud cadence.

/// SC-07 gate: every steady-state request poll (VmStatus each tick,
/// LoginState/CloudProjects on the 10-tick cadence) is fallback-only —
/// suppressed whenever the push subscription is delivering.
fn should_poll_fallback(push_stream_healthy: bool) -> bool {
    !push_stream_healthy
}

// Tick-wait semantics (TickWake, wait_tick_or_subscription_drop,
// tick_after_wake) were hoisted into the shared
// tillandsias_host_shell::subscription_health module so the macOS (order
// 155) and windows (order 154) tick loops cannot drift. Use the shared
// copies directly; this crate keeps no local duplicate.
use tillandsias_host_shell::subscription_health::{
    TickWake, tick_after_wake, wait_tick_or_subscription_drop,
};

/// The exact topic set the dedicated push connection subscribes to. Slice 2
/// widened this from `[VmStatus]` to all three topics now that the tray
/// consumes the order 230/231 guest push sources; pinned by
/// `push_subscribe_topics_is_all_four_slice3`. Slice 3 (order 155) added
/// LocalProjects now that order 260 shipped its guest-side push source —
/// so the tick loop's last steady-state poll (local projects) can be
/// demoted to fallback-only like the others (SC-07), which is what lets
/// the timer become a pure fallback path (SC-01/02).
fn push_subscribe_topics() -> Vec<tillandsias_control_wire::SubscriptionTopic> {
    vec![
        tillandsias_control_wire::SubscriptionTopic::VmStatus,
        tillandsias_control_wire::SubscriptionTopic::LoginState,
        tillandsias_control_wire::SubscriptionTopic::CloudProjects,
        tillandsias_control_wire::SubscriptionTopic::LocalProjects,
    ]
}

/// Map a `GithubLoginStatusReply`/`LoginStatePush` payload to the menu's
/// login state. Shared by the fallback poll and the push listener (order 155
/// slice 2) so both surfaces stay byte-identical.
fn map_login_state(
    logged_in: bool,
    handle: Option<String>,
) -> tillandsias_host_shell::menu_state::GithubLoginState {
    if logged_in {
        tillandsias_host_shell::menu_state::GithubLoginState::LoggedIn {
            handle: handle.unwrap_or_default(),
        }
    } else {
        tillandsias_host_shell::menu_state::GithubLoginState::LoggedOut
    }
}

/// Unix-epoch milliseconds of the most recent GitHub-login click that flipped
/// the chip to the transitional `LoggingIn` state (0 = no login in flight).
/// Anchors the grace window in [`apply_login_state`] so the prompt login-confirm
/// poll doesn't downgrade a fresh `LoggingIn` to `LoggedOut` while the user is
/// still completing the interactive `gh auth login` paste. macOS analog of the
/// windows-tray login fast-poll guard (wave-review 2026-07-22 finding #2).
static LOGIN_STARTED_AT_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How long after a login click a `LoggedOut` observation is treated as "the
/// user hasn't finished the interactive paste yet" and ignored. `LoggedIn` is
/// always applied immediately, so a real login still resolves in ~1-2s.
///
/// Kept modest (covers the name+email+PAT prompt sequence) but bounded: if the
/// login FAILS to persist a token, this window would otherwise mask the failure
/// as "Logging In". The authoritative failure surface is the login terminal
/// itself (it now stays open ~10s with the error — see pty/mod.rs), so the chip
/// only needs to hold long enough to avoid mid-interaction flicker, then fall
/// back to the actionable "GitHub Login" leaf. (A tighter fix — ending the grace
/// exactly when the login PTY session closes — is a follow-up.)
const LOGIN_GRACE: Duration = Duration::from_secs(60);

/// Record that a GitHub-login flow just started (chip flipped to `LoggingIn`).
fn mark_login_started() {
    LOGIN_STARTED_AT_MS.store(now_unix_ms(), std::sync::atomic::Ordering::SeqCst);
}

fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Apply a live login-state observation — from a poll reply or an
/// unrequested `LoginStatePush` frame — to the shared `MenuState`. Returns
/// whether the menu needs a rebuild (state changed); idempotent on repeat.
///
/// Grace window (login-stuck fix 2026-07-23): while a login click is fresh, a
/// `LoggedOut` observation means "the interactive paste isn't done yet", not
/// "logged out" — ignore it so the ~2s prompt-confirm poll can't flip the
/// transitional `LoggingIn` chip back to `LoggedOut` mid-flow. `LoggedIn` is
/// always applied immediately; `LoggedOut` applies once the grace window ends.
fn apply_login_state(
    login: tillandsias_host_shell::menu_state::GithubLoginState,
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
) -> bool {
    use tillandsias_host_shell::menu_state::GithubLoginState;
    let mut guard = menu_state.lock().unwrap();
    if matches!(login, GithubLoginState::LoggedOut) && guard.login == GithubLoginState::LoggingIn {
        let started = LOGIN_STARTED_AT_MS.load(std::sync::atomic::Ordering::SeqCst);
        if started != 0 && now_unix_ms().saturating_sub(started) < LOGIN_GRACE.as_millis() as u64 {
            // Still within the grace window — keep showing LoggingIn.
            return false;
        }
    }
    if guard.login == login {
        return false;
    }
    guard.login = login;
    drop(guard);
    // Login resolved (or otherwise changed) — clear the grace anchor so later
    // observations apply immediately.
    LOGIN_STARTED_AT_MS.store(0, std::sync::atomic::Ordering::SeqCst);
    eprintln!("[tillandsias-tray] github-login: menu_state updated");
    true
}

/// Apply a live cloud-projects observation — from a poll reply or an
/// unrequested `CloudProjectsPush` frame (full replacement list) — to the
/// shared `MenuState`. Returns whether the menu needs a rebuild; idempotent
/// on repeat.
fn apply_cloud_projects(
    projects: Vec<tillandsias_host_shell::menu_state::ProjectEntry>,
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
) -> bool {
    let new_count = projects.len();
    let mut guard = menu_state.lock().unwrap();
    if guard.cloud_projects == projects {
        return false;
    }
    guard.cloud_projects = projects;
    drop(guard);
    eprintln!("[tillandsias-tray] cloud-projects: menu_state updated ({new_count} entries)");
    true
}

/// Apply a live local-projects observation — from a poll reply or an
/// unrequested `LocalProjectsPush` frame (full replacement list) — to the
/// shared `MenuState`. Returns whether the menu needs a rebuild; idempotent
/// on repeat. Slice 3 (order 155): shared by the push listener and the
/// fallback tick poll so both surfaces stay byte-identical, mirroring
/// `apply_cloud_projects`.
fn apply_local_projects(
    projects: Vec<tillandsias_host_shell::menu_state::ProjectEntry>,
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
) -> bool {
    let new_count = projects.len();
    let mut guard = menu_state.lock().unwrap();
    if guard.local_projects == projects {
        return false;
    }
    guard.local_projects = projects;
    drop(guard);
    eprintln!("[tillandsias-tray] local-projects: menu_state updated ({new_count} entries)");
    true
}

/// Process-global live crash-loop detector, seeded once from the persisted
/// state file (`crate::diagnose::crashloop_state_path()`) so a loop that
/// tripped before the tray last restarted is still in view. std `Mutex` —
/// observations are infrequent (per-phase-change, not per-frame). Mirrors
/// windows-tray's `CRASH_LOOP_DETECTOR` (notify_icon.rs) byte-for-byte in
/// spirit; the detector itself lives in control-wire so the two hosts
/// cannot drift.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
static CRASH_LOOP_DETECTOR: std::sync::LazyLock<
    Mutex<tillandsias_control_wire::crashloop::CrashLoopDetector>,
> = std::sync::LazyLock::new(|| {
    Mutex::new(
        tillandsias_control_wire::crashloop::CrashLoopDetector::load(
            &crate::diagnose::crashloop_state_path(),
        ),
    )
});

/// Edge-trigger guard so the crash-loop banner (the single most-important
/// tray notification) fires once per trip, not on every subsequent push
/// while the loop persists. Re-armed when the verdict clears. Mirrors
/// windows-tray's `CRASH_LOOP_NOTIFIED`.
static CRASH_LOOP_NOTIFIED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Feed one live VM-status observation into the crash-loop detector, persist
/// the updated state so a separate `--diagnose` process (static /
/// filesystem-only on macOS) reads the SAME verdict the live tray just
/// computed, and — on a NEW trip — surface the crash-loop as the single
/// most-important notification: a Notification Center banner plus a chip
/// overwrite with the pinned-grammar verdict (`🔴 crash-loop:<subsystem>`,
/// matching windows' framing). Called LAST inside [`apply_vm_status`] so the
/// verdict overwrites the ordinary phase chip, same as windows'
/// chip-overwrite-last ordering. The terminal verdict clearing re-arms the
/// edge trigger so a later recurrence toasts again.
///
/// This is the WRITE side that closes the wave-1 gap: `--diagnose` already
/// knew how to READ `crashloop.state`, but the live tray never wrote it.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
fn note_crashloop_observation(
    phase: tillandsias_control_wire::VmPhase,
    last_event: Option<&str>,
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    status_text: &Arc<Mutex<String>>,
    status_item: &Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: &Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
) {
    use std::sync::atomic::Ordering::SeqCst;
    let verdict = {
        let Ok(mut det) = CRASH_LOOP_DETECTOR.lock() else {
            return;
        };
        let v = det.observe_phase(phase, last_event, unix_now_secs());
        if let Err(e) = det.save(&crate::diagnose::crashloop_state_path()) {
            eprintln!("[tillandsias-tray] could not persist crash-loop state: {e}");
        }
        v
    };
    if verdict.is_crash_loop() {
        // A crash-loop is THE single most-important state: overwrite the
        // chip (and MenuState's status row, so a menu rebuild does not
        // resurrect the ordinary phase text — same clobber class
        // apply_vm_status fixes for the healthy path).
        let chip = clamp_tray_status_chip(format!("\u{1F534} {}", verdict.verdict()));
        {
            let mut guard = menu_state.lock().unwrap();
            if guard.status_text != chip {
                guard.status_text = chip.clone();
            }
        }
        let chip_for_dispatch = chip.clone();
        let chip_status_text = status_text.clone();
        let chip_status_item = status_item.clone();
        let chip_status_menu_item = status_menu_item.clone();
        dispatch_to_main_thread(move || {
            *chip_status_text.lock().unwrap() = chip_for_dispatch.clone();
            apply_status_text_main_thread(
                &chip_for_dispatch,
                &chip_status_item,
                &chip_status_menu_item,
            );
        });
        if !CRASH_LOOP_NOTIFIED.swap(true, SeqCst) {
            eprintln!(
                "[tillandsias-tray] guest crash-loop detected: {}",
                verdict.verdict()
            );
            // osascript subprocess — no AppKit, so no main-thread dispatch
            // needed (same as notify_provisioning_failed).
            notify_crash_loop(&format!(
                "The guest is crash-looping ({}) — it is not converging. \
                 Reset the guest to recover; everything lives in the cloud, \
                 you'll re-authenticate once.",
                verdict.verdict()
            ));
        }
    } else {
        CRASH_LOOP_NOTIFIED.store(false, SeqCst);
    }
}

/// Apply a live `VmStatus` observation — from a poll reply or an unrequested
/// `VmStatusPush` frame — to the shared `MenuState` and status chip. Returns
/// whether the menu needs a rebuild (podman_ready / login gating changed).
/// Shared by the 30s fallback poll and `run_push_listener` (order 155
/// slice 1) so both surfaces stay byte-identical; mirrors windows-tray's
/// `apply_vm_status` (b6ca3290).
///
/// `last_logged_phase` is shared across both sources so a phase transition is
/// logged exactly once regardless of which surface observed it first (m8 F2:
/// a Failed VM must never be silent in the log).
#[allow(clippy::too_many_arguments)]
fn apply_vm_status(
    phase: tillandsias_control_wire::VmPhase,
    podman_ready: bool,
    last_event: Option<&str>,
    last_logged_phase: &Arc<Mutex<Option<tillandsias_control_wire::VmPhase>>>,
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    status_text: &Arc<Mutex<String>>,
    status_item: &Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: &Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
) -> bool {
    {
        let mut logged = last_logged_phase.lock().unwrap();
        if *logged != Some(phase) {
            *logged = Some(phase);
            eprintln!(
                "[tillandsias-tray] vm-status: phase={phase:?} podman_ready={podman_ready}{}",
                last_event
                    .map(|e| format!(" event={e}"))
                    .unwrap_or_default()
            );
        }
    }
    let base = vm_phase_status_text(phase, podman_ready);
    let text_for_dispatch = compose_chip_text(&base, last_event);
    let mut rebuild_needed = false;
    {
        let mut guard = menu_state.lock().unwrap();
        let new_login_runtime_ready =
            matches!(phase, tillandsias_control_wire::VmPhase::Ready) && podman_ready;
        if guard.podman_ready != podman_ready
            || guard.login_runtime_ready != new_login_runtime_ready
        {
            guard.podman_ready = podman_ready;
            guard.login_runtime_ready = new_login_runtime_ready;
            rebuild_needed = true;
        }
        // The status row is re-rendered from MenuState on every rebuild
        // (render() reads state.status_text). Without this write the state
        // keeps its BOOT_STATUS_TEXT default, so the rebuild triggered by
        // the very transition we're applying (e.g. -> Ready) clobbers the
        // chip back to "Booting…" right after the direct setTitle below —
        // the 2026-07-10 attended smoke caught the menu stuck there while
        // stderr showed phase=Ready (m8 F2 class: status must never lie).
        if guard.status_text != text_for_dispatch {
            guard.status_text = text_for_dispatch.clone();
        }
    }
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
    // Feed the same observation into the crash-loop detector LAST: on a trip
    // it overwrites the chip set above with the crash-loop verdict (the
    // single most-important surface) and persists state for `--diagnose`.
    // Mirrors windows-tray's chip-overwrite-last ordering in apply_vm_status.
    note_crashloop_observation(
        phase,
        last_event,
        menu_state,
        status_text,
        status_item,
        status_menu_item,
    );
    rebuild_needed
}

/// Dedicated push listener (order 155 slices 1+2): a persistent reader task
/// on its own control-wire connection. Connect → handshake →
/// `Subscribe{[VmStatus, LoginState, CloudProjects]}` → `SubscribeAck` →
/// loop `next_envelope`, applying each push frame to the chip/menu within
/// milliseconds of the guest-side change (SC-09, <500ms end-to-end) instead
/// of up to 30s (VmStatus) or 300s (login/cloud) later on a poll tick.
///
/// A separate connection (not the per-poll one-shots) is deliberate: the
/// request/reply helpers would mis-consume an unsolicited push frame arriving
/// between a request and its reply. The headless broadcasts pushes to every
/// subscribed client, so a dedicated connection gets the stream without
/// racing the request path. Started as a mirror of windows-tray
/// `run_vm_status_push_listener` (b6ca3290) on the macOS `GuestTransport`/VZ
/// stream + secure-wire path; slice 2 widened it to all three topics
/// (windows follows in its own slice 2).
///
/// Reconnects forever with the shared `BACKOFF_SCHEDULE` (250ms→4s), then
/// holds at 30s between attempts — while down, the shared
/// [`SubscriptionHealth`](tillandsias_host_shell::subscription_health::SubscriptionHealth)
/// signal is false and the tick loop's fallback polls cover freshness.
#[allow(clippy::too_many_arguments)]
async fn run_push_listener(
    vz: Arc<VzRuntime>,
    status_text: Arc<Mutex<String>>,
    status_item: Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
    menu_state: Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    self_handle: Arc<Mutex<Option<appkit_handle::TrayActionHostHandle>>>,
    last_logged_phase: Arc<Mutex<Option<tillandsias_control_wire::VmPhase>>>,
    vm_ever_ready: Arc<std::sync::atomic::AtomicBool>,
    health: Arc<tillandsias_host_shell::subscription_health::SubscriptionHealth>,
) {
    use std::sync::atomic::Ordering;
    use tillandsias_control_wire::transport::{CONTROL_WIRE_VSOCK_PORT, Transport};
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
    use tillandsias_host_shell::vsock_client::{BACKOFF_SCHEDULE, Client};

    let mut backoff_idx: usize = 0;
    loop {
        health.set(false);
        let established = async {
            let stream =
                open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(5))
                    .await?;
            let mut client = Client::from_stream(
                Box::new(stream),
                Transport::Vsock {
                    cid: TILLANDSIAS_GUEST_CID,
                    port: CONTROL_WIRE_VSOCK_PORT,
                },
            );
            let (_, guest_version) = client
                .handshake()
                .await
                .map_err(|e| format!("handshake: {e}"))?;
            if let Some(ref gv) = guest_version {
                if gv != tillandsias_secure_channel::workspace_version() {
                    tracing::warn!(
                        "build version skew: tray={} guest={}",
                        tillandsias_secure_channel::workspace_version(),
                        gv
                    );
                }
            }
            if let Ok(mut guard) = menu_state.lock() {
                guard.guest_version = guest_version;
            }
            let sub = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: client.allocate_seq(),
                body: ControlMessage::Subscribe {
                    topics: push_subscribe_topics(),
                },
            };
            let reply = client
                .request(&sub)
                .await
                .map_err(|e| format!("subscribe: {e}"))?;
            match reply.body {
                ControlMessage::SubscribeAck => Ok(client),
                other => Err(format!("expected SubscribeAck, got {}", other.kind())),
            }
        }
        .await;

        let mut client = match established {
            Ok(c) => c,
            Err(err) => {
                // Routine while the VM boots — the fallback poll owns
                // loud logging for a genuinely stuck wire (m8 F2).
                tracing::debug!(%err, "vm-status push subscription unavailable; will retry");
                let wait = BACKOFF_SCHEDULE
                    .get(backoff_idx)
                    .copied()
                    .unwrap_or(Duration::from_secs(30));
                backoff_idx = backoff_idx.saturating_add(1);
                tokio::time::sleep(wait).await;
                continue;
            }
        };

        backoff_idx = 0;
        health.set(true);
        eprintln!(
            "[tillandsias-tray] push subscription established \
             (vm-status/login/cloud/local polls demoted to fallback, SC-07)"
        );

        // Initial sync on the SAME connection: pushes are change-gated
        // (the guest sources emit only on transitions), so a subscriber
        // joining a steady-state VM would otherwise render nothing until
        // the next transition — while SC-07 suppresses the fallback polls
        // precisely because this stream is healthy. One request per topic
        // primes the state; the reader loop below accepts the replies
        // alongside pushes, so an interleaved push can never be
        // mis-consumed as a reply. A failed login/cloud prime is tolerated
        // (e.g. Error frame while logged out — the reader loop debug-logs
        // it); only a dead wire on send forces a reconnect.
        let seq = client.allocate_seq();
        let prime = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: client.allocate_seq(),
            body: ControlMessage::VmStatusRequest { seq },
        };
        if let Err(err) = client.send_envelope(&prime).await {
            tracing::debug!(%err, "vm-status initial-sync request failed; reconnecting");
            continue;
        }
        let seq = client.allocate_seq();
        let prime_login = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: client.allocate_seq(),
            body: ControlMessage::GithubLoginStatusRequest { seq },
        };
        if let Err(err) = client.send_envelope(&prime_login).await {
            tracing::debug!(%err, "login initial-sync request failed; reconnecting");
            continue;
        }
        let seq = client.allocate_seq();
        let prime_cloud = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: client.allocate_seq(),
            body: ControlMessage::CloudRefreshRequest { seq },
        };
        if let Err(err) = client.send_envelope(&prime_cloud).await {
            tracing::debug!(%err, "cloud-projects initial-sync request failed; reconnecting");
            continue;
        }
        // Slice 3 (order 155): prime local projects too — its push is
        // change-gated like the others, so a subscriber joining a
        // steady-state VM needs one EnumerateLocalProjects to render the
        // current list. Reply routes through the LocalProjectsReply arm.
        let seq = client.allocate_seq();
        let prime_local = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: client.allocate_seq(),
            body: ControlMessage::EnumerateLocalProjects { seq },
        };
        if let Err(err) = client.send_envelope(&prime_local).await {
            tracing::debug!(%err, "local-projects initial-sync request failed; reconnecting");
            continue;
        }

        loop {
            match client.next_envelope().await {
                Ok(env) => match env.body {
                    ControlMessage::VmStatusPush {
                        phase,
                        podman_ready,
                        last_event,
                        ..
                    }
                    | ControlMessage::VmStatusReply {
                        phase,
                        podman_ready,
                        last_event,
                        ..
                    } => {
                        vm_ever_ready.store(true, Ordering::SeqCst);
                        let rebuild_needed = apply_vm_status(
                            phase,
                            podman_ready,
                            last_event.as_deref(),
                            &last_logged_phase,
                            &menu_state,
                            &status_text,
                            &status_item,
                            &status_menu_item,
                        );
                        if rebuild_needed {
                            dispatch_rebuild(
                                &menu_state,
                                &status_item,
                                &status_menu_item,
                                &self_handle,
                            );
                        }
                    }
                    ControlMessage::LoginStatePush {
                        logged_in, handle, ..
                    }
                    | ControlMessage::GithubLoginStatusReply {
                        logged_in, handle, ..
                    } => {
                        let changed =
                            apply_login_state(map_login_state(logged_in, handle), &menu_state);
                        if changed {
                            dispatch_rebuild(
                                &menu_state,
                                &status_item,
                                &status_menu_item,
                                &self_handle,
                            );
                        }
                        // Login-transition burst (2026-07-10 attended smoke):
                        // the cloud list is auth-derived, but its ONLY push
                        // source is the CloudRefreshRequest handler and SC-07
                        // suppresses the tray's fallback poll while this
                        // stream is healthy — without this prime a fresh
                        // login renders "no repos" until the subscription
                        // reconnects. One request on this same connection;
                        // the reply routes through the CloudProjectsPush/
                        // CloudRefreshReply arm below. Mirrors the windows
                        // fast-poll-burst intent (order 154) push-natively.
                        // windows-260719-2: `changed` covers BOTH the
                        // LoggedOut→LoggedIn and the local
                        // LoggingIn→LoggedIn transitions (apply_login_state
                        // compares against whatever the menu currently
                        // holds), so cloud projects refresh promptly on the
                        // confirmed flip either way.
                        if changed && logged_in {
                            let seq = client.allocate_seq();
                            let prime_cloud = ControlEnvelope {
                                wire_version: WIRE_VERSION,
                                seq: client.allocate_seq(),
                                body: ControlMessage::CloudRefreshRequest { seq },
                            };
                            if let Err(err) = client.send_envelope(&prime_cloud).await {
                                tracing::debug!(
                                    %err,
                                    "post-login cloud prime failed; reconnecting"
                                );
                                break;
                            }
                        }
                    }
                    ControlMessage::CloudProjectsPush { projects, .. }
                    | ControlMessage::CloudRefreshReply { projects, .. } => {
                        let mapped = projects.iter().map(cloud_entry_to_menu).collect();
                        if apply_cloud_projects(mapped, &menu_state) {
                            dispatch_rebuild(
                                &menu_state,
                                &status_item,
                                &status_menu_item,
                                &self_handle,
                            );
                        }
                    }
                    ControlMessage::LocalProjectsPush { entries, .. }
                    | ControlMessage::LocalProjectsReply { entries, .. } => {
                        // Slice 3 (order 155): LocalProjects now has a push
                        // source (order 260), so the tick loop's last
                        // steady-state poll rides the stream too. Same
                        // shared applier as the fallback poll.
                        let mapped = entries.iter().map(local_entry_to_menu).collect();
                        if apply_local_projects(mapped, &menu_state) {
                            dispatch_rebuild(
                                &menu_state,
                                &status_item,
                                &status_menu_item,
                                &self_handle,
                            );
                        }
                    }
                    other => {
                        tracing::debug!("push stream: ignoring frame {}", other.kind());
                    }
                },
                Err(err) => {
                    tracing::debug!(%err, "vm-status push stream dropped; resubscribing");
                    break;
                }
            }
        }
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
    // Shared across the push listener and the fallback poll so phase
    // transitions log exactly once and early poll-noise suppression
    // works no matter which surface saw the VM first.
    let last_logged_phase: Arc<Mutex<Option<tillandsias_control_wire::VmPhase>>> =
        Arc::new(Mutex::new(None));
    let vm_ever_ready = Arc::new(std::sync::atomic::AtomicBool::new(false));

    // Push-first (order 155 slices 1+2): the dedicated reader task applies
    // VmStatusPush/LoginStatePush/CloudProjectsPush frames as they arrive;
    // the tick loop below polls only while that subscription is down (SC-07).
    // Slice 3 (SC-16): subscription health is a shared watch signal — the
    // listener writes it, the tick loop both reads it at poll decision
    // points and selects on its transitions while waiting.
    let health = Arc::new(tillandsias_host_shell::subscription_health::SubscriptionHealth::new());
    let mut health_rx = health.subscribe();
    tokio::spawn(run_push_listener(
        vz.clone(),
        status_text.clone(),
        status_item.clone(),
        status_menu_item.clone(),
        menu_state.clone(),
        self_handle.clone(),
        last_logged_phase.clone(),
        vm_ever_ready.clone(),
        health.clone(),
    ));
    tokio::spawn(async move {
        // Tick counter for the cloud-projects cadence. Matches windows-
        // tray's "first tick + every 10 ticks" pattern (commit
        // b0cdcdee) — first poll happens before the initial 30 s sleep,
        // subsequent polls every ~5 min (10 * 30 s = 300 s). gh repo
        // list is a slower-changing input than VmStatus so we don't
        // need every-tick granularity.
        let mut tick: u32 = 0;
        // Cold-boot warmup gate: the host marks the VM "running" the instant the
        // VZ process spawns, but the in-guest vsock agent only binds once the
        // guest OS finishes booting (~10s+ later). The projects/github pollers
        // fire at tick 0 and predictably hit "Connection reset by peer" until
        // then. Those errors are benign (each poller leaves last-known state
        // untouched) but printed loudly on every boot. Suppress the *projects/
        // github* connect errors until the VM has reported ready at least once;
        // the vm-status poll below keeps logging its own errors, so a genuinely
        // stuck boot still surfaces. See plan: macos-tray/cold-boot-vsock-poll-races.
        // (Shared with the push listener — a healthy push subscription also
        // proves the VM came up, and the poll may be suppressed by SC-07.)
        loop {
            // Cloud + local projects: first tick + every 10 ticks.
            // The cadence rationale (slower than VmStatus) is in the
            // cloud-poll docstring — gh repo list / local fs scan are
            // both slow-changing relative to phase. Local goes first
            // because `~/src/` walks are virtually free vs `gh`.
            let mut rebuild_needed = false;
            if tick.is_multiple_of(10) {
                // SC-07 (slice 3): local projects are now push-backed too
                // (order 260 shipped LocalProjectsPush), so ALL three
                // slow-cadence polls — local, cloud, login — are
                // fallback-only. While the push subscription is delivering,
                // the reader task owns every topic and this whole block is
                // skipped; the tick loop is a pure fallback path (SC-01/02).
                if should_poll_fallback(health.is_healthy()) {
                    match poll_local_projects_once(&vz).await {
                        Ok(projects) => {
                            if apply_local_projects(projects, &menu_state) {
                                rebuild_needed = true;
                            }
                        }
                        Err(e) => {
                            if vm_ever_ready.load(std::sync::atomic::Ordering::SeqCst) {
                                eprintln!("[tillandsias-tray] local-projects poll: {e}");
                            }
                        }
                    }
                    match poll_cloud_projects_once(&vz).await {
                        Ok(projects) => {
                            if apply_cloud_projects(projects, &menu_state) {
                                rebuild_needed = true;
                            }
                        }
                        Err(e) => {
                            if vm_ever_ready.load(std::sync::atomic::Ordering::SeqCst) {
                                eprintln!("[tillandsias-tray] cloud-projects poll: {e}");
                            }
                        }
                    }
                    match poll_github_login_once(&vz).await {
                        Ok(login_state) => {
                            if apply_login_state(login_state, &menu_state) {
                                rebuild_needed = true;
                            }
                        }
                        Err(e) => {
                            if vm_ever_ready.load(std::sync::atomic::Ordering::SeqCst) {
                                eprintln!("[tillandsias-tray] github-login poll: {e}");
                            }
                        }
                    }
                }
            }

            // SC-16: not a plain sleep — a healthy→down transition of the
            // push subscription ends the wait immediately and rewinds to
            // tick 0, so the full fallback round (local + cloud + login
            // above, VmStatus below) runs now instead of up to 300s later.
            let wake =
                wait_tick_or_subscription_drop(Duration::from_secs(30), &mut health_rx).await;
            tick = tick_after_wake(tick, &wake);

            // SC-07: while the push subscription is delivering, the poll is
            // suppressed entirely — the reader task owns status freshness.
            if !should_poll_fallback(health.is_healthy()) {
                if rebuild_needed {
                    dispatch_rebuild(&menu_state, &status_item, &status_menu_item, &self_handle);
                }
                continue;
            }

            match poll_vm_status_once(&vz).await {
                Ok((phase, podman_ready, last_event)) => {
                    // A successful VmStatus reply means the in-guest vsock agent
                    // is up; from here on the projects/github poll errors are
                    // real (mid-session) and worth logging — end cold-boot
                    // warmup suppression.
                    vm_ever_ready.store(true, std::sync::atomic::Ordering::SeqCst);
                    if apply_vm_status(
                        phase,
                        podman_ready,
                        last_event.as_deref(),
                        &last_logged_phase,
                        &menu_state,
                        &status_text,
                        &status_item,
                        &status_menu_item,
                    ) {
                        rebuild_needed = true;
                    }
                }
                Err(e) => {
                    // Mid-session wire failure (headless crash, VM
                    // terminated externally, lost handshake). Without
                    // an explicit chip update the user would see the
                    // last-known Ready forever. Mirrors windows-tray
                    // `mark_wire_unreachable` (commit d2cf10f0):
                    //   1. clear podman_ready so per-project actions
                    //      correctly re-gate off after the rebuild
                    //   2. flip the chip to the curated reconnecting
                    //      state (byte-identical to windows)
                    //   3. trigger a rebuild so the menu re-renders
                    //      the now-gated state
                    // The next successful poll restores phase +
                    // podman naturally — bounded chip flicker only on
                    // actual error ticks, no flapping when the wire
                    // is steady-state ok or steady-state broken.
                    eprintln!("[tillandsias-tray] vm-status poll: {e}");
                    // First-boot poll errors mean the guest vsock agent hasn't
                    // bound yet — that is "still Connecting…", NOT a lost
                    // connection. Only show the reconnecting chip once the guest
                    // has answered at least once (vm_ever_ready); before that,
                    // leave the curated Starting/Connecting chip in place so a
                    // slow first boot never looks unhealthy.
                    if vm_ever_ready.load(std::sync::atomic::Ordering::SeqCst) {
                        {
                            let mut guard = menu_state.lock().unwrap();
                            if guard.podman_ready || guard.login_runtime_ready {
                                guard.podman_ready = false;
                                guard.login_runtime_ready = false;
                                rebuild_needed = true;
                            }
                            // Keep MenuState's status row in sync so the rebuild
                            // below doesn't resurrect a stale label (same clobber
                            // class apply_vm_status fixes for the healthy path).
                            if guard.status_text != WIRE_UNREACHABLE_CHIP_TEXT {
                                guard.status_text = WIRE_UNREACHABLE_CHIP_TEXT.to_string();
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
            }

            // If either cloud_projects or podman_ready changed this
            // iteration, rebuild the NSMenu on the main thread so
            // the menu reflects the new state. Note: the rebuild
            // happens AFTER the chip dispatch — they're independent
            // main-thread tasks and the chip update doesn't depend
            // on the new menu being installed.
            if rebuild_needed {
                dispatch_rebuild(&menu_state, &status_item, &status_menu_item, &self_handle);
            }
        }
    });
}

/// Queue an NSMenu rebuild on the AppKit main thread from the held
/// MenuState. Shared by the fallback-poll tick loop and the push
/// listener so both trigger the identical rebuild path.
fn dispatch_rebuild(
    menu_state: &Arc<Mutex<tillandsias_host_shell::menu_state::MenuState>>,
    status_item: &Arc<Mutex<Option<appkit_handle::StatusItemHandle>>>,
    status_menu_item: &Arc<Mutex<Option<appkit_handle::StatusMenuItemHandle>>>,
    self_handle: &Arc<Mutex<Option<appkit_handle::TrayActionHostHandle>>>,
) {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// SC-07 pin: the fallback polls run exactly when the push
    /// subscription is NOT delivering. Mirrors windows-tray's gate
    /// (order 154/155 parity).
    #[test]
    fn should_poll_fallback_is_pure_fallback_gate() {
        assert!(!should_poll_fallback(true));
        assert!(should_poll_fallback(false));
    }

    // The tick-wait pins (tick_wait_wakes_early_only_on_subscription_drop,
    // tick_after_wake_rewinds_on_drop_and_advances_on_timer) now live in
    // tillandsias_host_shell::subscription_health alongside the hoisted
    // implementations — no local duplicate here.

    /// Slice-3 topic pin: the dedicated push connection subscribes to all
    /// FOUR topics now that order 260 shipped LocalProjectsPush and the
    /// tray consumes it. Fails loud if the topic list drifts without
    /// matching reader-loop consumers (each topic here MUST have an arm in
    /// run_push_listener + an initial-sync prime).
    #[test]
    fn push_subscribe_topics_is_all_four_slice3() {
        assert_eq!(
            push_subscribe_topics(),
            vec![
                tillandsias_control_wire::SubscriptionTopic::VmStatus,
                tillandsias_control_wire::SubscriptionTopic::LoginState,
                tillandsias_control_wire::SubscriptionTopic::CloudProjects,
                tillandsias_control_wire::SubscriptionTopic::LocalProjects,
            ]
        );
    }

    /// `apply_local_projects` reports a rebuild exactly on change and is
    /// idempotent on repeat (slice 3 — shared by the push listener and the
    /// fallback tick poll, mirroring apply_cloud_projects).
    #[test]
    fn apply_local_projects_reports_rebuild_only_on_change() {
        use tillandsias_host_shell::menu_state::ProjectEntry;
        let menu_state = Arc::new(Mutex::new(
            tillandsias_host_shell::menu_state::MenuState::initial(),
        ));
        let mk = || {
            vec![ProjectEntry {
                name: "tillandsias".into(),
                path: "/home/forge/src/tillandsias".into(),
                ready: false,
            }]
        };
        assert!(
            apply_local_projects(mk(), &menu_state),
            "first non-empty local list must request a rebuild"
        );
        assert!(
            !apply_local_projects(mk(), &menu_state),
            "identical local list must not re-request a rebuild"
        );
        assert!(
            apply_local_projects(Vec::new(), &menu_state),
            "clearing the list is a change and must request a rebuild"
        );
    }

    /// `map_login_state` mapping pin: logged_in with a handle, logged_in
    /// with a missing handle (defaults empty), and logged_out — identical
    /// to the poll path's historical mapping.
    #[test]
    fn map_login_state_covers_all_reply_shapes() {
        use tillandsias_host_shell::menu_state::GithubLoginState;
        assert_eq!(
            map_login_state(true, Some("octocat".into())),
            GithubLoginState::LoggedIn {
                handle: "octocat".into()
            }
        );
        assert_eq!(
            map_login_state(true, None),
            GithubLoginState::LoggedIn { handle: "".into() }
        );
        assert_eq!(map_login_state(false, None), GithubLoginState::LoggedOut);
        assert_eq!(
            map_login_state(false, Some("stale".into())),
            GithubLoginState::LoggedOut
        );
    }

    /// `apply_login_state` reports a rebuild exactly on change and is
    /// idempotent on repeat (order 155 slice 2 — shared by poll + push).
    #[test]
    fn apply_login_state_reports_rebuild_only_on_change() {
        use tillandsias_host_shell::menu_state::GithubLoginState;
        let menu_state = Arc::new(Mutex::new(
            tillandsias_host_shell::menu_state::MenuState::initial(),
        ));
        // initial() starts LoggedOut — reapplying it is a no-op.
        assert!(!apply_login_state(GithubLoginState::LoggedOut, &menu_state));
        let logged_in = GithubLoginState::LoggedIn {
            handle: "octocat".into(),
        };
        assert!(apply_login_state(logged_in.clone(), &menu_state));
        assert_eq!(menu_state.lock().unwrap().login, logged_in);
        assert!(!apply_login_state(logged_in, &menu_state));
        assert!(apply_login_state(GithubLoginState::LoggedOut, &menu_state));
    }

    /// `apply_cloud_projects` reports a rebuild exactly on change
    /// (full-replacement list semantics) and is idempotent on repeat.
    #[test]
    fn apply_cloud_projects_reports_rebuild_only_on_change() {
        use tillandsias_host_shell::menu_state::ProjectEntry;
        let menu_state = Arc::new(Mutex::new(
            tillandsias_host_shell::menu_state::MenuState::initial(),
        ));
        assert!(!apply_cloud_projects(Vec::new(), &menu_state));
        let projects = vec![ProjectEntry {
            name: "tillandsias".into(),
            path: "8007342/tillandsias".into(),
            ready: false,
        }];
        assert!(apply_cloud_projects(projects.clone(), &menu_state));
        assert_eq!(menu_state.lock().unwrap().cloud_projects, projects);
        assert!(!apply_cloud_projects(projects, &menu_state));
        assert!(apply_cloud_projects(Vec::new(), &menu_state));
    }

    /// `apply_vm_status` flips MenuState gating + reports a rebuild
    /// exactly on change (idempotent on repeat). Chip dispatch is
    /// queued to the (never-running-in-tests) main queue — harmless.
    #[test]
    fn apply_vm_status_updates_menu_state_and_reports_rebuild_on_change() {
        let last_logged = Arc::new(Mutex::new(None));
        let menu_state = Arc::new(Mutex::new(
            tillandsias_host_shell::menu_state::MenuState::initial(),
        ));
        let status_text = Arc::new(Mutex::new(String::new()));
        let status_item = Arc::new(Mutex::new(None));
        let status_menu_item = Arc::new(Mutex::new(None));

        let first = apply_vm_status(
            tillandsias_control_wire::VmPhase::Ready,
            true,
            Some("Securing Vault"),
            &last_logged,
            &menu_state,
            &status_text,
            &status_item,
            &status_menu_item,
        );
        assert!(first, "Ready+podman transition must request a rebuild");
        {
            let guard = menu_state.lock().unwrap();
            assert!(guard.podman_ready);
            assert!(guard.login_runtime_ready);
        }

        let second = apply_vm_status(
            tillandsias_control_wire::VmPhase::Ready,
            true,
            Some("Securing Vault"),
            &last_logged,
            &menu_state,
            &status_text,
            &status_item,
            &status_menu_item,
        );
        assert!(!second, "unchanged status must not re-request a rebuild");
    }

    /// Chip-clobber regression pin (2026-07-10 attended smoke): render()
    /// re-derives the status row from MenuState.status_text on every
    /// rebuild, so apply_vm_status MUST write the composed chip text into
    /// MenuState — otherwise the rebuild its own transition triggers
    /// resurrects the BOOT_STATUS_TEXT default and the menu shows
    /// "Booting…" forever while stderr says Ready.
    #[test]
    fn apply_vm_status_syncs_menu_state_status_text_for_rebuilds() {
        let last_logged = Arc::new(Mutex::new(None));
        let menu_state = Arc::new(Mutex::new(
            tillandsias_host_shell::menu_state::MenuState::initial(),
        ));
        let status_text = Arc::new(Mutex::new(String::new()));
        let status_item = Arc::new(Mutex::new(None));
        let status_menu_item = Arc::new(Mutex::new(None));

        assert_eq!(
            menu_state.lock().unwrap().status_text,
            tillandsias_host_shell::menu_state::BOOT_STATUS_TEXT,
            "precondition: fresh MenuState carries the boot default"
        );
        apply_vm_status(
            tillandsias_control_wire::VmPhase::Ready,
            true,
            None,
            &last_logged,
            &menu_state,
            &status_text,
            &status_item,
            &status_menu_item,
        );
        let synced = menu_state.lock().unwrap().status_text.clone();
        assert_ne!(
            synced,
            tillandsias_host_shell::menu_state::BOOT_STATUS_TEXT,
            "apply_vm_status left MenuState.status_text at the boot default — \
             the next rebuild will clobber the chip back to Booting…"
        );
        assert_eq!(
            synced,
            compose_chip_text(
                &vm_phase_status_text(tillandsias_control_wire::VmPhase::Ready, true),
                None
            ),
            "MenuState.status_text must carry the same composed chip text \
             the direct setTitle path applies"
        );
    }

    #[test]
    fn project_launch_lease_rejects_duplicate_until_released() {
        let in_flight = Arc::new(Mutex::new(HashSet::new()));
        let first = try_acquire_project_launch(&in_flight, "tillandsias")
            .expect("first project launch should acquire the slot");

        assert!(
            try_acquire_project_launch(&in_flight, "tillandsias").is_none(),
            "same-project double-click must not acquire a second launch slot"
        );
        assert!(
            try_acquire_project_launch(&in_flight, "other-project").is_some(),
            "a different project has an independent launch slot"
        );

        drop(first);

        assert!(
            try_acquire_project_launch(&in_flight, "tillandsias").is_some(),
            "slot must clear after the in-flight launch finishes"
        );
    }

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
        // Pin the expanded string literal so a partial typo (e.g. dropping
        // the space, or swapping the emoji codepoint) is caught.
        // windows-260722-5 curated wording (Tlatoāni-approved 'Workspace'
        // family): the transient state is ORANGE and says the app is
        // reconnecting BY ITSELF — 'Wire unreachable' was internals
        // vocabulary with no user-actionable meaning (tray-ux governance).
        assert_eq!(
            WIRE_UNREACHABLE_CHIP_TEXT.as_bytes(),
            "\u{1F7E0} Reconnecting to your workspace\u{2026}".as_bytes()
        );
        // Emoji codepoint is the LARGE ORANGE CIRCLE (transient, not the
        // red terminal state). Windows tray's mark_wire_unreachable uses
        // the exact same codepoint — keep these in lockstep.
        let first_char = WIRE_UNREACHABLE_CHIP_TEXT.chars().next().unwrap();
        assert_eq!(first_char, '\u{1F7E0}');
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

    /// The AppKit action host must resolve the macOS control-wire stream
    /// through the normalized GuestTransport facade instead of opening a
    /// VZ-specific stream directly.
    ///
    /// @trace spec:host-guest-transport
    #[test]
    fn action_host_control_wire_opener_uses_guest_transport_facade() {
        let source = include_str!("action_host.rs");
        let window = source
            .split("async fn open_control_wire_stream(")
            .nth(1)
            .and_then(|s| s.split("\n///").next())
            .expect("open_control_wire_stream source");
        assert!(
            window.contains("GuestEndpoint::MacVz"),
            "opener must construct the MacVz endpoint: {window}"
        );
        assert!(
            window.contains(".open_stream(&endpoint)"),
            "opener must use GuestTransport::open_stream: {window}"
        );
        assert!(
            !window.contains(".open_vsock_stream("),
            "opener must not bypass the GuestTransport facade: {window}"
        );
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

    #[test]
    fn compose_chip_text_caps_overlong_payloads() {
        let base = "\u{1F7E2} Ready";
        let long_event = "x".repeat(200);
        let text = compose_chip_text(base, Some(&long_event));
        assert!(
            text.chars().count() <= tillandsias_host_shell::menu_state::TRAY_STATUS_CHIP_MAX_CHARS,
            "chip must stay within budget: {text:?}"
        );
        assert!(text.ends_with('…'), "long event should ellipsize: {text:?}");
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
            agent: SelectedAgent::OpenCode,
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
