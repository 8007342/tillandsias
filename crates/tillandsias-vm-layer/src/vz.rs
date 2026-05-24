//! macOS Virtualization.framework backend for the VM runtime.
//!
//! Uses `objc2-virtualization` to construct a `VZVirtualMachineConfiguration`
//! with virtio-fs (for `~/src/` passthrough), virtio-vsock (for the control
//! wire), and a virtio-console for early-boot diagnostics. Boots a Fedora
//! guest from a pre-extracted rootfs image.
//!
//! macOS-only. Linux/Windows builds skip this module entirely.
//!
//! @trace spec:vm-idiomatic-layer, spec:macos-native-tray

#![allow(dead_code)]
#![allow(unused)]

use std::time::Duration;

use crate::{ProvisionManifest, VmRuntime};

/// Virtualization.framework-backed VM runtime.
pub struct VzRuntime {
    /// Stable vsock CID assigned to the guest.
    pub guest_cid: u32,
    /// On-disk location of the rootfs image (`~/Library/Application Support/tillandsias/vm/`).
    pub image_root: std::path::PathBuf,
}

impl VzRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(guest_cid: u32, image_root: std::path::PathBuf) -> Self {
        Self {
            guest_cid,
            image_root,
        }
    }
}

#[async_trait::async_trait]
impl VmRuntime for VzRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: extract rootfs, build VZVirtualMachineConfiguration")
    }

    async fn start(&self) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: VZVirtualMachine.start() with completion handler")
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: requestStop then forceStop fallback after timeout")
    }

    async fn exec(&self, _argv: &[&str]) -> Result<std::process::ExitStatus, String> {
        todo!("@spec vm-idiomatic-layer: in-VM exec via control-wire RPC, not host fork")
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: poll vsock readiness on guest_cid:42420")
    }
}
