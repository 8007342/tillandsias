// @trace spec:runtime-logging
/// Order 998-qrwu — the enclave CA bundle directory, declared once and shared
/// by every crate that binds it.
pub mod ca_path;
pub mod cache_root;
pub mod cache_validation;
pub mod config;
pub mod container_profile;
pub mod event;
pub mod format;
pub mod genus;
/// Order 1019-ivia: where the host stages the guest binary. Declared once so
/// the writer (macos-tray) and the readers (vm-layer, the guest fstab line)
/// cannot drift, the way 998-qrwu did for the CA path.
pub mod guest_bin_path;
pub mod icons;
pub mod image_builder;
pub mod preflight;
pub mod project;
pub mod secrets;
pub mod singleton;
pub mod state;
pub mod tools;
pub mod version_guard;
pub mod wsl;

// Re-export logging module
pub use tillandsias_logging as logging;
