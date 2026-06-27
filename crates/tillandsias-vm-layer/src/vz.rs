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

    /// Path of the early-boot serial console log.
    pub fn console_log_path(&self) -> PathBuf {
        self.image_root.join("console.log")
    }

    /// True if a previous provisioning has produced the disk image. Used by
    /// `provision` for the idempotency short-circuit.
    pub fn is_provisioned(&self) -> bool {
        self.rootfs_image_path().exists()
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

    /// Generate a `cidata.iso` image using `hdiutil makehybrid`.
    #[cfg(target_os = "macos")]
    fn generate_cidata_iso(&self, dest: &Path) -> Result<(), String> {
        let temp_dir = self.image_root.join("cidata_tmp");
        if temp_dir.exists() {
            let _ = std::fs::remove_dir_all(&temp_dir);
        }
        std::fs::create_dir_all(&temp_dir)
            .map_err(|e| format!("failed to create cidata temp dir: {e}"))?;

        // 1. Write user-data
        let user_data_content = r#"#!/bin/bash
set -euo pipefail

# Inject SSH keys for debugging
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGkwkOhAxGExE4dJUbIOMaVf8g0m0nSAp/JGzOxILfW tlatoani@Tlatoanis-MacBook-Air.local" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

mkdir -p /home/fedora/.ssh
chmod 700 /home/fedora/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGkwkOhAxGExE4dJUbIOMaVf8g0m0nSAp/JGzOxILfW tlatoani@Tlatoanis-MacBook-Air.local" >> /home/fedora/.ssh/authorized_keys
chown -R fedora:fedora /home/fedora/.ssh
chmod 600 /home/fedora/.ssh/authorized_keys

# Install podman + dependencies for the enclave
dnf install -y podman
systemctl enable podman.socket
systemctl start podman.socket

# Create directory
mkdir -p /usr/local/lib/tillandsias

# Write fetch-headless.sh
cat > /usr/local/lib/tillandsias/fetch-headless.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
if [[ -x "$DEST" ]]; then exit 0; fi
ARCH="$(uname -m)"
URL="https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-headless-${ARCH}-unknown-linux-musl"
curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 --output "$DEST" "$URL"
chmod 0755 "$DEST"
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
Before=tillandsias-headless.service
[Service]
Type=oneshot
RemainAfterExit=yes
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
[Service]
Type=exec
ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
EOF

# Reload and enable services
systemctl daemon-reload
systemctl enable tillandsias-headless-fetch.service tillandsias-headless.service
systemctl start tillandsias-headless-fetch.service tillandsias-headless.service
"#;

        std::fs::write(temp_dir.join("user-data"), user_data_content)
            .map_err(|e| format!("failed to write user-data: {e}"))?;

        // 2. Write meta-data
        let meta_data_content = r#"instance-id: tillandsias-vm-1
local-hostname: tillandsias-vm
"#;

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
        /// Optional cloud-init CIDATA ISO path.
        pub cidata_iso: Option<PathBuf>,
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
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.console_log_path())
                .ok()
                .map(|f| f.into_raw_fd())
        } else {
            None
        };

        let spec = boot::VzBootConfig {
            cpu_count: std::thread::available_parallelism()
                .map(|n| n.get().min(4))
                .unwrap_or(2),
            memory_bytes: 4 * 1024 * 1024 * 1024,
            root_disk: Some(rootfs),
            cidata_iso: Some(cidata_iso_path),
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
        // The PTY session machinery lives in tillandsias-host-shell, which
        // depends on THIS crate, so we cannot reuse it (cycle); instead we
        // speak the control wire directly via the self-contained vsock_exec
        // client. See plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md.
        use std::os::unix::process::ExitStatusExt;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

        let stream = self
            .open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
            .await
            .map_err(|e| format!("VzRuntime::exec: vsock connect: {e}"))?;
        let out = crate::vsock_exec::exec_over_stream(stream, argv).await?;

        // Synthesize a Unix ExitStatus from the guest waitpid-style result:
        // signal in the low 7 bits, else exit code in the high byte (WEXITSTATUS).
        let raw = match out.exit.signal {
            Some(sig) => sig & 0x7f,
            None => (out.exit.code & 0xff) << 8,
        };
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

        assert!(
            source.contains("if [[ -x \"$DEST\" ]]; then exit 0; fi"),
            "fetch script must be safe to run when the binary already exists"
        );
        assert!(fetch_unit.contains("Type=oneshot"));
        assert!(fetch_unit.contains("RemainAfterExit=yes"));
        assert!(
            !fetch_unit.contains("ConditionPathExists=!/usr/local/bin/tillandsias-headless"),
            "systemd must run the idempotent oneshot instead of skipping it"
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
        assert!(
            !headless_unit.contains("Requires=podman.socket"),
            "podman.socket is a wanted readiness input, not a hard dependency for diagnostics"
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

    /// `VzRuntime::exec` is explicitly deferred to Phase 5; returns a clear
    /// "deferred" message rather than `unimplemented!()` so callers don't
    /// silently panic.
    ///
    /// @trace spec:vm-idiomatic-layer
    /// `VzRuntime::exec` is now implemented over the control wire (see
    /// `vsock_exec`). Without a started VM it must fail at the vsock-connect
    /// step with a clear "VM not started" error — NOT silently succeed and NOT
    /// the old Phase-5 deferral stub. The happy-path protocol is unit-tested in
    /// `vsock_exec::tests` against an in-memory peer (no real VM).
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
            err.contains("vsock connect") && err.contains("not started"),
            "unexpected exec error: {err}"
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
