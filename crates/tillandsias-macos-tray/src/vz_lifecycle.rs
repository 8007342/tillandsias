//! macOS-side glue between the tray and the `tillandsias-vm-layer`
//! `VzRuntime`. Owns the disk-image path discovery (`~/Library/Application
//! Support/tillandsias/vm/`) and the Virtualization.framework configuration
//! builder.
//!
//! @trace spec:macos-native-tray, spec:vm-idiomatic-layer

#![allow(dead_code)]
#![allow(unused)]

/// Convenience wrapper around `tillandsias-vm-layer::vz::VzRuntime` that
/// carries the tray's preferred defaults (CID, image path).
pub struct VzLifecycle;

impl VzLifecycle {
    pub fn new() -> Self {
        Self
    }

    pub fn image_root() -> std::path::PathBuf {
        todo!("@spec macos-native-tray: resolve ~/Library/Application Support/tillandsias/vm")
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        todo!("@spec macos-native-tray: VZVirtualMachine.start with completion handler")
    }
}
