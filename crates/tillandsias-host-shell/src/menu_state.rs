//! Portable menu state model shared by the Windows and macOS trays.
//!
//! Mirrors the Linux tray's `TrayUiState` but emits a backend-agnostic
//! `MenuStructure`. The Windows tray turns this into Win32 `MENUITEMINFO`
//! entries; the macOS tray turns it into `NSMenuItem` instances.
//!
//! The structure is intentionally toolkit-agnostic: no `HMENU`, no
//! `NSMenuItem`, no D-Bus paths. Items carry a stable string `id` so the
//! UI backend can correlate a click event back to a logical action without
//! sharing typed handles.
//!
//! ## Parity with the Linux tray
//!
//! The Linux tray's `build_menu` (see
//! `crates/tillandsias-headless/src/tray/mod.rs::build_menu`) surfaces a
//! status header, then the `~/src` and `Cloud` submenus when authenticated.
//! Agents (`Seedlings`), Observatorium and OpenCode Web also live in that
//! tree. The portable menu reproduces this shape in a stable order so the
//! Windows + macOS trays render identical menus.
//!
//! @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray

#![allow(dead_code)]

use serde::{Deserialize, Serialize};

/// Maximum number of cloud projects that appear directly in the `Cloud`
/// submenu before being collapsed behind a single overflow leaf. Matches
/// the Linux tray's `MAX_CLOUD_PROJECTS_IN_MENU` constant verbatim so the
/// two trays clip the same way.
///
/// @trace spec:host-shell-architecture
pub const MAX_CLOUD_PROJECTS_IN_MENU: usize = 10;

/// Stable IDs the UI backends use to correlate `NSMenuItem` / `MENUITEMINFO`
/// click events back to logical actions. Kept centralised so both backends
/// match without coordination.
pub mod ids {
    pub const STATUS: &str = "status";
    pub const LOCAL_PROJECTS: &str = "local-projects";
    pub const LOCAL_PROJECTS_EMPTY: &str = "local-projects.empty";
    pub const CLOUD_PROJECTS: &str = "cloud-projects";
    pub const CLOUD_PROJECTS_EMPTY: &str = "cloud-projects.empty";
    pub const CLOUD_PROJECTS_OVERFLOW: &str = "cloud-projects.overflow";
    pub const AGENTS: &str = "agents";
    pub const AGENT_CLAUDE: &str = "agent.claude";
    pub const AGENT_CODEX: &str = "agent.codex";
    pub const AGENT_OPENCODE: &str = "agent.opencode";
    pub const OBSERVATORIUM: &str = "observatorium";
    pub const OPENCODE_WEB: &str = "opencode-web";
    pub const GITHUB_LOGIN: &str = "github-login";
    pub const VERSION: &str = "version";
    pub const QUIT: &str = "quit";

    /// Tooltip shown for items deferred to v2 on macOS.
    pub const V2_DISABLED_REASON: &str = "v2 — terminal-only in v1";
    /// Tooltip shown for browser items on WSLg-less Windows hosts.
    pub const WSLG_DISABLED_REASON: &str = "Requires Windows 11 + WSLg";
}

/// A single menu node.
///
/// The `enabled` flag plus `disabled_reason` lets either backend render a
/// greyed-out item with an explanatory tooltip. The `checked` flag drives
/// `MF_CHECKED` (Windows) / `setState(.on)` (AppKit) for the agent picker.
///
/// @trace spec:host-shell-architecture
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
    pub enabled: bool,
    pub disabled_reason: Option<String>,
    pub checked: bool,
    pub children: Vec<MenuItem>,
}

impl MenuItem {
    pub fn leaf(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn disabled(
        id: impl Into<String>,
        label: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: false,
            disabled_reason: Some(reason.into()),
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn submenu(
        id: impl Into<String>,
        label: impl Into<String>,
        children: Vec<MenuItem>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked: false,
            children,
        }
    }

    pub fn checkmark(
        id: impl Into<String>,
        label: impl Into<String>,
        checked: bool,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked,
            children: Vec::new(),
        }
    }
}

