//! WSL2 backend for the VM runtime.
//!
//! Shells out to `wsl.exe --exec`, `wsl.exe --import`, `wsl.exe --terminate`.
//! Manages a single distro per host (default name `tillandsias`).
//!
//! Windows-only. On Linux/macOS this module compiles but every method
//! returns `Err("WslRuntime is Windows-only")` so the workspace links.
//!
//! @trace spec:vm-idiomatic-layer, spec:windows-native-tray

#![allow(dead_code)]

use std::path::PathBuf;
use std::process::ExitStatus;
use std::time::Duration;

use crate::{ProvisionManifest, VmError, VmRuntime};

/// WSL2-backed VM runtime.
///
/// On Windows the methods invoke `wsl.exe` under the hood (Phase-2 skeleton:
/// real wsl shell-outs land below the `#[cfg(target_os = "windows")]` gate).
/// On other targets the trait impl exists for cross-platform linkability
/// but every method returns a structured "not supported on this OS" error.
pub struct WslRuntime {
    /// Distro name registered with `wsl --import`. Default `tillandsias`.
    pub distro_name: String,
    /// Install path on the Windows host (`%LOCALAPPDATA%\tillandsias\wsl\`).
    pub install_root: PathBuf,
}

impl WslRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(distro_name: impl Into<String>, install_root: PathBuf) -> Self {
        Self {
            distro_name: distro_name.into(),
            install_root,
        }
    }
}

// ---------------------------------------------------------------------------
// Windows: real wsl.exe shell-outs.
// @trace spec:vm-idiomatic-layer
// ---------------------------------------------------------------------------

#[cfg(target_os = "windows")]
impl WslRuntime {
    async fn wsl_list_quiet() -> Result<String, VmError> {
        let output = tokio::process::Command::new("wsl")
            .args(["--list", "--quiet"])
            .output()
            .await
            .map_err(|e| format!("wsl --list failed: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "wsl --list exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        // WSL emits UTF-16LE on some Windows builds; tolerate either by
        // dropping invalid bytes. Distro names are ASCII in practice.
        Ok(String::from_utf8_lossy(&output.stdout)
            .replace('\u{0}', "")
            .to_string())
    }

    fn distro_listed(listing: &str, distro: &str) -> bool {
        listing
            .lines()
            .map(|line| line.trim())
            .any(|name| name.eq_ignore_ascii_case(distro))
    }
}

#[cfg(target_os = "windows")]
#[async_trait::async_trait]
impl VmRuntime for WslRuntime {
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError> {
        // Idempotency: skip if `wsl --list -q` already shows the distro.
        let listing = Self::wsl_list_quiet().await?;
        if Self::distro_listed(&listing, &self.distro_name) {
            return Ok(());
        }
        tokio::fs::create_dir_all(&self.install_root)
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;
        let status = tokio::process::Command::new("wsl")
            .arg("--import")
            .arg(&self.distro_name)
            .arg(&self.install_root)
            .arg(&manifest.rootfs_tarball)
            .status()
            .await
            .map_err(|e| format!("wsl --import failed to spawn: {e}"))?;
        if !status.success() {
            return Err(format!("wsl --import exited {status}"));
        }
        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        // WSL distros auto-start on the first command; just poke `echo ready`.
        let status = tokio::process::Command::new("wsl")
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--exec")
            .arg("echo")
            .arg("ready")
            .status()
            .await
            .map_err(|e| format!("wsl --exec echo failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl start poke exited {status}"));
        }
        Ok(())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        let status = tokio::process::Command::new("wsl")
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await
            .map_err(|e| format!("wsl --terminate failed to spawn: {e}"))?;
        if !status.success() {
            return Err(format!("wsl --terminate exited {status}"));
        }
        Ok(())
    }

    async fn exec(&self, argv: &[&str]) -> Result<ExitStatus, VmError> {
        if argv.is_empty() {
            return Err("wsl exec: argv is empty".to_string());
        }
        let mut cmd = tokio::process::Command::new("wsl");
        cmd.arg("--distribution")
            .arg(&self.distro_name)
            .arg("--exec");
        for arg in argv {
            cmd.arg(arg);
        }
        cmd.status()
            .await
            .map_err(|e| format!("wsl --exec spawn failed: {e}"))
    }

    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let probe = tokio::process::Command::new("wsl")
                .arg("--distribution")
                .arg(&self.distro_name)
                .arg("--exec")
                .arg("systemctl")
                .arg("is-active")
                .arg("tillandsias-headless")
                .status()
                .await;
            if let Ok(status) = probe
                && status.success()
            {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return Err("wsl wait_ready: timed out waiting for tillandsias-headless".into());
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows: cross-platform link stubs. The trait impl exists so call
// sites compile, but every method returns the same "not on this OS" error.
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "windows"))]
#[async_trait::async_trait]
impl VmRuntime for WslRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn start(&self) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }
}
