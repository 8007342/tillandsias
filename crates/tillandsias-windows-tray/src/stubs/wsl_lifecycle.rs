//! Linux compile-stub for the Windows WSL lifecycle module.
//!
//! Allows portable callers in `main.rs` and tests to refer to the lifecycle
//! type without `cfg(target_os)` sprinkling. All methods return errors or
//! no-ops; the real WSL bodies live in the sibling Windows module.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]

use std::path::PathBuf;

/// Stubbed WSL lifecycle owner — Windows only at runtime.
pub struct WslLifecycle;

impl Default for WslLifecycle {
    fn default() -> Self {
        Self
    }
}

impl WslLifecycle {
    pub fn new() -> Self {
        Self
    }

    /// On Windows this resolves `%LOCALAPPDATA%\tillandsias\wsl`. Linux
    /// returns a fixed sentinel path so callers can detect the stub.
    pub fn install_root() -> PathBuf {
        PathBuf::from("/dev/null/tillandsias-windows-tray-stub/wsl")
    }

    pub fn cache_root() -> PathBuf {
        PathBuf::from("/dev/null/tillandsias-windows-tray-stub/cache")
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        Err("WslLifecycle::ensure_started is Windows-only".to_string())
    }

    pub async fn graceful_shutdown(&self) -> Result<(), String> {
        Err("WslLifecycle::graceful_shutdown is Windows-only".to_string())
    }
}
