//! macOS-side glue between the tray and the `tillandsias-vm-layer`
//! `VzRuntime`. Owns the disk-image path discovery (`~/Library/Application
//! Support/tillandsias/`) and the Virtualization.framework configuration
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

    /// `~/Library/Application Support/tillandsias/` — where the disk image
    /// (`rootfs.img`/`rootfs.qcow2`), `nvram.bin`, and `cidata.iso` land after
    /// provisioning. This MUST match the canonical live path used by the
    /// provision/diagnose surface (`diagnose::image_root`) and the auto-boot
    /// path (`status_item::default_image_root`) — the disk is written at the
    /// top level of this dir, NOT under a `vm/` subdir (see plan packet
    /// macos-tray/image-root-vm-subdir-divergence).
    pub fn image_root() -> PathBuf {
        let home = std::env::var("HOME").expect("HOME unset on macOS");
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("tillandsias")
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
    pub async fn ensure_started(&self, manifest: &ProvisionManifest) -> Result<(), String> {
        self.runtime.provision(manifest).await?;
        self.runtime.start().await?;
        self.runtime.wait_ready(Duration::from_secs(90)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The VM state dir is the top level of `…/tillandsias` — NOT a `vm/`
    /// subdir. `provision_main`/`--diagnose`/auto-boot all write/read there, so
    /// `image_root()` must agree or the (currently dead) VzLifecycle path would
    /// look in an empty dir. Guards macos-tray/image-root-vm-subdir-divergence.
    #[test]
    fn image_root_is_top_level_not_vm_subdir() {
        let root = VzLifecycle::image_root();
        assert!(
            root.ends_with("Library/Application Support/tillandsias"),
            "image_root must be the top-level state dir, got {}",
            root.display()
        );
        assert!(
            root.file_name().and_then(|s| s.to_str()) != Some("vm"),
            "image_root must not nest a vm/ subdir: {}",
            root.display()
        );
    }
}