/// The agent the user has selected for new attaches.
///
/// Mirrors `SelectedAgent` in the Linux tray. The portable menu surfaces
/// these as a `Agents` submenu with checkmark toggles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SelectedAgent {
    Claude,
    Codex,
    OpenCode,
}

impl SelectedAgent {
    pub fn display_name(self) -> &'static str {
        match self {
            SelectedAgent::Claude => "Claude",
            SelectedAgent::Codex => "Codex",
            SelectedAgent::OpenCode => "OpenCode",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            SelectedAgent::Claude => ids::AGENT_CLAUDE,
            SelectedAgent::Codex => ids::AGENT_CODEX,
            SelectedAgent::OpenCode => ids::AGENT_OPENCODE,
        }
    }
}

/// A single host-side project surfaced in the menu.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectEntry {
    /// Display name (typically the directory basename of `~/src/<name>`).
    pub name: String,
    /// Local projects: filesystem path on the host. Cloud projects: the
    /// `owner/repo` slug returned by `gh`.
    pub path: String,
    /// `true` once the in-VM forge for this project has reported "ready".
    /// Used for the running checkmark on local entries.
    pub ready: bool,
}

/// Login state surfaced in the menu's GitHub item.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum GithubLoginState {
    LoggedOut,
    LoggedIn { handle: String },
}

/// Which native UI backend is going to paint the menu. Drives which items
/// are tagged as v2-deferred.
///
/// @trace spec:macos-native-tray.ui.gui-passthrough-v2@v1
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TargetSurface {
    LinuxTray,
    WindowsTray,
    MacosTray,
}

impl TargetSurface {
    /// True if this surface defers GUI-passthrough items to v2.
    pub fn defers_gui_to_v2(self) -> bool {
        matches!(self, TargetSurface::MacosTray)
    }
}

/// Aggregated state the host shell feeds into `build()` to compute the
/// portable menu snapshot the OS-specific trays render.
///
/// `version` carries the host-shell crate version so the menu can display
/// the same `v<X.Y.Z> — By Tlatoāni` line the Linux tray does.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MenuState {
    pub status_text: String,
    pub version: String,
    pub login: GithubLoginState,
    pub local_projects: Vec<ProjectEntry>,
    pub cloud_projects: Vec<ProjectEntry>,
    pub selected_agent: SelectedAgent,
    /// True on Win11+WSLg hosts; false otherwise. Gates Observatorium +
    /// OpenCode Web items. Combined with the target surface (macOS defers
    /// GUI to v2 regardless), this determines whether browser items are
    /// rendered enabled.
    pub gui_passthrough_available: bool,
    /// True when podman is verified ready in the VM; gates per-project
    /// actions (`Attach Here` etc.) so the user is not asked to start a
    /// forge before the VM is healthy.
    pub podman_ready: bool,
    /// Target UI backend. Drives macOS's "(v2)" defer markers.
    pub target: TargetSurface,
}

impl MenuState {
    /// Baseline test state: cold-start, no projects, logged-out, podman
    /// not ready, target=WindowsTray.
    pub fn initial() -> Self {
        Self {
            status_text: "Setting up Fedora Linux\u{2026}".to_string(),
            version: crate::version().to_string(),
            login: GithubLoginState::LoggedOut,
            local_projects: Vec::new(),
            cloud_projects: Vec::new(),
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: false,
            podman_ready: false,
            target: TargetSurface::WindowsTray,
        }
    }
}

/// Coarse menu shape the tray paints.
///
/// Three states map onto three menu shapes:
/// - `Provisioning`: a single condensed status line + Quit footer.
/// - `Ready`: the full parity menu fed from `MenuState`.
/// - `Failed`: an error line with Retry + Open Log sub-items.
///
/// @trace spec:host-shell-architecture, spec:vm-provisioning-lifecycle
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MenuStructure {
    Provisioning { items: Vec<MenuItem> },
    Ready { items: Vec<MenuItem> },
    Failed { items: Vec<MenuItem> },
}

