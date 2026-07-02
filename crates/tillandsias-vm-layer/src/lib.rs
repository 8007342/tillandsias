//! Idiomatic VM-exec abstraction for Tillandsias.
//!
//! Mirrors the discipline of `tillandsias-podman`: a single portable Rust
//! surface (`VmRuntime`) with target-specific backends. The Windows backend
//! shells out to `wsl --exec`; the macOS backend spawns
//! `Virtualization.framework` guests directly.
//!
//! Phase-2 status: trait + provisioning manifest are real. The Windows
//! `WslRuntime` and macOS `VzRuntime` impls are cfg-gated skeletons whose
//! methods are marked `unimplemented!` rather than `todo!()` — call sites
//! need real symbols to link against during cross-platform header-only
//! compilation passes. The Linux `FakeVmRuntime` (behind the `fake` feature)
//! mocks the VM by running argv directly on the host so unit tests can
//! exercise the trait contract without a real VM.
//!
//! See `openspec/specs/vm-idiomatic-layer/spec.md` for the design contract.
//!
//! @trace spec:vm-idiomatic-layer

#![allow(dead_code)]

use std::time::Duration;

use serde::{Deserialize, Serialize};

// Both wsl and vz modules compile on every target so call sites can hold
// `WslRuntime` / `VzRuntime` symbols and tests can verify the trait impl
// shape on Linux. Real backend bodies are cfg-gated inside the modules.
pub mod vz;
pub mod wsl;

/// Self-contained control-wire client for non-interactive guest exec (the wire
/// half of `VmRuntime::exec` on vsock backends). Cross-platform / unit-testable
/// — see `vsock_exec::exec_over_stream`.
pub mod vsock_exec;

// macOS host-side vsock connector. Declared at this level so callers can
// import `tillandsias_vm_layer::transport_macos::connect_to_vm_vsock` from
// the macOS tray. The file is itself `#![cfg(target_os = "macos")]` so it
// no-ops on Linux/Windows builds.
//
// @trace spec:vsock-transport, spec:vm-idiomatic-layer
#[cfg(target_os = "macos")]
pub mod transport_macos;

// Windows host→guest transport backend (HvSocket / WSL2).
// The file is itself `#![cfg(target_os = "windows")]` so it no-ops on
// Linux/macOS builds. Exports `WslGuestTransport` (GuestTransport impl) +
// the HvSocket primitives the tray re-exports from here.
//
// @trace spec:host-guest-transport, spec:vm-idiomatic-layer
#[cfg(target_os = "windows")]
pub mod transport_windows;

#[cfg(all(target_os = "linux", feature = "fake"))]
pub mod fake;

/// HTTP fetch + SHA-256 verification for first-run provisioning. Behind the
/// `download` feature so trait-only consumers stay reqwest-free.
#[cfg(feature = "download")]
pub mod fetch;

/// Shared (co-owned) Recipefile + manifest.toml parser for the recipe
/// materializer (vm-recipe-provisioning §2). Behind the `recipe` feature.
#[cfg(feature = "recipe")]
pub mod recipe;

/// Recipe materializer driver (vm-recipe-provisioning §3 + §4). Reads the
/// parsed `Recipe` + `Manifest` from `recipe::`, walks each instruction,
/// derives a content-addressed `LayerKey`, looks up the on-disk cache,
/// invokes a `LayerExecutor` on cache miss (production: `buildah`
/// subprocess), and emits a final rootfs `.tar`. Linux-host owns this
/// driver (lease `linux-l-mat-2026-05-25T15Z`); per-OS converters
/// (§3.7.1 / §3.7.2) live in their own submodules under sibling claims.
///
/// Behind the `materialize` feature.
#[cfg(feature = "materialize")]
pub mod materialize;

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

/// Structured error returned by every `VmRuntime` operation.
///
/// Strings rather than typed wrappers around `io::Error` for now — the
/// host shell wants a single status line on the tray and benefits from
/// already-rendered context. Future iterations may add categorical
/// variants if the host shell starts branching on them.
///
/// @trace spec:vm-idiomatic-layer
pub type VmError = String;

/// Portable VM runtime contract.
///
/// Every method is async and returns `Result<_, VmError>`. Concrete backends
/// must NOT panic on caller-recoverable errors; they propagate them through
/// the result type so the tray's status line can render them.
///
/// @trace spec:vm-idiomatic-layer
#[async_trait::async_trait]
pub trait VmRuntime: Send + Sync {
    /// First-run install: import the rootfs, install the tillandsias binary,
    /// register the VM with the host's VM framework. Idempotent.
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError>;

    /// Boot the VM. No-op if already running.
    async fn start(&self) -> Result<(), VmError>;

    /// Graceful shutdown with bounded drain window. After `drain_timeout`
    /// the backend MAY force-stop.
    async fn stop(&self, drain_timeout: Duration) -> Result<(), VmError>;

    /// Run a command inside the VM, blocking until completion. Returns the
    /// exit status. stdout/stderr inherit from the caller for tray
    /// diagnostics; structured stdio capture is a follow-up.
    async fn exec(&self, argv: &[&str]) -> Result<std::process::ExitStatus, VmError>;

    /// Block until the guest reaches the "tillandsias-ready" milestone (the
    /// in-VM headless has bound the vsock listener). Returns `Err` on timeout.
    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError>;
}
