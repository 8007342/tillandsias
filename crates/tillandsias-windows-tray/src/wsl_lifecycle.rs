//! Windows-side glue between the tray and the `tillandsias-vm-layer`
//! `WslRuntime`. Owns the install-path discovery (`%LOCALAPPDATA%`) and the
//! `--listen-vsock` argument plumbing for the in-VM headless.
//!
//! @trace spec:windows-native-tray, spec:vm-idiomatic-layer

#![allow(dead_code)]
#![allow(unused)]

/// Convenience wrapper around `tillandsias-vm-layer::wsl::WslRuntime` that
/// carries the tray's preferred defaults (distro name, install path).
pub struct WslLifecycle;

impl WslLifecycle {
    pub fn new() -> Self {
        Self
    }

    pub fn install_root() -> std::path::PathBuf {
        todo!("@spec windows-native-tray: resolve %LOCALAPPDATA%\\tillandsias\\wsl")
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        todo!("@spec windows-native-tray: wsl --exec true to wake the distro")
    }
}