impl MenuStructure {
    /// Construct an initial provisioning menu with the verbatim default
    /// phase string from `vm-provisioning-lifecycle.ux.condensed-status@v1`.
    pub fn initial_provisioning() -> Self {
        MenuStructure::Provisioning {
            items: vec![
                MenuItem::disabled(
                    ids::STATUS,
                    "\u{1F535} Setting up Fedora Linux\u{2026}",
                    "VM is provisioning",
                ),
                MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"),
            ],
        }
    }

    /// Construct a failure menu with the error reason + retry/open-log
    /// affordances.
    pub fn failed(reason: impl Into<String>) -> Self {
        let reason = reason.into();
        MenuStructure::Failed {
            items: vec![
                MenuItem::disabled(
                    ids::STATUS,
                    format!("\u{1F940} Provisioning failed: {}", truncate_80(&reason)),
                    reason,
                ),
                MenuItem::leaf("retry", "Retry"),
                MenuItem::leaf("open-log", "Open log"),
                MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"),
            ],
        }
    }

    /// Convenience accessor: the top-level item list of whichever variant
    /// is active. Used by the OS trays to walk the menu uniformly.
    pub fn top_items(&self) -> &[MenuItem] {
        match self {
            MenuStructure::Provisioning { items }
            | MenuStructure::Ready { items }
            | MenuStructure::Failed { items } => items,
        }
    }
}

fn truncate_80(s: &str) -> String {
    if s.chars().count() <= 80 {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(77).collect();
        out.push('\u{2026}');
        out
    }
}

