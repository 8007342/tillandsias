//! macOS-side glue between the tray and the `tillandsias-vm-layer`
//! `VzRuntime`. Owns the disk-image path discovery (`~/Library/Application
//! Support/tillandsias/vm/`) and the Virtualization.framework configuration
//! builder.
//!
//! macOS-only.
//!
//! @trace spec:macos-native-tray, spec:vm-idiomatic-layer

#![allow(dead_code)]
#![allow(unused)]

use std::path::PathBuf;
use std::time::Duration;

use tillandsias_vm_layer::vz::VzRuntime;
use tillandsias_vm_layer::{ProvisionManifest, VmRuntime};

/// Default vsock CID assigned to the guest. CIDs <3 are reserved
/// (`HYPERVISOR_CID`, `LOCAL_CID`, `HOST_CID`); 3+ is free for guests.
pub const DEFAULT_GUEST_CID: u32 = 3;

/// Convenience wrapper around `VzRuntime` that carries the tray's preferred
/// defaults (CID, image path).
///
/// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
pub struct VzLifecycle {
    pub runtime: VzRuntime,
}

impl VzLifecycle {
    pub fn new() -> Self {
        Self {
            runtime: VzRuntime::new(DEFAULT_GUEST_CID, Self::image_root()),
        }
    }

    /// `~/Library/Application Support/tillandsias/vm/` — where the disk
    /// image, kernel, and initrd land after provisioning.
    pub fn image_root() -> PathBuf {
        let home = std::env::var("HOME").expect("HOME unset on macOS");
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("tillandsias")
            .join("vm")
    }

    /// `~/Library/Caches/tillandsias/` — where the downloaded Fedora rootfs
    /// tarball lives before being unpacked into the VM disk image.
    pub fn cache_root() -> PathBuf {
        let home = std::env::var("HOME").expect("HOME unset on macOS");
        PathBuf::from(home)
            .join("Library")
            .join("Caches")
            .join("tillandsias")
    }

    /// Drive `VzRuntime::provision` + `start` + `wait_ready` in sequence,
    /// returning the first error if any phase fails. Stays bound to the
    /// `host-shell` lifecycle module's phase-transition contract.
    ///
    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    pub async fn ensure_started(
        &self,
        manifest: &ProvisionManifest,
    ) -> Result<(), String> {
        self.runtime.provision(manifest).await?;
        self.runtime.start().await?;
        self.runtime
            .wait_ready(Duration::from_secs(90))
            .await
    }
}
