//! Native AppKit NSStatusItem tray for Tillandsias on macOS.
//!
//! On macOS this drives a Virtualization.framework-hosted Fedora VM and
//! renders the parity menu from `tillandsias-host-shell::MenuStructure`.
//! On non-macOS targets the binary still compiles (so the Linux dev box's
//! `cargo check --workspace` stays green) but `main` only prints a notice
//! pointing at the spec and exits 1.
//!
//! @trace spec:macos-native-tray

#![allow(dead_code)]
#![allow(unused)]

// Modules that have a real macOS body live behind `cfg(target_os = "macos")`.
// Their unit-testable portable bits (AppleScript formatting, menu mapping)
// re-export functions from sub-modules that compile everywhere — see
// `terminal_attach` and `menu_disabled_v2` for the pattern.
#[cfg(target_os = "macos")]
mod action_host;
#[cfg(target_os = "macos")]
mod installation_uuid;
#[cfg(target_os = "macos")]
mod status_item;
#[cfg(target_os = "macos")]
mod vz_lifecycle;

// These modules compile on every target: their public surface is host-shell
// data + plain Rust formatting that we want to test from the Linux dev box.
mod menu_disabled_v2;
mod terminal_attach;

#[cfg(target_os = "macos")]
fn main() {
    status_item::run();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!(
        "tillandsias-macos-tray runs on macOS only — see openspec/specs/macos-native-tray/spec.md"
    );
    std::process::exit(1);
}