/// Build the portable `MenuStructure` from the aggregate `MenuState`.
///
/// The returned menu is identical in shape across Windows and macOS (modulo
/// the `(v2)` markers on macOS). The OS-specific trays only translate the
/// labels + click IDs into their native menu APIs; they MUST NOT reorder
/// or filter items.
///
/// ## Top-level item contract (Ready)
///
/// 1. `status` — disabled, current status line
/// 2. `local-projects` — submenu of `~/src` entries (or `(no projects yet)` placeholder when empty)
/// 3. `cloud-projects` — submenu capped at `MAX_CLOUD_PROJECTS_IN_MENU` with an overflow leaf when overflowing
/// 4. `agents` — submenu with three checkmark items (Claude/Codex/OpenCode)
/// 5. `observatorium` — leaf (disabled with reason when `gui_passthrough_available == false` or target=MacosTray)
/// 6. `opencode-web` — leaf (same disabled rule)
/// 7. `github-login` — leaf (`🔑 GitHub Login` when logged-out; `GitHub: <user>` disabled when logged-in)
///
/// The `version` and `quit` items follow as a trailing footer, so the
/// `Ready` menu has exactly 9 top-level items.
///
/// @trace spec:host-shell-architecture, spec:windows-native-tray
pub fn build(state: &MenuState) -> MenuStructure {
    let mut items = Vec::new();

    // (1) Status — always disabled, always first.
    items.push(MenuItem::disabled(
        ids::STATUS,
        state.status_text.clone(),
        "current status",
    ));

    // (2) Local projects — submenu.
    items.push(build_local_projects(state));

    // (3) Cloud projects — submenu (cap + overflow).
    items.push(build_cloud_projects(state));

    // (4) Agents — submenu with three checkmark items.
    items.push(build_agents(state));

    // (5) Observatorium — leaf (gated by GUI passthrough or macOS v2).
    items.push(build_observatorium(state));

    // (6) OpenCode Web — same gating.
    items.push(build_opencode_web(state));

    // (7) GitHub login.
    items.push(build_github_login(state));

    // Footer.
    items.push(MenuItem::disabled(
        ids::VERSION,
        format!("v{} \u{2014} By Tlatoa\u{0304}ni", state.version),
        "informational",
    ));
    items.push(MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"));

    MenuStructure::Ready { items }
}

fn build_local_projects(state: &MenuState) -> MenuItem {
    let mut children: Vec<MenuItem> = state
        .local_projects
        .iter()
        .map(|p| build_project_submenu("local", p, state.podman_ready))
        .collect();
    if children.is_empty() {
        children.push(MenuItem::disabled(
            ids::LOCAL_PROJECTS_EMPTY,
            "(no projects yet)",
            "create a directory under ~/src",
        ));
    }
    MenuItem::submenu(ids::LOCAL_PROJECTS, "\u{1F3E0} ~/src", children)
}

fn build_cloud_projects(state: &MenuState) -> MenuItem {
    let total = state.cloud_projects.len();
    let visible = total.min(MAX_CLOUD_PROJECTS_IN_MENU);

    let mut children: Vec<MenuItem> = state
        .cloud_projects
        .iter()
        .take(visible)
        .map(|p| build_project_submenu("cloud", p, state.podman_ready))
        .collect();

    if children.is_empty() {
        children.push(MenuItem::disabled(
            ids::CLOUD_PROJECTS_EMPTY,
            "(no repos)",
            "no GitHub repos visible to the in-VM gh client",
        ));
    }

    if total > visible {
        children.push(MenuItem::leaf(
            ids::CLOUD_PROJECTS_OVERFLOW,
            format!("\u{2026} All cloud projects ({})\u{2026}", total),
        ));
    }

    MenuItem::submenu(ids::CLOUD_PROJECTS, "\u{2601}\u{FE0F} Cloud", children)
}

fn build_agents(state: &MenuState) -> MenuItem {
    let mut children = Vec::new();
    for agent in [SelectedAgent::Claude, SelectedAgent::Codex, SelectedAgent::OpenCode] {
        children.push(MenuItem::checkmark(
            agent.id(),
            agent.display_name(),
            state.selected_agent == agent,
        ));
    }
    MenuItem::submenu(ids::AGENTS, "\u{1F331} Agents", children)
}

fn build_observatorium(state: &MenuState) -> MenuItem {
    if state.target.defers_gui_to_v2() {
        MenuItem::disabled(
            ids::OBSERVATORIUM,
            "\u{1F52D} Observatorium",
            ids::V2_DISABLED_REASON,
        )
    } else if state.gui_passthrough_available {
        MenuItem::leaf(ids::OBSERVATORIUM, "\u{1F52D} Observatorium")
    } else {
        MenuItem::disabled(
            ids::OBSERVATORIUM,
            "\u{1F52D} Observatorium",
            ids::WSLG_DISABLED_REASON,
        )
    }
}

fn build_opencode_web(state: &MenuState) -> MenuItem {
    if state.target.defers_gui_to_v2() {
        MenuItem::disabled(
            ids::OPENCODE_WEB,
            "\u{1F310} OpenCode Web",
            ids::V2_DISABLED_REASON,
        )
    } else if state.gui_passthrough_available {
        MenuItem::leaf(ids::OPENCODE_WEB, "\u{1F310} OpenCode Web")
    } else {
        MenuItem::disabled(
            ids::OPENCODE_WEB,
            "\u{1F310} OpenCode Web",
            ids::WSLG_DISABLED_REASON,
        )
    }
}

fn build_github_login(state: &MenuState) -> MenuItem {
    match &state.login {
        GithubLoginState::LoggedOut => {
            MenuItem::leaf(ids::GITHUB_LOGIN, "\u{1F511} GitHub Login")
        }
        GithubLoginState::LoggedIn { handle } => MenuItem::disabled(
            ids::GITHUB_LOGIN,
            format!("GitHub: {}", handle),
            "logged in",
        ),
    }
}

fn build_project_submenu(scope: &str, project: &ProjectEntry, podman_ready: bool) -> MenuItem {
    let id = format!("project.{}.{}", scope, project.name);
    let attach_id = format!("{}.attach", id);
    let maintain_id = format!("{}.maintenance", id);

    let attach = if podman_ready {
        MenuItem::leaf(attach_id, "Attach Here")
    } else {
        MenuItem::disabled(attach_id, "Attach Here", "VM is not ready yet")
    };
    let maintain = if podman_ready {
        MenuItem::leaf(maintain_id, "Maintenance")
    } else {
        MenuItem::disabled(maintain_id, "Maintenance", "VM is not ready yet")
    };

    let label = if project.ready && scope == "local" {
        format!("{} (ready)", project.name)
    } else {
        project.name.clone()
    };

    MenuItem::submenu(id, label, vec![attach, maintain])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @trace spec:host-shell-architecture, spec:windows-native-tray
    ///
    /// Build a `MenuState` with 5 local + 22 cloud projects and assert the
    /// resulting `MenuStructure` matches the documented parity contract:
    /// - exactly 9 top-level items (7 contract items + version + quit footer)
    /// - cloud submenu caps at `MAX_CLOUD_PROJECTS_IN_MENU` + 1 overflow leaf
    /// - agent submenu has 3 items (Claude/Codex/OpenCode)
    #[test]
    fn menu_structure_matches_linux_tray_parity() {
        let local = (0..5)
            .map(|i| ProjectEntry {
                name: format!("local-{i}"),
                path: format!("/home/u/src/local-{i}"),
                ready: false,
            })
            .collect::<Vec<_>>();
        let cloud = (0..22)
            .map(|i| ProjectEntry {
                name: format!("cloud-{i}"),
                path: format!("octocat/cloud-{i}"),
                ready: false,
            })
            .collect::<Vec<_>>();

        let state = MenuState {
            status_text: "Ready".to_string(),
            version: "0.0.0".to_string(),
            login: GithubLoginState::LoggedIn {
                handle: "tlatoani".to_string(),
            },
            local_projects: local,
            cloud_projects: cloud,
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: true,
            podman_ready: true,
            target: TargetSurface::WindowsTray,
        };

        let menu = build(&state);
        let items = match &menu {
            MenuStructure::Ready { items } => items,
            other => panic!("expected MenuStructure::Ready, got {other:?}"),
        };

        // 7 contract items + version + quit footer = 9 top-level items.
        assert_eq!(items.len(), 9, "top-level item count");

        let actual_ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            actual_ids,
            vec![
                ids::STATUS,
                ids::LOCAL_PROJECTS,
                ids::CLOUD_PROJECTS,
                ids::AGENTS,
                ids::OBSERVATORIUM,
                ids::OPENCODE_WEB,
                ids::GITHUB_LOGIN,
                ids::VERSION,
                ids::QUIT,
            ],
            "top-level IDs must follow the parity contract",
        );

        // Local projects: 5 children, each a submenu with attach + maintenance.
        let local_node = &items[1];
        assert_eq!(local_node.children.len(), 5);
        for child in &local_node.children {
            assert_eq!(child.children.len(), 2);
        }

        // Cloud projects: cap + 1 overflow leaf = 11 children.
        let cloud_node = &items[2];
        assert_eq!(
            cloud_node.children.len(),
            MAX_CLOUD_PROJECTS_IN_MENU + 1,
            "cloud submenu caps at {} + 1 overflow leaf",
            MAX_CLOUD_PROJECTS_IN_MENU,
        );
        assert_eq!(
            cloud_node.children.last().unwrap().id,
            ids::CLOUD_PROJECTS_OVERFLOW,
        );
        assert!(cloud_node.children.last().unwrap().label.contains("22"));

        // Agents: exactly 3 items.
        let agent_node = &items[3];
        assert_eq!(agent_node.children.len(), 3);
        let agent_ids: Vec<&str> = agent_node.children.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            agent_ids,
            vec![ids::AGENT_CLAUDE, ids::AGENT_CODEX, ids::AGENT_OPENCODE]
        );
        assert!(agent_node.children[0].checked);
        assert!(!agent_node.children[1].checked);
        assert!(!agent_node.children[2].checked);

        // Observatorium + OpenCode Web are enabled because
        // gui_passthrough_available && target=WindowsTray.
        assert!(items[4].enabled);
        assert!(items[5].enabled);

        // GitHub login: "GitHub: tlatoani" (disabled).
        assert!(!items[6].enabled);
        assert!(items[6].label.contains("tlatoani"));
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn macos_target_disables_observatorium_and_opencode_web_for_v2() {
        let state = MenuState {
            gui_passthrough_available: true,
            target: TargetSurface::MacosTray,
            ..MenuState::initial()
        };
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let observ = items.iter().find(|i| i.id == ids::OBSERVATORIUM).unwrap();
        let web = items.iter().find(|i| i.id == ids::OPENCODE_WEB).unwrap();
        assert!(!observ.enabled, "macOS v1 disables Observatorium");
        assert!(!web.enabled, "macOS v1 disables OpenCode Web");
        assert_eq!(
            observ.disabled_reason.as_deref(),
            Some(ids::V2_DISABLED_REASON),
        );
        assert_eq!(
            web.disabled_reason.as_deref(),
            Some(ids::V2_DISABLED_REASON),
        );
    }

    /// @trace spec:windows-native-tray.ui.wslg-chromium-passthrough@v1
    #[test]
    fn wslg_unavailable_disables_browser_items_with_specific_reason() {
        let state = MenuState {
            gui_passthrough_available: false,
            target: TargetSurface::WindowsTray,
            ..MenuState::initial()
        };
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let observ = items.iter().find(|i| i.id == ids::OBSERVATORIUM).unwrap();
        let web = items.iter().find(|i| i.id == ids::OPENCODE_WEB).unwrap();
        assert!(!observ.enabled);
        assert!(!web.enabled);
        assert_eq!(
            observ.disabled_reason.as_deref(),
            Some(ids::WSLG_DISABLED_REASON),
        );
        assert_eq!(
            web.disabled_reason.as_deref(),
            Some(ids::WSLG_DISABLED_REASON),
        );
    }

    /// @trace spec:vm-provisioning-lifecycle
    #[test]
    fn initial_provisioning_menu_has_status_and_quit_only() {
        let menu = MenuStructure::initial_provisioning();
        match menu {
            MenuStructure::Provisioning { items } => {
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].id, ids::STATUS);
                assert!(!items[0].enabled);
                assert_eq!(items[1].id, ids::QUIT);
            }
            other => panic!("expected Provisioning, got {other:?}"),
        }
    }

    #[test]
    fn empty_local_projects_renders_placeholder() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn {
                handle: "u".into(),
            },
            ..MenuState::initial()
        };
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let local = &items[1];
        assert_eq!(local.children.len(), 1);
        assert_eq!(local.children[0].id, ids::LOCAL_PROJECTS_EMPTY);
        assert!(!local.children[0].enabled);
    }

    #[test]
    fn failed_menu_carries_retry_and_open_log() {
        let menu = MenuStructure::failed("rootfs checksum mismatch");
        let items = match menu {
            MenuStructure::Failed { items } => items,
            _ => panic!("expected Failed"),
        };
        assert!(items.iter().any(|i| i.id == "retry" && i.enabled));
        assert!(items.iter().any(|i| i.id == "open-log" && i.enabled));
    }

    #[test]
    fn failed_status_label_truncates_at_80_chars() {
        let long_reason = "x".repeat(200);
        let menu = MenuStructure::failed(long_reason.clone());
        let items = match menu {
            MenuStructure::Failed { items } => items,
            _ => panic!("expected Failed"),
        };
        let status = &items[0];
        // Reason text inside the label is truncated at 80 chars (per spec);
        // a small fixed prefix ("🥀 Provisioning failed: ") is allowed
        // on top of that.
        assert!(
            status.label.chars().count() <= 80 + 32,
            "label should stay near 80 chars, got {} chars",
            status.label.chars().count(),
        );
        // Full reason is preserved in disabled_reason for the tooltip.
        assert_eq!(status.disabled_reason.as_deref(), Some(long_reason.as_str()));
    }

    #[test]
    fn cloud_projects_under_cap_show_no_overflow() {
        let state = MenuState {
            cloud_projects: (0..3)
                .map(|i| ProjectEntry {
                    name: format!("c-{i}"),
                    path: format!("o/c-{i}"),
                    ready: false,
                })
                .collect(),
            ..MenuState::initial()
        };
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let cloud = &items[2];
        assert_eq!(cloud.children.len(), 3);
        assert!(cloud
            .children
            .iter()
            .all(|c| c.id != ids::CLOUD_PROJECTS_OVERFLOW));
    }
}
