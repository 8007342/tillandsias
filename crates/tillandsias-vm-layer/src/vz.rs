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
    /// VM handle storage (macOS-only). `Some` between `start()` and `stop()`.
    /// Wrapped in a Mutex so multiple `&self` callers (start/stop/wait_ready)
    /// can coordinate on the same VZVirtualMachine.
    #[cfg(target_os = "macos")]
    vm: std::sync::Mutex<Option<vm_handle::VmHandle>>,
}

/// Send+Sync wrapper around `Retained<VZVirtualMachine>` so `VzRuntime` can
/// satisfy `Send + Sync` (required by the `VmRuntime` trait).
///
/// SAFETY: `Virtualization.framework` documents that a single
/// `VZVirtualMachine` must be operated on a single dispatch queue. `VzRuntime`
/// serialises all VZ method calls through `self.vm` (Mutex), and every
/// invocation must run on a thread that is currently pumping
/// `CFRunLoopRunInMode(kCFRunLoopDefaultMode, ...)` — typically the main
/// thread of the tray binary or the dispatch queue created by
/// `VZVirtualMachine`'s own infrastructure. The `unsafe impl` reflects that
/// VZRuntime's API surface (not the bindings) enforces single-queue access.
#[cfg(target_os = "macos")]
mod vm_handle {
    use objc2::rc::Retained;
    use objc2_virtualization::VZVirtualMachine;

    pub(crate) struct VmHandle(pub Retained<VZVirtualMachine>);

    // SAFETY: see module docstring.
    unsafe impl Send for VmHandle {}
    // SAFETY: see module docstring.
    unsafe impl Sync for VmHandle {}
}

