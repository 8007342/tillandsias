//! First-run VM provisioning orchestration for the cross-platform trays.
//!
//! Two top-level responsibilities:
//! 1. `ensure_vm_provisioned` — cheap "does the VM already accept a
//!    handshake?" probe used by the tray on every launch. Decides whether
//!    the caller can skip provisioning entirely and jump straight into the
//!    ready menu, or whether it needs to drive the longer download/import
//!    flow via the `VmRuntime::provision` path.
//! 2. `ProvisionProgress` — trait the VM-layer backends call to report
//!    phase transitions. The Windows + macOS trays implement it to update
//!    their single condensed status line.
//!
//! @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle

#![allow(dead_code)]

use std::time::Duration;

use serde::{Deserialize, Serialize};

use tillandsias_control_wire::transport::Transport;

use crate::vsock_client::{connect_with_handshake, DEFAULT_HANDSHAKE_TIMEOUT};

/// Outcome of `ensure_vm_provisioned`.
///
/// `AlreadyProvisioned` short-circuits the tray straight into the ready
/// menu. `NeedsProvisioning` signals the caller to invoke the longer
/// `VmRuntime::provision` flow with progress reporting.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProvisionReport {
    AlreadyProvisioned,
    NeedsProvisioning { reason: String },
}

/// Phase tags emitted by the provisioning pipeline. Wire-equivalent to the
/// verbatim status strings in
/// `vm-provisioning-lifecycle.ux.condensed-status@v1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProvisionPhase {
    SettingUp,
    DownloadingRootfs,
    DownloadingTillandsias,
    InstallingTillandsias,
    StartingVm,
    Connecting,
}

impl ProvisionPhase {
    /// Verbatim user-facing status string for this phase. The tray paints
    /// this in the single condensed status line per
    /// `vm-provisioning-lifecycle.ux.condensed-status@v1`.
    pub fn status_text(self) -> &'static str {
        match self {
            ProvisionPhase::SettingUp => "\u{1F535} Setting up Fedora Linux\u{2026}",
            ProvisionPhase::DownloadingRootfs => "\u{1F535} Downloading Fedora rootfs\u{2026}",
            ProvisionPhase::DownloadingTillandsias => "\u{1F535} Downloading Tillandsias\u{2026}",
            ProvisionPhase::InstallingTillandsias => "\u{1F535} Installing Tillandsias\u{2026}",
            ProvisionPhase::StartingVm => "\u{1F535} Starting Fedora Linux\u{2026}",
            ProvisionPhase::Connecting => "\u{1F535} Connecting\u{2026}",
        }
    }

    /// English-only fallback string for systems without emoji rendering
    /// support. The Windows tray surfaces this when it cannot resolve a
    /// font with the U+1F535 large blue circle glyph.
    pub fn status_text_ascii(self) -> &'static str {
        match self {
            ProvisionPhase::SettingUp => "Setting up Fedora Linux...",
            ProvisionPhase::DownloadingRootfs => "Downloading Fedora rootfs...",
            ProvisionPhase::DownloadingTillandsias => "Downloading Tillandsias...",
            ProvisionPhase::InstallingTillandsias => "Installing Tillandsias...",
            ProvisionPhase::StartingVm => "Starting Fedora Linux...",
            ProvisionPhase::Connecting => "Connecting...",
        }
    }
}

/// Callback surface the VM-layer backends use to report progress. The
/// Windows + macOS trays implement it to update the single condensed
/// status line; `tracing::info!` is the fallback when no tray is wired.
///
/// `report_phase` is the structured channel — the host shell maps the
/// phase to the verbatim status string. `report_message` is for ad-hoc
/// text the backend wants to attach (e.g. "78% downloaded").
///
/// Implementations MUST be cheap; the backend calls them often.
///
/// @trace spec:vm-provisioning-lifecycle
pub trait ProvisionProgress: Send + Sync {
    /// Report a phase transition. The host shell renders this as the
    /// new menu status line.
    fn report_phase(&self, phase: ProvisionPhase);
    /// Report a free-form sub-message attached to the current phase. The
    /// tray MAY ignore this (the spec only requires the phase strings).
    fn report_message(&self, message: &str);
}

/// `ProvisionProgress` impl that logs to `tracing` and otherwise no-ops.
/// Suitable for non-tray invocations (CI, headless tooling).
#[derive(Debug, Default, Clone, Copy)]
pub struct TracingProgress;

impl ProvisionProgress for TracingProgress {
    fn report_phase(&self, phase: ProvisionPhase) {
        tracing::info!(target: "provisioning", phase = ?phase, "{}", phase.status_text());
    }
    fn report_message(&self, message: &str) {
        tracing::info!(target: "provisioning", "{}", message);
    }
}

