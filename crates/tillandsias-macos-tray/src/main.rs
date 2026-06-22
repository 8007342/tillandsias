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
    // Fast-exit metadata flags MUST short-circuit before the tray/VM fallthrough
    // below — otherwise `--version`/`--help` boot the Virtualization.framework VM
    // and put up a menu-bar icon instead of printing and exiting (see plan
    // packet macos-tray/version-help-flags-boot-vm).
    if args.iter().any(|a| a == "--version" || a == "-V") {
        // Include git SHA + build time (embedded by build.rs) so freshness is
        // verifiable — the crate version and VERSION file alone can't tell a
        // stale artifact from a HEAD build.
        println!(
            "tillandsias-tray {} (git {}, built {})",
            env!("CARGO_PKG_VERSION"),
            env!("TILLANDSIAS_GIT_SHA"),
            env!("TILLANDSIAS_BUILD_TIME"),
        );
        std::process::exit(0);
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!(
            "tillandsias-tray {}\n\n\
             Native macOS menu-bar tray for Tillandsias.\n\n\
             USAGE:\n    \
             tillandsias-tray [FLAGS]\n\n\
             FLAGS:\n    \
             (no flags)    Launch the menu-bar tray and auto-boot the VM\n    \
             --provision   Provision the VM disk from the manifest, then exit\n    \
             --exec-guest <cmd...>  Boot the VM, run a command in the guest over\n                  \
             the control wire, print its output + exit, then stop\n    \
             --diagnose    Print a static health report, then exit\n    \
             --json        With --diagnose, emit JSON instead of human text\n    \
             -V, --version Print version and exit\n    \
             -h, --help    Print this help and exit",
            env!("CARGO_PKG_VERSION")
        );
        std::process::exit(0);
    }
    if args.iter().any(|a| a == "--provision") {
        std::process::exit(diagnose::provision_main());
    }
    // Headless guest-exec smoke: boot the provisioned VM, run a command in the
    // guest over the control wire (VzRuntime::exec path), print its output +
    // exit, then stop. Real-path proof for the idiomatic exec layer and a
    // reusable smoke tool. MUST run on the main thread (Vz start() pumps the
    // main dispatch queue from its calling thread) — exec_guest_main uses a
    // current-thread runtime for exactly that. See
    // plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md.
    if let Some(idx) = args.iter().position(|a| a == "--exec-guest") {
        let guest_argv: Vec<String> = args[idx + 1..].to_vec();
        std::process::exit(diagnose::exec_guest_main(guest_argv));
    }
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
