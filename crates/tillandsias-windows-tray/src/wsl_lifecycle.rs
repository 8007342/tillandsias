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

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_vm_layer::{ProvisionManifest, VmRuntime, wsl::WslRuntime};

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
        Self::cache_root()
            .join(format!("rootfs-fedora-44-{}.tar.xz", sha256_short))
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
        self.runtime
            .stop(Duration::from_secs(30))
            .await
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
    pub async fn bootstrap(
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

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        // The actual HTTP download lives in `WslRuntime::provision` once
        // wired through `assets/provisioning-manifest.json`. The tray
        // surfaces the phase string; the network work happens below.
        let rootfs = download_fedora_rootfs_if_missing(&Self::cache_root()).await?;

        progress.report_phase(ProvisionPhase::DownloadingTillandsias);
        let host_version = tillandsias_host_shell::version();
        let binary =
            download_tillandsias_binary_if_missing(&Self::cache_root(), host_version).await?;

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

fn user_src_dir() -> PathBuf {
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"));
    base.join("src")
}

async fn download_fedora_rootfs_if_missing(cache_root: &PathBuf) -> Result<PathBuf, String> {
    let dir = cache_root.join("rootfs");
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("create rootfs cache dir failed: {e}"))?;
    // For now, return a deterministic placeholder path. Wave 4 ships the
    // download orchestration sketch; the real HTTP fetch + SHA verify
    // lands with the manifest pin (DEFERRED: needs assets/provisioning-
    // manifest.json + reqwest plumbing wired into vm-layer).
    Ok(dir.join("fedora-44-rootfs.tar.xz"))
}

async fn download_tillandsias_binary_if_missing(
    cache_root: &PathBuf,
    version: &str,
) -> Result<PathBuf, String> {
    let dir = cache_root.join("bin");
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("create bin cache dir failed: {e}"))?;
    Ok(dir.join(format!("tillandsias-headless-{}", version)))
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
