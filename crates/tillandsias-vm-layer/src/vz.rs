//! macOS Virtualization.framework backend for the VM runtime.
//!
//! Uses `objc2-virtualization` to construct a `VZVirtualMachineConfiguration`
//! with virtio-fs (for `~/src/` passthrough), virtio-vsock (for the control
//! wire), and a virtio-console for early-boot diagnostics. Boots a Fedora
//! guest from a raw disk image.
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
use std::io;
#[cfg(target_os = "macos")]
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitStatus;
use std::time::Duration;

use crate::{ProvisionManifest, VmError, VmRuntime};

#[cfg(target_os = "macos")]
const GUEST_TRANSPORT_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

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
    /// When true, `start()` routes the guest serial console (early-boot getty +
    /// kernel) to `console.log` instead of the host process stderr. Headless CLI
    /// modes (`--exec-guest`, `--github-login`) set this so the getty's terminal
    /// probe escapes don't spill onto the user's terminal; the tray leaves it
    /// false (serial on stderr for live diagnostics).
    serial_to_log: std::sync::atomic::AtomicBool,
}

#[cfg(target_os = "macos")]
impl Drop for VzRuntime {
    fn drop(&mut self) {
        let cidata_path = self.image_root.join("cidata.iso");
        if cidata_path.exists() {
            let _ = std::fs::remove_file(&cidata_path);
        }
    }
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
    use objc2_foundation::NSError;
    use objc2_virtualization::VZVirtualMachine;

    pub(crate) struct VmHandle(pub Retained<VZVirtualMachine>);

    impl VmHandle {
        pub(crate) fn start_and_report(self, tx: std::sync::mpsc::Sender<Result<(), String>>) {
            let handler = block2::RcBlock::new(move |err: *mut NSError| {
                let result = if err.is_null() {
                    Ok(())
                } else {
                    Err(unsafe { (*err).localizedDescription() }.to_string())
                };
                let _ = tx.send(result);
            });
            unsafe { self.0.startWithCompletionHandler(&handler) };
        }
    }

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
            serial_to_log: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Route the guest serial console to `console.log` instead of host stderr on
    /// the next `start()`. Used by headless CLI modes to keep the user's
    /// terminal free of the guest getty's terminal-probe escape sequences.
    pub fn set_serial_to_log(&self, enabled: bool) {
        self.serial_to_log
            .store(enabled, std::sync::atomic::Ordering::Relaxed);
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

    /// Largest `console.log` we keep before rotating (690-cb62).
    ///
    /// Chosen against the measured growth rate — ~680 bytes per VM start on
    /// this host — so a cap of 4 MiB holds on the order of six thousand boots
    /// of history before anything is displaced. Generous enough that the log
    /// stays useful for debugging a boot problem, bounded enough that it can
    /// never grow without limit on a long-lived install.
    const CONSOLE_LOG_MAX_BYTES: u64 = 4 * 1024 * 1024;

    /// RETENTION POLICY, stated where the file is opened (690-cb62): at most
    /// TWO generations — `console.log` and `console.log.prev` — each bounded by
    /// [`Self::CONSOLE_LOG_MAX_BYTES`], so total on-disk is bounded by twice
    /// that.
    ///
    /// Rotation rather than truncation: a boot problem is usually diagnosed
    /// from the boot BEFORE the one that failed to come up, and truncating in
    /// place would discard exactly that. Rotating keeps a full previous
    /// generation intact.
    ///
    /// Best-effort by construction — this runs on the VM start path, and a
    /// logging-hygiene failure must never prevent a VM from booting. Every
    /// error is swallowed deliberately; the worst case is the pre-690-cb62
    /// behaviour of an unbounded file.
    fn rotate_console_log_if_oversized(path: &std::path::Path) {
        let Ok(md) = std::fs::metadata(path) else {
            return; // absent (first boot) — nothing to rotate
        };
        if md.len() <= Self::CONSOLE_LOG_MAX_BYTES {
            return;
        }
        let prev = path.with_extension("log.prev");
        let _ = std::fs::rename(path, &prev);
    }

    /// Path of the early-boot serial console log.
    pub fn console_log_path(&self) -> PathBuf {
        self.image_root.join("console.log")
    }

    /// True if a previous provisioning has produced the disk image. Used by
    /// `provision` for the idempotency short-circuit.
    pub fn is_provisioned(&self) -> bool {
        self.rootfs_image_path().exists()
    }

    /// Intentional EPHEMERAL RESET, macOS wipe half (windows-260717-4):
    /// delete the provisioned boot artifacts — `rootfs.img` (the guest disk,
    /// and with it the in-VM vault), `vmlinuz`, `initramfs.img` — plus the
    /// best-effort byproducts (`rootfs.qcow2` fetch intermediate,
    /// `console.log`, `cidata.iso`), so `is_provisioned()` flips false and
    /// the next boot takes the exact same first-provision path a fresh
    /// install does. Destructive BY DESIGN per the operator's ephemeral
    /// doctrine: state of value lives in the cloud + the operator's auth,
    /// so the only cost is one re-authentication.
    ///
    /// Callers MUST stop any running VM first (`VmRuntime::stop`); this
    /// method only touches the filesystem. Deliberately file-targeted — it
    /// never removes `image_root` itself, so unrelated per-installation
    /// state living beside the artifacts (e.g. `crashloop.state`) survives
    /// for its owner to manage. Missing artifacts are fine (a half-wiped or
    /// never-provisioned root resets to the same clean outcome); only a
    /// real deletion failure on a present required artifact errors.
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    pub fn wipe_provisioned_artifacts(&self) -> std::io::Result<()> {
        for required in [
            self.rootfs_image_path(),
            self.kernel_path(),
            self.initrd_path(),
        ] {
            match std::fs::remove_file(&required) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }
        for best_effort in [
            self.rootfs_image_path().with_extension("qcow2"),
            self.console_log_path(),
            self.image_root.join("cidata.iso"),
        ] {
            let _ = std::fs::remove_file(&best_effort);
        }
        Ok(())
    }

    /// Fetch Fedora's official Cloud qcow2 image and convert it to the
    /// raw disk image Virtualization.framework boots.
    ///
    /// @trace plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md
    ///        m9/vz-boot-via-fedora-cloud-image
    #[cfg(all(feature = "recipe", feature = "download"))]
    pub async fn fetch_fedora_cloud_image(
        &self,
        manifest: &crate::recipe::Manifest,
        on_phase: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<(), String> {
        use crate::fetch::{RemoteArtifact, download_verified};

        let arch = if cfg!(target_arch = "aarch64") {
            "aarch64"
        } else {
            "x86_64"
        };
        let format = "qcow2";
        let key = format!("{arch}.{format}");
        let url = manifest
            .artifact_url(arch, format, "fedora-44")
            .ok_or_else(|| {
                format!("manifest has no [output].artifact_url_template; cannot resolve {key} URL")
            })?;
        let sha256 = manifest
            .expected_sha(&key)
            .ok_or_else(|| {
                format!(
                    "manifest [output.expected_rootfs_sha] missing key {key:?}; \
                     cannot verify Fedora Cloud image"
                )
            })?
            .to_string();

        if let Some(parent) = self.rootfs_image_path().parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }

        let qcow2_dest = self.rootfs_image_path().with_extension("qcow2");
        let artifact = RemoteArtifact {
            url,
            sha256,
            bytes: None,
        };
        on_phase("Downloading Fedora Cloud image");
        // Throttle to integer-percent changes. `download_verified` invokes this
        // callback per chunk (~100x per MB), so emitting unconditionally spammed
        // ~64k identical "N/528 MB (P%)" phase lines for one 528 MB download
        // (see plan: macos-tray/provision-progress-log-spam). Mirror the rootfs
        // path's `last_percent` throttle. The callback bound is `Fn + Send +
        // Sync`, so use an atomic (Cell is not Sync).
        let last_percent = std::sync::atomic::AtomicI32::new(-1);
        download_verified(&artifact, &qcow2_dest, &|downloaded, total| {
            if let Some(total_bytes) = total {
                let percent = ((downloaded * 100) / total_bytes.max(1)) as i32;
                if last_percent.swap(percent, std::sync::atomic::Ordering::Relaxed) != percent {
                    on_phase(&format!(
                        "Downloading Fedora Cloud image {}/{} MB ({}%)",
                        downloaded / 1_000_000,
                        total_bytes / 1_000_000,
                        percent
                    ));
                }
            }
        })
        .await
        .map_err(|e| e.to_string())?;

        convert_qcow2_to_raw(&qcow2_dest, &self.rootfs_image_path(), on_phase)
    }

    /// Fetch the recipe-published rootfs artifact (per l9 URL contract)
    /// and verify it against the manifest's pinned SHA-256, writing
    /// the verified bytes to `self.rootfs_image_path()`. The macOS
    /// tray calls this on first launch (and on any subsequent launch
    /// where the image is absent) before `start()`.
    ///
    /// Arch is picked from `cfg!(target_arch = ...)` — Apple Silicon
    /// gets `aarch64`, the (currently absent) Intel-Mac path would
    /// get `x86_64`. Format is `"img"` for macOS since VFR boots a
    /// raw EFI+ext4 disk image directly (Windows uses `"tar"` via
    /// `wsl --import`).
    ///
    /// `tag` is the release tag (e.g. `"v0.2.260526.3"`) the caller
    /// resolved from `CARGO_PKG_VERSION` or an explicit
    /// `--release-tag` flag. Substituted into the manifest's
    /// `[output].artifact_url_template`.
    ///
    /// Fails fast (without touching the network) if the manifest has
    /// no `artifact_url_template`, no `expected_rootfs_sha` for the
    /// chosen `<arch>.<format>` key, or the SHA-256 isn't a valid
    /// 64-char hex string (which is how `download_verified` refuses
    /// the placeholder `"pending-ci"` value until real CI publishes
    /// pinned SHAs).
    ///
    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md
    ///        l9 (artifact URL + SHA contract),
    ///        plan/steps/20-macos-tray-v0_0_1.md (m5/vfr-image-via-ci-rootfs)
    #[cfg(all(feature = "recipe", feature = "download"))]
    pub async fn fetch_recipe_artifact(
        &self,
        manifest: &crate::recipe::Manifest,
        tag: &str,
        on_phase: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<(), String> {
        let arch = if cfg!(target_arch = "aarch64") {
            "aarch64"
        } else {
            "x86_64"
        };
        let format = "img";
        let key = format!("{arch}.{format}");

        let base_url = manifest.artifact_url(arch, format, tag).ok_or_else(|| {
            format!("manifest has no [output].artifact_url_template; cannot resolve {key} URL")
        })?;

        let sha256 = manifest
            .expected_sha(&key)
            .ok_or_else(|| {
                format!(
                    "manifest [output.expected_rootfs_sha] missing key {key:?}; \
                 was the recipe-publish CI job run yet?"
                )
            })?
            .to_string();

        // Ensure image_root exists; the helpers below write the dest
        // path directly and won't create parent dirs.
        if let Some(parent) = self.rootfs_image_path().parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }

        // Format-specific dispatch. The raw .img is ~8 GB sparse,
        // exceeding GitHub's 2 GiB release-asset limit, so CI publishes
        // it xz-compressed (.img.xz, ~74 MB). The manifest's pinned SHA
        // is the DECOMPRESSED bytes — the bytes VFR actually boots —
        // so we fetch the .xz unverified, decompress, then sha-verify.
        // .tar artifacts (Windows path) are published raw and verified
        // at download time via `download_verified`.
        if format == "img" {
            let xz_url = format!("{base_url}.xz");
            let xz_dest = self.rootfs_image_path().with_extension("img.xz.partial");
            fetch_then_decompress_xz_then_verify(
                &xz_url,
                &xz_dest,
                &self.rootfs_image_path(),
                &sha256,
                on_phase,
            )
            .await
        } else {
            use crate::fetch::{RemoteArtifact, download_verified};
            let artifact = RemoteArtifact {
                url: base_url,
                sha256,
                bytes: None,
            };
            on_phase("Downloading rootfs");
            let result = download_verified(&artifact, &self.rootfs_image_path(), &|_, _| {}).await;
            on_phase("Verifying rootfs SHA-256");
            result
        }
    }

    /// Open a host-side vsock stream to the running VM on `port`. Returns
    /// an error if the VM hasn't been started (no handle in the slot) or
    /// if VZ's connect path fails.
    ///
    /// Async wrapper around the blocking `connect_to_vm_vsock` (which
    /// must pump the CFRunLoop for VZ's completion handler). We spawn it
    /// on a blocking-friendly Tokio worker so the calling task isn't
    /// blocked. The returned `VsockStream` is `AsyncRead + AsyncWrite`
    /// and ready to hand to `pty_vsock_bridge::spawn_pty_bridge` in the
    /// macOS tray.
    ///
    /// @trace spec:vsock-transport, spec:macos-native-tray,
    ///        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c)
    #[cfg(target_os = "macos")]
    pub async fn open_vsock_stream(
        &self,
        port: u32,
        timeout: std::time::Duration,
    ) -> Result<crate::transport_macos::VsockStream, OpenVsockError> {
        // Take a clone of the existing VmHandle so we can use it from
        // the spawn_blocking thread without holding the mutex. The
        // module-level `vm_handle::VmHandle` already wraps the
        // Retained<VZVirtualMachine> with the unsafe Send+Sync impl
        // and a documented single-queue-access SAFETY rationale.
        let send_handle = {
            let slot = self
                .vm
                .lock()
                .map_err(|e| OpenVsockError::LockPoisoned(e.to_string()))?;
            let handle = slot.as_ref().ok_or(OpenVsockError::VmNotStarted)?;
            vm_handle::VmHandle(handle.0.clone())
        };

        let fd = tokio::task::spawn_blocking(move || {
            // Rust 2021 closures do per-field disjoint capture, which
            // would project send_handle.0 (the bare Retained, NOT Send)
            // instead of moving the whole VmHandle (which IS Send via
            // the unsafe impl). Forcing a borrow of the whole struct
            // disables that projection and captures the wrapper as a
            // unit. See rust-lang/rust#73214.
            let _force_full_capture = &send_handle;
            crate::transport_macos::connect_to_vm_vsock(&send_handle.0, port, timeout)
        })
        .await
        .map_err(|e| OpenVsockError::Join(e.to_string()))?
        .map_err(OpenVsockError::Connect)?;

        crate::transport_macos::VsockStream::from_vsock_fd(fd).map_err(OpenVsockError::Stream)
    }

    /// Like [`Self::open_vsock_stream`] but performs the VZ connect on the
    /// CALLING thread (no `spawn_blocking`). Use ONLY from the process main
    /// thread.
    ///
    /// VZ delivers `connectToPort:` completion on the **main dispatch queue**,
    /// which is serviced only while the main thread pumps the CFRunLoop.
    /// `connect_to_vm_vsock` pumps it internally, so a *main-thread* caller
    /// drives its own completion. `open_vsock_stream` offloads the connect to a
    /// `spawn_blocking` worker — correct for the tray (NSApp pumps the main
    /// runloop) but it hangs for a headless caller that parks the main thread in
    /// `block_on` (e.g. `--exec-guest`): the worker pumps its own runloop, the
    /// main-queue completion never fires, and the connect times out. Established
    /// socket I/O is reactor-driven (kqueue) and needs no further pumping.
    ///
    /// @trace plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
    #[cfg(target_os = "macos")]
    pub async fn open_vsock_stream_current_thread(
        &self,
        port: u32,
        timeout: std::time::Duration,
    ) -> Result<crate::transport_macos::VsockStream, OpenVsockError> {
        let handle = {
            let slot = self
                .vm
                .lock()
                .map_err(|e| OpenVsockError::LockPoisoned(e.to_string()))?;
            let h = slot.as_ref().ok_or(OpenVsockError::VmNotStarted)?;
            vm_handle::VmHandle(h.0.clone())
        };
        let fd = crate::transport_macos::connect_to_vm_vsock(&handle.0, port, timeout)
            .map_err(OpenVsockError::Connect)?;
        crate::transport_macos::VsockStream::from_vsock_fd(fd).map_err(OpenVsockError::Stream)
    }

    /// Current-thread variant of the normalized GuestTransport stream opener.
    ///
    /// The trait-level `GuestTransport::open_stream` owns the default backend
    /// timeout. Headless macOS CLI flows (`--diagnose`, `--exec-guest`,
    /// `--github-login`) need per-attempt timeouts while pumping the process
    /// main thread, so they use this endpoint-shaped helper instead of reaching
    /// down to raw `VsockStream` construction.
    ///
    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    pub async fn open_guest_transport_stream_current_thread(
        &self,
        ep: &tillandsias_control_wire::guest_transport::GuestEndpoint,
        timeout: std::time::Duration,
    ) -> io::Result<Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>>
    {
        let port = macvz_port(ep)?;
        let stream = self
            .open_vsock_stream_current_thread(port, timeout)
            .await
            .map_err(macvz_io_error)?;
        Ok(Box::new(stream))
    }

    /// Generate a `cidata.iso` image using `hdiutil makehybrid`.
    #[cfg(target_os = "macos")]
    fn generate_cidata_iso(&self, dest: &Path) -> Result<(), String> {
        let temp_dir = self.image_root.join("cidata_tmp");
        if temp_dir.exists() {
            let _ = std::fs::remove_dir_all(&temp_dir);
        }
        std::fs::create_dir_all(&temp_dir)
            .map_err(|e| format!("failed to create cidata temp dir: {e}"))?;
        let secure_control_wire = match std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE") {
            Ok(value) if value.eq_ignore_ascii_case("on") => "on",
            _ => "off",
        };
        let guest_binary_fingerprint = guest_binary_fingerprint().unwrap_or_else(|err| {
            eprintln!("[vz] guest binary fingerprint unavailable: {err}");
            "missing".to_string()
        });

        // 1. Write user-data
        let user_data_content = provision_user_data(secure_control_wire);

        std::fs::write(temp_dir.join("user-data"), user_data_content)
            .map_err(|e| format!("failed to write user-data: {e}"))?;

        // 2. Write meta-data
        let meta_data_content = format!(
            "instance-id: tillandsias-vm-secure-{secure_control_wire}-{guest_binary_fingerprint}\n\
local-hostname: tillandsias-vm
"
        );

        std::fs::write(temp_dir.join("meta-data"), meta_data_content)
            .map_err(|e| format!("failed to write meta-data: {e}"))?;

        // 3. run hdiutil makehybrid -o <dest> -joliet -iso -default-volume-name CIDATA <temp_dir>
        if dest.exists() {
            let _ = std::fs::remove_file(dest);
        }

        let output = std::process::Command::new("hdiutil")
            .arg("makehybrid")
            .arg("-o")
            .arg(dest)
            .arg("-joliet")
            .arg("-iso")
            .arg("-default-volume-name")
            .arg("CIDATA")
            .arg(&temp_dir)
            .output()
            .map_err(|e| format!("failed to run hdiutil: {e}"))?;

        // Clean up temp dir
        let _ = std::fs::remove_dir_all(&temp_dir);

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("hdiutil failed: {stderr}"));
        }

        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn home_src_dir() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("src")
}

