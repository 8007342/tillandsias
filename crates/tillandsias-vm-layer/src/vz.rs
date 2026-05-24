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
//! **Phase 5 status**: `provision` now sketches the real first-run flow on
//! macOS — cache discovery, idempotency check, config-builder placeholder.
//! The ext4 conversion step is explicitly stubbed with `unimplemented!`
//! and tracked in `cheatsheets/runtime/vz-framework-provisioning.md` (see
//! "Converting Fedora 44 to a VZ-bootable image"). The actual
//! `VZVirtualMachine` boot lives behind another `unimplemented!` pending
//! a macOS host to validate the bindings.
//!
//! @trace spec:vm-idiomatic-layer, spec:macos-native-tray, spec:vm-provisioning-lifecycle

#![allow(dead_code)]

#[cfg(target_os = "macos")]
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitStatus;
use std::time::Duration;

use crate::{ProvisionManifest, VmError, VmRuntime};

/// Virtualization.framework-backed VM runtime.
///
/// Holds enough configuration to drive provision/start/stop. Real VZ object
/// state (the `VZVirtualMachine` handle) is owned by an internal cell that
/// is only constructed on `start` so we don't keep ObjC retain/release
/// traffic alive across long idle periods.
pub struct VzRuntime {
    /// Stable vsock CID assigned to the guest. Set at config time and
    /// pinned for the lifetime of the guest (per spec invariant
    /// `vz-cid-allocated-at-config`).
    pub guest_cid: u32,
    /// On-disk root for VM artifacts (`~/Library/Application Support/tillandsias/vm/`).
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

    /// Path of the raw root disk image written during provisioning.
    pub fn rootfs_image_path(&self) -> PathBuf {
        self.image_root.join("rootfs.img")
    }

    /// Path of the extracted kernel image (`vmlinuz`) read by `VZLinuxBootLoader`.
    pub fn kernel_path(&self) -> PathBuf {
        self.image_root.join("vmlinuz")
    }

    /// Path of the extracted initramfs read by `VZLinuxBootLoader`.
    pub fn initrd_path(&self) -> PathBuf {
        self.image_root.join("initramfs.img")
    }

    /// Path of the early-boot serial console log.
    pub fn console_log_path(&self) -> PathBuf {
        self.image_root.join("console.log")
    }

    /// True if a previous provisioning has produced the disk image. Used by
    /// `provision` for the idempotency short-circuit.
    pub fn is_provisioned(&self) -> bool {
        self.rootfs_image_path().exists()
            && self.kernel_path().exists()
            && self.initrd_path().exists()
    }
}

/// Default values for the VZ guest config; surfaced as a struct so tests can
/// assert on them without spinning up a real VM.
///
/// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VzGuestConfig {
    /// Logical CPU count. Capped at `min(4, host_cores)`.
    pub cpu_count: u32,
    /// Memory size in bytes (4 GiB default).
    pub memory_bytes: u64,
    /// Stable vsock CID for the guest.
    pub vsock_cid: u32,
    /// Vsock port the in-VM headless listens on.
    pub vsock_port: u32,
    /// Host directory shared into the guest (typically `~/src/`).
    pub shared_host_dir: PathBuf,
    /// virtio-fs share tag — must match the guest's `/etc/fstab` entry.
    pub share_tag: String,
}

impl VzGuestConfig {
    /// Build a default config from the manifest. Caps CPU count at
    /// `min(4, host_cores)` so we never starve the host.
    pub fn from_manifest(manifest: &ProvisionManifest) -> Self {
        let host_cores = std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(2);
        Self {
            cpu_count: host_cores.min(4).max(1),
            memory_bytes: 4 * 1024 * 1024 * 1024,
            vsock_cid: manifest.vsock_cid,
            vsock_port: manifest.vsock_port,
            shared_host_dir: manifest.shared_host_dir.clone(),
            share_tag: "home-src".to_string(),
        }
    }
}

// ---------------------------------------------------------------------------
// macOS: real VZ bodies start in phase 5. Provision now does the cache +
// idempotency dance; boot/exec are still stubbed pending a macOS host.
// @trace spec:vm-idiomatic-layer, spec:vm-provisioning-lifecycle
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod vz_real {
    use super::*;

    /// Convert a downloaded Fedora rootfs tarball into the raw ext4 image
    /// VZ expects. macOS cannot mkfs.ext4 natively; see the cheatsheet for
    /// the production approach (installer-VM sidecar). For now this is an
    /// explicit `unimplemented!` so callers fail loudly.
    pub(super) fn convert_rootfs_to_disk_image(
        _tarball: &Path,
        _image: &Path,
    ) -> Result<(), VmError> {
        unimplemented!(
            "rootfs-to-disk conversion deferred — see \
             cheatsheets/runtime/vz-framework-provisioning.md \
             'Converting Fedora 44 to a VZ-bootable image'"
        )
    }

    /// Extract `vmlinuz` and `initramfs.img` from the Fedora kernel-core
    /// RPM packaged inside the rootfs tarball. Same deferral as the disk
    /// conversion above — placeholder until the installer-VM path lands.
    pub(super) fn extract_kernel_artifacts(
        _tarball: &Path,
        _image_root: &Path,
    ) -> Result<(), VmError> {
        unimplemented!(
            "kernel/initrd extraction deferred — see \
             cheatsheets/runtime/vz-framework-provisioning.md"
        )
    }
}

