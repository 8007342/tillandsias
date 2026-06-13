//! Windows-side glue between the tray and `tillandsias-vm-layer::WslRuntime`.
//!
//! Owns the install-path discovery (`%LOCALAPPDATA%\tillandsias\wsl`), the
//! cache directory (`%LOCALAPPDATA%\tillandsias\cache`), and the
//! provisioning bootstrap that downloads the Fedora rootfs + tillandsias
//! binary, calls `wsl --import`, and starts the in-VM headless via
//! systemd. Per the host-shell plan, the actual heavy lifting lives in
//! `WslRuntime::provision`; this module orchestrates progress reporting +
//! `bootstrap` sequencing.
//!
//! @trace spec:windows-native-tray, spec:vm-idiomatic-layer

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_vm_layer::fetch::{RemoteArtifact, download_verified, is_sha256_hex};
use tillandsias_vm_layer::materialize::{MaterializedRootfs, tar_to_wsl_import};
use tillandsias_vm_layer::recipe::Manifest;
use tillandsias_vm_layer::{VmRuntime, wsl::WslRuntime};

/// Committed per-release pins (rootfs + headless binary URLs and checksums).
/// Embedded so an installed, checkout-free tray still provisions correctly.
///
/// @trace spec:vm-provisioning-lifecycle
const PROVISIONING_MANIFEST: &str = include_str!("../assets/provisioning-manifest.json");

/// The recipe materialization manifest (l9 `[output]` artifact-URL + SHA
/// contract), embedded so the installed, checkout-free tray can resolve the
/// CI-published rootfs without a repo. Manifest-delivery decision (w5 consumer
/// question): embed at build time — one trusted artifact, no runtime fetch of
/// the trust root.
pub const RECIPE_MANIFEST: &str = include_str!("../../../images/vm/manifest.toml");

/// The single WSL2 distro the tray manages (see `tillandsias-vm-layer::wsl`,
/// "one distro per host"). Also the `wsl.exe -d <name>` target the Open-Shell
/// terminal attaches to.
pub const DISTRO_NAME: &str = "tillandsias";

/// Convenience wrapper around `tillandsias-vm-layer::wsl::WslRuntime` that
/// carries the tray's preferred defaults (distro name `tillandsias`,
/// install root under `%LOCALAPPDATA%`).
pub struct WslLifecycle {
    runtime: WslRuntime,
}

impl Default for WslLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl WslLifecycle {
    pub fn new() -> Self {
        Self {
            runtime: WslRuntime::new(DISTRO_NAME, Self::install_root()),
        }
    }

    /// The managed distro's name — the `wsl.exe -d <name>` attach target.
    pub fn distro_name(&self) -> &str {
        &self.runtime.distro_name
    }

    pub fn install_root() -> PathBuf {
        // %LOCALAPPDATA%\tillandsias\wsl
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public\\AppData\\Local"));
        base.join("tillandsias").join("wsl")
    }

    pub fn cache_root() -> PathBuf {
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public\\AppData\\Local"));
        base.join("tillandsias").join("cache")
    }

    pub fn rootfs_cache_path(sha256_short: &str) -> PathBuf {
        Self::cache_root().join(format!("rootfs-fedora-44-{}.tar.xz", sha256_short))
    }

    pub fn binary_cache_path(version: &str) -> PathBuf {
        Self::cache_root()
            .join("bin")
            .join(format!("tillandsias-headless-{}", version))
    }

    /// Wake the distro by issuing a cheap `wsl --exec true` through the
    /// runtime. Idempotent.
    pub async fn ensure_started(&self) -> Result<(), String> {
        self.runtime.start().await
    }

    /// Spawn a keepalive `wsl --exec` session that holds the WSL2 utility VM
    /// open (it idles down otherwise, dropping the HvSocket control wire). The
    /// caller holds the returned `Child` for the tray's lifetime; it's
    /// `kill_on_drop`, so releasing it lets the VM idle normally again.
    pub fn spawn_keepalive(&self) -> Result<tokio::process::Child, String> {
        self.runtime.spawn_keepalive()
    }

    /// Graceful shutdown — issued by the tray on Quit. The host-shell's
    /// `VmLifecycle::stop` is the production entry point; this wrapper
    /// exists for callers that don't want the full `VmLifecycle` machinery.
    pub async fn graceful_shutdown(&self) -> Result<(), String> {
        self.runtime.stop(Duration::from_secs(30)).await
    }