/// Host-side home for the guest's model cache and ollama engine payload.
///
/// DELIBERATELY OUTSIDE `image_root()`. On macOS the install, data and config
/// directories all collapse onto `~/Library/Application Support/tillandsias`,
/// which IS the VM directory (order 804-bpke found `uninstall.sh` deleting
/// 11.83 GiB of it while printing "Cache preserved"). Anything stored there —
/// or inside `rootfs.img`, which lives there — dies with the VM. `~/Library/
/// Caches` is the idiomatic macOS home for large, re-downloadable state and is
/// untouched by `--reset-guest` and by any rootfs rebuild, which are the
/// frequent operations. A deliberate full-wipe e2e still clears it, and that
/// is correct: that flow is asking for a from-scratch install.
///
/// What lives here is ~2.47 GB at the CURRENT model size — a 1.44 GiB ollama
/// arm64 engine, a 379 MiB qwen2.5:0.5b blob, and the `.tools` payload whose
/// absence makes `/api/version` answer while every `/api/generate` returns
/// HTTP 500 (the order-406 root cause).
///
/// @trace order:804-deux, order:804-bpke
#[cfg(target_os = "macos")]
/// The cloud-init `user-data` provisioning script for the macOS VZ guest.
///
/// Hoisted out of `provision` (order 740-3k4s) so the units it installs can be
/// asserted by a test WITHOUT booting a VM. The readiness work this packet adds
/// is about not trusting signals nobody verified; a systemd unit that only ever
/// gets read by a human is one of those signals.
fn provision_user_data(secure_control_wire: &str) -> String {
    r#"#!/bin/bash
set -euo pipefail

# Order 272 (guest-ssh-backdoor-closure): the secure control wire is the
# ONLY host<->guest channel. No SSH keys are injected, and every sshd
# surface is masked — the NAT-reachable daemon AND the AF_VSOCK socket
# systemd-ssh-generator would auto-create (the 'ssh vsock%3' boot-banner
# hint). The Tlatoani's isolation directive, 2026-07-10: host and guest
# never share a trusted network; the guest is fully isolated.
systemctl disable --now sshd.service sshd.socket 2>/dev/null || true
systemctl mask sshd.service sshd.socket 2>/dev/null || true
systemctl mask sshd-vsock.socket sshd-unix-local.socket 2>/dev/null || true
mkdir -p /etc/systemd/system-generators
ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator

# Install podman + dependencies for the enclave
echo "Waiting for network..."
until curl -sI https://mirrors.fedoraproject.org >/dev/null 2>&1; do
  echo "Still waiting for network..."
  sleep 1
done

# socat is the readiness probe's only external dependency (order 740-3k4s).
#
# MEASURED, and the reason this line exists: the packet recorded "socat ships
# in the Fedora guest image built WITH_VSOCK; no new dependency is needed".
# That is true of the WINDOWS image and NOT of this one -- the VZ guest is
# plain Fedora Cloud, and the first loaded run of the probe here reported
# `socat: No such file or directory`. Inherited claims about a sibling
# platform's image are not evidence about this one.
dnf install -y podman socat
systemctl enable podman.socket
systemctl start podman.socket

# Mount host ~/src via virtio-fs when the VZ config provides the home-src tag.
# PERSISTED via /etc/fstab (2026-07-10 attended-smoke finding): cloud-init
# runs first boot only, so a mount issued here evaporates on every
# subsequent boot — the guest then scans an empty /home/forge/src
# (EnumerateLocalProjects returns []) and fetch-headless.sh can't see the
# staged guest binary. nofail keeps boots green when the VZ config omits
# the share.
mkdir -p /home/forge/src
if ! grep -q "^home-src " /etc/fstab; then
  echo "home-src /home/forge/src virtiofs nofail 0 0" >> /etc/fstab
fi
if ! mountpoint -q /home/forge/src; then
  mount -t virtiofs home-src /home/forge/src || true
fi

# Mount the host-backed model cache (order 804-deux). Same fstab reasoning as
# home-src above. This is the path the inference container binds as
# /home/ollama/.ollama/models, and it holds BOTH the model blobs and the
# `.tools` engine payload (llama-server, libggml, libllama) — without which
# /api/version answers while every /api/generate returns HTTP 500, which was
# the order-406 root cause.
#
# Living on a host share rather than inside rootfs.img is the entire point:
# before this, every VM-directory deletion forced a ~2.47 GB re-download, and
# the Metal lane exists to justify models far larger than the 379 MiB one that
# floor assumes. nofail keeps boots green on a tray that predates the share.
mkdir -p /root/.cache/tillandsias/models
if ! grep -q "^model-cache " /etc/fstab; then
  echo "model-cache /root/.cache/tillandsias/models virtiofs nofail 0 0" >> /etc/fstab
fi
if ! mountpoint -q /root/.cache/tillandsias/models; then
  mount -t virtiofs model-cache /root/.cache/tillandsias/models || true
fi

# Create directory
mkdir -p /usr/local/lib/tillandsias

# Write fetch-headless.sh
cat > /usr/local/lib/tillandsias/fetch-headless.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
STAGED="/home/forge/src/.tillandsias/guest-bin/tillandsias-headless"
if [[ -x "$STAGED" ]]; then
  install -D -m 0755 "$STAGED" "$DEST"
  exit 0
fi
# 701-iu9b TRAP 1. Say WHY the staged binary was not used, and distinguish the
# two causes — they call for opposite responses and used to be indistinguishable
# because this path printed nothing at all.
#
# `findmnt` rather than `mountpoint`: findmnt is verified present in this guest
# (used to read the share during the 2026-08-18 instrumented boot), and under
# `set -euo pipefail` a MISSING mountpoint binary would make `! mountpoint -q`
# succeed and report "not mounted" for a share that is fine.
if ! findmnt -n /home/forge/src >/dev/null 2>&1; then
  echo "[tillandsias-fetch] staged_binary=unreachable reason=share-not-mounted path=$STAGED" >&2
  echo "[tillandsias-fetch]   /home/forge/src is not mounted yet, so the host-staged binary is invisible to this unit." >&2
else
  echo "[tillandsias-fetch] staged_binary=absent path=$STAGED" >&2
fi
if [[ -x "$DEST" ]]; then
  echo "[tillandsias-fetch] keeping the EXISTING $DEST — it may be OLDER than what the host staged (701-iu9b)." >&2
  exit 0
fi
ARCH="$(uname -m)"
URL="https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-headless-${ARCH}-unknown-linux-musl"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 --output "$TMP" "$URL"
install -D -m 0755 "$TMP" "$DEST"
EOF
chmod 0755 /usr/local/lib/tillandsias/fetch-headless.sh

# Write headless-preflight.sh
cat > /usr/local/lib/tillandsias/headless-preflight.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
if [[ ! -x "$DEST" ]]; then
  echo "[tillandsias-preflight] headless_binary=missing"
  exit 1
fi
echo "[tillandsias-preflight] headless_binary=ok"
if [[ ! -e /dev/vsock ]]; then
  echo "[tillandsias-preflight] vsock_device=missing"
  exit 1
fi
echo "[tillandsias-preflight] vsock_device=present"
if [[ -S /run/podman/podman.sock ]]; then
  echo "[tillandsias-preflight] podman_socket=present"
else
  echo "[tillandsias-preflight] podman_socket=missing"
fi
if systemctl is-active --quiet podman.socket; then
  echo "[tillandsias-preflight] podman_socket_unit=active"
else
  echo "[tillandsias-preflight] podman_socket_unit=inactive"
fi
EOF
chmod 0755 /usr/local/lib/tillandsias/headless-preflight.sh

# Write tillandsias-headless-fetch.service
cat > /etc/systemd/system/tillandsias-headless-fetch.service << 'EOF'
[Unit]
Description=Ensure tillandsias-headless is present
After=network-online.target
Wants=network-online.target
After=home-forge-src.mount
Before=tillandsias-headless.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=/root
ExecStart=/usr/local/lib/tillandsias/fetch-headless.sh
TimeoutStartSec=300s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
EOF

# Write tillandsias-headless.service
cat > /etc/systemd/system/tillandsias-headless.service << 'EOF'
[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target podman.socket tillandsias-headless-fetch.service
Wants=network-online.target podman.socket
Requires=tillandsias-headless-fetch.service
# Bound the restart loop (735-ewzp): a daemon that can never start should end
# in `failed`, loudly and once, not restart every two seconds forever. These
# two directives belong to the unit section, NOT the service section -- systemd
# silently ignores them in the latter, which is the same
# looks-configured-does-nothing shape 740-3k4s exists to remove. The section
# names are spelled out here rather than bracketed on purpose: a bracketed
# token in a comment is indistinguishable from a real section header to the
# scans that check this file, and the windows unit was bitten by exactly that
# (601-462g).
StartLimitIntervalSec=120
StartLimitBurst=3
[Service]
Type=exec
ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh
Environment=HOME=/root
# XDG_RUNTIME_DIR must match the value the tray's control-wire exec preamble
# exports for guest login/satisfier processes (macos-tray diagnose.rs github
# login lane). The order-232 per-resource flocks live under
# $XDG_RUNTIME_DIR/tillandsias-locks; if this unit leaves the variable unset,
# resource_lock::lock_dir() falls back to /tmp/tillandsias-locks-0 while the
# exec'd satisfier locks under /run/user/0/tillandsias-locks — two disjoint
# lock namespaces, and the vault name-in-use race (order 259) reproduces on
# every fresh-VM first login. Verified live 2026-07-09 on macOS.
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
Environment=TILLANDSIAS_SECURE_CONTROL_WIRE=__SECURE_CONTROL_WIRE__
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
EOF

# Write headless-ready.sh -- the BOUND-LISTENER assertion (order 740-3k4s).
#
# Everything above this point tests proxies. `headless-preflight.sh` reports
# `vsock_device=present` from /dev/vsock, which vsock_loopback alone provides;
# systemd reports `active (running)` from a process that is alive. 735-ewzp
# found a guest where both were green, `--listen-vsock 42420` was on the
# command line, and NOTHING WAS BOUND -- the host saw a seven-and-a-half minute
# timeout. This connects to the port and sees whether anything accepts.
cat > /usr/local/lib/tillandsias/headless-ready.sh << 'READYEOF'
__READY_SCRIPT__
READYEOF
chmod 0755 /usr/local/lib/tillandsias/headless-ready.sh

# The probe reaches CID 1 (VMADDR_CID_LOCAL), which needs vsock_loopback. Load
# it and SAY which way it went: `modprobe` alone can no-op on a kernel that
# lacks the module and leave a silent gap for the probe to find minutes later.
# An unavailable module does NOT fail provisioning -- the host wire does not use
# loopback, so the honest verdict is the probe's INDETERMINATE, not a dead VM.
__VSOCK_LOOPBACK_SNIPPET__

# Write tillandsias-headless-ready.service -- deliberately its OWN oneshot unit
# and NOT an ExecStartPost on the daemon (order 757-4hdt). As an ExecStartPost
# this same script stopped a healthy daemon on every cold boot: a control
# process that fails there STOPS the service it was measuring, and
# Restart=on-failure then began the same minutes-long work again. A probe that
# can kill the process it measures is not a check. Failing here leaves the
# daemon untouched and still shows up in `systemctl --failed` and the journal.
cat > /etc/systemd/system/tillandsias-headless-ready.service << 'EOF'
__READY_UNIT__EOF

# Reload and enable services
systemctl daemon-reload
systemctl enable tillandsias-headless-fetch.service tillandsias-headless.service tillandsias-headless-ready.service
systemctl start tillandsias-headless-fetch.service tillandsias-headless.service
# Started last and NOT waited on: it is an assertion about the daemon, so it
# must not gate the provisioning that produced the daemon.
systemctl start --no-block tillandsias-headless-ready.service
"#
    .replace("__SECURE_CONTROL_WIRE__", secure_control_wire)
    .replace("__READY_SCRIPT__", crate::readiness::READY_SCRIPT)
    .replace(
        "__VSOCK_LOOPBACK_SNIPPET__",
        crate::readiness::vsock_loopback_provision_snippet(),
    )
    .replace("__READY_UNIT__", &crate::readiness::ready_unit(42420))
}

#[cfg(test)]
pub(crate) fn provision_user_data_for_test() -> String {
    provision_user_data("off")
}

fn model_cache_dir() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("Library/Caches/tillandsias/models")
}