/// Idempotent provisioning probe.
///
/// Opens the control wire to `transport` with a 2s handshake budget. On
/// success, returns `AlreadyProvisioned` — the tray can skip the long
/// rootfs-download flow and jump straight into the ready menu. On any
/// failure (timeout, refused, wire-version mismatch), returns
/// `NeedsProvisioning { reason }` so the caller invokes the longer
/// `VmRuntime::provision` flow.
///
/// The actual rootfs download + import is owned by the
/// `VmRuntime::provision` impl in `WslRuntime`/`VzRuntime`. This function
/// only orchestrates the decision: do we need to call it, or can we skip it?
///
/// @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle
pub async fn ensure_vm_provisioned(transport: &Transport) -> Result<ProvisionReport, String> {
    match connect_with_handshake(transport.clone(), DEFAULT_HANDSHAKE_TIMEOUT).await {
        Ok(_client) => Ok(ProvisionReport::AlreadyProvisioned),
        Err(err) => Ok(ProvisionReport::NeedsProvisioning {
            reason: format!("handshake failed: {err}"),
        }),
    }
}

/// Helper for tests + tray code that wants a synchronous custom timeout.
pub async fn ensure_vm_provisioned_with_timeout(
    transport: &Transport,
    timeout: Duration,
) -> Result<ProvisionReport, String> {
    match connect_with_handshake(transport.clone(), timeout).await {
        Ok(_client) => Ok(ProvisionReport::AlreadyProvisioned),
        Err(err) => Ok(ProvisionReport::NeedsProvisioning {
            reason: format!("handshake failed: {err}"),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_control_wire::{
        ControlEnvelope, ControlMessage, WIRE_VERSION, decode, encode,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    async fn spawn_handshake_responder(path: std::path::PathBuf) -> tokio::task::JoinHandle<()> {
        let listener = UnixListener::bind(&path).expect("bind");
        tokio::spawn(async move {
            let (mut stream, _addr) = listener.accept().await.expect("accept");
            let mut len_buf = [0u8; 4];
            stream.read_exact(&mut len_buf).await.expect("read len");
            let len = u32::from_be_bytes(len_buf) as usize;
            let mut body = vec![0u8; len];
            stream.read_exact(&mut body).await.expect("read body");
            let env = decode(&body).expect("decode");
            assert!(matches!(env.body, ControlMessage::Hello { .. }));
            let ack = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: env.seq,
                body: ControlMessage::HelloAck {
                    wire_version: WIRE_VERSION,
                    server_caps: vec!["v1".into()],
                },
            };
            let bytes = encode(&ack).expect("encode");
            stream
                .write_all(&(bytes.len() as u32).to_be_bytes())
                .await
                .expect("write len");
            stream.write_all(&bytes).await.expect("write ack");
            stream.flush().await.expect("flush");
            tokio::time::sleep(Duration::from_millis(50)).await;
        })
    }

    /// @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle
    #[tokio::test]
    async fn ensure_vm_provisioned_returns_already_when_handshake_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("control.sock");
        let _server = spawn_handshake_responder(path.clone()).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let report = ensure_vm_provisioned(&Transport::Unix(path))
            .await
            .expect("returns Ok");
        assert_eq!(report, ProvisionReport::AlreadyProvisioned);
    }

    /// When no server is listening at the socket path, `ensure_vm_provisioned`
    /// MUST surface `NeedsProvisioning` so the tray drives the longer flow.
    ///
    /// @trace spec:vm-provisioning-lifecycle
    #[tokio::test]
    async fn ensure_vm_provisioned_returns_needs_when_no_server() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.sock");
        let report = ensure_vm_provisioned_with_timeout(
            &Transport::Unix(path),
            Duration::from_millis(200),
        )
        .await
        .expect("returns Ok");
        match report {
            ProvisionReport::NeedsProvisioning { reason } => {
                assert!(!reason.is_empty(), "reason must be populated: {reason}");
            }
            other => panic!("expected NeedsProvisioning, got {other:?}"),
        }
    }

    #[test]
    fn phase_text_matches_verbatim_spec_strings() {
        // Verbatim strings from vm-provisioning-lifecycle.ux.condensed-status@v1.
        assert_eq!(
            ProvisionPhase::SettingUp.status_text(),
            "\u{1F535} Setting up Fedora Linux\u{2026}"
        );
        assert_eq!(
            ProvisionPhase::DownloadingRootfs.status_text(),
            "\u{1F535} Downloading Fedora rootfs\u{2026}"
        );
        assert_eq!(
            ProvisionPhase::DownloadingTillandsias.status_text(),
            "\u{1F535} Downloading Tillandsias\u{2026}"
        );
        assert_eq!(
            ProvisionPhase::InstallingTillandsias.status_text(),
            "\u{1F535} Installing Tillandsias\u{2026}"
        );
        assert_eq!(
            ProvisionPhase::StartingVm.status_text(),
            "\u{1F535} Starting Fedora Linux\u{2026}"
        );
        assert_eq!(
            ProvisionPhase::Connecting.status_text(),
            "\u{1F535} Connecting\u{2026}"
        );
    }
}
