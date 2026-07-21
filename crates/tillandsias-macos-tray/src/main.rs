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
mod guest_binary;
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

/// Order 277: true iff a live tray process holds the app singleton.
/// The one-shot CLI modes boot their own VZ VM against the same root
/// disk the tray's VM has attached, so VZ fails with the opaque
/// "storage device attachment is invalid" (hit live in the 2026-07-10
/// attended smoke, blocking every in-session forensics attempt). Probe
/// the tray's own singleton lock instead of pattern-matching that
/// error: acquiring and immediately dropping the guard is side-effect
/// free when the lock is free, and `Ok(None)` (WouldBlock) means a
/// running tray owns the VM. A probe infrastructure error returns
/// false — the one-shot proceeds and at worst surfaces the raw VZ
/// error as before, never a false refusal.
#[cfg(target_os = "macos")]
fn live_tray_holds_singleton() -> bool {
    matches!(
        tillandsias_core::singleton::SingletonGuard::try_acquire("tillandsias-macos-tray"),
        Ok(None)
    )
}

/// Order 277 enforcement for VM-booting one-shot modes: fail fast with
/// operator guidance instead of the raw VZ storage error.
#[cfg(target_os = "macos")]
fn require_no_live_tray(mode: &str) {
    if live_tray_holds_singleton() {
        eprintln!(
            "Error: {mode} needs to boot the VM, but a running Tillandsias tray owns it.\n\
             Use the tray menu instead, or quit the tray (menu bar \u{2192} \u{274C} Quit Tillandsias) and re-run."
        );
        std::process::exit(3);
    }
}

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
             --github-login  Boot the VM and log in to GitHub in the guest;\n                  \
             prompts for your git name, email, and PAT (token hidden)\n    \
             --list-cloud-projects  Boot the VM and list GitHub repos via the\n                  \
             stored Vault token; streams the repo listing to stdout\n    \
             --opencode <path> [--prompt <text>]  Boot the VM and launch the\n                  \
             OpenCode forge on <path> inside the guest; streams forge output\n                  \
             to this terminal. With --prompt runs non-interactively (one shot).\n    \
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
        require_no_live_tray("--exec-guest");
        // Join remaining args into a shell command string so the user can write
        // --exec-guest "ls -la" or --exec-guest tillandsias --debug --init
        // without needing to pre-split argv themselves.
        let shell_cmd = args[idx + 1..].join(" ");
        let guest_argv = vec!["/bin/bash".to_string(), "-lc".to_string(), shell_cmd];
        std::process::exit(diagnose::exec_guest_main(guest_argv));
    }
    // Shared GuestTransport conformance fixtures (order 128) against the live
    // VZ backend (order 126 exit criterion 3). Boots the provisioned VM, runs
    // vm-layer::transport_conformance::run_all over GuestEndpoint::MacVz, and
    // prints the falsifiable verdict line `transport-conformance: PASS n=<N>`
    // (or `FAIL <fixture>: <reason>`), then stops the VM. Main-thread rule as
    // for --exec-guest.
    if args.iter().any(|a| a == "--transport-conformance") {
        require_no_live_tray("--transport-conformance");
        std::process::exit(diagnose::transport_conformance_main());
    }
    // Headless GitHub login: boot the VM and drive the guest --github-login over
    // the control wire. Prompts the user on the host terminal for THEIR own git
    // name, email, and PAT (token echo suppressed) and feeds the guest prompts
    // via the proven expect-style PTY input path; token never enters argv/logs.
    //   tillandsias-tray --github-login
    if args.iter().any(|a| a == "--github-login") {
        require_no_live_tray("--github-login");
        std::process::exit(diagnose::github_login_main());
    }
    // List GitHub cloud projects using the token stored in guest Vault.
    // Mirrors the Linux `tillandsias --list-cloud-projects` CLI mode.
    if args.iter().any(|a| a == "--list-cloud-projects") {
        require_no_live_tray("--list-cloud-projects");
        std::process::exit(diagnose::list_cloud_projects_main());
    }
    // `--opencode <path> [--prompt <text>]`: boot VM and launch forge in guest.
    if let Some(oc_idx) = args.iter().position(|a| a == "--opencode") {
        require_no_live_tray("--opencode");
        let path = args
            .get(oc_idx + 1)
            .cloned()
            .unwrap_or_else(|| ".".to_string());
        let prompt = args
            .iter()
            .position(|a| a == "--prompt")
            .and_then(|i| args.get(i + 1))
            .cloned();
        std::process::exit(diagnose::opencode_main(path, prompt));
    }
    if args.iter().any(|a| a == "--diagnose") {
        let format = if args.iter().any(|a| a == "--json") {
            diagnose::DiagnoseFormat::Json
        } else {
            diagnose::DiagnoseFormat::Human
        };
        std::process::exit(diagnose::main(format));
    }

    let _singleton_guard =
        match tillandsias_core::singleton::SingletonGuard::try_acquire("tillandsias-macos-tray") {
            Ok(Some(guard)) => guard,
            Ok(None) => {
                eprintln!(
                    "[tillandsias-tray] another macOS tray instance is already running; exiting"
                );
                std::process::exit(0);
            }
            Err(err) => {
                eprintln!("[tillandsias-tray] singleton guard failed: {err}");
                std::process::exit(1);
            }
        };
    status_item::run();
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!(
        "tillandsias-macos-tray runs on macOS only — see openspec/specs/macos-native-tray/spec.md"
    );
    std::process::exit(1);
}

