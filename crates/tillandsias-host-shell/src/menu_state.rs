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
    /// Separator rendered before the footer (version/quit).
    pub const SEPARATOR: &str = "---";
    pub const GITHUB_LOGIN: &str = "github-login";
    pub const VERSION: &str = "version";
    /// Intentional EPHEMERAL RESET (windows-260717-4): one-click wipe +
    /// reprovision of the guest. Destructive by design — the guest+vault are
    /// disposable; state of value lives in the cloud and the only cost is one
    /// re-authentication. Always visible (Quit-adjacent footer leaf) so a
    /// wedged guest can be recovered even when nothing else in the menu works.
    pub const RESET_GUEST: &str = "reset-guest";
    pub const QUIT: &str = "quit";

    // Legacy global-picker IDs — no longer emitted by `build()` but kept so
    // the action resolver still compiles.
    pub const AGENTS: &str = "agents";
    pub const AGENT_CLAUDE: &str = "agent.claude";
    pub const AGENT_CODEX: &str = "agent.codex";
    pub const AGENT_OPENCODE: &str = "agent.opencode";
    pub const AGENT_ANTIGRAVITY: &str = "agent.antigravity";
    pub const OBSERVATORIUM: &str = "observatorium";
    pub const OPENCODE_WEB: &str = "opencode-web";

    // Per-project action verb suffixes — used by `build_project_submenu` and
    // resolved by `menu_action::resolve_project`.
    pub const VERB_CLAUDE: &str = "claude";
    pub const VERB_CODEX: &str = "codex";
    pub const VERB_OPENCODE: &str = "opencode";
    pub const VERB_ANTIGRAVITY: &str = "antigravity";
    pub const VERB_OPENCODE_WEB: &str = "opencode-web";
    pub const VERB_OBSERVATORIUM: &str = "observatorium";
    pub const VERB_MAINTENANCE: &str = "maintenance";

    /// Tooltip shown for items deferred to v2 on macOS.
    pub const V2_DISABLED_REASON: &str = "v2 — terminal-only in v1";
    /// Tooltip shown for browser items on WSLg-less Windows hosts.
    pub const WSLG_DISABLED_REASON: &str = "Requires Windows 11 + WSLg";
}

/// Hard cap for the tray chip. The UI backends should never surface a
/// longer string than this in the status row.
pub const TRAY_STATUS_CHIP_MAX_CHARS: usize = 37;

/// Short boot label used before the VM has emitted a richer state.
pub const BOOT_STATUS_TEXT: &str = "\u{1F535} Booting\u{2026}";

/// Clamp a tray chip string to the visible budget. Keeps the string
/// readable without allowing a long event payload to push the chip past
/// the intended 37-character menu-bar budget.
pub fn clamp_tray_status_chip(text: impl AsRef<str>) -> String {
    let text = text.as_ref();
    if text.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS {
        return text.to_string();
    }

    let mut out = String::with_capacity(TRAY_STATUS_CHIP_MAX_CHARS);
    for ch in text.chars().take(TRAY_STATUS_CHIP_MAX_CHARS - 1) {
        out.push(ch);
    }
    out.push('\u{2026}');
    out
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

    pub fn checkmark(id: impl Into<String>, label: impl Into<String>, checked: bool) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            enabled: true,
            disabled_reason: None,
            checked,
            children: Vec::new(),
        }
    }

    /// A visual separator. Backends render this as a horizontal rule.
    /// Use `ids::SEPARATOR` as the id so the renderer can detect it.
    pub fn separator() -> Self {
        Self {
            id: ids::SEPARATOR.to_string(),
            label: String::new(),
            enabled: false,
            disabled_reason: None,
            checked: false,
            children: Vec::new(),
        }
    }

    pub fn is_separator(&self) -> bool {
        self.id == ids::SEPARATOR
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
    Antigravity,
}

