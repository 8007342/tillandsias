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
mod diagnose;
#[cfg(target_os = "macos")]
mod installation_uuid;
#[cfg(target_os = "macos")]
mod main_thread;
#[cfg(target_os = "macos")]
mod pty_vsock_bridge;
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
    // Argv-driven sub-modes (mirrors windows-tray's `--diagnose`
    // pattern from commit 20fb9d1f). `--diagnose` runs the static
    // health report and exits before AppKit gets a chance to
    // initialize, so the binary can be invoked from a terminal
    // session without putting a stray menu-bar icon up.
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--diagnose") {
        let format = if args.iter().any(|a| a == "--json") {
            diagnose::DiagnoseFormat::Json
        } else {
            diagnose::DiagnoseFormat::Human
        };
        std::process::exit(diagnose::main(format));
    }
    status_item::run();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!(
        "tillandsias-macos-tray runs on macOS only — see openspec/specs/macos-native-tray/spec.md"
    );
    std::process::exit(1);
}
