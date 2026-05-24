//! Idiomatic VM-exec abstraction for Tillandsias.
//!
//! Mirrors the discipline of `tillandsias-podman`: a single portable Rust
//! surface (`VmRuntime`) with target-specific backends. The Windows backend
//! shells out to `wsl --exec`; the macOS backend spawns
//! `Virtualization.framework` guests directly.
//!
//! This crate is a SCAFFOLD ONLY — every method returns `todo!()` pending
//! implementation. See `openspec/specs/vm-idiomatic-layer/spec.md` for the
//! design contract.
//!
//! @trace spec:vm-idiomatic-layer

#![allow(dead_code)]
#![allow(unused)]

use std::time::Duration;

use serde::{Deserialize, Serialize};

#[cfg(target_os = "windows")]
pub mod wsl;

#[cfg(target_os = "macos")]
pub mod vz;

/// Provisioning manifest passed to `VmRuntime::provision`.
///
/// Captures every input the backend needs to produce a working VM the first
/// time the tray launches: which Fedora rootfs to import, which tillandsias
/// binary to install, which CID to assign for vsock, etc.
///
/// @trace spec:vm-idiomatic-layer, spec:vm-provisioning-lifecycle
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvisionManifest {
    /// Local path to the cached Fedora rootfs tarball.
    pub rootfs_tarball: std::path::PathBuf,
    /// Local path to the cached tillandsias linux binary.
    pub tillandsias_binary: std::path::PathBuf,
    /// Stable vsock CID the guest will own. WSL2 assigns auto; macOS sets explicitly.
    pub vsock_cid: u32,
    /// Vsock port the in-VM headless listens on. Default `42420`.
    pub vsock_port: u32,
    /// Host directory shared into the guest (typically `~/src/`).
    pub shared_host_dir: std::path::PathBuf,
}

/// Portable VM runtime contract.
///
/// Every method is async and returns `Result<_, String>`. Concrete backends
/// must NOT panic on caller-recoverable errors; they propagate them through
/// the result type so the tray's status line can render them.
///
/// @trace spec:vm-idiomatic-layer
#[async_trait::async_trait]
pub trait VmRuntime: Send + Sync {
    /// First-run install: import the rootfs, install the tillandsias binary,
    /// register the VM with the host's VM framework. Idempotent.
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), String>;

    /// Boot the VM. No-op if already running.
    async fn start(&self) -> Result<(), String>;

    /// Graceful shutdown with bounded drain window. After `drain_timeout`
    /// the backend MAY force-stop.
    async fn stop(&self, drain_timeout: Duration) -> Result<(), String>;

    /// Run a command inside the VM, blocking until completion. Returns the
    /// exit status. stdout/stderr inherit from the caller for tray
    /// diagnostics; structured stdio capture is a follow-up.
    async fn exec(&self, argv: &[&str]) -> Result<std::process::ExitStatus, String>;

    /// Block until the guest reaches the "tillandsias-ready" milestone (the
    /// in-VM headless has bound the vsock listener). Returns `Err` on timeout.
    async fn wait_ready(&self, timeout: Duration) -> Result<(), String>;
}
