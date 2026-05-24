//! Native Win32 NotifyIcon tray for Tillandsias on Windows.
//!
//! On Windows this drives a WSL2-hosted Fedora VM running the existing
//! headless tillandsias + podman enclave. On non-Windows targets the
//! binary still compiles (so the Linux dev box's `cargo check --workspace`
//! stays green) but `main` only prints a notice and exits 1.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]
#![allow(unused)]

#[cfg(target_os = "windows")]
mod notify_icon;

#[cfg(target_os = "windows")]
mod wsl_lifecycle;

#[cfg(target_os = "windows")]
fn main() {
    notify_icon::run();
}

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!("tillandsias-windows-tray runs on Windows only");
    std::process::exit(1);
}