impl SelectedAgent {
    pub fn display_name(self) -> &'static str {
        match self {
            SelectedAgent::Claude => "Claude",
            SelectedAgent::Codex => "Codex",
            SelectedAgent::OpenCode => "OpenCode",
            SelectedAgent::Antigravity => "Antigravity",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            SelectedAgent::Claude => ids::AGENT_CLAUDE,
            SelectedAgent::Codex => ids::AGENT_CODEX,
            SelectedAgent::OpenCode => ids::AGENT_OPENCODE,
            SelectedAgent::Antigravity => ids::AGENT_ANTIGRAVITY,
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
///
/// windows-260719-2: a THREE-state machine, not a boolean. `LoggingIn` is a
/// purely LOCAL, transitional state each tray flips synchronously on the
/// GitHub Login menu click — before any wire round-trip — and clears on the
/// next CONFIRMED login observation (a `LoginStatePush` / login-status reply
/// maps only to `LoggedIn`/`LoggedOut`, so a confirmed probe always
/// overwrites it: success renders logged-in, an invalid/missing token falls
/// back to the `GitHub Login` leaf, never a stale rendering). Deliberately
/// NOT a wire variant: the click is a local signal (the packet's
/// local-flag-preferred design), and no concrete cross-client in-progress
/// coordination need has surfaced that would justify widening
/// `LoginStatePush`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum GithubLoginState {
    LoggedOut,
    /// The login flow has been started from this tray and the confirming
    /// probe has not yet reported. Renders as a disabled "Logging in…" row
    /// in place of the actionable login leaf.
    LoggingIn,
    LoggedIn {
        handle: String,
    },
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
    pub guest_version: Option<String>,
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
    /// True when the runtime is ready to execute GitHub Login (init complete
    /// plus Vault/git/egress containers up). When false and logged out, replaces
    /// the GitHub Login item with a disabled "Setting up\u{2026}" entry so the
    /// user does not attempt login before the runtime is healthy.
    pub login_runtime_ready: bool,
    /// Target UI backend. Drives macOS's "(v2)" defer markers.
    pub target: TargetSurface,
}

impl MenuState {
    /// Baseline test state: cold-start, no projects, logged-out, podman
    /// not ready, target=WindowsTray.
    pub fn initial() -> Self {
        Self {
            guest_version: None,
            status_text: BOOT_STATUS_TEXT.to_string(),
            version: crate::version().to_string(),
            login: GithubLoginState::LoggedOut,
            local_projects: Vec::new(),
            cloud_projects: Vec::new(),
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: false,
            podman_ready: false,
            login_runtime_ready: false,
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
                MenuItem::disabled(ids::STATUS, BOOT_STATUS_TEXT, "VM is provisioning"),
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
/// The returned menu matches the Linux tray `build_menu` structure 1:1.
/// OS-specific trays only translate labels + click IDs into native APIs;
/// they MUST NOT reorder or filter items.
///
/// ## Top-level item contract (Ready) — login-gated
///
/// The body is **auth-gated**: exactly one of `{github-login}` OR
/// `{~/src, Cloud}` is emitted, never both — matching the Linux golden.
/// Agent selection lives inside each per-project submenu, not at top level.
///
/// Logged **out** (collapsed) — 6 items:
/// 1. `status` — disabled, current status line
/// 2. `github-login` — `🔑 GitHub Login` leaf (or `📋 Setting up…` if not ready)
/// 3. `---` — separator
/// 4. `version` — disabled footer
/// 5. `reset-guest` — `♻️ Reset Guest…` (always enabled; windows-260717-4)
/// 6. `quit`
///
/// Logged **in** (expanded) — 7 items:
/// 1. `status`
/// 2. `local-projects` — submenu of `~/src` entries; each project has
///    Claude / Codex / OpenCode / OpenCode Web / Observatorium / Maintenance
/// 3. `cloud-projects` — submenu capped at `MAX_CLOUD_PROJECTS_IN_MENU` + overflow
/// 4. `---` — separator
/// 5. `version` — disabled footer
/// 6. `reset-guest` — `♻️ Reset Guest…` (always enabled; windows-260717-4)
/// 7. `quit`
///
/// @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray
pub fn build(state: &MenuState) -> MenuStructure {
    let mut items = Vec::new();

    // (1) Status — always disabled, always first.
    items.push(MenuItem::disabled(
        ids::STATUS,
        clamp_tray_status_chip(&state.status_text),
        "current status",
    ));

    // (2) Auth-gated body. Mirror the Linux golden `build_menu`: emit exactly
    //     one of {GitHub Login} OR {~/src + Cloud}, never both.
    match &state.login {
        GithubLoginState::LoggedOut => {
            if state.login_runtime_ready {
                items.push(MenuItem::leaf(ids::GITHUB_LOGIN, "\u{1F511} GitHub Login"));
            } else {
                items.push(MenuItem::disabled(
                    ids::GITHUB_LOGIN,
                    "\u{1F4CB} Setting up\u{2026}",
                    "login runtime not ready",
                ));
            }
        }
        GithubLoginState::LoggingIn => {
            // windows-260719-2: transitional state, flipped locally on the
            // login click before any wire round-trip. Disabled (a second
            // click mid-flow is meaningless) in the same short-list slot as
            // the login leaf, mirroring the "Setting up…" disabled-item
            // pattern above. Cleared by the next confirmed probe reply.
            items.push(MenuItem::disabled(
                ids::GITHUB_LOGIN,
                "\u{1F504} Logging in\u{2026}",
                "login in progress",
            ));
        }
        GithubLoginState::LoggedIn { .. } => {
            // Local projects — submenu with per-project agent leaves.
            items.push(build_local_projects(state));
            // Cloud projects — submenu (cap + overflow).
            items.push(build_cloud_projects(state));
        }
    }

    // (3) Separator before footer — matches Linux tray.
    items.push(MenuItem::separator());

    let mut ver_str = format!("v{} \u{2014} By Tlatoa\u{0304}ni", state.version);
    if let Some(ref guest_ver) = state.guest_version
        && guest_ver != &state.version
    {
        ver_str.push_str(" (Update Pending)");
    }

    // (4) Footer. Reset Guest sits Quit-adjacent and is ALWAYS enabled —
    //     it is the designed recovery affordance for a wedged guest, so it
    //     must never itself be gated on the guest being healthy
    //     (windows-260717-4; ephemeral doctrine: destructive ok, one re-auth).
    items.push(MenuItem::disabled(ids::VERSION, ver_str, "informational"));
    items.push(MenuItem::leaf(
        ids::RESET_GUEST,
        "\u{267B}\u{FE0F} Reset Guest\u{2026}",
    ));
    items.push(MenuItem::leaf(ids::QUIT, "\u{274C} Quit Tillandsias"));

    MenuStructure::Ready { items }
}

fn build_local_projects(state: &MenuState) -> MenuItem {
    let mut children: Vec<MenuItem> = state
        .local_projects
        .iter()
        .map(|p| build_project_submenu("local", p, state.podman_ready, state.target))
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
        .map(|p| build_project_submenu("cloud", p, state.podman_ready, state.target))
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

// Legacy top-level helpers — no longer called from `build()` (moved into
// per-project submenus for Linux parity). Retained for reference.
#[allow(dead_code)]
fn build_agents(state: &MenuState) -> MenuItem {
    let mut children = Vec::new();
    for agent in [
        SelectedAgent::Claude,
        SelectedAgent::Codex,
        SelectedAgent::OpenCode,
        SelectedAgent::Antigravity,
    ] {
        children.push(MenuItem::checkmark(
            agent.id(),
            agent.display_name(),
            state.selected_agent == agent,
        ));
    }
    MenuItem::submenu(ids::AGENTS, "\u{1F331} Agents", children)
}

#[allow(dead_code)]
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

#[allow(dead_code)]
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

fn build_project_submenu(
    scope: &str,
    project: &ProjectEntry,
    podman_ready: bool,
    target: TargetSurface,
) -> MenuItem {
    let id = format!("project.{}.{}", scope, project.name);

    // Browser-launching leaves (OpenCode Web, Observatorium) are deferred to
    // v2 on macOS because AppKit trays can't open GUI windows in v1.
    let browser_verbs = &[ids::VERB_OPENCODE_WEB, ids::VERB_OBSERVATORIUM];

    let leaves: &[(&str, &str)] = &[
        (ids::VERB_CLAUDE, "\u{1F47E} Claude"),
        (ids::VERB_CODEX, "\u{1F3D7}\u{FE0F} Codex"),
        (ids::VERB_OPENCODE, "\u{1F4BB} OpenCode"),
        (ids::VERB_ANTIGRAVITY, "\u{1FA90} Antigravity"),
        (ids::VERB_OPENCODE_WEB, "\u{1F4D0} OpenCode Web"),
        (ids::VERB_OBSERVATORIUM, "\u{1F52D} Observatorium"),
        (ids::VERB_MAINTENANCE, "\u{1F527} Maintenance"),
    ];

    let children = leaves
        .iter()
        .map(|(verb, label)| {
            let leaf_id = format!("{}.{}", id, verb);
            if target.defers_gui_to_v2() && browser_verbs.contains(verb) {
                MenuItem::disabled(leaf_id, *label, ids::V2_DISABLED_REASON)
            } else if podman_ready {
                MenuItem::leaf(leaf_id, *label)
            } else {
                MenuItem::disabled(leaf_id, *label, "VM is not ready yet")
            }
        })
        .collect();

    let label = if project.ready && scope == "local" {
        format!("{} \u{2713}", project.name)
    } else {
        project.name.clone()
    };

    MenuItem::submenu(id, label, children)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @trace spec:host-shell-architecture, spec:windows-native-tray
    ///
    /// Logged-in menu: status + ~/src submenu + Cloud submenu + separator +
    /// version + quit = 6 top-level items, matching the Linux tray 1:1.
    /// Agent selection lives inside each per-project submenu (6 leaves each).
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
            guest_version: None,
            login_runtime_ready: true,
            target: TargetSurface::WindowsTray,
        };

        let menu = build(&state);
        let items = match &menu {
            MenuStructure::Ready { items } => items,
            other => panic!("expected MenuStructure::Ready, got {other:?}"),
        };

        // status + local + cloud + separator + version + reset-guest + quit
        // = 7 top-level items (reset-guest added by windows-260717-4).
        assert_eq!(
            items.len(),
            7,
            "top-level item count (authenticated, Linux parity)"
        );

        let actual_ids: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            actual_ids,
            vec![
                ids::STATUS,
                ids::LOCAL_PROJECTS,
                ids::CLOUD_PROJECTS,
                ids::SEPARATOR,
                ids::VERSION,
                ids::RESET_GUEST,
                ids::QUIT,
            ],
            "top-level IDs must follow the Linux-parity contract",
        );
        assert!(
            !actual_ids.contains(&ids::GITHUB_LOGIN),
            "github-login must NOT appear alongside the project body",
        );
        // Global Agents/Observatorium/OpenCode Web no longer at top level.
        for gone in [ids::AGENTS, ids::OBSERVATORIUM, ids::OPENCODE_WEB] {
            assert!(
                !actual_ids.contains(&gone),
                "{gone} must NOT appear at top level"
            );
        }

        // Local projects: 5 children, each a submenu with 7 per-project
        // leaves (Antigravity added 2026-07-11 for Linux parity).
        let local_node = &items[1];
        assert_eq!(local_node.children.len(), 5);
        for child in &local_node.children {
            assert_eq!(
                child.children.len(),
                7,
                "each project has 7 agent/action leaves"
            );
            let verbs: Vec<&str> = child
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
    }

    /// @trace spec:host-shell-architecture, spec:macos-native-tray.ui.menu-parity@v1
    ///
    /// Logged-out collapses to exactly
    /// {status, github-login, separator, version, quit} — the project body is
    /// gated behind authentication (mirrors the Linux golden).
    #[test]
    fn logged_out_menu_collapses_to_login_leaf() {
        let state = MenuState {
            login: GithubLoginState::LoggedOut,
            login_runtime_ready: true,
            // Projects present but must NOT surface while logged out.
            local_projects: vec![ProjectEntry {
                name: "secret".into(),
                path: "/home/u/src/secret".into(),
                ready: false,
            }],
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::RESET_GUEST,
                ids::QUIT
            ],
            "logged-out menu must collapse to the login-gated short list",
        );
        // The login item is an actionable leaf.
        let login = &items[1];
        assert!(login.enabled);
        assert!(login.children.is_empty());
        // None of the gated bodies leaked through.
        for gated in [ids::LOCAL_PROJECTS, ids::CLOUD_PROJECTS] {
            assert!(
                !ids_seen.contains(&gated),
                "{gated} must be hidden while logged out",
            );
        }
    }

    /// @trace spec:host-shell-architecture
    #[test]
    fn logged_out_menu_shows_setting_up_when_runtime_not_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedOut,
            login_runtime_ready: false,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::RESET_GUEST,
                ids::QUIT
            ],
            "logged-out menu must still collapse to the short list",
        );
        let login = &items[1];
        assert!(!login.enabled);
        assert_eq!(
            login.disabled_reason.as_deref(),
            Some("login runtime not ready")
        );
        assert!(login.label.contains("Setting up"));
    }

    /// windows-260719-2: the transitional `LoggingIn` state renders a
    /// disabled "Logging in…" row in the login slot — same collapsed short
    /// list as logged-out (the project body stays auth-gated), no actionable
    /// login leaf (a second click mid-flow is meaningless).
    #[test]
    fn logging_in_menu_shows_disabled_logging_in_row() {
        let state = MenuState {
            login: GithubLoginState::LoggingIn,
            login_runtime_ready: true,
            local_projects: vec![ProjectEntry {
                name: "secret".into(),
                path: "/home/u/src/secret".into(),
                ready: false,
            }],
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        let ids_seen: Vec<&str> = items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(
            ids_seen,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::RESET_GUEST,
                ids::QUIT
            ],
            "logging-in menu keeps the collapsed short list",
        );
        let login = &items[1];
        assert!(!login.enabled, "the in-progress row must not be clickable");
        assert!(login.label.contains("Logging in"));
        assert_eq!(login.disabled_reason.as_deref(), Some("login in progress"));
        // The gated project body must NOT leak through mid-login.
        for gated in [ids::LOCAL_PROJECTS, ids::CLOUD_PROJECTS] {
            assert!(!ids_seen.contains(&gated), "{gated} hidden while LoggingIn");
        }
    }

    /// Per-project leaves are gated on podman_ready — when podman is not ready
    /// all 6 leaves are disabled with a "VM is not ready yet" reason.
    #[test]
    fn per_project_leaves_disabled_when_podman_not_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            local_projects: vec![ProjectEntry {
                name: "myapp".into(),
                path: "/home/u/src/myapp".into(),
                ready: false,
            }],
            podman_ready: false,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let proj = &items[1].children[0];
        assert_eq!(proj.children.len(), 7);
        assert!(proj.children.iter().all(|l| !l.enabled));
        assert!(
            proj.children
                .iter()
                .all(|l| { l.disabled_reason.as_deref() == Some("VM is not ready yet") })
        );
    }

    /// Per-project leaves are enabled when podman is ready.
    #[test]
    fn per_project_leaves_enabled_when_podman_ready() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
            local_projects: vec![ProjectEntry {
                name: "myapp".into(),
                path: "/home/u/src/myapp".into(),
                ready: false,
            }],
            podman_ready: true,
            ..MenuState::initial()
        };
        let items = match build(&state) {
            MenuStructure::Ready { items } => items,
            _ => panic!("expected Ready"),
        };
        let proj = &items[1].children[0];
        assert_eq!(proj.children.len(), 7);
        assert!(proj.children.iter().all(|l| l.enabled));
        // IDs follow the project.local.<name>.<verb> scheme.
        assert!(proj.children[0].id.ends_with(".claude"));
        assert!(proj.children[3].id.ends_with(".antigravity"));
        assert!(proj.children[6].id.ends_with(".maintenance"));
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
    fn tray_status_chip_clamps_to_37_chars() {
        let raw = format!("🟢 Ready · {}", "x".repeat(80));
        let clamped = clamp_tray_status_chip(&raw);
        assert!(
            clamped.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS,
            "chip should stay within the 37-char budget: {clamped:?}"
        );
        assert!(
            clamped.ends_with('…'),
            "overlong chip should be ellipsized, got {clamped:?}"
        );
    }

    #[test]
    fn initial_menu_uses_short_boot_status() {
        let state = MenuState::initial();
        assert_eq!(state.status_text, BOOT_STATUS_TEXT);
        let menu = build(&state);
        let items = match menu {
            MenuStructure::Ready { items } => items,
            other => panic!("expected Ready, got {other:?}"),
        };
        assert_eq!(items[0].label, BOOT_STATUS_TEXT);
        assert!(items[0].label.chars().count() <= TRAY_STATUS_CHIP_MAX_CHARS);
    }

    #[test]
    fn empty_local_projects_renders_placeholder() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
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
        assert_eq!(
            status.disabled_reason.as_deref(),
            Some(long_reason.as_str())
        );
    }

    #[test]
    fn cloud_projects_under_cap_show_no_overflow() {
        let state = MenuState {
            login: GithubLoginState::LoggedIn { handle: "u".into() },
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
        assert!(
            cloud
                .children
                .iter()
                .all(|c| c.id != ids::CLOUD_PROJECTS_OVERFLOW)
        );
    }

    /// windows-260717-4: the intentional ephemeral-reset affordance is an
    /// ALWAYS-enabled, Quit-adjacent leaf in every auth state — a wedged
    /// guest must be recoverable from the menu no matter what else is broken.
    #[test]
    fn reset_guest_leaf_always_present_and_enabled() {
        for login in [
            GithubLoginState::LoggedOut,
            GithubLoginState::LoggingIn,
            GithubLoginState::LoggedIn { handle: "u".into() },
        ] {
            let state = MenuState {
                login,
                ..MenuState::initial()
            };
            let items = match build(&state) {
                MenuStructure::Ready { items } => items,
                other => panic!("expected Ready, got {other:?}"),
            };
            let reset = items
                .iter()
                .find(|i| i.id == ids::RESET_GUEST)
                .expect("reset-guest leaf must be present in every auth state");
            assert!(reset.enabled, "reset-guest must never be gated/disabled");
            assert!(reset.children.is_empty(), "reset-guest is a leaf");
            assert!(reset.label.contains("Reset Guest"));
            // Quit-adjacent: immediately before the quit item.
            let reset_idx = items.iter().position(|i| i.id == ids::RESET_GUEST).unwrap();
            let quit_idx = items.iter().position(|i| i.id == ids::QUIT).unwrap();
            assert_eq!(reset_idx + 1, quit_idx, "reset-guest sits right above Quit");
        }
    }
}