    /// Recipe-path first-run provisioning — the **w11 Fedora pivot**. Supersedes the
    /// legacy OCI-base + separate-binary path:
    ///
    /// 1. `SettingUp` — ensure cache/install dirs.
    /// 2. `DownloadingRootfs` — resolve the OFFICIAL Fedora 44 WSL image from the
    ///    embedded recipe manifest and `download_verified` it (SHA-gated; resumable).
    /// 3. `InstallingTillandsias` — decompress `.tar.xz` -> `.tar`, then
    ///    `wsl --import`. Post-import, inject `wsl.conf` and the bootstrap script
    ///    that curl-installs `tillandsias-headless` on first boot.
    /// 4. `StartingVm` — `WslRuntime::start`.
    ///
    /// @trace plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md (w11 flip),
    /// spec:vm-provisioning-lifecycle.provision.first-run-downloads@v2
    pub async fn provision_via_recipe(
        &self,
        progress: Arc<dyn ProvisionProgress>,
    ) -> Result<(), String> {
        progress.report_phase(ProvisionPhase::SettingUp);
        tokio::fs::create_dir_all(Self::cache_root())
            .await
            .map_err(|e| format!("create cache_root failed: {e}"))?;
        tokio::fs::create_dir_all(Self::install_root())
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;

        // Idempotent: if a prior run already imported the distro, skip the
        // download + `wsl --import` and just (re)start it.
        if self.runtime.is_registered().await {
            progress.report_phase(ProvisionPhase::StartingVm);
            self.runtime.start().await?;
            progress.report_phase(ProvisionPhase::Connecting);
            return Ok(());
        }

        let manifest = Manifest::from_toml(RECIPE_MANIFEST)
            .map_err(|e| format!("parse embedded recipe manifest: {e}"))?;
        let artifact = recipe_rootfs_artifact(&manifest)?;

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        let cache_root = Self::cache_root();
        let xz_dest = cache_root
            .join("rootfs")
            .join(format!("fedora-44-wsl-{}.tar.xz", &artifact.sha256[..12]));

        let progress_for_cb = progress.clone();
        let last_pct = std::sync::atomic::AtomicU8::new(101);
        let on_progress = move |downloaded: u64, total: Option<u64>| {
            let Some(total) = total.filter(|t| *t > 0) else {
                return;
            };
            let pct = (downloaded.saturating_mul(100) / total).min(100) as u8;
            if last_pct.swap(pct, std::sync::atomic::Ordering::Relaxed) == pct {
                return;
            }
            let mb = downloaded / (1024 * 1024);
            let total_mb = total / (1024 * 1024);
            progress_for_cb.report_message(&format!(
                "\u{1F535} Downloading Fedora rootfs {mb} / {total_mb} MB ({pct}%)"
            ));
        };
        download_verified(&artifact, &xz_dest, &on_progress).await?;

        progress.report_phase(ProvisionPhase::InstallingTillandsias);
        progress.report_message("\u{1F4E6} Decompressing Fedora image...");
        let tar_dest = xz_dest.with_extension(""); // .tar.xz -> .tar
        if !tar_dest.exists() {
            let status = tokio::process::Command::new("tar")
                .arg("-xJf")
                .arg(&xz_dest)
                .arg("-C")
                .arg(xz_dest.parent().unwrap())
                .status()
                .await
                .map_err(|e| format!("decompress failed to spawn: {e}"))?;
            if !status.success() {
                return Err(format!("decompress exited {status}"));
            }
        }

        tar_to_wsl_import(
            "tillandsias",
            &Self::install_root(),
            &MaterializedRootfs::Tar(tar_dest),
        )
        .await?;

        // Fedora official images need wsl.conf for systemd, and our bootstrap
        // units for the vsock control wire.
        progress.report_message("\u{2699}\u{FE0F} Configuring Fedora distro...");
        self.runtime.configure_recipe_distro().await?;
        self.inject_bootstrap_logic().await?;

        progress.report_phase(ProvisionPhase::StartingVm);
        self.runtime.start().await?;

        progress.report_phase(ProvisionPhase::Connecting);
        const CW_PORT: u32 = tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        let mut last_err = String::from("(no attempt)");
        for attempt in 1..=12u32 {
            match self.try_connect_until_ready(CW_PORT, attempt).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last_err = e;
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
        Err(format!(
            "control-wire handshake did not succeed within budget: {last_err}"
        ))
    }

    /// Inject the `fetch-headless.sh` script and systemd units into the
    /// official Fedora image via `wsl --exec`.
    async fn inject_bootstrap_logic(&self) -> Result<(), String> {
        // 1. fetch-headless.sh
        let fetch_script = r#"#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
if [[ -x "$DEST" ]]; then exit 0; fi
ARCH="$(uname -m)"
URL="https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-headless-${ARCH}-unknown-linux-musl"
curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 --output "$DEST" "$URL"
chmod 0755 "$DEST"
"#;
        self.wsl_root_write(
            "/usr/local/lib/tillandsias/fetch-headless.sh",
            fetch_script,
            true,
        )
        .await?;

        // 2. tillandsias-headless-fetch.service
        let fetch_unit = r#"[Unit]
Description=Fetch tillandsias-headless on first boot
After=network-online.target
Wants=network-online.target
Before=tillandsias-headless.service
ConditionPathExists=!/usr/local/bin/tillandsias-headless
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/tillandsias/fetch-headless.sh
TimeoutStartSec=300s
[Install]
WantedBy=multi-user.target
"#;
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless-fetch.service",
            fetch_unit,
            false,
        )
        .await?;

        // 3. tillandsias-headless.service
        let headless_unit = r#"[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target tillandsias-headless-fetch.service
Requires=tillandsias-headless-fetch.service
[Service]
Type=exec
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
[Install]
WantedBy=multi-user.target
"#;
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless.service",
            headless_unit,
            false,
        )
        .await?;