/// Guest floor — never allocate less than the 689-eux9 pinned policy gave.
/// A 4 GiB / 4 vCPU guest is what every macOS host ran until 919-jii2, so a
/// host too small for the headroom policy keeps exactly the behaviour it had
/// rather than being handed a guest smaller than any previously shipped.
const GUEST_FLOOR_MEMORY_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const GUEST_FLOOR_CPU_COUNT: usize = 4;

/// RAM left to the host: macOS itself, the tray, WindowServer, and whatever the
/// operator is actually doing on the machine they are also running a forge on.
/// A VM that boots by swapping its host is worse than a smaller VM.
const HOST_RESERVED_MEMORY_BYTES: u64 = 6 * 1024 * 1024 * 1024;

/// Above this the fraction stops buying anything a forge uses — a 7B model plus
/// the container stack fits many times over — and the unused pages are better
/// left to the host.
const GUEST_MAX_MEMORY_BYTES: u64 = 32 * 1024 * 1024 * 1024;

fn host_logical_cores() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
}

/// Host physical RAM in bytes, via `sysctl hw.memsize`.
///
/// On failure this returns 8 GiB rather than 0: 0 would drive `guest_sizing`
/// to the floor, which is the correct SHAPE of the fallback, and 8 GiB reaches
/// the same floor while keeping the reported number plausible in the log line.
/// Read once per VM start, not per frame, so a subprocess is the right cost for
/// avoiding a `libc`/`sysctlbyname` dependency in this crate.
#[cfg(target_os = "macos")]
fn host_memory_bytes() -> u64 {
    std::process::Command::new("/usr/sbin/sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(8 * 1024 * 1024 * 1024)
}

/// Host-headroom-aware guest sizing — a PURE function of the host's shape, so a
/// measurement taken on any host is reproducible from the two numbers it names
/// (798-q4m9 / 807-bjjv comparability, preserved without re-pinning the size).
///
/// MEMORY: half the host, less whatever `HOST_RESERVED_MEMORY_BYTES` demands,
/// clamped into `[GUEST_FLOOR_MEMORY_BYTES, GUEST_MAX_MEMORY_BYTES]` and
/// rounded down to a whole GiB. On the 16 GiB M5 of 919-jii2 that is 8 GiB —
/// the allocation the packet asks for, reached by policy rather than hardcoded.
///
/// CPU: 80% of logical cores, never below the 4 the pinned policy gave (or the
/// host's core count if it has fewer than 4). On a 10-core host that is 8.
fn guest_sizing(host_cores: usize, host_memory: u64) -> (usize, u64) {
    let half = host_memory / 2;
    let after_reserve = host_memory.saturating_sub(HOST_RESERVED_MEMORY_BYTES);
    let memory = half
        .min(after_reserve)
        .clamp(GUEST_FLOOR_MEMORY_BYTES, GUEST_MAX_MEMORY_BYTES);
    let memory = memory / (1024 * 1024 * 1024) * (1024 * 1024 * 1024);

    let scaled = host_cores * 8 / 10;
    let floor = GUEST_FLOOR_CPU_COUNT.min(host_cores.max(1));
    let cpus = scaled.max(floor).max(1);
    (cpus, memory)
}

#[cfg(target_os = "macos")]
fn guest_binary_fingerprint() -> Result<String, String> {
    use sha2::{Digest, Sha256};

    let path = home_src_dir().join(".tillandsias/guest-bin/tillandsias-headless");
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("read staged guest binary {}: {e}", path.display()))?;
    let digest = Sha256::digest(&bytes);
    Ok(format!("{:x}", digest))
}

#[cfg(all(feature = "recipe", feature = "download"))]
fn convert_qcow2_to_raw(
    qcow2_path: &std::path::Path,
    raw_dest: &std::path::Path,
    on_phase: &(dyn Fn(&str) + Send + Sync),
) -> Result<(), String> {
    on_phase("Converting Fedora Cloud image");
    let raw_part = raw_dest.with_extension("img.partial");
    let status = std::process::Command::new("qemu-img")
        .arg("convert")
        .arg("-f")
        .arg("qcow2")
        .arg("-O")
        .arg("raw")
        .arg(qcow2_path)
        .arg(&raw_part)
        .status()
        .map_err(|e| {
            format!(
                "spawn qemu-img: {e} (install qemu, e.g. `brew install qemu`, to convert Fedora Cloud qcow2)"
            )
        })?;
    if !status.success() {
        let _ = std::fs::remove_file(&raw_part);
        return Err(format!("qemu-img convert failed: exit {status}"));
    }
    // Grow the raw disk before first boot. The Fedora Cloud qcow2 is a ~5 GB
    // virtual disk — nowhere near enough once the forge-base image builds its
    // full dev toolchain (558 packages: gcc, valgrind, delve, gopls, rust,
    // node, python…) on top of the base OS, podman's overlay store for every
    // enclave image, and a cloned project. Symptom before this fix
    // (2026-07-11 operator session): EVERY agent/maintenance attach opened a
    // PTY, streamed the forge-base package downloads, then died with
    // 'installing package … needs NNN MB more space on the / filesystem' →
    // 'Error: building at STEP "RUN microdnf install …"' → PtyClose code=1,
    // i.e. a blank terminal that "times out". Fedora Cloud's cloud-init
    // (cc_growpart + cc_resizefs) grows the root partition/filesystem to fill
    // the disk on first boot, so simply enlarging the raw file here is enough.
    // The raw image stays sparse, so a 64 GiB virtual disk does not consume
    // 64 GiB on the host until actually written.
    let resize = std::process::Command::new("qemu-img")
        .arg("resize")
        .arg("-f")
        .arg("raw")
        .arg(&raw_part)
        .arg(GUEST_DISK_SIZE)
        .status()
        .map_err(|e| format!("spawn qemu-img resize: {e}"))?;
    if !resize.success() {
        let _ = std::fs::remove_file(&raw_part);
        return Err(format!("qemu-img resize failed: exit {resize}"));
    }
    std::fs::rename(&raw_part, raw_dest).map_err(|e| {
        let _ = std::fs::remove_file(&raw_part);
        format!(
            "rename {} -> {}: {e}",
            raw_part.display(),
            raw_dest.display()
        )
    })?;
    on_phase("Fedora Cloud image ready");
    Ok(())
}

/// Virtual size the Fedora Cloud raw disk is grown to before first boot so
/// the forge-base toolchain + podman overlay store + project checkouts fit.
/// A string like "250G" for `qemu-img resize`. The raw image stays SPARSE,
/// so this costs no host disk until actually written — the original ~5 GB
/// disk was the hard wall every agent attach hit (2026-07-11). Generous by
/// operator direction; trim later if needed. See `convert_qcow2_to_raw`.
const GUEST_DISK_SIZE: &str = "250G";

