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

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_vm_layer::fetch::{ProvisioningPins, download_verified};
use tillandsias_vm_layer::{ProvisionManifest, VmRuntime, wsl::WslRuntime};

/// Committed per-release pins (rootfs + headless binary URLs and checksums).
/// Embedded so an installed, checkout-free tray still provisions correctly.
///
/// @trace spec:vm-provisioning-lifecycle
const PROVISIONING_MANIFEST: &str = include_str!("../assets/provisioning-manifest.json");

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
            runtime: WslRuntime::new("tillandsias", Self::install_root()),
        }
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

    /// Graceful shutdown — issued by the tray on Quit. The host-shell's
    /// `VmLifecycle::stop` is the production entry point; this wrapper
    /// exists for callers that don't want the full `VmLifecycle` machinery.
    pub async fn graceful_shutdown(&self) -> Result<(), String> {
        self.runtime.stop(Duration::from_secs(30)).await
    }

    /// Full first-run bootstrap. Reports progress through the
    /// `ProvisionProgress` sink so the tray can update its condensed
    /// status line.
    ///
    /// Sequence (idempotent at every step):
    /// 1. `SettingUp` — verify cache directories exist.
    /// 2. `DownloadingRootfs` — fetch Fedora 44 rootfs (skip if cached).
    /// 3. `DownloadingTillandsias` — fetch the matching headless binary
    ///    from the GitHub release (skip if cached).
    /// 4. `InstallingTillandsias` — call `WslRuntime::provision` (which
    ///    does `wsl --import` + drops the systemd unit). Skipped if the
    ///    distro is already registered.
    /// 5. `StartingVm` — `WslRuntime::start`.
    /// 6. `Connecting` — the caller's vsock handshake step.
    ///
    /// @trace spec:vm-provisioning-lifecycle
    pub async fn bootstrap(&self, progress: Arc<dyn ProvisionProgress>) -> Result<(), String> {
        progress.report_phase(ProvisionPhase::SettingUp);
        tokio::fs::create_dir_all(Self::cache_root())
            .await
            .map_err(|e| format!("create cache_root failed: {e}"))?;
        tokio::fs::create_dir_all(Self::install_root())
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;

        let pins = ProvisioningPins::from_json(PROVISIONING_MANIFEST)?;

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        let rootfs = download_rootfs(&Self::cache_root(), &pins).await?;

        progress.report_phase(ProvisionPhase::DownloadingTillandsias);
        let binary = download_headless_binary(&Self::cache_root(), &pins).await?;

        progress.report_phase(ProvisionPhase::InstallingTillandsias);
        let manifest = ProvisionManifest {
            rootfs_tarball: rootfs,
            tillandsias_binary: binary,
            vsock_cid: 0, // WSL assigns dynamically
            vsock_port: tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT,
            shared_host_dir: user_src_dir(),
        };
        self.runtime.provision(&manifest).await?;

        progress.report_phase(ProvisionPhase::StartingVm);
        self.runtime.start().await?;

        progress.report_phase(ProvisionPhase::Connecting);
        Ok(())
    }
}

pub(crate) fn user_src_dir() -> PathBuf {
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"));
    base.join("src")
}

/// Download + SHA-verify the pinned Fedora rootfs archive into the cache.
///
/// Returns the local path to the verified archive. NOTE: this is a Fedora
/// **OCI image archive**, not a flat rootfs — `WslRuntime::provision` must
/// flatten its layer(s) into a rootfs tar before `wsl --import` (Phase 2b).
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
async fn download_rootfs(cache_root: &Path, pins: &ProvisioningPins) -> Result<PathBuf, String> {
    let short = &pins.rootfs.sha256[..pins.rootfs.sha256.len().min(12)];
    let dest = cache_root
        .join("rootfs")
        .join(format!("rootfs-fedora-44-{short}.oci.tar.xz"));
    download_verified(&pins.rootfs, &dest, &|_, _| {}).await?;
    Ok(dest)
}

/// Download + SHA-verify the pinned `tillandsias-linux-x86_64` headless
/// binary (the in-VM process) into the cache.
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
async fn download_headless_binary(
    cache_root: &Path,
    pins: &ProvisioningPins,
) -> Result<PathBuf, String> {
    let dest = cache_root.join("bin").join(format!(
        "tillandsias-headless-{}",
        pins.headless_release_tag
    ));
    download_verified(&pins.headless_binary, &dest, &|_, _| {}).await?;
    Ok(dest)
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
}
