//! Native AppKit NSStatusItem tray for Tillandsias on macOS.
//!
//! On macOS this drives a Virtualization.framework-hosted Fedora VM. On
//! non-macOS targets the binary still compiles (so the Linux dev box's
//! `cargo check --workspace` stays green) but `main` only prints a notice
//! and exits 1.
//!
//! @trace spec:macos-native-tray

#![allow(dead_code)]
#![allow(unused)]

#[cfg(target_os = "macos")]
mod status_item;

#[cfg(target_os = "macos")]
mod vz_lifecycle;

#[cfg(target_os = "macos")]
fn main() {
    status_item::run();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("tillandsias-macos-tray runs on macOS only");
    std::process::exit(1);
}