/// Fetch the xz-compressed asset at `xz_url` to `xz_temp_dest`,
/// decompress to `final_dest` via `xz -d`, then SHA-256-verify the
/// decompressed bytes against `expected_sha`. On any failure, both
/// the temp file AND the final dest are removed so a retry starts
/// clean.
///
/// Used by [`VzRuntime::fetch_recipe_artifact`] for the `.img.xz`
/// path. Stays a free function (vs method) so future Windows/Linux
/// xz-asset paths can reuse it without touching `VzRuntime`.
///
/// macOS today; would also apply to any other host fetching a large
/// recipe-published `.img.xz`. `xz` must be on `$PATH` — the macOS
/// `.app` install path assumes it (system `/usr/bin/xz` on macOS 14+
/// or homebrew `/opt/homebrew/bin/xz`).
///
/// @trace plan/issues/tray-convergence-coordination.md
///        (linux 2026-05-27T00:20Z .img.xz note)
#[cfg(all(feature = "recipe", feature = "download"))]
async fn fetch_then_decompress_xz_then_verify(
    xz_url: &str,
    xz_temp_dest: &std::path::Path,
    final_dest: &std::path::Path,
    expected_sha: &str,
    on_phase: &(dyn Fn(&str) + Send + Sync),
) -> Result<(), String> {
    use crate::fetch::is_sha256_hex;
    use sha2::{Digest, Sha256};
    use tokio::io::AsyncReadExt;

    if !is_sha256_hex(expected_sha) {
        return Err(format!(
            "{} has no pinned SHA-256 (got {expected_sha:?}); \
             refusing to fetch unverified",
            xz_url
        ));
    }

    // Step 1: stream-download the .xz to xz_temp_dest. We can't use
    // `download_verified` here because it would expect the SHA to
    // match the .xz bytes, but the manifest SHA is for the
    // decompressed bytes.
    //
    // Byte-level progress: emit a refined "Downloading rootfs N/M MB
    // (P%)" line through on_phase, throttled by integer percent so we
    // don't spam main-thread dispatches. Matches the windows-tray
    // format introduced in commit 6645d04b — keeps the cold-launch UX
    // identical across both trays for the macOS-/Windows-specific
    // VM-spinup layer.
    on_phase("Downloading rootfs");
    {
        let mut response = reqwest::get(xz_url)
            .await
            .map_err(|e| format!("GET {xz_url}: {e}"))?;
        if !response.status().is_success() {
            return Err(format!("GET {xz_url}: HTTP {}", response.status()));
        }
        let total: Option<u64> = response.content_length();
        let mut downloaded: u64 = 0;
        let mut last_percent: i32 = -1;
        let mut out = tokio::fs::File::create(xz_temp_dest)
            .await
            .map_err(|e| format!("create {}: {e}", xz_temp_dest.display()))?;
        use tokio::io::AsyncWriteExt;
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| format!("read {xz_url}: {e}"))?
        {
            out.write_all(&chunk)
                .await
                .map_err(|e| format!("write {}: {e}", xz_temp_dest.display()))?;
            downloaded += chunk.len() as u64;
            if let Some(total_bytes) = total {
                let percent = ((downloaded * 100) / total_bytes.max(1)) as i32;
                if percent != last_percent {
                    last_percent = percent;
                    on_phase(&format!(
                        "Downloading rootfs {}/{} MB ({}%)",
                        downloaded / 1_000_000,
                        total_bytes / 1_000_000,
                        percent
                    ));
                }
            }
        }
        out.flush()
            .await
            .map_err(|e| format!("flush {}: {e}", xz_temp_dest.display()))?;
    }

    // Step 2: decompress via `xz -d -c <temp>` → final_dest.
    on_phase("Decompressing rootfs");
    let final_out = std::fs::File::create(final_dest)
        .map_err(|e| format!("create {}: {e}", final_dest.display()))?;
    let xz_status = std::process::Command::new("xz")
        .arg("-d")
        .arg("-c")
        .arg(xz_temp_dest)
        .stdout(std::process::Stdio::from(final_out))
        .stderr(std::process::Stdio::piped())
        .status()
        .map_err(|e| format!("spawn xz: {e} (is `xz` on $PATH?)"))?;
    if !xz_status.success() {
        let _ = std::fs::remove_file(final_dest);
        let _ = std::fs::remove_file(xz_temp_dest);
        return Err(format!("xz -d failed: exit {xz_status}"));
    }
    let _ = std::fs::remove_file(xz_temp_dest);

    // Step 3: SHA-256-verify the decompressed bytes against the pin.
    on_phase("Verifying rootfs SHA-256");
    let mut f = tokio::fs::File::open(final_dest)
        .await
        .map_err(|e| format!("open {}: {e}", final_dest.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f
            .read(&mut buf)
            .await
            .map_err(|e| format!("read {}: {e}", final_dest.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let actual = hasher
        .finalize()
        .iter()
        .fold(String::with_capacity(64), |mut s, b| {
            use std::fmt::Write;
            let _ = write!(s, "{b:02x}");
            s
        });
    let expected_lower = expected_sha.to_ascii_lowercase();
    if actual != expected_lower {
        let _ = std::fs::remove_file(final_dest);
        return Err(format!(
            "SHA-256 mismatch on decompressed {}: expected {expected_lower}, got {actual}",
            final_dest.display()
        ));
    }
    Ok(())
}

/// Errors returned by [`VzRuntime::open_vsock_stream`].
#[cfg(target_os = "macos")]
#[derive(Debug)]
pub enum OpenVsockError {
    /// `start()` hasn't installed a VM handle yet (or `stop()` cleared it).
    VmNotStarted,
    /// Internal Mutex was poisoned by an earlier panic.
    LockPoisoned(String),
    /// `spawn_blocking` task panicked or was cancelled.
    Join(String),
    /// VZ-level connect error (see `transport_macos::ConnectError`).
    Connect(crate::transport_macos::ConnectError),
    /// Wrapping the raw fd into `VsockStream` (fcntl/AsyncFd) failed.
    Stream(std::io::Error),
}

#[cfg(target_os = "macos")]
impl std::fmt::Display for OpenVsockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::VmNotStarted => f.write_str("VM not started (call start() first)"),
            Self::LockPoisoned(s) => write!(f, "VzRuntime vm lock poisoned: {s}"),
            Self::Join(s) => write!(f, "spawn_blocking failure: {s}"),
            Self::Connect(e) => write!(f, "{e}"),
            Self::Stream(e) => write!(f, "VsockStream wrap: {e}"),
        }
    }
}

#[cfg(target_os = "macos")]
impl std::error::Error for OpenVsockError {}

