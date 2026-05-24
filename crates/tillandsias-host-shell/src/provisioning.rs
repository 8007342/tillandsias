//! First-run VM provisioning orchestration for the cross-platform trays.
//!
//! Wraps the rootfs/binary download, importing into the VM framework, and
//! emitting condensed progress to the tray menu's single status line.
//!
//! @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle

#![allow(dead_code)]
#![allow(unused)]

use serde::{Deserialize, Serialize};

use tillandsias_control_wire::transport::Transport;

/// Result of a provisioning attempt; carries enough detail for the tray to
/// render either a green check or a `🥀 Provisioning failed: <reason>` line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvisionReport {
    pub fedora_rootfs_cached: bool,
    pub tillandsias_binary_cached: bool,
    pub vm_imported: bool,
    pub last_error: Option<String>,
}

/// Idempotent provisioning entry point invoked by the tray on every launch.
///
/// First run downloads + imports; subsequent runs detect existing artifacts
/// and short-circuit. The condensed status string surfaced to the menu
/// (`Downloading rootfs…`, `Installing tillandsias…`, etc.) is emitted via
/// the `tracing` log stream that the tray subscribes to.
pub async fn ensure_vm_provisioned(_transport: &Transport) -> Result<ProvisionReport, String> {
    todo!("@spec vm-provisioning-lifecycle: cache-check, download, import, idempotent retry")
}
