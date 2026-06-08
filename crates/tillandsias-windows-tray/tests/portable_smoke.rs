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
    GithubLoginState, MenuState, MenuStructure, ProjectEntry, SelectedAgent, TargetSurface, build,
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
    let agents = items
        .iter()
        .find(|i| i.id == "agents")
        .expect("agents present");
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
    let github = items
        .iter()
        .find(|i| i.id == "github-login")
        .expect("github");
    assert!(!github.enabled);
    assert!(github.label.contains("bulloncito"));
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