// ---------------------------------------------------------------------------
// macOS: the live VZ backend. Provisioning is the Fedora Cloud qcow2 path
// (`fetch_fedora_cloud_image` + qemu-img convert/resize); boot/exec/vsock are
// real Virtualization.framework bodies. The legacy tarball-import path and
// its `VzGuestConfig` builder were removed (order 606-r42f) — the boot spec
// is `boot::VzBootConfig`, built inline in `start()`.
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
        VZBootLoader, VZDirectoryShare, VZDirectorySharingDeviceConfiguration,
        VZDiskImageStorageDeviceAttachment, VZEFIBootLoader, VZEFIVariableStore,
        VZEFIVariableStoreInitializationOptions, VZEntropyDeviceConfiguration,
        VZFileHandleSerialPortAttachment, VZGenericPlatformConfiguration,
        VZMemoryBalloonDeviceConfiguration, VZNATNetworkDeviceAttachment,
        VZNetworkDeviceConfiguration, VZPlatformConfiguration, VZSerialPortAttachment,
        VZSerialPortConfiguration, VZSharedDirectory, VZSingleDirectoryShare,
        VZSocketDeviceConfiguration, VZStorageDeviceConfiguration,
        VZVirtioBlockDeviceConfiguration, VZVirtioConsoleDeviceSerialPortConfiguration,
        VZVirtioEntropyDeviceConfiguration, VZVirtioFileSystemDeviceConfiguration,
        VZVirtioNetworkDeviceConfiguration, VZVirtioSocketDeviceConfiguration,
        VZVirtioTraditionalMemoryBalloonDeviceConfiguration, VZVirtualMachineConfiguration,
    };

    /// One host directory exposed to the guest over virtio-fs.
    ///
    /// Before order 804-deux this layer could express exactly ONE share: the
    /// spec carried a single `Option<PathBuf>` and a single tag, and the
    /// builder installed an `NSArray` of length one. That is why the guest's
    /// model cache and ollama engine payload live inside `rootfs.img` — not
    /// because anyone chose the undurable path, but because there was no other
    /// path to choose. Every VM-directory deletion therefore costs a ~2.47 GB
    /// re-download, and the Metal lane (397/483/657-s6g8) exists to justify
    /// models much larger than the 379 MiB one that floor assumes.
    ///
    /// @trace order:804-deux, spec:vm-idiomatic-layer
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct VzShare {
        /// Host directory to expose. Must exist at boot; VZ rejects a missing
        /// source with a validation error rather than booting without it.
        pub host_dir: PathBuf,
        /// virtio-fs tag the guest mounts by (`mount -t virtiofs <tag> …`).
        /// Must be unique within one configuration.
        pub tag: String,
        /// Expose read-only. The guest's model cache must be writable; a
        /// source share may not be.
        pub read_only: bool,
    }

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
        /// Optional cloud-init CIDATA ISO path.
        pub cidata_iso: Option<PathBuf>,
        /// Host directories exposed to the guest over virtio-fs, in order.
        /// Empty installs no directory-sharing device at all — which is what
        /// `None` used to mean.
        pub shares: Vec<VzShare>,
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
                cidata_iso: None,
                shares: Vec::new(),
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
            let plat_super: &VZPlatformConfiguration = &platform;
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
            let efi_super: &VZBootLoader = &efi;
            cfg.setBootLoader(Some(efi_super));

            // Storage devices (root disk and optional cidata ISO).
            let mut storage_devices = Vec::new();

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
                storage_devices.push(Retained::cast(blk));
            }

            if let Some(path) = &spec.cidata_iso {
                let url = ns_url_for_path(path);
                let att = VZDiskImageStorageDeviceAttachment::initWithURL_readOnly_error(
                    VZDiskImageStorageDeviceAttachment::alloc(),
                    &url,
                    true,
                )
                .map_err(|e| format!("cidata attach: {}", e.localizedDescription()))?;
                let blk = VZVirtioBlockDeviceConfiguration::initWithAttachment(
                    VZVirtioBlockDeviceConfiguration::alloc(),
                    &att,
                );
                storage_devices.push(Retained::cast(blk));
            }

            if !storage_devices.is_empty() {
                let arr: Retained<NSArray<VZStorageDeviceConfiguration>> =
                    NSArray::from_id_slice(&storage_devices);
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
            let att_super: &VZSerialPortAttachment = &serial_att;
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

            // virtio-fs shares. `home-src` is mounted by cloud-init at
            // /home/forge/src before the staged headless binary is installed;
            // order 804-deux made this a LIST so the model cache and ollama
            // engine payload can live on a host path instead of inside
            // rootfs.img, where every VM-directory deletion destroys them.
            //
            // One setDirectorySharingDevices call with an N-element array —
            // VZ replaces the whole device list per call, so calling it once
            // per share would silently keep only the last one.
            if !spec.shares.is_empty() {
                let mut devices: Vec<Retained<VZDirectorySharingDeviceConfiguration>> =
                    Vec::with_capacity(spec.shares.len());
                for share_spec in &spec.shares {
                    let url = ns_url_for_path(&share_spec.host_dir);
                    let shared_dir = VZSharedDirectory::initWithURL_readOnly(
                        VZSharedDirectory::alloc(),
                        &url,
                        share_spec.read_only,
                    );
                    let share = VZSingleDirectoryShare::initWithDirectory(
                        VZSingleDirectoryShare::alloc(),
                        &shared_dir,
                    );
                    let fs = VZVirtioFileSystemDeviceConfiguration::initWithTag(
                        VZVirtioFileSystemDeviceConfiguration::alloc(),
                        &NSString::from_str(&share_spec.tag),
                    );
                    let share_super: &VZDirectoryShare = &share;
                    fs.setShare(Some(share_super));
                    devices.push(Retained::into_super(fs));
                }
                let arr_fs: Retained<NSArray<VZDirectorySharingDeviceConfiguration>> =
                    NSArray::from_id_slice(&devices);
                cfg.setDirectorySharingDevices(&arr_fs);
            }

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

    /// Schedule `f` onto libdispatch's main queue. VZ start/stop APIs assert
    /// queue affinity, while the tray calls into this runtime from worker
    /// tasks to avoid blocking AppKit.
    pub fn dispatch_to_main_queue<F>(f: F)
    where
        F: FnOnce() + Send + 'static,
    {
        unsafe extern "C" {
            static _dispatch_main_q: std::ffi::c_void;
            fn dispatch_async_f(
                queue: *const std::ffi::c_void,
                context: *mut std::ffi::c_void,
                work: extern "C" fn(*mut std::ffi::c_void),
            );
        }

        extern "C" fn trampoline<F: FnOnce()>(ctx: *mut std::ffi::c_void) {
            // SAFETY: `ctx` is created by Box::into_raw immediately below and
            // is consumed exactly once by libdispatch.
            unsafe {
                let boxed = Box::from_raw(ctx as *mut F);
                (*boxed)();
            }
        }

        let boxed: Box<F> = Box::new(f);
        let ctx = Box::into_raw(boxed) as *mut std::ffi::c_void;
        // SAFETY: `_dispatch_main_q` is libdispatch's process-wide main queue.
        unsafe {
            dispatch_async_f(
                &_dispatch_main_q as *const std::ffi::c_void,
                ctx,
                trampoline::<F>,
            );
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
            open(c"/dev/null".as_ptr(), 0 /* O_RDONLY */)
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
#[async_trait::async_trait]
impl VmRuntime for VzRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), VmError> {
        // Idempotency short-circuit per
        // vm-provisioning-lifecycle.provision.idempotency@v1.
        if self.is_provisioned() {
            return Ok(());
        }
        // The legacy tarball import path never existed on macOS: this trait
        // method used to reach two `unimplemented!` placeholders. macOS
        // provisions through `VzRuntime::fetch_fedora_cloud_image` (Fedora
        // Cloud qcow2 download + qemu-img convert/resize), driven by
        // `action_host::run_start` and `diagnose::provision_main`.
        Err("tarball provisioning is not a macOS path — provision via \
             VzRuntime::fetch_fedora_cloud_image (qcow2), as \
             action_host::run_start and diagnose::provision_main do"
            .to_string())
    }

    async fn start(&self) -> Result<(), VmError> {
        use objc2::ClassType;
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

        let cidata_iso_path = self.image_root.join("cidata.iso");
        self.generate_cidata_iso(&cidata_iso_path)?;

        // Route guest serial to console.log (headless modes) or host stderr
        // (tray, default). Opening console.log and handing its raw fd to the VZ
        // attachment keeps the getty's terminal-probe escapes off the user's
        // terminal. The fd is intentionally leaked — it lives for the VM's
        // lifetime; on open failure we fall back to stderr (None).
        let serial_writer_fd = if self
            .serial_to_log
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            use std::os::fd::IntoRawFd;
            // 690-cb62: bound the log before opening it append. Every VM start
            // appends a boot banner plus the getty's terminal-probe escapes, and
            // nothing pruned it — the only code that removed console.log was the
            // destructive reset. Measured on this host: 43 KB / 62 boots, then
            // 54 KB / 78 boots ~22 hours later, i.e. ~680 bytes per start and
            // strictly monotonic. Not urgent by volume; unbounded by design.
            Self::rotate_console_log_if_oversized(&self.console_log_path());
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.console_log_path())
                .ok()
                .map(|f| f.into_raw_fd())
        } else {
            None
        };

        // GUEST SIZING: HOST-HEADROOM-AWARE (order 919-jii2, operator decision
        // 2026-08-28), superseding the pinned 4 GiB / 4-vCPU policy of 689-eux9.
        //
        // WHY THE PIN WAS RIGHT AND IS NOW WRONG. 689-eux9 measured, on a
        // Mac17,3 / Apple M5 / 10 cores / 16 GiB, an IDLE guest at 4 GiB with
        // SWAP USED = 0, and concluded there was no pressure to relieve. That
        // measurement was honest and it still stands — for the workload it
        // measured. The workload changed: 919-jii2 records a forge running
        // local inference in which 4 GiB is not a comfort question but a
        // capability wall. Measured in-guest on that same host: qwen2.5:0.5b
        // and 1.5b load but fabricate on 6/6 spec queries, 3b has under 1 GiB
        // of headroom for OS + KV cache, and 7b — the size sibling GPU hosts
        // report as the accuracy sweet spot — cannot load at all. The pin did
        // not make the guest slow; it made a whole class of work impossible.
        //
        // WHAT REPLACES IT, AND WHAT SURVIVES. `guest_sizing` below is a pure
        // function of (host cores, host RAM), so the second pinned-policy
        // rationale — that a host-derived size makes cross-host measurements
        // incomparable (798-q4m9, 807-bjjv) — is answered without reverting:
        // a measurement names the host's cores and RAM and the size is then
        // reproducible from them, and TILLANDSIAS_VZ_CPU_COUNT_FOR_MEASUREMENT
        // still constrains the guest to a fixed vCPU count for any benchmark
        // that needs one. The floor is what keeps a small host working: the
        // policy never hands the guest less than the 4 GiB / 4 vCPU it had.
        //
        // HONEST LIMIT: the 8 GiB figure comes from model arithmetic (a 7B
        // quantized model plus OS plus the forge stack), not from a loaded
        // measurement of this guest at 8 GiB. 919-jii2's closure asks for that
        // measurement; this is the allocation it will be measured at.
        //
        // Baseline record: cheatsheets/runtime/macos-vz-guest-boot-baseline.md
        let (pinned_cpu_count, guest_memory_bytes) =
            guest_sizing(host_logical_cores(), host_memory_bytes());
        eprintln!(
            "[tillandsias-vz] guest sizing: {pinned_cpu_count} vCPU / {} GiB (host: {} cores / {} \
             GiB) — order 919-jii2 host-headroom-aware allocation",
            guest_memory_bytes / (1024 * 1024 * 1024),
            host_logical_cores(),
            host_memory_bytes() / (1024 * 1024 * 1024),
        );

        // MEASUREMENT SEAM — NOT a scaling knob (798-q4m9 criterion 3).
        //
        // Deliberately NOT read from a config file or a menu: it is unset in
        // every normal launch, and a value outside 1..=the derived count is
        // ignored rather than honoured, so it can only ever CONSTRAIN the guest
        // for a measurement — never grow it past what the host-headroom policy
        // already allowed.
        let cpu_count = std::env::var("TILLANDSIAS_VZ_CPU_COUNT_FOR_MEASUREMENT")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .filter(|n| (1..=pinned_cpu_count).contains(n))
            .inspect(|n| {
                eprintln!(
                    "[tillandsias-vz] MEASUREMENT OVERRIDE: cpu_count={n} (host-derived default is \
                     {pinned_cpu_count}). This is a 798-q4m9 measurement seam, not a supported \
                     configuration."
                );
            })
            .unwrap_or(pinned_cpu_count);

        // VZ refuses to validate a share whose source directory is missing, so
        // this must exist BEFORE the config is built — on a fresh host nothing
        // has been downloaded yet and the directory would not otherwise be
        // there. Failure is not fatal: a VM that boots without its cache share
        // is degraded (it re-downloads into rootfs.img, the old behaviour), and
        // that is strictly better than refusing to start.
        let model_cache = model_cache_dir();
        let mut shares = vec![boot::VzShare {
            host_dir: home_src_dir(),
            tag: "home-src".to_string(),
            read_only: false,
        }];
        match std::fs::create_dir_all(&model_cache) {
            Ok(()) => shares.push(boot::VzShare {
                host_dir: model_cache,
                tag: "model-cache".to_string(),
                read_only: false,
            }),
            Err(err) => eprintln!(
                "[tillandsias-vz] WARNING: could not create the model cache directory {} ({err}). \
                 Booting WITHOUT the model-cache share — models will land inside rootfs.img and \
                 will not survive a VM rebuild (order 804-deux).",
                model_cache.display()
            ),
        }

        let spec = boot::VzBootConfig {
            cpu_count,
            memory_bytes: guest_memory_bytes,
            root_disk: Some(rootfs),
            cidata_iso: Some(cidata_iso_path),
            shares,
            nvram: Some(self.image_root.join("nvram.bin")),
            serial_writer_fd,
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
        let vm_for_start = vm_handle::VmHandle(vm.clone());
        boot::dispatch_to_main_queue(move || vm_for_start.start_and_report(tx));

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
        //
        // 690-xeda recorded justification (the no-polling doctrine permits a
        // justified transient timer): this loop exists ONLY inside stop(),
        // bounded by `drain_timeout`, and contributes zero steady-state
        // wakeups — the 2026-08-16 idle measurement (3.11 -> 1.92 wakeups/s
        // after the tick-loop retirement) was taken with this code present
        // and idle. The runloop pump is load-bearing while we wait (VZ
        // delivers its state transitions and completion blocks via the
        // pumped loop), so replacing the poll means real delegate plumbing,
        // not a blocking wait — and the shutdown path is exactly where the
        // 690-xeda windows near-miss (a guest that killed itself every 30s,
        // caught only by a measurement guard) says not to rewire casually.
        // If the delegate lands, remove this justification with it.
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
        let stop_res = loop {
            // VZ state enum: 0=Stopped, 1=Running, 2=Paused, 3=Error, 4=Starting,
            // 5=Pausing, 6=Resuming, 7=Stopping, 8=Saving, 9=Restoring.
            let state = unsafe { vm.state() }.0;
            if state == 0 {
                // Stopped cleanly.
                break Ok(());
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
                break Err(format!(
                    "VzRuntime::stop: drain_timeout ({}s) expired; force-stop dispatched",
                    drain_timeout.as_secs()
                ));
            }
            boot::pump_cf_loop_for(Duration::from_millis(250));
        };

        // Explicitly drop handle to release VZ and unlock any files.
        drop(handle);

        // Clean up the cidata ISO.
        let cidata_path = self.image_root.join("cidata.iso");
        if cidata_path.exists() {
            let _ = std::fs::remove_file(&cidata_path);
        }

        stop_res
    }

    async fn exec(&self, argv: &[&str]) -> Result<ExitStatus, VmError> {
        // Non-interactive guest exec over the control wire, mirroring
        // WslRuntime::exec (`wsl --exec`) for cross-platform VmRuntime parity.
        // Route through the normalized GuestTransport facade so the macOS
        // one-shot path shares the same ExecOneShot primitive as platform
        // callers that use GuestEndpoint::MacVz directly.
        use std::os::unix::process::ExitStatusExt;
        use tillandsias_control_wire::guest_transport::{
            ExecRequest, GuestEndpoint, GuestTransport,
        };
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

        let out = <Self as GuestTransport>::exec(
            self,
            &GuestEndpoint::MacVz {
                port: CONTROL_WIRE_VSOCK_PORT,
            },
            ExecRequest::new(argv),
        )
        .await
        .map_err(|e| format!("VzRuntime::exec: {e}"))?;

        // Synthesize a Unix ExitStatus from the facade's exit-code result
        // (high byte = WEXITSTATUS).
        let raw = (out.exit_code & 0xff) << 8;
        Ok(ExitStatus::from_raw(raw))
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
                        return Err("VzRuntime::wait_ready: VM not running (start() first)".into());
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
                        return Err("VzRuntime::wait_ready: VM stopped during stage 2".into());
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
                    return Err(
                        "VzRuntime::wait_ready: VM config missing virtio-vsock device".to_string(),
                    );
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

/// Semantic readiness: wait until the in-VM headless reports `VmPhase::Ready`.
///
/// Separate `impl` block (not part of the `VmRuntime` trait) so macOS-specific
/// callers can use it directly on `VzRuntime` without touching the trait surface.
///
/// @trace plan/issues/osx-next-work-queue-2026-05-25.md#macos-tray/wait-ready-phase-signal
#[cfg(target_os = "macos")]
impl VzRuntime {
    /// Wait until the in-VM headless reports `VmPhase::Ready` (podman up,
    /// enclave network live) via a Hello/HelloAck + `VmStatusRequest` round-trip.
    ///
    /// Replaces raw-connect probe in `wait_ready` with an actual protocol check
    /// — no arbitrary wall-clock guessing. Caller stays blocked until:
    ///   - `VmPhase::Ready`  → `Ok(())`
    ///   - `VmPhase::Failed` → `Err` (headless gave up)
    ///   - `timeout` elapsed → `Err` (safety cutoff, not the primary mechanism)
    ///
    /// Requires a current-thread Tokio runtime on the macOS main thread
    /// (same constraint as `open_vsock_stream_current_thread`).
    ///
    /// `probe_once` performs one connect+probe attempt with a per-attempt
    /// timeout and returns the in-VM `VmPhase`. This crate does not depend on
    /// `tillandsias-secure-channel`, so it cannot decide Plain-vs-Secure
    /// itself — the caller supplies `probe_once` using the *same*
    /// secure-or-plain opener (`open_control_wire_stream` /
    /// `secure_control_wire_mode()`) it uses for its own user-action control
    /// wire traffic, so readiness probing never bypasses secure mode.
    /// @trace plan/issues/secure-channel-release-and-probe-hardening-2026-07-05.md
    ///
    /// `probe_once` takes only a per-attempt timeout (not `&Self`): callers
    /// close over their own `&VzRuntime` reference so the closure's returned
    /// future is a single concrete opaque type rather than one generic over
    /// an arbitrary borrow lifetime, which `rustc` cannot unify against an
    /// `FnMut(&Self, ..)` bound (async fn items don't satisfy HRTB `for<'a>
    /// Fn(&'a Self, ..) -> Fut` — the opaque future type captures the
    /// specific input lifetime it was defined with).
    pub async fn wait_phase_ready<F, Fut>(
        &self,
        timeout: Duration,
        mut probe_once: F,
    ) -> Result<(), VmError>
    where
        F: FnMut(Duration) -> Fut,
        Fut: std::future::Future<Output = Result<tillandsias_control_wire::VmPhase, String>>,
    {
        use std::time::Instant;
        use tillandsias_control_wire::VmPhase;

        // Stage 1: wait until VZ kernel is Running (same as wait_ready stage 1).
        let deadline = Instant::now() + timeout;
        let backoff_ms = [250u64, 500, 1000, 2000, 4000];
        let mut step = 0usize;
        loop {
            let state = {
                let guard = self
                    .vm
                    .lock()
                    .map_err(|e| format!("vm lock poisoned: {e}"))?;
                let vm = match guard.as_ref() {
                    Some(h) => &h.0,
                    None => {
                        return Err(
                            "VzRuntime::wait_phase_ready: VM not running (start() first)".into(),
                        );
                    }
                };
                unsafe { vm.state() }.0
            };
            if state == 1 {
                break;
            }
            if state == 3 {
                return Err(format!(
                    "VzRuntime::wait_phase_ready: VM state Error (={state})"
                ));
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "VzRuntime::wait_phase_ready: stage 1 timeout after {}s; state={state}",
                    timeout.as_secs()
                ));
            }
            let wait_ms = backoff_ms[step.min(backoff_ms.len() - 1)];
            step = step.saturating_add(1);
            boot::pump_cf_loop_for(Duration::from_millis(wait_ms));
        }

        // Stage 2: probe VmPhase over the control wire until Ready.
        // Connect → Hello/HelloAck → VmStatusRequest → VmStatusReply.
        // Retry on Starting/Provisioning (headless up but enclave not yet live).
        step = 0;
        loop {
            if Instant::now() >= deadline {
                return Err(format!(
                    "VzRuntime::wait_phase_ready: timeout after {}s (phase never reached Ready)",
                    timeout.as_secs()
                ));
            }
            match probe_once(Duration::from_secs(2)).await {
                Ok(VmPhase::Ready) => return Ok(()),
                Ok(VmPhase::Failed) => {
                    return Err("VzRuntime::wait_phase_ready: VM phase is Failed".to_string());
                }
                Ok(phase) => {
                    // Starting / Provisioning / Draining / Stopping — keep waiting.
                    let _ = phase; // phase is Debug but we don't want the dep here
                    let wait_ms = backoff_ms[step.min(backoff_ms.len() - 1)];
                    step = step.saturating_add(1);
                    boot::pump_cf_loop_for(Duration::from_millis(wait_ms));
                }
                Err(_probe_err) => {
                    // Wire error (headless just started, framing not ready) — retry.
                    let wait_ms = backoff_ms[step.min(backoff_ms.len() - 1)];
                    step = step.saturating_add(1);
                    boot::pump_cf_loop_for(Duration::from_millis(wait_ms));
                }
            }
        }
    }
}

