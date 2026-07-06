//! Native Win32 NotifyIcon tray for Tillandsias on Windows.
//!
//! On Windows this drives a WSL2-hosted Fedora VM running the existing
//! headless tillandsias + podman enclave. On non-Windows targets the
//! binary still compiles (so the Linux dev box's `cargo check --workspace`
//! stays green) but `main` only prints a notice and exits 1.
//!
//! @trace spec:windows-native-tray

// Helpers in hvsocket / installation_uuid / wsl_lifecycle that aren't
// wired into the active code paths yet (Credential Manager UUID flow,
// pre-recipe download paths kept as architecture for future iteration).
// Per-item allows would be noisy; this crate-level allow on the binary
// preserves them without polluting the source files.
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
    //
    // NOTE on stdio: the release tray is a GUI-subsystem binary, so when
    // invoked from PowerShell `println!` to a captured pipe may or may not be
    // delivered (Rust treats a detached stdout as BrokenPipe and discards).
    // The reliable path for support scripts is to REDIRECT to a file
    // (`exe --diagnose --json > out.json`) — file handles work regardless of
    // console attachment — and to branch on the *exit code* rather than the
    // captured output. `scripts/install-windows.ps1` and `scripts/tray-diagnose.ps1`
    // do this. Tried AttachConsole(ATTACH_PARENT_PROCESS) — it attaches the
    // binary to the *visible* parent console, bypassing PowerShell's pipe, so
    // captured-output scripts see nothing. Reverted.
    // --help / -h and --version / -V short-circuit before any of the
    // diagnostic modes so they always succeed and never touch the WSL
    // surface (e.g. a customer with a totally broken WSL install can still
    // ask the binary what it is and how to use it).
    if std::env::args().any(|a| a == "--help" || a == "-h") {
        print!("{}", notify_icon::help_text());
        std::process::exit(0);
    }
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!("{}", notify_icon::version_line());
        std::process::exit(0);
    }
    if std::env::args().any(|a| a == "--provision-once") {
        std::process::exit(notify_icon::provision_once());
    }
    if std::env::args().any(|a| a == "--status-once") {
        let format = if std::env::args().any(|a| a == "--json") {
            notify_icon::DiagnoseFormat::Json
        } else {
            notify_icon::DiagnoseFormat::Human
        };
        std::process::exit(notify_icon::status_once(format));
    }
    if std::env::args().any(|a| a == "--diagnose") {
        let format = if std::env::args().any(|a| a == "--json") {
            notify_icon::DiagnoseFormat::Json
        } else {
            notify_icon::DiagnoseFormat::Human
        };
        std::process::exit(notify_icon::diagnose(format));
    }
    if std::env::args().any(|a| a == "--logs") {
        // Optional `--tail <N>`: print the last N lines instead of the
        // full file. Malformed values (non-numeric, missing arg) fall
        // through to the full-file path — friendlier than rejecting the
        // run for a typo.
        let mut iter = std::env::args();
        let tail: Option<usize> = loop {
            match iter.next() {
                Some(a) if a == "--tail" => break iter.next().and_then(|v| v.parse().ok()),
                Some(_) => continue,
                None => break None,
            }
        };
        // `--bak`: read `tray.log.bak` (the size-rotation backup; see
        // TRAY_LOG_MAX_BYTES). Useful after a long-lived tray triggered
        // rotation and the operator wants the prior session's history.
        // Exit 1 if the backup doesn't exist.
        let bak = std::env::args().any(|a| a == "--bak");
        std::process::exit(notify_icon::logs(tail, bak));
    }
    // R2: Concurrent tray instances race and double-poll. Enforce singleton behavior.
    let _singleton = match tillandsias_core::singleton::SingletonGuard::acquire(
        "tray-windows",
        std::time::Duration::from_secs(5),
    ) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("Error: Tray is already running, or failed to acquire singleton: {e}");
            std::process::exit(1);
        }
    };

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
