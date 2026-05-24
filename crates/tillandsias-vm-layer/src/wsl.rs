//! WSL2 backend for the VM runtime.
//!
//! Shells out to `wsl.exe --exec`, `wsl.exe --import`, `wsl.exe --terminate`.
//! Manages a single distro named `tillandsias` per host.
//!
//! Windows-only. Linux/macOS builds skip this module entirely.
//!
//! @trace spec:vm-idiomatic-layer, spec:windows-native-tray

#![allow(dead_code)]
#![allow(unused)]

use std::time::Duration;

use crate::{ProvisionManifest, VmRuntime};

/// WSL2-backed VM runtime.
pub struct WslRuntime {
    /// Distro name registered with `wsl --import`. Default `tillandsias`.
    pub distro_name: String,
    /// Install path on the Windows host (`%LOCALAPPDATA%\tillandsias\wsl\`).
    pub install_root: std::path::PathBuf,
}

impl WslRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(distro_name: impl Into<String>, install_root: std::path::PathBuf) -> Self {
        Self {
            distro_name: distro_name.into(),
            install_root,
        }
    }
}

#[async_trait::async_trait]
impl VmRuntime for WslRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: wsl --import + tillandsias binary install")
    }

    async fn start(&self) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: wsl --exec /usr/bin/true to wake the distro")
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: graceful drain then wsl --terminate fallback")
    }

    async fn exec(&self, _argv: &[&str]) -> Result<std::process::ExitStatus, String> {
        todo!("@spec vm-idiomatic-layer: wsl --exec passthrough with exit-code propagation")
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), String> {
        todo!("@spec vm-idiomatic-layer: poll the in-VM headless vsock readiness file")
    }
}
