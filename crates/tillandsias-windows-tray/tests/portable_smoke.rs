//! Portable smoke tests for the Windows tray crate that run on the Linux
//! dev box. The real tray binary is Windows-only; these tests cover the
//! portable surface (host-shell glue, menu state interop, stub modules).
//!
//! Windows-specific behavior is split: the Credential Manager read/write/
//! delete round-trip now has *automated, hermetic* coverage in the
//! `installation_uuid::tests::credential_manager_persists_uuid_across_calls`
//! unit test (it runs on every `cargo test` on a Windows host — this crate
//! is a binary, so that test can reach the binary-private module that
//! integration tests here cannot). The Win32 NotifyIcon registration test
//! below stays `#[ignore]` because it needs an interactive desktop session.
//!
//! @trace spec:windows-native-tray

use tillandsias_host_shell::menu_state::{
    GithubLoginState, MenuState, MenuStructure, ProjectEntry, TargetSurface, build,
};

/// The Windows tray paints the host-shell `MenuStructure` verbatim, matching
/// the Linux tray 1:1 (F3): logged-out collapses to
/// {status, github-login, separator, version, quit}; logged-in shows
/// {status, local-projects, cloud-projects, separator, version, quit}.
#[test]
fn portable_menu_build_is_invokable_from_windows_tray_path() {
    // Logged-out, runtime ready: collapsed short list with separator.
    let out = MenuState {
        target: TargetSurface::WindowsTray,
        gui_passthrough_available: true,
        login_runtime_ready: true,
        ..MenuState::initial()
    };
    match build(&out) {
        MenuStructure::Ready { items } => {
            let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
            assert_eq!(
                ids,
                vec![
                    "status",
                    "github-login",
                    "---",
                    "version",
                    "reset-guest",
                    "quit"
                ]
            );
        }
        other => panic!("expected Ready, got {other:?}"),
    }

    // Logged-in: projects + separator + footer; no github-login, no global
    // agents/observatorium/opencode-web at top level (Linux parity).
    let logged_in = MenuState {
        target: TargetSurface::WindowsTray,
        gui_passthrough_available: true,
        login: GithubLoginState::LoggedIn { handle: "u".into() },
        ..MenuState::initial()
    };
    match build(&logged_in) {
        MenuStructure::Ready { items } => {
            let ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
            assert_eq!(
                ids,
                vec![
                    "status",
                    "local-projects",
                    "cloud-projects",
                    "---",
                    "version",
                    "reset-guest",
                    "quit"
                ]
            );
            assert!(
                !items.iter().any(|i| i.id == "github-login"),
                "github-login is gated out when logged in (F3 mutual exclusivity)"
            );
            // Global pickers removed — agent/browser choices live inside per-project submenus.
            for gone in ["agents", "observatorium", "opencode-web"] {
                assert!(
                    !items.iter().any(|i| i.id == gone),
                    "{gone} must NOT appear at top level (Linux parity)"
                );
            }
        }
        other => panic!("expected Ready, got {other:?}"),
    }
}

/// Agent actions live inside each per-project submenu (Linux parity).
/// Each project has exactly 6 leaves: Claude/Codex/OpenCode/OpenCode Web/
/// Observatorium/Maintenance.
#[test]
fn agent_picker_lists_three_agents_in_canonical_order() {
    let mut state = MenuState::initial();
    state.target = TargetSurface::WindowsTray;
    state.gui_passthrough_available = true;
    state.podman_ready = true;
    state.login = GithubLoginState::LoggedIn { handle: "u".into() };
    state.local_projects = vec![ProjectEntry {
        name: "myapp".into(),
        path: "/home/u/src/myapp".into(),
        ready: false,
    }];
    let menu = build(&state);
    let items = match menu {
        MenuStructure::Ready { items } => items,
        _ => panic!("expected Ready"),
    };
    let local = items
        .iter()
        .find(|i| i.id == "local-projects")
        .expect("local-projects present");
    let proj = &local.children[0];
    let verbs: Vec<&str> = proj
        .children
        .iter()
        .map(|l| l.id.rsplit('.').next().unwrap_or(""))
        .collect();
    assert_eq!(
        verbs,
        vec![
            "claude",
            "codex",
            "opencode",
            "antigravity",
            "opencode-web",
            "observatorium",
            "maintenance"
        ]
    );
    // All leaves enabled because podman_ready = true.
    assert!(proj.children.iter().all(|l| l.enabled));
}

/// LoggedIn gates OUT the `github-login` row (mutually exclusive with the
/// project body, mirroring the Linux golden). The authenticated user instead
/// sees the project/agent body; the account identity is conveyed elsewhere
/// (status line), not as a top-level menu row. (F3)
#[test]
fn logged_in_state_gates_out_github_login_row() {
    let mut state = MenuState::initial();
    state.target = TargetSurface::WindowsTray;
    state.gui_passthrough_available = true;
    state.login = GithubLoginState::LoggedIn {
        handle: "bulloncito".into(),
    };
    state.local_projects = vec![ProjectEntry {
        name: "a".into(),
        path: "/x".into(),
        ready: true,
    }];
    let menu = build(&state);
    let items = match menu {
        MenuStructure::Ready { items } => items,
        _ => panic!("expected Ready"),
    };
    assert!(
        !items.iter().any(|i| i.id == "github-login"),
        "github-login must be gated out when authenticated"
    );
    // The project body is what surfaces instead.
    assert!(items.iter().any(|i| i.id == "local-projects"));
}

// The Credential Manager round-trip (CredWriteW/CredReadW/CredDeleteW) is
// covered automatically and hermetically by
// `installation_uuid::tests::credential_manager_persists_uuid_across_calls`
// in the binary crate — see the module note above. That test must live in
// the binary (not here) because `tillandsias-windows-tray` exposes no lib
// target, so an integration test cannot reach the `installation_uuid`
// module. Operators wanting to eyeball the *production* credential can run
// the tray once and check `cmdkey /list` for `tillandsias-vm-uuid`.

/// The Win32 NotifyIcon registration test must run inside an interactive
/// Windows desktop session (the Shell needs a foreground UI). Marked
/// ignored so CI does not invoke it without explicit operator action.
///
/// Manual repro:
/// ```powershell
/// cargo test -p tillandsias-windows-tray --target x86_64-pc-windows-msvc --test portable_smoke -- --ignored notify_icon_registers
/// ```
///
/// @trace spec:windows-native-tray
#[cfg(target_os = "windows")]
#[test]
#[ignore = "requires interactive Windows desktop session"]
fn notify_icon_registers_on_windows_desktop() {
    // Manual repro: spawn `tillandsias-tray.exe` and verify the icon
    // appears in the system tray within 500ms.
}