#[cfg(test)]
mod tests {
    #[test]
    fn singleton_guard_applies_only_to_appkit_tray_mode() {
        let source = include_str!("main.rs");
        // rfind: the LAST acquisition is the app-mode guard in main();
        // the first occurrence is order 277's live-tray probe helper.
        let guard_idx = source
            .rfind("SingletonGuard::try_acquire(\"tillandsias-macos-tray\")")
            .expect("macOS tray must acquire a non-destructive singleton guard");
        let diagnose_idx = source
            .find("diagnose::main(format)")
            .expect("--diagnose handler must exist");
        let appkit_idx = source
            .find("status_item::run()")
            .expect("AppKit tray launch must exist");

        assert!(
            diagnose_idx < guard_idx,
            "CLI utility modes must exit before the singleton guard"
        );
        assert!(
            guard_idx < appkit_idx,
            "AppKit tray mode must acquire the singleton guard before launch"
        );
    }

    /// Order 277 pin: every VM-booting one-shot mode fails fast with
    /// operator guidance when a live tray owns the VM, instead of the
    /// opaque VZ storage-attachment error. Source-scan: each dispatch
    /// branch calls `require_no_live_tray` before its diagnose:: entry.
    #[test]
    fn vm_booting_oneshots_guard_against_live_tray() {
        let source = include_str!("main.rs");
        for (mode, entry) in [
            ("--exec-guest", "diagnose::exec_guest_main"),
            ("--github-login", "diagnose::github_login_main()"),
            (
                "--list-cloud-projects",
                "diagnose::list_cloud_projects_main()",
            ),
            ("--opencode", "diagnose::opencode_main"),
            (
                "--transport-conformance",
                "diagnose::transport_conformance_main()",
            ),
        ] {
            let guard_call = format!("require_no_live_tray(\"{mode}\")");
            let g = source
                .find(&guard_call)
                .unwrap_or_else(|| panic!("{mode} must call require_no_live_tray (order 277)"));
            let e = source
                .find(entry)
                .unwrap_or_else(|| panic!("{entry} dispatch must exist"));
            assert!(
                g < e,
                "{mode}: require_no_live_tray must run before {entry} (order 277)"
            );
        }
    }

    /// Guest crash-loop DETECTION wiring pin. `diagnose.rs` is
    /// `cfg(target_os = "macos")` and so is NOT compiled on the Linux dev box
    /// where `cargo check -p tillandsias-macos-tray` runs; this source-scan
    /// (a platform-independent `include_str!`) keeps `--diagnose`'s
    /// pinned-grammar guest-health line wired in on every host.
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    #[test]
    fn diagnose_wires_in_crashloop_verdict() {
        let source = include_str!("diagnose.rs");
        assert!(
            source.contains("pub fn guest_health_verdict()"),
            "diagnose must expose the guest-health verdict reader"
        );
        assert!(
            source.contains("crashloop::CrashLoopDetector::load(&crashloop_state_path())"),
            "the verdict must load the persisted crash-loop detector state"
        );
        assert!(
            source.contains("Guest health:"),
            "--diagnose must print the guest-health verdict line"
        );
    }
}
