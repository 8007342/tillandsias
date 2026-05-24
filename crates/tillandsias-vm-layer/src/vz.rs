//! macOS Virtualization.framework backend for the VM runtime.
//!
//! Uses `objc2-virtualization` to construct a `VZVirtualMachineConfiguration`
//! with virtio-fs (for `~/src/` passthrough), virtio-vsock (for the control
//! wire), and a virtio-console for early-boot diagnostics. Boots a Fedora
//! guest from a pre-extracted rootfs image.
//!
//! macOS is the only target where the real VZ shell-out body will land
//! (Phase 5). On other targets this module compiles with a link stub that
//! returns "VzRuntime is macOS-only" so callers still link cleanly.
//!
//! @trace spec:vm-idiomatic-layer, spec:macos-native-tray

#![allow(dead_code)]

use std::path::PathBuf;
use std::process::ExitStatus;
use std::time::Duration;

use crate::{ProvisionManifest, VmError, VmRuntime};

/// Virtualization.framework-backed VM runtime.
pub struct VzRuntime {
    /// Stable vsock CID assigned to the guest.
    pub guest_cid: u32,
    /// On-disk location of the rootfs image (`~/Library/Application Support/tillandsias/vm/`).
    pub image_root: PathBuf,
}

impl VzRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(guest_cid: u32, image_root: PathBuf) -> Self {
        Self {
            guest_cid,
            image_root,
        }
    }
}

// ---------------------------------------------------------------------------
// macOS: real VZ bodies land in phase 5. Today the methods compile but
// signal "not implemented" loudly via `unimplemented!` so a Mac developer
// who calls them immediately knows wiring is owed.
// @trace spec:vm-idiomatic-layer
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
#[async_trait::async_trait]
impl VmRuntime for VzRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), VmError> {
        unimplemented!("VzRuntime body — phase 5")
    }

    async fn start(&self) -> Result<(), VmError> {
        unimplemented!("VzRuntime body — phase 5")
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        unimplemented!("VzRuntime body — phase 5")
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        unimplemented!("VzRuntime body — phase 5")
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        unimplemented!("VzRuntime body — phase 5")
    }
}

// ---------------------------------------------------------------------------
// Non-macOS: cross-platform link stubs.
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "macos"))]
#[async_trait::async_trait]
impl VmRuntime for VzRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), VmError> {
        Err("VzRuntime is macOS-only".into())
    }

    async fn start(&self) -> Result<(), VmError> {
        Err("VzRuntime is macOS-only".into())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        Err("VzRuntime is macOS-only".into())
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        Err("VzRuntime is macOS-only".into())
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        Err("VzRuntime is macOS-only".into())
    }
}
