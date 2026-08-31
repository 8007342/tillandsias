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
mod wsl_probe_policy;
// Pure NotifyIconSettings reconciliation policy (order 663-64xi). Deliberately
// NOT cfg-gated and deliberately free of Win32: the decision is what needs
// pinning, and keeping it platform-independent means its three exit criteria —
// including the negative control that a live portable build survives — are
// exercised on every host rather than only where a registry exists.
mod tray_registry;

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

/// Every flag this binary understands.
///
/// Kept as ONE list, deliberately, because the refusal below is only as good
/// as this set: a mode added to `main` without a line here becomes an
/// immediate hard error, which is the loud direction. (A mode added here
/// without a `help_text()` entry is caught by
/// `help_text_documents_all_cli_modes`.)
///
/// `--tail`'s VALUE is not flag-shaped, so it needs no entry.
const KNOWN_FLAGS: &[&str] = &[
    // modes (each exits the process)
    "--help",
    "-h",
    "--version",
    "-V",
    "--provision-once",
    "--reset-guest",
    "--status-once",
    "--diagnose",
    "--logs",
    "--forge",
    // mode modifiers
    "--json",
    "--tail",
    "--bak",
    // 945-vpg3: forge-launch intent selectors. They modify `--forge` rather
    // than being modes of their own, and they are listed here for the same
    // reason every other flag is: `unknown_flag` refuses anything absent from
    // this list, and a mode reachable in `main` but missing here becomes an
    // immediate hard error.
    "--shell",
    "--claude",
    "--codex",
    "--opencode",
    // the one option that modifies GUI mode and must reach `notify_icon::run`
    "--no-provision",
];