        // Enable units
        self.wsl_root_sh(
            "systemctl enable tillandsias-headless-fetch.service tillandsias-headless.service",
        )
        .await?;

        Ok(())
    }

    async fn wsl_root_write(
        &self,
        path: &str,
        content: &str,
        make_executable: bool,
    ) -> Result<(), String> {
        let dir = Path::new(path).parent().unwrap().to_str().unwrap();
        self.wsl_root_sh(&format!("mkdir -p {dir}")).await?;

        let mut child = tokio::process::Command::new("wsl")
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("sh")
            .arg("-c")
            .arg(format!(
                "cat > {path} && if [ \"{make_executable}\" = \"true\" ]; then chmod +x {path}; fi"
            ))
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("wsl write {path} failed: {e}"))?;

        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            stdin
                .write_all(content.as_bytes())
                .await
                .map_err(|e| format!("write stdin to {path} failed: {e}"))?;
        }

        let status = child
            .wait()
            .await
            .map_err(|e| format!("wait for wsl write {path} failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl write {path} exited {status}"));
        }
        Ok(())
    }

    async fn wsl_root_sh(&self, script: &str) -> Result<(), String> {
        let status = tokio::process::Command::new("wsl")
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("sh")
            .arg("-c")
            .arg(script)
            .status()
            .await
            .map_err(|e| format!("wsl root sh failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl root sh exited {status} for: {script}"));
        }
        Ok(())
    }

    /// One connect attempt that succeeds only when the VM is **operationally
    /// Ready**: HvSocket handshake → `VmStatusRequest` → require `phase: Ready`.
    /// During first boot the headless reports `Provisioning`/`Starting` while it
    /// self-installs; the caller retries until this returns `Ok`. (Request path
    /// proven E2E: `VmStatusReply { phase: Ready, podman_ready: true }`.)
    async fn try_connect_until_ready(&self, port: u32, attempt: u32) -> Result<(), String> {
        use tillandsias_control_wire::transport::Transport;
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, VmPhase, WIRE_VERSION};
        use tillandsias_host_shell::vsock_client::Client;

        // Open the HvSocket transport, then drive the standard host-shell Client
        // (same Hello/HelloAck + request path the macOS tray uses over its
        // VZVirtioSocketConnection stream — slice 4 `80d9196e`).
        let stream = crate::hvsocket::open_hvsocket_stream(port)
            .await
            .map_err(|e| format!("hvsocket open: {e}"))?;
        let mut client = Client::from_stream(Box::new(stream), Transport::Vsock { cid: 0, port });
        let wire_version = client
            .handshake()
            .await
            .map_err(|e| format!("handshake: {e}"))?;
        crate::installation_uuid::deliver_credentials_and_check_handover(&mut client)
            .await
            .map_err(|e| format!("credentials delivery failed: {e}"))?;
        let seq = client.allocate_seq();
        let envelope = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq,
            body: ControlMessage::VmStatusRequest { seq },
        };
        let reply = client
            .request(&envelope)
            .await
            .map_err(|e| format!("VmStatusRequest: {e}"))?;

        match reply.body {
            ControlMessage::VmStatusReply {
                phase: VmPhase::Ready,
                ..
            } => {
                tracing::info!(
                    wire_version,
                    attempt,
                    "VM operationally Ready (control wire up)"
                );
                // NOTE: `stream` is dropped here; holding it for the session +
                // routing menu actions over it is the next w9 increment.
                Ok(())
            }
            ControlMessage::VmStatusReply { phase, .. } => {
                Err(format!("VM not yet Ready (phase {phase:?})"))
            }
            other => Err(format!("unexpected reply to VmStatusRequest: {other:?}")),
        }
    }
}