#[cfg(target_os = "macos")]
#[async_trait::async_trait]
impl VmRuntime for VzRuntime {
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError> {
        // Idempotency short-circuit per
        // vm-provisioning-lifecycle.provision.idempotency@v1.
        if self.is_provisioned() {
            return Ok(());
        }
        tokio::fs::create_dir_all(&self.image_root)
            .await
            .map_err(|e| format!("create image_root failed: {e}"))?;
        if !manifest.rootfs_tarball.exists() {
            return Err(format!(
                "rootfs tarball missing at {}",
                manifest.rootfs_tarball.display()
            ));
        }
        // Build the guest config eagerly so any config-shape bugs surface
        // before we touch the slow filesystem operations.
        let _guest_cfg = VzGuestConfig::from_manifest(manifest);
        // Extract kernel + initrd, then convert the rootfs tarball into a
        // raw ext4 disk image. Both are `unimplemented!` for now — see
        // the cheatsheet for the production approach (installer-VM sidecar
        // or hdiutil + mkfs via a helper container).
        vz_real::extract_kernel_artifacts(&manifest.rootfs_tarball, &self.image_root)?;
        vz_real::convert_rootfs_to_disk_image(
            &manifest.rootfs_tarball,
            &self.rootfs_image_path(),
        )?;
        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        // Real VZVirtualMachine.start with completion handler lands in the
        // macOS-host follow-up. The skeleton verifies that provisioning
        // ran first so callers get a clear error if they skip it.
        if !self.is_provisioned() {
            return Err("VzRuntime::start called before provision".into());
        }
        unimplemented!(
            "VZVirtualMachine.start with completion handler — \
             tracked at openspec/specs/macos-native-tray/spec.md"
        )
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        unimplemented!("VZVirtualMachine.requestStop + force-stop fallback")
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        unimplemented!(
            "VZ exec — host opens vsock to the in-VM headless and \
             forwards the argv; see cheatsheets/runtime/idiomatic-vm-exec.md"
        )
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        unimplemented!("VZ wait_ready — poll vsock handshake on guest_cid:vsock_port")
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

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> ProvisionManifest {
        ProvisionManifest {
            rootfs_tarball: PathBuf::from("/tmp/fedora-44.tar.xz"),
            tillandsias_binary: PathBuf::from("/tmp/tillandsias-linux-x86_64"),
            vsock_cid: 7,
            vsock_port: 42420,
            shared_host_dir: PathBuf::from("/home/user/src"),
        }
    }

    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    #[test]
    fn vz_guest_config_caps_cpu_at_4_and_carries_4gib_memory() {
        let cfg = VzGuestConfig::from_manifest(&manifest());
        assert!(cfg.cpu_count >= 1, "cpu_count must be at least 1");
        assert!(cfg.cpu_count <= 4, "cpu_count must be capped at 4");
        assert_eq!(cfg.memory_bytes, 4 * 1024 * 1024 * 1024);
    }

    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    #[test]
    fn vz_guest_config_uses_share_tag_home_src() {
        let cfg = VzGuestConfig::from_manifest(&manifest());
        assert_eq!(cfg.share_tag, "home-src");
    }

    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    #[test]
    fn vz_guest_config_pins_vsock_cid_from_manifest() {
        let cfg = VzGuestConfig::from_manifest(&manifest());
        assert_eq!(cfg.vsock_cid, 7);
        assert_eq!(cfg.vsock_port, 42420);
    }

    /// @trace spec:vm-provisioning-lifecycle.provision.idempotency@v1
    #[test]
    fn fresh_runtime_is_not_provisioned() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        assert!(!rt.is_provisioned());
    }

    /// @trace spec:vm-provisioning-lifecycle.provision.idempotency@v1
    #[test]
    fn provisioned_check_requires_all_three_artifacts() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        std::fs::write(rt.rootfs_image_path(), b"").unwrap();
        assert!(!rt.is_provisioned(), "rootfs alone is not enough");
        std::fs::write(rt.kernel_path(), b"").unwrap();
        assert!(!rt.is_provisioned(), "rootfs+kernel is not enough");
        std::fs::write(rt.initrd_path(), b"").unwrap();
        assert!(rt.is_provisioned(), "all three artifacts make it provisioned");
    }

    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    #[test]
    fn vz_artifact_paths_live_under_image_root() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        assert!(rt.rootfs_image_path().starts_with(tmp.path()));
        assert!(rt.kernel_path().starts_with(tmp.path()));
        assert!(rt.initrd_path().starts_with(tmp.path()));
        assert!(rt.console_log_path().starts_with(tmp.path()));
    }
}
