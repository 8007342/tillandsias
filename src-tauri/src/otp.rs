//! Tray-side facade over the `tillandsias-otp` workspace crate, with
//! publisher plumbing for the router-side sidecar.
//!
//! `pub use tillandsias_otp::*` keeps the existing `crate::otp::*` paths
//! working for the six tray-side callers (browser.rs, cdp.rs,
//! control_socket/handler.rs, event_loop.rs, main.rs, handlers.rs).
//!
//! On top of that this module adds:
//!
//! - [`install_publisher`] — called once at tray startup with the
//!   broadcast sender from the control-socket `Server`, so subsequent
//!   `issue_and_publish` / `evict_and_publish` calls can fan envelopes
//!   out to subscribed sidecars.
//! - [`issue_and_publish`] — production replacement for
//!   `tillandsias_otp::issue_session`. Generates a token, pushes into the
//!   tray-local store (so the accountability log fires here too), AND
//!   publishes an `IssueWebSession` envelope. Returns the raw token for
//!   CDP injection.
//! - [`evict_and_publish`] — production replacement for
//!   `tillandsias_otp::OtpStore::evict_project`. Drops the project's
//!   entries from the tray-local store AND broadcasts `EvictProject` so
//!   the sidecar drops its mirror.
//!
//! The tray-local store still exists post-chunk-6 for two reasons: the
//! accountability log on `OtpStore::push` runs at issuance time (not
//! validate time), and tray-side diagnostic surfaces (`session_count`,
//! future debug CLI commands) read it. The sidecar's store is the
//! authoritative one for `forward_auth` validation.
//!
//! @trace spec:opencode-web-session-otp, spec:secrets-management
//! @cheatsheet web/cookie-auth-best-practices.md

use std::sync::OnceLock;

use tillandsias_control_wire::ControlMessage;
use tokio::sync::broadcast;

pub use tillandsias_otp::*;

/// Process-global slot for the control-socket server's broadcast publisher.
/// Set once during tray startup; every subsequent `issue_and_publish` /
/// `evict_and_publish` call reads from here.
///
/// Stored as a `Sender` clone (the broadcast channel is internally
/// reference-counted; cloning is cheap).
static PUBLISHER: OnceLock<broadcast::Sender<ControlMessage>> = OnceLock::new();

/// Install the publisher. Called from `main.rs` exactly once after
/// `Server::bind` returns. A second call is a no-op (the OnceLock keeps
/// the first installed sender) — duplicate setup is logged at the call
/// site.
///
/// @trace spec:opencode-web-session-otp
pub fn install_publisher(publisher: broadcast::Sender<ControlMessage>) -> bool {
    PUBLISHER.set(publisher).is_ok()
}

/// Generate a fresh session token, push it into the tray-local store
/// (where the accountability log fires), AND publish an
/// `IssueWebSession` envelope so subscribed sidecars learn about the
/// new cookie. Returns the raw 32-byte token so the caller can hand it
/// to CDP `Network.setCookies`.
///
/// If the publisher hasn't been installed yet (early-startup race) or
/// no sidecars are connected (`SendError`), the issuance still succeeds
/// in the tray-local store — the user's browser window opens with the
/// cookie set, but the sidecar will return 401 until the next reconnect
/// + re-issue. Acceptable degraded behaviour, not a panic.
///
/// @trace spec:opencode-web-session-otp, spec:secrets-management
pub fn issue_and_publish(project_label: &str) -> [u8; COOKIE_LEN] {
    let token = issue_session(project_label);
    if let Some(publisher) = PUBLISHER.get() {
        // SendError = no subscribers. That's the "no sidecar connected
        // yet" case — degrade silently; the cookie still goes into the
        // browser, just won't validate at the router until the sidecar
        // catches up. Logging at debug because this is normal during
        // startup.
        let _ = publisher.send(ControlMessage::IssueWebSession {
            project_label: project_label.to_string(),
            cookie_value: token,
        });
    }
    token
}

/// Drop every session entry for `project_label` from the tray-local
/// store AND broadcast `EvictProject` so the sidecar drops its mirror.
/// Called when the project's container stack stops.
///
/// @trace spec:opencode-web-session-otp
pub fn evict_and_publish(project_label: &str) {
    global().evict_project(project_label);
    if let Some(publisher) = PUBLISHER.get() {
        let _ = publisher.send(ControlMessage::EvictProject {
            project_label: project_label.to_string(),
        });
    }
}