pub(crate) fn user_src_dir() -> PathBuf {
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"));
    base.join("src")
}

/// Resolve the Windows rootfs artifact (`x86_64.tar.xz`) to a verifiable download
/// pin from the recipe `Manifest` (l9 contract).
///
/// Bridges the recipe `[output]` block — `artifact_url_template` +
/// `expected_rootfs_sha["x86_64.tar.xz"]` — into the [`RemoteArtifact`] that
/// [`download_verified`] consumes.
///
/// @trace plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md
pub fn recipe_rootfs_artifact(manifest: &Manifest) -> Result<RemoteArtifact, String> {
    const ARCH: &str = "x86_64";
    const FORMAT: &str = "tar.xz";
    const SHA_KEY: &str = "x86_64.tar.xz";

    let url = manifest
        .artifact_url(ARCH, FORMAT, "fedora-pivot")
        .ok_or_else(|| "manifest has no [output].artifact_url_template".to_string())?;
    let sha = manifest
        .expected_sha(SHA_KEY)
        .ok_or_else(|| format!("manifest [output].expected_rootfs_sha has no \"{SHA_KEY}\" pin"))?;
    if !is_sha256_hex(sha) {
        return Err(format!(
            "rootfs SHA for {SHA_KEY} not yet published (manifest pin = {sha:?})"
        ));
    }
    Ok(RemoteArtifact {
        url,
        sha256: sha.to_string(),
        bytes: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_root_resolves_under_localappdata() {
        // SAFETY: tests set env synchronously; cargo test runs in single
        // process so the env mutation only affects this test.
        unsafe {
            std::env::set_var("LOCALAPPDATA", "C:\\Users\\Tester\\AppData\\Local");
        }
        let root = WslLifecycle::install_root();
        assert!(root.ends_with("tillandsias\\wsl") || root.ends_with("tillandsias/wsl"));
    }

    // The committed recipe manifest — used for a live-contract integration check.
    const REAL_MANIFEST: &str = include_str!("../../../images/vm/manifest.toml");

    // A minimal synthetic manifest with a caller-chosen x86_64.tar.xz SHA.
    fn manifest_with_x86_tar_sha(sha: &str) -> Manifest {
        const TMPL: &str = r#"recipe_version = 1
[output]
artifact_url_template = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/{arch}/images/Fedora-Cloud-Base-WSL-44-1.2.{arch}.tar.xz"
[output.expected_rootfs_sha]
"x86_64.tar.xz" = "__SHA__"
"#;
        Manifest::from_toml(&TMPL.replace("__SHA__", sha)).expect("parse inline manifest")
    }

    #[test]
    fn recipe_rootfs_artifact_resolves_url_and_sha() {
        let sha = "a".repeat(64);
        let m = manifest_with_x86_tar_sha(&sha);
        let art = recipe_rootfs_artifact(&m).expect("resolves with a real SHA");
        assert_eq!(art.sha256, sha);
        assert_eq!(
            art.url,
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-WSL-44-1.2.x86_64.tar.xz"
        );
    }
}