#[cfg(target_os = "macos")]
#[async_trait::async_trait]
impl tillandsias_control_wire::guest_transport::GuestTransport for VzRuntime {
    async fn open_stream(
        &self,
        ep: &tillandsias_control_wire::guest_transport::GuestEndpoint,
    ) -> io::Result<Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>>
    {
        let port = macvz_port(ep)?;
        let stream = self
            .open_vsock_stream(port, GUEST_TRANSPORT_CONNECT_TIMEOUT)
            .await
            .map_err(macvz_io_error)?;
        Ok(Box::new(stream))
    }

    async fn exec(
        &self,
        ep: &tillandsias_control_wire::guest_transport::GuestEndpoint,
        req: tillandsias_control_wire::guest_transport::ExecRequest,
    ) -> io::Result<tillandsias_control_wire::guest_transport::ExecOutput> {
        let port = macvz_port(ep)?;
        let argv_refs: Vec<&str> = req.argv.iter().map(String::as_str).collect();
        let stdin = req.stdin.unwrap_or_default();

        let stream = self
            .open_vsock_stream(port, GUEST_TRANSPORT_CONNECT_TIMEOUT)
            .await
            .map_err(macvz_io_error)?;
        let out = crate::vsock_exec::exec_over_stream_with_input(stream, &argv_refs, &stdin)
            .await
            .map_err(io::Error::other)?;

        Ok(tillandsias_control_wire::guest_transport::ExecOutput {
            stdout: out.stdout,
            stderr: vec![],
            exit_code: guest_transport_exit_code(out.exit),
        })
    }

    async fn exec_streaming(
        &self,
        ep: &tillandsias_control_wire::guest_transport::GuestEndpoint,
        req: tillandsias_control_wire::guest_transport::ExecRequest,
        on_chunk: &mut (dyn FnMut(tillandsias_control_wire::guest_transport::ExecChunk) + Send),
    ) -> io::Result<tillandsias_control_wire::guest_transport::ExecOutput> {
        let port = macvz_port(ep)?;
        let argv_refs: Vec<&str> = req.argv.iter().map(String::as_str).collect();
        let stdin = req.stdin.unwrap_or_default();

        let stream = self
            .open_vsock_stream(port, GUEST_TRANSPORT_CONNECT_TIMEOUT)
            .await
            .map_err(macvz_io_error)?;
        let out = crate::vsock_exec::exec_over_stream_with_input_streaming(
            stream,
            &argv_refs,
            &stdin,
            |bytes: &[u8]| {
                on_chunk(
                    tillandsias_control_wire::guest_transport::ExecChunk::Stdout(bytes.to_vec()),
                )
            },
        )
        .await
        .map_err(io::Error::other)?;

        Ok(tillandsias_control_wire::guest_transport::ExecOutput {
            stdout: out.stdout,
            stderr: vec![],
            exit_code: guest_transport_exit_code(out.exit),
        })
    }
}

#[cfg(target_os = "macos")]
fn guest_transport_exit_code(exit: tillandsias_control_wire::PtyExit) -> i32 {
    match exit.signal {
        Some(signal) => 128 + signal,
        None => exit.code,
    }
}

#[cfg(target_os = "macos")]
fn macvz_port(ep: &tillandsias_control_wire::guest_transport::GuestEndpoint) -> io::Result<u32> {
    match ep {
        tillandsias_control_wire::guest_transport::GuestEndpoint::MacVz { port } => Ok(*port),
        other => Err(io::Error::other(format!(
            "VzRuntime GuestTransport: unsupported endpoint {other:?}"
        ))),
    }
}

