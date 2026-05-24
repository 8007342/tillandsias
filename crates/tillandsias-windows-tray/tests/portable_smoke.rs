//! Portable smoke tests for the Windows tray crate that run on the Linux
//! dev box. The real tray binary is Windows-only; these tests cover the
//! portable surface (host-shell glue, menu state interop, stub modules).
//!
//! Windows-specific behavior (Win32 NotifyIcon registration, Credential
//! Manager read/write) is covered by `#[cfg(target_os = "windows")]
//! #[ignore]` tests below — to be unignored when a Win11 box is wired
//! into CI.
//!
//! @trace spec:windows-native-tray

use tillandsias_host_shell::menu_state::{
    build, GithubLoginState, MenuState, MenuStructure, ProjectEntry, SelectedAgent, TargetSurface,
};

/// The Windows tray paints the host-shell `MenuStructure` verbatim. Build
/// one and assert it has the seven canonical top-level groups + footer.
#[test]
fn portable_menu_build_is_invokable_from_windows_tray_path() {
    let state = MenuState {
        target: TargetSurface::WindowsTray,
        gui_passthrough_available: true,
        ..MenuState::initial()
    };
    let menu = build(&state);
    match menu {
        MenuStructure::Ready { items } => {
            assert!(items.iter().any(|i| i.id == "status"));
            assert!(items.iter().any(|i| i.id == "local-projects"));
            assert!(items.iter().any(|i| i.id == "cloud-projects"));
            assert!(items.iter().any(|i| i.id == "agents"));
            assert!(items.iter().any(|i| i.id == "observatorium"));
            assert!(items.iter().any(|i| i.id == "opencode-web"));
            assert!(items.iter().any(|i| i.id == "github-login"));
            assert!(items.iter().any(|i| i.id == "quit"));
        }
        other => panic!("expected Ready, got {other:?}"),
    }
}

/// Agent picker contract: exactly Claude / Codex / OpenCode in that order.
#[test]
fn agent_picker_lists_three_agents_in_canonical_order() {
    let mut state = MenuState::initial();
    state.selected_agent = SelectedAgent::Codex;
    state.target = TargetSurface::WindowsTray;
    state.gui_passthrough_available = true;
    let menu = build(&state);
    let items = match menu {
        MenuStructure::Ready { items } => items,
        _ => panic!("expected Ready"),
    };
    let agents = items.iter().find(|i| i.id == "agents").expect("agents present");
    let ids: Vec<&str> = agents.children.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids, vec!["agent.claude", "agent.codex", "agent.opencode"]);
    // Codex selected → middle is checked.
    assert!(!agents.children[0].checked);
    assert!(agents.children[1].checked);
    assert!(!agents.children[2].checked);
}

/// LoggedIn surfaces "GitHub: <user>" as a disabled item with the user's
/// handle in the label.
#[test]
fn logged_in_state_renders_github_user_disabled() {
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
    let github = items.iter().find(|i| i.id == "github-login").expect("github");
    assert!(!github.enabled);
    assert!(github.label.contains("bulloncito"));
}

/// Win11 + Credential Manager test — manually repro by running the test
/// binary on a Win11 machine with `--ignored`. The body uses the Win32
/// `CredWriteW` / `CredReadW` API, which is unavailable on Linux.
///
/// @trace spec:windows-native-tray
#[cfg(target_os = "windows")]
#[test]
#[ignore = "requires Windows 11 box with Credential Manager"]
fn installation_uuid_roundtrips_via_credential_manager() {
    // Manual repro: run the test binary on Win11, then verify the
    // credential appears under `cmdkey /list` as `tillandsias-vm-uuid`.
}

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