/// The first flag-shaped argument that is not in [`KNOWN_FLAGS`], if any.
///
/// WHY THIS EXISTS (E4, 2026-08-17). Before this, `main` dispatched its known
/// modes and then FELL THROUGH to the GUI tray for anything else. The
/// 2026-08-16 build-install smoke invoked `--provision` — the mode is
/// `--provision-once` — so no arm matched, the binary became a resident GUI
/// tray, and the harness read a healthy provision as a hang. Its
/// `03-provision.log` has 528 lines and ZERO `[provision]` lines, which is
/// proof `provision_once()` never ran; the run then filed a PHANTOM finding
/// asking whether resident-after-Ready was the intended SC-07 design. It cost
/// 10 minutes, one kill, and a false FAIL verdict.
///
/// macOS has refused unknown flags since `tillandsias-macos-tray`'s
/// `args.iter().skip(1).find(|a| a.starts_with('-'))` check, and
/// `plan/archive/build-install-smoke-e2e-findings-2026-06-14.md` prescribed the
/// policy for BOTH trays. Windows never implemented it. This is that.
///
/// Pure and not cfg-gated, so the Linux dev box's test run evaluates it too.
///
/// @trace spec:windows-native-tray
fn unknown_flag(args: &[String]) -> Option<&str> {
    args.iter()
        .skip(1)
        .find(|a| a.starts_with('-') && !KNOWN_FLAGS.contains(&a.as_str()))
        .map(String::as_str)
}

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
    // 945-vpg3: headless forge launch. Until this existed, the ONLY way to
    // open a forge was a tray menu click, so an automated release blessing
    // could smoke every other leg and had to stop here — v0.4.260830.5 did.
    //
    // This calls `notify_icon::launch_pty`, the SAME function the menu arm
    // calls, which is the whole point: a headless path that rebuilt the argv
    // itself could pass while the menu did something else, and the smoke would
    // be testing the tester. Flag names mirror the Linux CLI lanes
    // (--claude / --codex / --opencode <project>) so one contract spans both
    // platforms.
    if std::env::args().any(|a| a == "--forge") {
        std::process::exit(forge_launch_once());
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

    // Every recognized mode above exits the process. Anything flag-shaped that
    // reaches here is unknown, and falling through would launch the full GUI
    // tray — which provisions, takes the WSL singleton, and goes resident. An
    // unattended caller waiting on process exit then reads a healthy tray as a
    // hang. That is exactly what happened to the 2026-08-16 build-install
    // smoke, which typed `--provision` for `--provision-once` and filed a
    // phantom SC-07 design question about it. Refuse loudly instead; macOS has
    // done this since its own equivalent. See `unknown_flag`.
    if let Some(unknown) = unknown_flag(&std::env::args().collect::<Vec<_>>()) {
        eprintln!(
            "Error: unknown flag {unknown}\n\
             Run `tillandsias-tray.exe --help` for the supported flags.\n\
             Note: the one-shot provisioning mode is `--provision-once`, not \
             `--provision`; `--no-provision` is the GUI option that SKIPS \
             provisioning."
        );
        std::process::exit(2);
    }

    // windows-260722-3: stable, version-free shell identity BEFORE any UI
    // exists. Without an explicit AppUserModelID Windows derives identity
    // from the exe path/heuristics, and identity churn across updates is
    // how Taskbar-settings/notification surfaces accumulate duplicate
    // entries. One constant ID = one app, forever.
    {
        use windows::core::w;
        let _ = unsafe {
            windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID(w!(
                "Tlatoani.Tillandsias"
            ))
        };
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
    use super::{KNOWN_FLAGS, unknown_flag};

    fn argv(rest: &[&str]) -> Vec<String> {
        std::iter::once("tillandsias-tray.exe")
            .chain(rest.iter().copied())
            .map(str::to_string)
            .collect()
    }

    /// E4, 2026-08-17: an unrecognized flag must be REFUSED, not silently
    /// turned into a GUI-tray launch.
    ///
    /// `--provision` is the literal string the 2026-08-16 build-install smoke
    /// typed. It is first in the list on purpose.
    #[test]
    fn unknown_flags_are_refused() {
        for bad in [
            "--provision", // the exact 2026-08-16 smoke typo
            "--provision-now",
            "--with-token", // a tillandsias-headless flag with no tray meaning
            "--staus-once", // transposition
            "--Diagnose",   // wrong case
            "-x",
            "--",
        ] {
            assert_eq!(
                unknown_flag(&argv(&[bad])),
                Some(bad),
                "{bad:?} must be refused"
            );
        }
        // It refuses even when a VALID flag comes first, so `--diagnose --oops`
        // cannot smuggle a typo past the check.
        assert_eq!(
            unknown_flag(&argv(&["--diagnose", "--oops"])),
            Some("--oops")
        );
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik). "Fail loud" must not degrade
    /// into "refuse everything": the bare GUI launch and every legitimate
    /// flag combination still pass. `--no-provision` is the load-bearing one —
    /// it is the ONLY flag that must survive this check and reach
    /// `notify_icon::run`, and `scripts/build-and-install-windows-local.ps1`
    /// puts it on the Start Menu shortcut by default.
    #[test]
    fn known_flags_and_bare_gui_launch_are_accepted() {
        assert_eq!(unknown_flag(&argv(&[])), None, "bare GUI launch must work");
        for good in [
            vec!["--no-provision"],
            vec!["--help"],
            vec!["-h"],
            vec!["--version"],
            vec!["-V"],
            vec!["--provision-once"],
            vec!["--reset-guest"],
            vec!["--status-once"],
            vec!["--status-once", "--json"],
            vec!["--diagnose"],
            vec!["--diagnose", "--json"],
            vec!["--logs"],
            vec!["--logs", "--tail", "50"],
            vec!["--logs", "--bak"],
        ] {
            assert_eq!(
                unknown_flag(&argv(&good)),
                None,
                "{good:?} must be accepted"
            );
        }
    }

    /// The refusal is only as strong as `KNOWN_FLAGS`, and `main` is the only
    /// place that consumes them. Pin the correspondence so a mode added to one
    /// and not the other is a test failure rather than a runtime surprise in
    /// either direction (an undispatched allowlist entry silently launches the
    /// GUI; an unlisted dispatch is refused before it can run).
    #[test]
    fn known_flags_match_the_dispatch_in_main() {
        let main_src = include_str!("main.rs");
        for flag in KNOWN_FLAGS {
            assert!(
                main_src.matches(&format!("\"{flag}\"")).count() >= 2,
                "{flag} must appear in KNOWN_FLAGS *and* be consumed by main"
            );
        }
        // And the refusal itself is wired in, not merely defined.
        assert!(
            main_src.contains("if let Some(unknown) = unknown_flag("),
            "main must call unknown_flag and refuse"
        );
        assert!(
            main_src.contains("std::process::exit(2)"),
            "an unknown flag must exit non-zero (2), never launch the tray"
        );
    }

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

    /// 803-49re + 804-ckst: EVERY path that wipes the guest must also clear
    /// the host's copy of that guest's vault identity from Credential
    /// Manager, preserving `tillandsias-vm-uuid`.
    ///
    /// A source scan and not a runtime test, deliberately, because the three
    /// call sites live in three different languages — Rust, PowerShell, and
    /// two Markdown runbooks — and no runtime test can reach all three. What
    /// made 803-49re a p1 was not one missing call but the SET being
    /// incomplete: the product's own advertised reset bricked its own GitHub
    /// login, and the e2e that should have caught it carried the same gap, so
    /// the release passed its smoke and failed for the operator forty minutes
    /// later. A pin that covers one site would not have caught it.
    ///
    /// @trace order:803-49re, order:804-ckst
    #[test]
    fn every_guest_wipe_path_clears_the_host_side_vault_credentials() {
        const SHARE: &str = "vault-shamir-share-v1";
        const TOKEN: &str = "vault-root-token-v1";
        const UUID: &str = "tillandsias-vm-uuid";

        // 1. The primitive exists and names exactly the two guest credentials.
        let cred = include_str!("installation_uuid.rs");
        let cred_stub = include_str!("stubs/installation_uuid.rs");
        for (src, which) in [(cred, "windows"), (cred_stub, "linux stub")] {
            assert!(
                src.contains("pub fn clear_guest_vault_credentials()"),
                "the {which} credential module must expose the clear primitive"
            );
            assert!(
                src.contains("pub const GUEST_VAULT_TARGETS: [&str; 2]"),
                "the {which} module must declare exactly two guest-vault targets"
            );
        }

        // 2. --reset-guest calls it. This is the path whose own help text
        //    promises "you'll re-authenticate once" and then did not let you.
        let notify = include_str!("notify_icon.rs");
        assert!(
            notify.contains("clear_guest_vault_credentials()"),
            "reset_guest_once must clear the host vault credentials after the wipe"
        );

        // 3. The installer's -Purge clears them, and keeps the install anchor.
        let installer = include_str!("../../../scripts/install-windows.ps1");
        assert!(
            installer.contains(SHARE) && installer.contains(TOKEN),
            "install-windows.ps1 -Purge must clear both guest vault credentials"
        );

        // 4. Both e2e runbooks name them in their destructive-reset step —
        //    804-ckst's verifiable closure, stated as a grep and pinned as one.
        let curl_e2e = include_str!("../../../skills/smoke-curl-install-and-test-e2e/SKILL.md");
        let build_e2e = include_str!("../../../skills/build-install-and-smoke-test-e2e/SKILL.md");
        for (src, which) in [(curl_e2e, "curl-install"), (build_e2e, "local-build")] {
            assert!(
                src.contains(SHARE) && src.contains(TOKEN),
                "the {which} e2e runbook's Windows reset must name both credentials, \
                 or its 'cold run' claim is one the run cannot support"
            );
        }

        // 5. The installation anchor is preserved everywhere. Each artifact
        //    must SAY so, so a later editor cannot read the deletions as
        //    "clear the credential store" and take this one too.
        for (src, which) in [
            (cred, "windows credential module"),
            (installer, "installer"),
            (curl_e2e, "curl-install runbook"),
            (build_e2e, "local-build runbook"),
        ] {
            assert!(
                src.contains(UUID),
                "the {which} must name tillandsias-vm-uuid as preserved"
            );
        }
    }

    /// windows-260723-1: the registered-distro integrity probe's Windows
    /// bodies are cfg-gated away on Linux. Keep a portable wiring pin so the
    /// Linux-host test suite still proves that timeouts remain inconclusive,
    /// recovery is bounded to one attempt, and only an independently
    /// service-sane failed exec may reach the destructive reprovision
    /// disposition.
    #[test]
    fn registered_distro_probe_timeout_policy_is_wired_non_destructively() {
        let src = include_str!("wsl_lifecycle.rs");
        let policy = include_str!("wsl_probe_policy.rs");
        let vm_layer = include_str!("../../tillandsias-vm-layer/src/wsl.rs");

        assert!(
            policy.contains("DistroExecProbeAttempt::Initial")
                && policy.contains(
                    "DistroExecProbeClass::Timeout | DistroExecProbeClass::ServiceFailure",
                )
                && policy.contains("DistroExecProbeDecision::RecoverAndRetry"),
            "the initial timeout must select one recovery+retry"
        );
        assert!(
            policy.contains("DistroExecProbeAttempt::AfterShutdownRecovery")
                && policy.contains("DistroExecProbeDecision::FailNonDestructively"),
            "a second timeout/service failure and infrastructure failures must fail non-destructively"
        );
        assert!(
            src.contains("WslRuntime::perform_wsl_shutdown_recovery()")
                && vm_layer.contains("cmd.kill_on_drop(true)")
                && vm_layer.contains("WSL_SHUTDOWN_RECOVERY_TIMEOUT_SECS"),
            "the existing shutdown recovery must own a hard child-process bound"
        );
        assert!(
            src.contains("WslRuntime::is_wsl_service_sane().await")
                && src.contains("classify_nonzero_distro_exec(&stderr, service_sane)")
                && policy.contains("E_UNEXPECTED")
                && policy.contains("DistroExecProbeClass::DistroFailure")
                && src.contains("DistroExecProbeDecision::ReprovisionDamaged"),
            "only nonzero exec plus independent service-sane classification may authorize reprovisioning"
        );

        let provision = src
            .split("pub async fn provision_via_recipe")
            .nth(1)
            .and_then(|tail| tail.split("let manifest =").next())
            .expect("registered-distro fast path");
        assert!(
            provision.contains("registered_distro_disposition().await?")
                && provision.contains("RegisteredDistroDisposition::ReprovisionDamaged")
                && provision.contains("self.unregister_distro().await?"),
            "unregister must remain behind the conclusive damaged disposition"
        );
        assert!(
            !provision.contains("if self.distro_exec_probe().await"),
            "the provisioning path must not collapse probe outcomes back to bool"
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

#[cfg(target_os = "windows")]
/// `--forge <project> [--shell|--claude|--codex|--opencode]` — open a forge
/// PTY without a tray click. 945-vpg3.
///
/// Exit codes are the contract a smoke harness consumes:
///   0  the PTY was spawned
///   2  usage error (no project, or two agent flags)
///   1  the launch itself was refused or failed
///
/// The agent flag is OPTIONAL and defaults to `--shell`, the maintenance
/// intent, because that launch needs no agent installed in the guest and is
/// therefore the one a blessing round can always run.
///
/// REFUSES rather than guesses on two inputs. A missing project name is a
/// usage error, not "attach to something reasonable": the tray's own refusal
/// comment says a silently rewritten name launches a DIFFERENT project than
/// the one asked for, and inventing one headlessly is the same defect with
/// nobody watching. Two agent flags is refused rather than last-one-wins,
/// because a harness passing both has a bug and should be told, not served.
fn forge_launch_once() -> i32 {
    use tillandsias_host_shell::menu_state::SelectedAgent;
    use tillandsias_host_shell::pty::PtyIntent;

    let args: Vec<String> = std::env::args().collect();
    let project = match args.iter().position(|a| a == "--forge") {
        Some(i) => match args.get(i + 1) {
            Some(p) if !p.starts_with("--") && !p.is_empty() => p.clone(),
            _ => {
                eprintln!("refused: --forge needs a project name, e.g. --forge myproject");
                return 2;
            }
        },
        None => return 2,
    };

    let mut intent: Option<PtyIntent> = None;
    for (flag, agent) in [
        ("--claude", Some(SelectedAgent::Claude)),
        ("--codex", Some(SelectedAgent::Codex)),
        ("--opencode", Some(SelectedAgent::OpenCode)),
        ("--shell", None),
    ] {
        if args.iter().any(|a| a == flag) {
            if intent.is_some() {
                eprintln!("refused: pass at most one of --shell/--claude/--codex/--opencode");
                return 2;
            }
            intent = Some(match agent {
                Some(a) => PtyIntent::Agent(a),
                None => PtyIntent::Shell,
            });
        }
    }
    let intent = intent.unwrap_or(PtyIntent::Shell);

    match notify_icon::launch_pty(&intent, Some(project.as_str())) {
        Ok(()) => {
            println!("ok:forge-launch:{project}");
            0
        }
        Err(err) => {
            eprintln!("failed:forge-launch:{project}: {err}");
            1
        }
    }
}
