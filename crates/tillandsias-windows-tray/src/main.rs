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

// Windows Event Log relay (self-gated with `#![cfg(target_os = "windows")]`;
// compiles to nothing elsewhere). @trace spec:windows-event-logging
mod eventlog;
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
    // Intentional EPHEMERAL RESET (windows-260717-4): wipe the guest and
    // reprovision from scratch. Destructive by design — one re-auth is the
    // only cost.
    if std::env::args().any(|a| a == "--reset-guest") {
        std::process::exit(notify_icon::reset_guest_once());
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
    // Initialize tracing BEFORE the singleton guard and any Win32 setup so
    // every startup failure below lands in tray.log AND the Windows Event
    // Log (source "Tillandsias") — a GUI-subsystem binary has no console, so
    // an unlogged early exit is invisible and reads as a silent crash loop
    // to the user. @trace spec:windows-event-logging
    notify_icon::init_tracing();
    // Panics in a GUI binary otherwise vanish (no console, default hook
    // prints to stderr). Record them where a power user can find them —
    // the ERROR relays to the Event Log — then continue into the default
    // hook to preserve abort/backtrace semantics.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        tracing::error!(panic = %info, "tray panicked");
        default_hook(info);
    }));

    // R2: Concurrent tray instances race and double-poll. Enforce singleton behavior.
    let _singleton = match tillandsias_core::singleton::SingletonGuard::acquire(
        "tray-windows",
        std::time::Duration::from_secs(5),
    ) {
        Ok(g) => g,
        Err(e) => {
            tracing::error!(error = %e, "tray startup refused: singleton lock unavailable");
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

#[cfg(test)]
mod tests {
    /// Guest crash-loop DETECTION wiring pin. `notify_icon.rs` is
    /// `cfg(target_os = "windows")` and so is NOT compiled on the Linux dev box
    /// where `cargo check -p tillandsias-windows-tray` runs — a behavioral test
    /// there could not catch a dropped wire-in. This source-scan (an
    /// `include_str!` compile-time read, platform-independent) keeps the four
    /// load-bearing hooks from silently regressing on any host.
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    #[test]
    fn notify_icon_wires_in_crashloop_detection() {
        let src = include_str!("notify_icon.rs");
        // 1. The detector is fed from the single VM-status funnel.
        assert!(
            src.contains("note_crashloop_observation("),
            "apply_vm_status must feed the crash-loop detector"
        );
        // 2. State is persisted so a separate --diagnose process can read it.
        assert!(
            src.contains("fn crashloop_state_path()"),
            "the live tray must persist crash-loop state for --diagnose"
        );
        // 3. --diagnose emits the pinned-grammar verdict line.
        assert!(
            src.contains("CrashLoopDetector::load(&crashloop_state_path())")
                && src.contains("Guest health:"),
            "--diagnose must read the persisted detector and print the verdict"
        );
        // 4. A trip raises the single most-important notification (Error balloon).
        assert!(
            src.contains("Tillandsias: guest crash-loop"),
            "a crash-loop must raise the top-priority Error balloon"
        );
    }

    /// EPHEMERAL RESET wiring pin (windows-260717-4, amended 2026-07-22 by
    /// operator order — tray-ux "UX curation governance"). The Windows
    /// bodies are `cfg(target_os = "windows")` and cannot be type-checked on
    /// the Linux dev box, so this platform-independent source-scan keeps the
    /// contract from silently regressing on any host: the MENU click wiring
    /// is GONE (the `Reset Guest…` leaf was an unapproved UX surface), while
    /// the runtime paths REMAIN — the auto-reset flag, the message-loop
    /// drain, the wipe primitive, the reprovision hand-off, and the
    /// `--reset-guest` CLI verb.
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    #[test]
    fn reset_guest_menu_wiring_absent_cli_and_runtime_present() {
        let notify = include_str!("notify_icon.rs");
        // 1. ABSENCE: no menu dispatch arm may reach the guest reset. The
        //    `MenuAction::ResetGuest` variant itself was deleted from
        //    host-shell, so ANY mention here means the click path came back.
        assert!(
            !notify.contains("MenuAction::ResetGuest"),
            "the reset-guest menu click wiring must stay REMOVED \
             (operator order 2026-07-22; tray-ux \"UX curation governance\")"
        );
        // 2. The message loop still drains the (auto-reset) flag into the
        //    LocalSet spawn.
        assert!(
            notify.contains("RESET_GUEST_REQUESTED.swap(false"),
            "the message loop must drain RESET_GUEST_REQUESTED"
        );
        assert!(
            notify.contains("fn spawn_guest_reset("),
            "the wipe+reprovision task spawner must exist"
        );
        // 3. The wipe hands off to the SAME first-provision path.
        assert!(
            notify.contains("wipe_guest().await"),
            "the reset must call the WslLifecycle wipe primitive"
        );
        // 4. A fresh guest clears the crash-loop history for --diagnose.
        assert!(
            notify.contains("fn reset_crashloop_state()"),
            "a wiped guest must clear persisted crash-loop state"
        );
        // 5. The bounded auto-reset policy is consulted (opt-in).
        assert!(
            notify.contains("AutoResetDecision::Reset { attempt }"),
            "the bounded auto-reset policy must be consulted on observations"
        );
        // 6. The CLI verb exists and main dispatches it.
        assert!(
            notify.contains("pub fn reset_guest_once()"),
            "--reset-guest CLI mode must exist"
        );
        let main_src = include_str!("main.rs");
        assert!(
            main_src.contains("notify_icon::reset_guest_once()"),
            "main must dispatch --reset-guest"
        );

        let wsl = include_str!("wsl_lifecycle.rs");
        assert!(
            wsl.contains("pub async fn wipe_guest("),
            "WslLifecycle must expose the user-invokable wipe primitive"
        );
    }

    /// Login transitive-state wiring pin (windows-260719-2). notify_icon.rs
    /// is cfg(windows)-gated and untype-checkable on the Linux dev box; this
    /// source-scan keeps the click→LoggingIn flip (a purely local signal,
    /// before any wire round-trip) and the confirmed-reply overwrite path
    /// from silently regressing on any host. The type/rendering logic itself
    /// is fully unit-pinned in tillandsias-host-shell (compiled everywhere).
    #[test]
    fn login_transitive_state_wiring_is_present() {
        let src = include_str!("notify_icon.rs");
        // 1. The GithubLogin click flips to LoggingIn immediately, before
        //    the terminal spawn / any wire round-trip.
        let arm = src
            .split("MenuAction::Attach { .. } | MenuAction::Maintain { .. } | MenuAction::GithubLogin =>")
            .nth(1)
            .expect("the GithubLogin dispatch arm must exist")
            .split("launch_open_shell_terminal(")
            .next()
            .unwrap();
        assert!(
            arm.contains("state.login = GithubLoginState::LoggingIn"),
            "the click must flip to LoggingIn before the launch (local signal)"
        );
        // 2. Only a LoggedOut menu flips (idempotent re-click mid-flow).
        assert!(
            arm.contains("GithubLoginState::LoggedOut"),
            "the flip must be gated on the current LoggedOut state"
        );
        // 3. The confirmed probe reply path overwrites the transitional
        //    state unconditionally (fallback on invalid/missing token).
        assert!(
            src.contains("fn apply_github_login(")
                && src.contains("github_login_state_from_reply(logged_in, handle)"),
            "the confirm path must map replies over the transitional state"
        );
    }
}
