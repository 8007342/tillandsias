//! Native Win32 NotifyIcon tray for Tillandsias on Windows.
//!
//! On Windows this drives a WSL2-hosted Fedora VM running the existing
//! headless tillandsias + podman enclave. On non-Windows targets the
//! binary still compiles (so the Linux dev box's `cargo check --workspace`
//! stays green) but `main` only prints a notice and exits 1.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]
// Tell Windows this is a GUI subsystem binary — no console window pops up
// on tray launch. Non-Windows builds ignore this attribute entirely.
#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod hvsocket;
#[cfg(target_os = "windows")]
mod installation_uuid;
#[cfg(target_os = "windows")]
mod notify_icon;
#[cfg(target_os = "windows")]
mod wsl_lifecycle;

// Linux stub modules so unit tests + portable code paths compile cleanly.
#[cfg(not(target_os = "windows"))]
#[path = "stubs/installation_uuid.rs"]
mod installation_uuid;
#[cfg(not(target_os = "windows"))]
#[path = "stubs/notify_icon.rs"]
mod notify_icon;
#[cfg(not(target_os = "windows"))]
#[path = "stubs/wsl_lifecycle.rs"]
mod wsl_lifecycle;

#[cfg(target_os = "windows")]
fn main() {
    // Headless diagnostic: provision the VM to Ready, print progress, exit with
    // status. For CI smoke + the live-provision dress rehearsal (the GUI tray
    // has no console). Otherwise launch the interactive tray.
    if std::env::args().any(|a| a == "--provision-once") {
        std::process::exit(notify_icon::provision_once());
    }
    notify_icon::run();
}

#[cfg(not(target_os = "windows"))]
fn main() {
    eprintln!(
        "tillandsias-windows-tray runs on Windows only \
         — see openspec/specs/windows-native-tray/spec.md"
    );
    std::process::exit(1);
}