#[cfg(target_os = "macos")]
fn macvz_io_error(err: OpenVsockError) -> io::Error {
    io::Error::other(format!("VzRuntime GuestTransport: {err}"))
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

    /// Order 804-deux, THE LOAD-BEARING TEST. Two shares reach the VZ
    /// configuration as two devices.
    ///
    /// This is the capability the packet's problem statement says did not
    /// exist: `VzBootConfig` carried a single `Option<PathBuf>` and a single
    /// tag, and the builder installed an `NSArray` of length one, so the model
    /// cache had nowhere to live except inside `rootfs.img`. Asserting the
    /// COUNT is what makes that structural claim falsifiable — it goes red if
    /// anyone collapses the list back to one, and it goes red for the specific
    /// mistake that is easiest to make here: calling
    /// `setDirectorySharingDevices` once per share, which replaces the device
    /// list each time and silently keeps only the last.
    ///
    /// Real VZ objects, on this host — not a source scan.
    // 804-deux landed this on osx-next, where `pub mod boot` is compiled. That
    // module is #[cfg(target_os = "macos")] (vz.rs:1066), but this `mod tests` is
    // #[cfg(test)] ONLY — so on Linux the test below references a module that
    // does not exist, and the lib-test target fails with E0433, taking
    // `cargo test --workspace` down with it. Gated at the TEST rather than at the
    // module because the doc comment is explicit that these need "Real VZ
    // objects, on this host — not a source scan": they are genuinely macOS-only,
    // so skipping them off-macOS is honest, whereas widening the cfg on
    // `mod tests` would silently drop the platform-independent tests beside them.
    #[cfg(target_os = "macos")]
    #[test]
    fn two_shares_become_two_directory_sharing_devices() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let spec = boot::VzBootConfig {
            shares: vec![
                boot::VzShare {
                    host_dir: a.path().to_path_buf(),
                    tag: "home-src".to_string(),
                    read_only: false,
                },
                boot::VzShare {
                    host_dir: b.path().to_path_buf(),
                    tag: "model-cache".to_string(),
                    read_only: false,
                },
            ],
            ..boot::VzBootConfig::defaults()
        };
        let cfg = boot::build_vm_configuration(&spec).expect("build config");
        let devices = unsafe { cfg.directorySharingDevices() };
        assert_eq!(
            devices.len(),
            2,
            "both shares must reach the VZ config; one device means the list \
             collapsed or setDirectorySharingDevices was called per-share"
        );
    }

    /// The empty case still installs no device at all — what `None` used to
    /// mean. Guards the other direction of the same change.
    // 804-deux landed this on osx-next, where `pub mod boot` is compiled. That
    // module is #[cfg(target_os = "macos")] (vz.rs:1066), but this `mod tests` is
    // #[cfg(test)] ONLY — so on Linux the test below references a module that
    // does not exist, and the lib-test target fails with E0433, taking
    // `cargo test --workspace` down with it. Gated at the TEST rather than at the
    // module because the doc comment is explicit that these need "Real VZ
    // objects, on this host — not a source scan": they are genuinely macOS-only,
    // so skipping them off-macOS is honest, whereas widening the cfg on
    // `mod tests` would silently drop the platform-independent tests beside them.
    #[cfg(target_os = "macos")]
    #[test]
    fn no_shares_installs_no_directory_sharing_device() {
        let spec = boot::VzBootConfig {
            shares: Vec::new(),
            ..boot::VzBootConfig::defaults()
        };
        let cfg = boot::build_vm_configuration(&spec).expect("build config");
        let devices = unsafe { cfg.directorySharingDevices() };
        assert_eq!(devices.len(), 0, "no shares must install no device");
    }

    /// The guest half of 804-deux: cloud-init must PERSIST the model-cache
    /// mount to /etc/fstab, for the same reason the home-src mount is
    /// persisted — cloud-init runs on first boot only, so a mount issued
    /// there and not written to fstab evaporates on every later boot, and the
    /// cache silently reverts to living inside rootfs.img.
    #[test]
    fn cloud_init_persists_the_model_cache_mount() {
        let source = include_str!("vz.rs");
        assert!(
            source.contains("model-cache /root/.cache/tillandsias/models virtiofs nofail 0 0"),
            "cloud-init must persist the model-cache virtio-fs mount in /etc/fstab"
        );
        // The mount point must match the path the headless actually derives:
        // the unit sets Environment=HOME=/root and main.rs joins
        // `.cache/tillandsias/models` onto $HOME. A mismatch here mounts the
        // share somewhere nothing reads, and the cache silently stays in the
        // image with no error anywhere.
        assert!(
            source.contains("Environment=HOME=/root"),
            "the model-cache mount point is derived from the unit's HOME; if that \
             changes, /root/.cache/tillandsias/models is the wrong path"
        );
    }

    /// 2026-07-11: the raw disk MUST be grown past the ~5 GB Fedora Cloud
    /// default before first boot, or the forge-base image build runs the
    /// root filesystem out of space and every agent attach dies with a
    /// blank timing-out terminal. Pin the resize (source scan — the resize
    /// runs in the download-gated convert path) so it can't silently
    /// regress, and require a roomy target.
    #[test]
    fn convert_grows_raw_disk_before_first_boot() {
        let source = include_str!("vz.rs");
        assert!(
            source.contains("const GUEST_DISK_SIZE: &str"),
            "the guest disk-size constant must exist"
        );
        assert!(
            source.contains("\"qemu-img\"")
                && source.contains(".arg(\"resize\")")
                && source.contains(".arg(GUEST_DISK_SIZE)"),
            "convert_qcow2_to_raw must qemu-img resize the raw disk to GUEST_DISK_SIZE \
             before first boot (else forge-base build fills the ~5 GB default)"
        );
        // The size string must parse as a generous GiB value (>= 32 GiB).
        let size = source
            .split("const GUEST_DISK_SIZE: &str =")
            .nth(1)
            .and_then(|t| t.split('"').nth(1))
            .expect("GUEST_DISK_SIZE literal");
        let gib: u64 = size
            .trim_end_matches(['G', 'g'])
            .parse()
            .expect("GUEST_DISK_SIZE must be an <N>G literal");
        assert!(
            gib >= 32,
            "guest disk must be >= 32 GiB for the forge toolchain + overlay store, got {size}"
        );
    }

    /// Order 606-r42f: the macOS provisioning surface must never regain a
    /// panicking placeholder. The two legacy `vz_real` helpers reached
    /// `unimplemented!` from `VmRuntime::provision`; both were deleted, and
    /// the trait contract (lib.rs `VmRuntime` doc) forbids panicking on
    /// caller-recoverable errors. Whole-file source scan; the needles are
    /// concatenated so this test cannot match its own literals.
    #[test]
    fn no_unimplemented_or_todo_placeholders_in_vz() {
        let source = include_str!("vz.rs");
        let unimpl = format!("unimpl{}!(", "emented");
        let todo = format!("to{}!(", "do");
        assert!(
            !source.contains(&unimpl) && !source.contains(&todo),
            "vz.rs must not contain panicking placeholders — the macOS \
             provisioning path is fetch_fedora_cloud_image (order 606-r42f)"
        );
    }

    /// Order 606-r42f: the live boot spec (built inline in `start()`) must
    /// keep the host-protecting clamps the deleted `VzGuestConfig` used to
    /// pin: CPU capped at 4 and 4 GiB guest memory.
    ///
    /// WINDOW WIDENED 2026-08-18 (order 804-deux), and the reason is worth
    /// keeping. This scan used to start at `let spec = boot::VzBootConfig {`,
    /// which worked only while the cap was written INLINE as
    /// `cpu_count: available_parallelism().map(|n| n.get().min(4))`. Order
    /// 798-q4m9 hoisted that into `pinned_cpu_count` a few lines above so a
    /// measurement seam could constrain it — the cap was unchanged and still
    /// 4, but the LITERAL left the window and this test went red on a refactor
    /// that broke nothing. It is the 828-itr9 failure mode with the better
    /// ending: a scan anchored to a moveable literal, going loudly red instead
    /// of silently vacuous.
    ///
    /// So anchor on the derivation, not on the struct literal, and assert the
    /// anchor EXISTS before scanning — otherwise a future rename turns this
    /// back into a test that passes while checking nothing.
    #[test]
    fn live_boot_spec_derives_sizing_from_the_host_not_a_literal() {
        let source = include_str!("vz.rs");
        let anchor = "let (pinned_cpu_count, guest_memory_bytes) =";
        assert!(
            source.contains(anchor),
            "the sizing derivation moved or was renamed — this scan is \
             checking nothing until it is repointed"
        );
        let window = source
            .split("async fn start(&self)")
            .nth(1)
            .and_then(|t| t.split("let cfg = boot::build_vm_configuration").next())
            .expect("start() must derive the sizing then build the spec");
        assert!(
            window.contains("guest_sizing(host_logical_cores(), host_memory_bytes())"),
            "boot spec must size the guest from the host's shape (919-jii2)"
        );
        assert!(
            window.contains("memory_bytes: guest_memory_bytes"),
            "boot spec must carry the host-derived guest memory, not a literal"
        );
    }

    /// The floor is the whole reason a small host is safe under 919-jii2: it
    /// must never hand out less than the 4 GiB / 4 vCPU every macOS host ran
    /// under the pinned policy.
    #[test]
    fn guest_sizing_never_drops_below_the_pinned_floor() {
        for (cores, gib) in [(2usize, 4u64), (4, 8), (8, 8), (1, 2)] {
            let (cpus, mem) = guest_sizing(cores, gib * 1024 * 1024 * 1024);
            assert!(
                mem >= GUEST_FLOOR_MEMORY_BYTES,
                "{cores}c/{gib}GiB host must not go below the 4 GiB floor, got {mem}"
            );
            assert!(
                cpus >= GUEST_FLOOR_CPU_COUNT.min(cores.max(1)),
                "{cores}c host must not go below the vCPU floor, got {cpus}"
            );
        }
    }

    /// The host of 919-jii2 — Mac17,3 / M5 / 10 cores / 16 GiB — is the case
    /// the packet was filed about, so it is pinned here by name: 8 GiB / 8 vCPU.
    #[test]
    fn guest_sizing_gives_the_919_jii2_host_8gib_and_8_vcpu() {
        let (cpus, mem) = guest_sizing(10, 16 * 1024 * 1024 * 1024);
        assert_eq!(cpus, 8, "10-core host should yield 8 vCPU (80%)");
        assert_eq!(
            mem,
            8 * 1024 * 1024 * 1024,
            "16 GiB host should yield 8 GiB"
        );
    }

    #[test]
    fn guest_sizing_leaves_the_host_its_reserve_and_caps_large_hosts() {
        // 12 GiB: half is 6, but the host reserve allows only 6 — both agree.
        let (_, mem) = guest_sizing(8, 12 * 1024 * 1024 * 1024);
        assert_eq!(mem, 6 * 1024 * 1024 * 1024);
        // 8 GiB: half is 4, reserve allows 2 — the floor wins, host is small.
        let (_, mem) = guest_sizing(8, 8 * 1024 * 1024 * 1024);
        assert_eq!(mem, GUEST_FLOOR_MEMORY_BYTES);
        // 128 GiB: half is 64, well past what a forge uses — capped.
        let (_, mem) = guest_sizing(24, 128 * 1024 * 1024 * 1024);
        assert_eq!(mem, GUEST_MAX_MEMORY_BYTES);
    }

    /// @trace spec:vm-provisioning-lifecycle.provision.idempotency@v1
    #[test]
    fn fresh_runtime_is_not_provisioned() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        assert!(!rt.is_provisioned());
    }

    /// Order 606-r42f cold-provision lifecycle smoke — the LIVE macOS
    /// provisioning body (`fetch_fedora_cloud_image`: SHA-verify + qemu-img
    /// convert + resize) run end-to-end against a temp image root, proving a
    /// cold root goes !provisioned → provisioned through the qcow2 path.
    ///
    /// Ignored by default: it is slow (qemu-img convert of a ~600 MB image)
    /// and needs a seed. Run it on a macOS host with:
    ///   TILLANDSIAS_SMOKE_QCOW2="$HOME/Library/Application Support/tillandsias/rootfs.qcow2" \
    ///     cargo test -p tillandsias-vm-layer --release --features recipe,download \
    ///     -- --ignored cold_provision
    /// The seed pre-populates `download_verified`'s cache-hit path (the file
    /// is still SHA-verified against the bundled manifest pin); without a
    /// seed the test performs the real 528 MB download.
    #[cfg(all(target_os = "macos", feature = "recipe", feature = "download"))]
    #[tokio::test]
    #[ignore = "slow cold-provision smoke; seed via TILLANDSIAS_SMOKE_QCOW2"]
    async fn cold_provision_via_qcow2_path_flips_is_provisioned() {
        let manifest =
            crate::recipe::Manifest::from_toml(include_str!("../../../images/vm/manifest.toml"))
                .expect("bundled manifest parses");
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        assert!(!rt.is_provisioned(), "temp root must start cold");
        if let Ok(seed) = std::env::var("TILLANDSIAS_SMOKE_QCOW2") {
            let dest = rt.rootfs_image_path().with_extension("qcow2");
            std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
            std::fs::copy(&seed, &dest).expect("seed qcow2 copies into temp root");
        }
        rt.fetch_fedora_cloud_image(&manifest, &|phase| eprintln!("[smoke] {phase}"))
            .await
            .expect("cold provision through the live qcow2 path succeeds");
        assert!(
            rt.is_provisioned(),
            "fetch_fedora_cloud_image must leave the root provisioned"
        );
    }

    /// windows-260717-4 (intentional ephemeral reset): wiping a provisioned
    /// image root removes every boot artifact — `is_provisioned()` flips
    /// false so the next boot takes the first-provision path — while
    /// UNRELATED per-installation state beside the artifacts survives.
    #[test]
    fn wipe_provisioned_artifacts_resets_to_first_provision_state() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        for path in [
            rt.rootfs_image_path(),
            rt.kernel_path(),
            rt.initrd_path(),
            rt.rootfs_image_path().with_extension("qcow2"),
            rt.console_log_path(),
            tmp.path().join("cidata.iso"),
        ] {
            std::fs::write(&path, b"x").unwrap();
        }
        // Unrelated sibling state (e.g. the crash-loop detector file) must
        // NOT be touched by the wipe — its owner clears it deliberately.
        let sibling = tmp.path().join("crashloop.state");
        std::fs::write(&sibling, b"state").unwrap();

        assert!(rt.is_provisioned());
        rt.wipe_provisioned_artifacts().unwrap();

        assert!(!rt.is_provisioned(), "wipe must flip is_provisioned false");
        for gone in [
            rt.rootfs_image_path(),
            rt.kernel_path(),
            rt.initrd_path(),
            rt.rootfs_image_path().with_extension("qcow2"),
            rt.console_log_path(),
            tmp.path().join("cidata.iso"),
        ] {
            assert!(!gone.exists(), "{} must be deleted", gone.display());
        }
        assert!(sibling.exists(), "unrelated sibling state must survive");
        assert!(tmp.path().exists(), "image_root itself must survive");
    }

    /// The wipe is idempotent: a never-provisioned (or half-wiped) root
    /// resets to the same clean outcome without erroring.
    #[test]
    fn wipe_provisioned_artifacts_is_idempotent_on_missing_files() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        rt.wipe_provisioned_artifacts().unwrap();
        rt.wipe_provisioned_artifacts().unwrap();
        assert!(!rt.is_provisioned());
    }

    /// @trace spec:vm-provisioning-lifecycle.provision.idempotency@v1
    #[test]
    fn provisioned_check_requires_root_disk() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(7, tmp.path().to_path_buf());
        std::fs::write(rt.rootfs_image_path(), b"").unwrap();
        assert!(rt.is_provisioned(), "raw Fedora Cloud disk is enough");
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

    /// 690-cb62. An oversized console.log must be ROTATED, not left to grow —
    /// nothing pruned this file before, and the only code that ever removed it
    /// was the destructive reset. Rotation rather than in-place truncation
    /// because a boot problem is usually diagnosed from the boot BEFORE the one
    /// that failed, which truncation would discard.
    #[test]
    fn oversized_console_log_is_rotated_to_a_previous_generation() {
        let tmp = std::env::temp_dir().join(format!(
            "tillandsias-690cb62-rotate-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&tmp).expect("temp dir");
        let log = tmp.join("console.log");
        let oversized = vec![b'x'; (VzRuntime::CONSOLE_LOG_MAX_BYTES + 1) as usize];
        std::fs::write(&log, &oversized).expect("write oversized");

        VzRuntime::rotate_console_log_if_oversized(&log);

        assert!(
            !log.exists(),
            "the oversized log must be moved aside so the next open starts fresh"
        );
        assert!(
            log.with_extension("log.prev").exists(),
            "the previous generation must be PRESERVED, not deleted — it holds the \
             boot before the one being debugged"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik) for the rotation above. A rotator
    /// that fired unconditionally would satisfy that test while destroying the
    /// log on every single boot — leaving an operator with one boot of history
    /// exactly when they need several. An under-cap log must be untouched.
    #[test]
    fn console_log_under_the_cap_is_left_alone() {
        let tmp = std::env::temp_dir().join(format!(
            "tillandsias-690cb62-keep-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&tmp).expect("temp dir");
        let log = tmp.join("console.log");
        std::fs::write(&log, b"a few boots worth of serial output").expect("write small");

        VzRuntime::rotate_console_log_if_oversized(&log);

        assert!(
            log.exists(),
            "a log under the cap must NOT be rotated — otherwise every boot discards history"
        );
        assert!(
            !log.with_extension("log.prev").exists(),
            "no previous generation should be created for an under-cap log"
        );
        assert_eq!(
            std::fs::read(&log).expect("readable"),
            b"a few boots worth of serial output",
            "an under-cap log must be byte-identical after the check"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// An absent log (first boot ever) must be a no-op, not an error path.
    #[test]
    fn absent_console_log_rotates_without_error() {
        let missing = std::env::temp_dir().join(format!(
            "tillandsias-690cb62-absent-{}-{}/console.log",
            std::process::id(),
            line!()
        ));
        VzRuntime::rotate_console_log_if_oversized(&missing);
        assert!(
            !missing.exists(),
            "nothing should be created for an absent log"
        );
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

    /// The macOS VZ runtime is the Darwin backend for the normalized
    /// host<->guest transport facade.
    ///
    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[test]
    fn vz_runtime_implements_guest_transport() {
        fn assert_guest_transport<T: tillandsias_control_wire::guest_transport::GuestTransport>() {}
        assert_guest_transport::<VzRuntime>();
    }

    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[test]
    fn macvz_endpoint_accepts_only_macos_vz() {
        use tillandsias_control_wire::guest_transport::GuestEndpoint;

        assert_eq!(
            macvz_port(&GuestEndpoint::MacVz { port: 42420 }).unwrap(),
            42420
        );
        let err = macvz_port(&GuestEndpoint::Wsl { port: 42420 }).unwrap_err();
        assert!(
            err.to_string().contains("unsupported endpoint"),
            "unexpected error: {err}"
        );
    }

    /// The fetch unit must remain an idempotent oneshot. If systemd skips it
    /// with `ConditionPathExists=...`, the dependent headless service can be
    /// skipped on reboot even though the binary is already installed.
    ///
    /// @trace spec:vm-idiomatic-layer
    #[test]
    fn vz_cloud_init_headless_fetch_unit_is_idempotent() {
        let source = include_str!("vz.rs");
        let fetch_unit = source
            .split("# Write tillandsias-headless-fetch.service")
            .nth(1)
            .and_then(|tail| tail.split("# Write tillandsias-headless.service").next())
            .expect("fetch unit window");

        // 701-iu9b widened this from a LITERAL match on
        // `if [[ -x "$DEST" ]]; then exit 0; fi` to the property that line was
        // standing in for. The one-line form had to grow a diagnostic (below),
        // and pinning its exact spelling made a correct change look like a
        // regression — the failure mode `litmus:litmus-expression-pinning-
        // enforcement-shape` exists to discourage. The INTENT is idempotence:
        // an existing binary must still short-circuit to exit 0.
        assert!(
            source.contains("if [[ -x \"$DEST\" ]]; then")
                && source.contains("[tillandsias-fetch] keeping the EXISTING $DEST"),
            "fetch script must still be safe to run when the binary already exists, \
             and must now SAY it kept the existing one"
        );
        assert!(fetch_unit.contains("Type=oneshot"));
        assert!(fetch_unit.contains("RemainAfterExit=yes"));

        // 701-iu9b TRAP 1. The fetch unit must be ordered AFTER the virtiofs
        // share, or it races the mount that carries the very binary it installs.
        // Measured on this host 2026-08-18 from systemd's own resolved view:
        // RequiresMountsFor= was EMPTY and After= omitted the mount. The race
        // did not fire that boot — mount active at monotonic 3.005s, fetch
        // started at 4.461s — but the margin was only 1.456s, small enough that
        // a slower virtiofs mount closes it, and the failure is SILENT: the
        // script kept the old binary and exited 0.
        assert!(
            fetch_unit.contains("After=home-forge-src.mount"),
            "the fetch unit must be ordered after the share that carries the staged binary"
        );
        // ...but NOT via RequiresMountsFor, which implies Requires=. The fstab
        // entry is deliberately `nofail` because a VZ config may legitimately
        // omit the share; `tillandsias-headless.service` has
        // Requires=tillandsias-headless-fetch.service, so a hard requirement
        // here would turn a benign no-share boot into a DEAD GUEST. That
        // regression would surface only on a boot, which is exactly the
        // instrument this fix cannot afford to spend.
        assert!(
            !fetch_unit.contains("RequiresMountsFor="),
            "use plain After=, not RequiresMountsFor= — the latter implies Requires= and would \
             make a legitimate no-share boot fail the guest entirely"
        );
        assert!(
            !fetch_unit.contains("ConditionPathExists=!/usr/local/bin/tillandsias-headless"),
            "systemd must run the idempotent oneshot instead of skipping it"
        );
    }

    /// 701-iu9b TRAP 1, the diagnostic half. Ordering makes the race unlikely;
    /// this makes it VISIBLE when it happens anyway — ordering cannot help a
    /// boot where the share is genuinely absent, and that boot must not look
    /// identical to a healthy one.
    ///
    /// The two causes need opposite responses and used to be indistinguishable,
    /// because the fall-through printed nothing at all: an unmounted share means
    /// the staged binary exists and is invisible (retry / check the share); a
    /// genuinely absent staged file means nothing was ever staged (run the .app
    /// bundle — 701-kgvk).
    #[test]
    fn vz_cloud_init_fetch_script_names_why_it_skipped_the_staged_binary() {
        let source = include_str!("vz.rs");
        let script = source
            .split("# Write fetch-headless.sh")
            .nth(1)
            .and_then(|tail| tail.split("# Write headless-preflight.sh").next())
            .expect("fetch script window");

        assert!(
            script.contains("staged_binary=unreachable reason=share-not-mounted"),
            "an unmounted share must be named as the reason, not silently skipped"
        );
        assert!(
            script.contains("staged_binary=absent"),
            "a genuinely absent staged binary must be distinguishable from an unreachable one"
        );
        assert!(
            script.contains("findmnt"),
            "probe the mount with findmnt, which is verified present in this guest — under \
             `set -euo pipefail` a MISSING `mountpoint` binary would make `! mountpoint -q` \
             succeed and report a healthy share as unmounted"
        );
        assert!(
            script.contains(">&2"),
            "diagnostics belong on stderr so the journal captures them"
        );
    }

    /// The fetch script must prefer the staged host-provided binary over the
    /// network fallback (virtio-fs /home/forge/src → staged guest binary).
    ///
    /// @trace spec:macos-native-tray.lifecycle.vz-guest@v1
    #[test]
    fn vz_fetch_script_prefers_staged_binary_over_network() {
        let source = include_str!("vz.rs");

        assert!(
            source
                .contains("STAGED=\"/home/forge/src/.tillandsias/guest-bin/tillandsias-headless\""),
            "fetch script must define the staged binary path under /home/forge/src"
        );
        assert!(
            source.contains("if [[ -x \"$STAGED\" ]]; then"),
            "fetch script must check staged binary executability before curl"
        );
        assert!(
            source.contains("install -D -m 0755 \"$STAGED\" \"$DEST\""),
            "fetch script must install the staged binary when present and executable"
        );
    }

    /// The network fallback must not curl directly onto the live
    /// `/usr/local/bin/tillandsias-headless` path. Download to a temp file,
    /// then install into place so interrupted writes cannot leave a partial
    /// executable behind.
    ///
    /// @trace plan/issues/race-safeguards-research-2026-07-02.md#r9
    #[test]
    fn vz_fetch_script_installs_download_via_temp_file() {
        let source = include_str!("vz.rs");
        let fetch_script = source
            .split("# Write fetch-headless.sh")
            .nth(1)
            .and_then(|tail| {
                tail.split("chmod 0755 /usr/local/lib/tillandsias/fetch-headless.sh")
                    .next()
            })
            .expect("fetch-headless script window");

        assert!(
            fetch_script.contains("TMP=\"$(mktemp)\""),
            "fetch script must create a temp file before downloading"
        );
        assert!(
            fetch_script.contains("trap 'rm -f \"$TMP\"' EXIT"),
            "fetch script must clean the temp file"
        );
        assert!(
            fetch_script.contains("--output \"$TMP\" \"$URL\""),
            "curl must write to the temp file, not the live binary"
        );
        assert!(
            fetch_script.contains("install -D -m 0755 \"$TMP\" \"$DEST\""),
            "fetch script must install the temp file into the live path"
        );
        assert!(
            !fetch_script.contains("--output \"$DEST\""),
            "fetch script must not curl directly onto the live binary"
        );
    }

    /// The guest service should fail early for missing control-wire primitives
    /// while only recording Podman socket state. Podman readiness is reported
    /// over the control wire; making it a hard ExecStartPre dependency would
    /// remove the diagnostic channel we need when the stack is degraded.
    ///
    /// @trace spec:vm-idiomatic-layer
    #[test]
    fn vz_cloud_init_headless_service_has_control_wire_preflight() {
        let source = include_str!("vz.rs");
        let headless_unit = source
            .split("# Write tillandsias-headless.service")
            .nth(1)
            .and_then(|tail| tail.split("# Reload and enable services").next())
            .expect("headless unit window");

        assert!(source.contains("cat > /usr/local/lib/tillandsias/headless-preflight.sh"));
        assert!(source.contains("vsock_device=missing"));
        assert!(source.contains("podman_socket_unit=inactive"));
        assert!(headless_unit.contains("Wants=network-online.target podman.socket"));
        assert!(
            headless_unit.contains("ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh")
        );
        assert!(
            headless_unit.contains("Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200")
        );
        // Order 259: the boot-path bootstrap and the exec'd login satisfier
        // must resolve the SAME $XDG_RUNTIME_DIR/tillandsias-locks dir or the
        // order-232 vault flock never contends across the two processes and
        // the name-in-use race returns. /run/user/0 is the value the tray's
        // github-login exec preamble exports (macos-tray diagnose.rs).
        assert!(
            headless_unit.contains("Environment=XDG_RUNTIME_DIR=/run/user/0"),
            "headless unit must pin XDG_RUNTIME_DIR to the satisfier's lock namespace (order 259)"
        );
        assert!(
            !headless_unit.contains("Requires=podman.socket"),
            "podman.socket is a wanted readiness input, not a hard dependency for diagnostics"
        );
        // 2026-07-10 attended smoke: cloud-init runs first boot only, so
        // the home-src virtio-fs mount MUST be persisted to /etc/fstab or
        // every subsequent boot scans an empty /home/forge/src (local
        // projects vanish from the tray, staged headless never picked up).
        assert!(
            source.contains("home-src /home/forge/src virtiofs nofail 0 0"),
            "cloud-init must persist the home-src virtio-fs mount in /etc/fstab \
             (first-boot-only mounts evaporate on reboot)"
        );
        // Order 272 (guest-ssh-backdoor-closure): the control wire is the
        // ONLY host<->guest channel. Scope the scan to the user-data
        // template window (the whole-file source contains these needles in
        // this very test), then fail loud if key injection returns or the
        // sshd surfaces (NAT daemon + systemd-ssh-generator's AF_VSOCK
        // socket) lose their masks.
        // Repointed by 740-3k4s: the template moved out of `provision` into
        // `provision_user_data` so the units it installs could be asserted
        // without booting a VM. The anchor is checked to EXIST before the
        // window is taken, so a future move fails this test loudly instead of
        // silently scanning an empty string.
        assert!(
            source.contains("fn provision_user_data(secure_control_wire: &str) -> String {"),
            "the user-data template moved or was renamed — repoint this scan"
        );
        let user_data = source
            .split("fn provision_user_data(secure_control_wire: &str) -> String {")
            .nth(1)
            .and_then(|tail| tail.split("r#\"").nth(1))
            .and_then(|tail| tail.split("\"#").next())
            .expect("user-data template window");
        assert!(
            !user_data.contains("authorized_keys") && !user_data.contains("ssh-ed25519"),
            "cloud-init must not inject SSH keys — the guest is reachable only \
             via the secure control wire (order 272; The Tlatoani 2026-07-10)"
        );
        assert!(
            user_data.contains("systemctl mask sshd.service sshd.socket")
                && user_data.contains("/etc/systemd/system-generators/systemd-ssh-generator"),
            "cloud-init must mask sshd and the systemd-ssh-generator vsock \
             surface (order 272)"
        );
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

    /// `VzRuntime::exec` is now implemented over the control wire (see
    /// the GuestTransport facade). Without a started VM it must fail at the
    /// MacVz backend with a clear "VM not started" error — NOT silently succeed
    /// and NOT the old Phase-5 deferral stub. The happy-path protocol is
    /// unit-tested in `vsock_exec::tests` against an in-memory peer (no real VM).
    ///
    /// @trace spec:vm-idiomatic-layer, spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn vz_exec_without_started_vm_fails_at_connect() {
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(42, tmp.path().to_path_buf());
        let err = rt
            .exec(&["/bin/true"])
            .await
            .expect_err("exec without a started VM must fail");
        assert!(
            err.contains("GuestTransport") && err.contains("not started"),
            "unexpected exec error: {err}"
        );
    }

    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[test]
    fn vmruntime_exec_routes_through_guest_transport_exec() {
        let source = include_str!("vz.rs");
        let window = source
            .split("async fn exec(&self, argv: &[&str]) -> Result<ExitStatus, VmError> {")
            .nth(1)
            .and_then(|s| s.split("\n    async fn wait_ready").next())
            .expect("VzRuntime::exec source");
        assert!(
            window.contains("<Self as GuestTransport>::exec"),
            "VmRuntime::exec must route through GuestTransport::exec: {window}"
        );
        assert!(
            window.contains("GuestEndpoint::MacVz"),
            "VmRuntime::exec must target the MacVz endpoint: {window}"
        );
    }

    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[test]
    fn current_thread_guest_transport_opener_uses_endpoint_boundary() {
        let source = include_str!("vz.rs");
        let window = source
            .split("pub async fn open_guest_transport_stream_current_thread(")
            .nth(1)
            .and_then(|s| s.split("\n    /// Generate a `cidata.iso`").next())
            .expect("current-thread guest transport opener source");
        assert!(
            window.contains("macvz_port(ep)"),
            "current-thread opener must validate the GuestEndpoint: {window}"
        );
        assert!(
            window.contains("open_vsock_stream_current_thread(port, timeout)"),
            "current-thread opener must preserve caller-supplied timeout: {window}"
        );
    }

    /// @trace spec:host-guest-transport
    #[cfg(target_os = "macos")]
    #[test]
    fn guest_transport_exit_code_preserves_unix_signal_convention() {
        use tillandsias_control_wire::PtyExit;

        assert_eq!(
            guest_transport_exit_code(PtyExit {
                code: 17,
                signal: None
            }),
            17
        );
        assert_eq!(
            guest_transport_exit_code(PtyExit {
                code: 0,
                signal: Some(15)
            }),
            143
        );
        assert_eq!(
            guest_transport_exit_code(PtyExit {
                code: 143,
                signal: Some(15)
            }),
            143
        );
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

    /// `fetch_recipe_artifact` must refuse the placeholder `"pending-ci"`
    /// SHA value gracefully — that's the gating state until a real
    /// recipe-publish CI run populates manifest.toml with pinned SHAs.
    /// Verifies the macOS-side fetch path is plumbed end-to-end but
    /// fails closed before touching the network.
    ///
    /// @trace plan/issues/cross-host-blocker-roundup-2026-05-25.md l9
    #[cfg(all(target_os = "macos", feature = "recipe", feature = "download"))]
    #[tokio::test]
    async fn fetch_recipe_artifact_refuses_placeholder_sha() {
        use crate::recipe::Manifest;
        let toml = r#"
recipe_version = 1
[output]
artifact_url_template = "https://example.invalid/{tag}/{arch}.{format}"
[output.expected_rootfs_sha]
"aarch64.img" = "pending-ci"
"x86_64.img"  = "pending-ci"
"#;
        let manifest = Manifest::from_toml(toml).expect("parse test manifest");
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(3, tmp.path().to_path_buf());
        let err = rt
            .fetch_recipe_artifact(&manifest, "v0.0.0-test", &|_| {})
            .await
            .expect_err("placeholder SHA must be refused");
        assert!(
            err.contains("no pinned SHA-256"),
            "expected SHA-refusal error, got: {err}"
        );
    }

    /// `fetch_recipe_artifact` returns a clear error when the manifest
    /// has no `artifact_url_template` (template absent → caller can't
    /// resolve the URL).
    #[cfg(all(target_os = "macos", feature = "recipe", feature = "download"))]
    #[tokio::test]
    async fn fetch_recipe_artifact_reports_missing_template() {
        use crate::recipe::Manifest;
        let toml = r#"
recipe_version = 1
[output.expected_rootfs_sha]
"aarch64.img" = "0000000000000000000000000000000000000000000000000000000000000000"
"#;
        let manifest = Manifest::from_toml(toml).expect("parse test manifest");
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(3, tmp.path().to_path_buf());
        let err = rt
            .fetch_recipe_artifact(&manifest, "vX", &|_| {})
            .await
            .expect_err("missing template must error");
        assert!(
            err.contains("artifact_url_template"),
            "expected template-missing error, got: {err}"
        );
    }

    /// `open_vsock_stream` must return `VmNotStarted` when no VM handle
    /// has been installed yet (the common pre-start state). The happy
    /// path requires a booted VM and is exercised by the macOS tray's
    /// manual smoke once m5 lands; here we only verify the gating.
    ///
    /// @trace plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 4c)
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn open_vsock_stream_errors_when_vm_not_started() {
        use std::time::Duration;
        let tmp = tempfile::tempdir().unwrap();
        let rt = VzRuntime::new(3, tmp.path().to_path_buf());
        // VsockStream doesn't impl Debug (it wraps a raw fd + a
        // retained ObjC connection), so we match on the Result
        // directly instead of using `.expect_err`.
        match rt.open_vsock_stream(42420, Duration::from_millis(50)).await {
            Err(OpenVsockError::VmNotStarted) => {}
            Err(other) => panic!("unexpected error variant: {other}"),
            Ok(_) => panic!("expected error, got an open stream"),
        }
    }
}