impl VzRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(guest_cid: u32, image_root: PathBuf) -> Self {
        Self {
            guest_cid,
            image_root,
            #[cfg(target_os = "macos")]
            vm: std::sync::Mutex::new(None),
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
            cpu_count: host_cores.clamp(1, 4),
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

/// Building blocks for VZ-backed Linux VMs. Public so the `vz-spike` example
/// and the eventual `VmRuntime::start` impl share the same config-builder
/// instead of forking parallel implementations.
///
/// macOS-only — the module isn't even defined on Linux/Windows.
///
/// @trace spec:vm-idiomatic-layer, spec:macos-native-tray
#[cfg(target_os = "macos")]
pub mod boot {
    use std::os::raw::c_int;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, Instant};

    use objc2::ClassType;
    use objc2::rc::Retained;
    use objc2_foundation::{NSArray, NSFileHandle, NSString, NSURL};
    use objc2_virtualization::{
        VZBootLoader, VZDiskImageStorageDeviceAttachment, VZEFIBootLoader, VZEFIVariableStore,
        VZEFIVariableStoreInitializationOptions, VZEntropyDeviceConfiguration,
        VZFileHandleSerialPortAttachment, VZGenericPlatformConfiguration,
        VZMemoryBalloonDeviceConfiguration, VZNATNetworkDeviceAttachment,
        VZNetworkDeviceConfiguration, VZPlatformConfiguration, VZSerialPortAttachment,
        VZSerialPortConfiguration, VZSocketDeviceConfiguration, VZStorageDeviceConfiguration,
        VZVirtioBlockDeviceConfiguration, VZVirtioConsoleDeviceSerialPortConfiguration,
        VZVirtioEntropyDeviceConfiguration, VZVirtioNetworkDeviceConfiguration,
        VZVirtioSocketDeviceConfiguration, VZVirtioTraditionalMemoryBalloonDeviceConfiguration,
        VZVirtualMachineConfiguration,
    };

    /// Inputs to [`build_vm_configuration`]. The builder consumes a borrow
    /// and produces a retained `VZVirtualMachineConfiguration`; it does NOT
    /// validate (callers do, so they can inspect intermediate state for
    /// debugging).
    ///
    /// @trace spec:vm-idiomatic-layer
    pub struct VzBootConfig {
        pub cpu_count: usize,
        pub memory_bytes: u64,
        /// Raw root disk image (`.img`). `None` skips storage entirely —
        /// useful for "does the framework accept the rest of my config"
        /// smoke tests, but won't actually boot anything.
        pub root_disk: Option<PathBuf>,
        /// Persistent EFI variable store path. `None` skips NVRAM, which
        /// makes the EFI bootloader invalid; callers should always pass
        /// `Some(...)` for a bootable VM (the file is created if missing).
        pub nvram: Option<PathBuf>,
        /// Optional override for the serial writer fd. If `None`, the
        /// builder dups `STDERR_FILENO` so guest serial flows to host
        /// stderr for early-boot diagnostics.
        pub serial_writer_fd: Option<c_int>,
    }

    impl VzBootConfig {
        /// Modest defaults: 2 vCPU, 2 GiB RAM, no disk, no NVRAM. Useful
        /// as a starting point for tests; production callers MUST set
        /// `root_disk` and `nvram` for a bootable VM.
        pub fn defaults() -> Self {
            Self {
                cpu_count: 2,
                memory_bytes: 2 * 1024 * 1024 * 1024,
                root_disk: None,
                nvram: None,
                serial_writer_fd: None,
            }
        }
    }

    /// Build a fully-wired `VZVirtualMachineConfiguration` from the spec:
    /// EFI boot, optional virtio-blk root disk, virtio-net NAT,
    /// virtio-console serial → host stderr (or `serial_writer_fd`),
    /// virtio-entropy, virtio-balloon, virtio-vsock.
    ///
    /// The caller's next step is `cfg.validateWithError()`, then
    /// `VZVirtualMachine::initWithConfiguration(alloc, &cfg)`.
    ///
    /// @trace spec:vm-idiomatic-layer, spec:macos-native-tray
    pub fn build_vm_configuration(
        spec: &VzBootConfig,
    ) -> Result<Retained<VZVirtualMachineConfiguration>, String> {
        unsafe {
            let cfg = VZVirtualMachineConfiguration::new();
            cfg.setCPUCount(spec.cpu_count);
            cfg.setMemorySize(spec.memory_bytes);

            // Generic platform — no Mac-host-specific requirements.
            let platform = VZGenericPlatformConfiguration::new();
            let plat_super: &VZPlatformConfiguration = &*platform;
            cfg.setPlatform(plat_super);

            // EFI bootloader with optional persistent NVRAM.
            let efi = VZEFIBootLoader::new();
            if let Some(path) = &spec.nvram {
                let url = ns_url_for_path(path);
                let alloc = VZEFIVariableStore::alloc();
                let store = if path.exists() {
                    VZEFIVariableStore::initWithURL(alloc, &url)
                } else {
                    VZEFIVariableStore::initCreatingVariableStoreAtURL_options_error(
                        alloc,
                        &url,
                        VZEFIVariableStoreInitializationOptions::VZEFIVariableStoreInitializationOptionAllowOverwrite,
                    )
                    .map_err(|e| format!("create nvram: {}", e.localizedDescription()))?
                };
                efi.setVariableStore(Some(&store));
            }
            let efi_super: &VZBootLoader = &*efi;
            cfg.setBootLoader(Some(efi_super));

            // virtio-blk root disk (optional).
            if let Some(path) = &spec.root_disk {
                let url = ns_url_for_path(path);
                let att = VZDiskImageStorageDeviceAttachment::initWithURL_readOnly_error(
                    VZDiskImageStorageDeviceAttachment::alloc(),
                    &url,
                    false,
                )
                .map_err(|e| format!("disk attach: {}", e.localizedDescription()))?;
                let blk = VZVirtioBlockDeviceConfiguration::initWithAttachment(
                    VZVirtioBlockDeviceConfiguration::alloc(),
                    &att,
                );
                let arr: Retained<NSArray<VZStorageDeviceConfiguration>> =
                    NSArray::from_id_slice(&[Retained::cast(blk)]);
                cfg.setStorageDevices(&arr);
            }

            // virtio-net + NAT.
            let nat = VZNATNetworkDeviceAttachment::new();
            let nat_super: &objc2_virtualization::VZNetworkDeviceAttachment = &nat;
            let nic = VZVirtioNetworkDeviceConfiguration::new();
            nic.setAttachment(Some(nat_super));
            let nic_super: Retained<VZNetworkDeviceConfiguration> = Retained::into_super(nic);
            let arr_n: Retained<NSArray<VZNetworkDeviceConfiguration>> =
                NSArray::from_id_slice(&[nic_super]);
            cfg.setNetworkDevices(&arr_n);

            // virtio-console serial: guest writes → host stderr (or override),
            // host reads /dev/null (no input forwarded).
            let null_fd =
                open_read_only_devnull().ok_or_else(|| "open(/dev/null) failed".to_string())?;
            let writer_fd = match spec.serial_writer_fd {
                Some(fd) => fd,
                None => dup_fd(2).ok_or_else(|| "dup(stderr) failed".to_string())?,
            };
            let read_fh = NSFileHandle::initWithFileDescriptor_closeOnDealloc(
                NSFileHandle::alloc(),
                null_fd,
                true,
            );
            let write_fh = NSFileHandle::initWithFileDescriptor_closeOnDealloc(
                NSFileHandle::alloc(),
                writer_fd,
                true,
            );
            let serial_att =
                VZFileHandleSerialPortAttachment::initWithFileHandleForReading_fileHandleForWriting(
                    VZFileHandleSerialPortAttachment::alloc(),
                    Some(&read_fh),
                    Some(&write_fh),
                );
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration::new();
            let att_super: &VZSerialPortAttachment = &*serial_att;
            serial.setAttachment(Some(att_super));
            let arr_s: Retained<NSArray<VZSerialPortConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(serial)]);
            cfg.setSerialPorts(&arr_s);

            // virtio-entropy + virtio-balloon.
            let entropy = VZVirtioEntropyDeviceConfiguration::new();
            let arr_e: Retained<NSArray<objc2_virtualization::VZEntropyDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(entropy)]);
            let _: &VZEntropyDeviceConfiguration = &arr_e[0];
            cfg.setEntropyDevices(&arr_e);

            let balloon = VZVirtioTraditionalMemoryBalloonDeviceConfiguration::new();
            let arr_b: Retained<NSArray<VZMemoryBalloonDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(balloon)]);
            cfg.setMemoryBalloonDevices(&arr_b);

            // virtio-vsock — host connects later via VZVirtioSocketDevice
            // (see crates/tillandsias-vm-layer/src/transport_macos.rs, TBD).
            let sock = VZVirtioSocketDeviceConfiguration::new();
            let arr_sd: Retained<NSArray<VZSocketDeviceConfiguration>> =
                NSArray::from_id_slice(&[Retained::cast(sock)]);
            cfg.setSocketDevices(&arr_sd);

            Ok(cfg)
        }
    }

    /// Pump CoreFoundation's main runloop for `dur`, letting VZ completion
    /// handlers dispatched to the main queue fire. Returns when the
    /// wall-clock deadline elapses (whether or not any sources fired).
    ///
    /// Without this, the main thread sleeping blocks dispatch delivery and
    /// `startWithCompletionHandler` callbacks never run — confirmed
    /// empirically (commit 3716dd40).
    ///
    /// @trace spec:vm-idiomatic-layer
    pub fn pump_cf_loop_for(dur: Duration) {
        #[link(name = "CoreFoundation", kind = "framework")]
        unsafe extern "C" {
            fn CFRunLoopRunInMode(
                mode: *const std::ffi::c_void,
                seconds: f64,
                return_after_source_handled: u8,
            ) -> i32;
            static kCFRunLoopDefaultMode: *const std::ffi::c_void;
        }
        let deadline = Instant::now() + dur;
        loop {
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .as_secs_f64();
            if remaining <= 0.0 {
                break;
            }
            let _rc = unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining.min(1.0), 0) };
        }
    }

    // ─── small helpers ────────────────────────────────────────────────────

    fn ns_url_for_path(p: &Path) -> Retained<NSURL> {
        let s = NSString::from_str(p.to_string_lossy().as_ref());
        unsafe { NSURL::fileURLWithPath(&s) }
    }

    fn open_read_only_devnull() -> Option<c_int> {
        unsafe extern "C" {
            fn open(path: *const std::os::raw::c_char, oflag: c_int) -> c_int;
        }
        let fd = unsafe {
            open(b"/dev/null\0".as_ptr() as _, 0 /* O_RDONLY */)
        };
        if fd < 0 { None } else { Some(fd) }
    }

    fn dup_fd(fd: c_int) -> Option<c_int> {
        unsafe extern "C" {
            fn dup(fd: c_int) -> c_int;
        }
        let new_fd = unsafe { dup(fd) };
        if new_fd < 0 { None } else { Some(new_fd) }
    }
}

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
        vz_real::convert_rootfs_to_disk_image(&manifest.rootfs_tarball, &self.rootfs_image_path())?;
        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        use objc2::ClassType;
        use objc2_foundation::NSError;
        use objc2_virtualization::VZVirtualMachine;
        use std::time::Instant;

        // Phase 1 interim: VzRuntime::start expects the rootfs.img path
        // already populated at `<image_root>/rootfs.img`. Phase 4 will
        // materialize via recipe per D6; for now callers point image_root
        // at a manually-built rootfs (qemu-img convert of a Fedora cloud
        // image — same path vz-spike uses).
        let rootfs = self.rootfs_image_path();
        if !rootfs.exists() {
            return Err(format!(
                "VzRuntime::start: rootfs not found at {} \
                 (Phase 4 / D6 amendment will materialize via recipe)",
                rootfs.display()
            ));
        }

        // Refuse double-start.
        {
            let slot = self
                .vm
                .lock()
                .map_err(|e| format!("vm lock poisoned: {e}"))?;
            if slot.is_some() {
                return Err("VzRuntime::start: VM already running".into());
            }
        }

        let spec = boot::VzBootConfig {
            cpu_count: std::thread::available_parallelism()
                .map(|n| n.get().min(4))
                .unwrap_or(2),
            memory_bytes: 4 * 1024 * 1024 * 1024,
            root_disk: Some(rootfs),
            nvram: Some(self.image_root.join("nvram.bin")),
            serial_writer_fd: None,
        };

        let cfg = boot::build_vm_configuration(&spec)?;
        unsafe { cfg.validateWithError() }
            .map_err(|e| format!("validate: {}", e.localizedDescription()))?;

        let alloc = VZVirtualMachine::alloc();
        let vm = unsafe { VZVirtualMachine::initWithConfiguration(alloc, &cfg) };

        // Bridge VZ's dispatch-queue completion handler to this thread via a
        // mpsc channel, then pump CFRunLoop until the result arrives or 30s
        // elapses. The pump blocks this thread; the caller must run start()
        // on `tokio::task::spawn_blocking` if invoked from an async runtime.
        let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
        let handler = block2::RcBlock::new(move |err: *mut NSError| {
            let result = if err.is_null() {
                Ok(())
            } else {
                Err(unsafe { (*err).localizedDescription() }.to_string())
            };
            let _ = tx.send(result);
        });
        unsafe { vm.startWithCompletionHandler(&handler) };

        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Ok(result) = rx.try_recv() {
                result.map_err(|e| format!("VM start failed: {e}"))?;
                break;
            }
            if Instant::now() >= deadline {
                return Err("VzRuntime::start: VM start timed out after 30s".into());
            }
            boot::pump_cf_loop_for(Duration::from_millis(250));
        }

        // Persist the handle so stop()/wait_ready() can address the same VM.
        let mut slot = self
            .vm
            .lock()
            .map_err(|e| format!("vm lock poisoned: {e}"))?;
        *slot = Some(vm_handle::VmHandle(vm));
        Ok(())
    }

    async fn stop(&self, drain_timeout: Duration) -> Result<(), VmError> {
        use std::time::Instant;

        // Take the handle for the duration of the stop dance so a concurrent
        // start() can't race (and so we drop it at the end → ref-count → 0 →
        // VZ frees the runtime objects).
        let handle = {
            let mut slot = self
                .vm
                .lock()
                .map_err(|e| format!("vm lock poisoned: {e}"))?;
            slot.take()
                .ok_or_else(|| "VzRuntime::stop: VM not running".to_string())?
        };
        let vm = &handle.0;

        // Phase 1 cut: requestStop is synchronous-ish (returns immediately;
        // the actual stop happens on the VZ dispatch queue). We pump CFRunLoop
        // for up to `drain_timeout` waiting for the VM state to transition to
        // Stopped via a delegate-equivalent poll, then call hard stop() on
        // timeout to guarantee bounded shutdown.
        //
        // We don't yet observe VZVirtualMachineDelegate.guestDidStop — the
        // delegate plumbing is a follow-on iteration. Instead we poll
        // `state` (== `VZVirtualMachineStateStopped` = 4) every 250 ms while
        // pumping the runloop so VZ callbacks can fire.
        let request_result = unsafe { vm.requestStopWithError() };
        if let Err(e) = request_result {
            // The VM may already be stopped or in an invalid state for stop;
            // log + fall through to force-stop to honor the drain_timeout
            // contract.
            let msg = e.localizedDescription().to_string();
            // Returning here would leak the VM in a weird state; better to
            // surface and let the caller decide.
            return Err(format!("VzRuntime::stop: requestStop failed: {msg}"));
        }

        let deadline = Instant::now() + drain_timeout;
        loop {
            // VZ state enum: 0=Stopped, 1=Running, 2=Paused, 3=Error, 4=Starting,
            // 5=Pausing, 6=Resuming, 7=Stopping, 8=Saving, 9=Restoring.
            let state = unsafe { vm.state() }.0;
            if state == 0 {
                // Stopped cleanly.
                return Ok(());
            }
            if Instant::now() >= deadline {
                // Drain timeout — try a hard stop. `stop:completionHandler:`
                // is the force-stop variant; we wait briefly for it then
                // return regardless.
                let (tx, rx) = std::sync::mpsc::channel::<()>();
                let handler = block2::RcBlock::new(move |_err: *mut objc2_foundation::NSError| {
                    let _ = tx.send(());
                });
                unsafe { vm.stopWithCompletionHandler(&handler) };
                let force_deadline = Instant::now() + Duration::from_secs(5);
                while Instant::now() < force_deadline {
                    if rx.try_recv().is_ok() {
                        break;
                    }
                    boot::pump_cf_loop_for(Duration::from_millis(100));
                }
                return Err(format!(
                    "VzRuntime::stop: drain_timeout ({}s) expired; force-stop dispatched",
                    drain_timeout.as_secs()
                ));
            }
            boot::pump_cf_loop_for(Duration::from_millis(250));
        }
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        // Phase 5 work (gated on control-wire-pty-attach merging). Returns
        // a clear error so callers don't silently swallow the gap.
        Err("VzRuntime::exec: deferred to Phase 5 (gated on \
             control-wire-pty-attach merging). See plan/steps/20-macos-tray-v0_0_1.md."
            .into())
    }

    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError> {
        use std::time::Instant;

        // Two-stage readiness check (Phase 1 step 1.8 — m1b sub-task C):
        //   1. Structural: poll VZVirtualMachineState until Running. Means
        //      VZ accepted the start and the guest kernel is executing.
        //   2. Functional: connect_to_vm_vsock(CONTROL_WIRE_VSOCK_PORT)
        //      until success. Means the in-VM tillandsias-headless's
        //      vsock_server has actually bound the port and is accepting
        //      connections.
        //
        // The full Hello/HelloAck handshake check is the next layer up —
        // belongs in tillandsias-host-shell::vsock_client, not in
        // VmRuntime::wait_ready. A successful TCP-equivalent connect is
        // enough to say "the listener is alive."
        //
        // Backoff cadence matches host-shell::vsock_client::BACKOFF_SCHEDULE
        // (250 → 500 → 1000 → 2000 → 4000 ms, capped) so the chain
        // start → wait_ready → vsock connect has consistent perceived
        // latency in the tray.

        // ── Stage 1: structural state-poll ────────────────────────────
        let deadline = Instant::now() + timeout;
        let backoff_ms = [250u64, 500, 1000, 2000, 4000];
        let mut step = 0usize;
        loop {
            // Re-acquire the lock briefly each iteration so we don't hold
            // it across the multi-second CFRunLoop pump (would block
            // concurrent stop()).
            let state = {
                let guard = self
                    .vm
                    .lock()
                    .map_err(|e| format!("vm lock poisoned: {e}"))?;
                let vm = match guard.as_ref() {
                    Some(h) => &h.0,
                    None => {
                        return Err(
                            "VzRuntime::wait_ready: VM not running (start() first)".into(),
                        );
                    }
                };
                unsafe { vm.state() }.0
            };
            // 1 = VZVirtualMachineStateRunning → proceed to stage 2.
            if state == 1 {
                break;
            }
            // 3 = Error; abort immediately.
            if state == 3 {
                return Err(format!(
                    "VzRuntime::wait_ready: VM state Error (={state}) during stage 1"
                ));
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "VzRuntime::wait_ready: stage 1 timeout after {}s; final state={state}",
                    timeout.as_secs()
                ));
            }
            let wait_ms = backoff_ms[step.min(backoff_ms.len() - 1)];
            step = step.saturating_add(1);
            boot::pump_cf_loop_for(Duration::from_millis(wait_ms));
        }

        // ── Stage 2: functional vsock-probe ───────────────────────────
        // CONTROL_WIRE_VSOCK_PORT comes from tillandsias-control-wire (the
        // shared canonical constant). The in-VM headless's vsock_server
        // binds (VMADDR_CID_ANY, 42420) on startup; we treat a successful
        // host-side connect as proof the listener is up.
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        let mut step = 0usize;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(format!(
                    "VzRuntime::wait_ready: stage 2 timeout after {}s (vsock listener \
                     never came up at port {CONTROL_WIRE_VSOCK_PORT})",
                    timeout.as_secs()
                ));
            }
            // Cap per-probe budget at 1s so we don't burn the whole
            // remaining timeout in a single connect attempt that hits
            // VFR-internal slow paths.
            let probe_timeout = remaining.min(Duration::from_secs(1));
            let connect_result = {
                let guard = self
                    .vm
                    .lock()
                    .map_err(|e| format!("vm lock poisoned: {e}"))?;
                let vm = match guard.as_ref() {
                    Some(h) => &h.0,
                    None => {
                        return Err(
                            "VzRuntime::wait_ready: VM stopped during stage 2".into(),
                        );
                    }
                };
                crate::transport_macos::connect_to_vm_vsock(
                    vm,
                    CONTROL_WIRE_VSOCK_PORT,
                    probe_timeout,
                )
            };
            match connect_result {
                Ok(_vsock_fd) => {
                    // Drop immediately — the probe is success-on-connect.
                    // Hello/HelloAck handshake is the host-shell's job.
                    return Ok(());
                }
                Err(crate::transport_macos::ConnectError::NoSocketDevice)
                | Err(crate::transport_macos::ConnectError::UnexpectedSocketDeviceKind) => {
                    // Structural config error — no point retrying.
                    return Err(format!(
                        "VzRuntime::wait_ready: VM config missing virtio-vsock device"
                    ));
                }
                Err(_transient) => {
                    // Timeout / VzError / NullConnection — keep retrying.
                    let wait_ms = backoff_ms[step.min(backoff_ms.len() - 1)];
                    step = step.saturating_add(1);
                    boot::pump_cf_loop_for(Duration::from_millis(wait_ms));
                }
            }
        }
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
        assert!(
            rt.is_provisioned(),
            "all three artifacts make it provisioned"
        );
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

    /// `VzRuntime` must be `Send + Sync` to satisfy the `VmRuntime` trait
    /// bound. This compile-time check ensures the `VmHandle` Send/Sync
    /// `unsafe impl` (vm_handle module) keeps the struct portable across
    /// async runtimes.
    ///
    /// @trace spec:vm-idiomatic-layer
    #[test]
    fn vz_runtime_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<VzRuntime>();
    }

    /// `VzRuntime::stop` and `wait_ready` must surface a clear error when
    /// called before `start()` populated the handle slot.
    ///
    /// @trace spec:vm-idiomatic-layer
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn vz_stop_and_wait_ready_fail_clean_before_start() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(42, tmp.path().to_path_buf());

        let stop_err = rt
            .stop(Duration::from_secs(1))
            .await
            .expect_err("stop without start must fail");
        assert!(
            stop_err.contains("VM not running"),
            "unexpected stop error: {stop_err}"
        );

        let wait_err = rt
            .wait_ready(Duration::from_secs(1))
            .await
            .expect_err("wait_ready without start must fail");
        assert!(
            wait_err.contains("VM not running"),
            "unexpected wait_ready error: {wait_err}"
        );
    }

    /// `VzRuntime::exec` is explicitly deferred to Phase 5; returns a clear
    /// "deferred" message rather than `unimplemented!()` so callers don't
    /// silently panic.
    ///
    /// @trace spec:vm-idiomatic-layer
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn vz_exec_returns_phase5_deferral() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(42, tmp.path().to_path_buf());
        let err = rt
            .exec(&["/bin/true"])
            .await
            .expect_err("exec should not silently succeed in Phase 1");
        assert!(err.contains("Phase 5"), "unexpected exec error: {err}");
    }

    /// `VzRuntime::start` must surface a clear error when rootfs.img is
    /// missing — Phase 4 will materialize it via the recipe, but until then
    /// the spike/test path expects the caller to point at a pre-built image.
    ///
    /// @trace spec:vm-idiomatic-layer, spec:vm-provisioning-lifecycle
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn vz_start_fails_clean_when_rootfs_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(42, tmp.path().to_path_buf());
        let err = rt
            .start()
            .await
            .expect_err("start without rootfs.img must fail");
        assert!(
            err.contains("rootfs not found"),
            "unexpected error message: {err}"
        );
    }
}
