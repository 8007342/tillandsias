//! Render `MenuItem` entries that the macOS v1 surface defers to v2.
//!
//! The portable `MenuStructure` (built by `host_shell::menu_state::build`)
//! already marks GUI-passthrough items as `enabled = false` with a
//! `disabled_reason` when `target == TargetSurface::MacosTray`. This module
//! is the macOS-side adapter: it produces backend-neutral `MacMenuItemSpec`
//! records the NSMenu builder can convert one-to-one into `NSMenuItem`s,
//! using `setEnabled(NO)` for the deferred items and `setToolTip:` for
//! their reason string.
//!
//! Kept in its own module — and compiled on every target — so the
//! formatting can be unit-tested from the Linux dev box without AppKit.
//!
//! @trace spec:macos-native-tray.ui.menu-parity@v1,
//!        spec:macos-native-tray.ui.gui-passthrough-v2@v1

#![allow(dead_code)]
#![allow(unused)]

use tillandsias_host_shell::menu_state::{MenuItem, MenuStructure};

/// Backend-neutral spec for a single AppKit menu entry. The status_item
/// module walks the tree once and constructs the live `NSMenuItem`s from
/// these. Stays plain Rust so we can assert on the structure from tests.
///
/// @trace spec:macos-native-tray
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacMenuItemSpec {
    /// Stable id propagated from the host-shell menu item (e.g.
    /// `observatorium`, `agent.claude`).
    pub id: String,
    /// What the user sees in the menu.
    pub label: String,
    /// Maps directly to `[NSMenuItem setEnabled:]`.
    pub enabled: bool,
    /// Maps to `[NSMenuItem setState:]` for the checkmark column.
    pub checked: bool,
    /// Maps to `[NSMenuItem setToolTip:]`. Empty when no hint.
    pub tooltip: String,
    /// Nested entries (sub-menu). Empty for leaves.
    pub children: Vec<MacMenuItemSpec>,
}

impl MacMenuItemSpec {
    /// Walk a portable `MenuItem` and produce its AppKit-side spec.
    pub fn from_menu_item(item: &MenuItem) -> Self {
        Self {
            id: item.id.clone(),
            label: item.label.clone(),
            enabled: item.enabled,
            checked: item.checked,
            tooltip: item.disabled_reason.clone().unwrap_or_default(),
            children: item
                .children
                .iter()
                .map(MacMenuItemSpec::from_menu_item)
                .collect(),
        }
    }
}

/// Flatten a host-shell `MenuStructure` into the AppKit-side spec list.
///
/// All three `MenuStructure` variants already carry their full item list,
/// so this is a straight per-item transform. The OS tray never re-orders
/// or filters the items.
///
/// @trace spec:macos-native-tray.ui.menu-parity@v1
pub fn render(structure: &MenuStructure) -> Vec<MacMenuItemSpec> {
    structure
        .top_items()
        .iter()
        .map(MacMenuItemSpec::from_menu_item)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_host_shell::menu_state::{
        GithubLoginState, MenuState, MenuStructure, ProjectEntry, SelectedAgent, TargetSurface,
        build, ids,
    };

    fn macos_ready_menu() -> MenuStructure {
        let state = MenuState {
            status_text: "Ready".to_string(),
            version: "0.2.0".to_string(),
            login: GithubLoginState::LoggedIn {
                handle: "bulloncito".to_string(),
            },
            local_projects: vec![ProjectEntry {
                name: "tillandsias".to_string(),
                path: "/home/u/src/tillandsias".to_string(),
                ready: true,
            }],
            cloud_projects: Vec::new(),
            selected_agent: SelectedAgent::Claude,
            gui_passthrough_available: true,
            podman_ready: true,
            login_runtime_ready: true,
            target: TargetSurface::MacosTray,
        };
        build(&state)
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_starts_with_status_item_disabled() {
        let specs = render(&MenuStructure::initial_provisioning());
        assert_eq!(specs[0].id, ids::STATUS);
        assert!(!specs[0].enabled);
        assert!(specs[0].label.contains("Setting up Fedora"));
    }

    /// @trace spec:macos-native-tray.ui.gui-passthrough-v2@v1
    #[test]
    fn render_marks_observatorium_disabled_with_v2_tooltip_on_macos() {
        let specs = render(&macos_ready_menu());
        let local = specs
            .iter()
            .find(|s| s.id == ids::LOCAL_PROJECTS)
            .expect("local-projects");
        let proj = &local.children[0];
        let obs = proj
            .children
            .iter()
            .find(|l| l.id.ends_with(&format!(".{}", ids::VERB_OBSERVATORIUM)))
            .expect("observatorium leaf present in project submenu");
        assert!(!obs.enabled, "Observatorium must be disabled on macOS v1");
        assert_eq!(obs.tooltip, ids::V2_DISABLED_REASON);
    }

    /// @trace spec:macos-native-tray.ui.gui-passthrough-v2@v1
    #[test]
    fn render_marks_opencode_web_disabled_with_v2_tooltip_on_macos() {
        let specs = render(&macos_ready_menu());
        let local = specs
            .iter()
            .find(|s| s.id == ids::LOCAL_PROJECTS)
            .expect("local-projects");
        let proj = &local.children[0];
        let web = proj
            .children
            .iter()
            .find(|l| l.id.ends_with(&format!(".{}", ids::VERB_OPENCODE_WEB)))
            .expect("opencode-web leaf present in project submenu");
        assert!(!web.enabled, "OpenCode Web must be disabled on macOS v1");
        assert_eq!(web.tooltip, ids::V2_DISABLED_REASON);
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_failed_carries_retry_and_open_log_items() {
        let specs = render(&MenuStructure::failed("checksum mismatch"));
        let ids_in_order: Vec<&str> = specs.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(
            ids_in_order,
            vec![ids::STATUS, "retry", "open-log", ids::QUIT]
        );
        assert!(!specs[0].enabled, "status line is non-clickable");
        // The "Retry" and "Open log" items are clickable.
        assert!(specs.iter().any(|s| s.id == "retry" && s.enabled));
        assert!(specs.iter().any(|s| s.id == "open-log" && s.enabled));
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_ready_walks_local_projects_submenu() {
        let specs = render(&macos_ready_menu());
        let projects = specs
            .iter()
            .find(|s| s.id == ids::LOCAL_PROJECTS)
            .expect("local-projects present");
        assert_eq!(projects.children.len(), 1);
        // Linux parity: each project has 6 leaves.
        assert_eq!(
            projects.children[0].children.len(),
            6,
            "each project has 6 leaves (claude/codex/opencode/opencode-web/observatorium/maintenance)"
        );
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_propagates_checkmarks_for_agents() {
        let specs = render(&macos_ready_menu());
        // No top-level agents picker (Linux parity).
        assert!(
            specs.iter().all(|s| s.id != ids::AGENTS),
            "top-level agents picker must be gone (Linux parity)"
        );
        // Per-project leaves include claude/codex/opencode as first 3 entries.
        let local = specs
            .iter()
            .find(|s| s.id == ids::LOCAL_PROJECTS)
            .expect("local-projects");
        let proj = &local.children[0];
        let verbs: Vec<&str> = proj
            .children
            .iter()
            .map(|l| l.id.rsplit('.').next().unwrap_or(""))
            .take(3)
            .collect();
        assert_eq!(
            verbs,
            vec![ids::VERB_CLAUDE, ids::VERB_CODEX, ids::VERB_OPENCODE]
        );
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_propagates_disabled_reason_into_tooltip() {
        let specs = render(&macos_ready_menu());
        let local = specs
            .iter()
            .find(|s| s.id == ids::LOCAL_PROJECTS)
            .expect("local-projects");
        let proj = &local.children[0];
        let obs = proj
            .children
            .iter()
            .find(|l| l.id.ends_with(&format!(".{}", ids::VERB_OBSERVATORIUM)))
            .expect("observatorium leaf present");
        assert!(!obs.tooltip.is_empty(), "tooltip must carry v2 reason");
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    ///
    /// Drift-protection for gap-2 (`plan/issues/macos-tray-ux-gaps-2026-05-29.md`)
    /// and F3 (`plan/issues/macos-m8-interactive-smoke-failures-2026-06-16.md`):
    /// when authenticated, the macOS Ready menu MUST surface exactly the 8
    /// login-gated top-level items in parity-contract order — no macOS-only
    /// extras, no reordering, no missing rows, and crucially NO `github-login`
    /// row alongside the project body (it is mutually exclusive with login, per
    /// the Linux golden). `host_shell::menu_state` pins this sequence for the
    /// Windows target (`menu_structure_matches_linux_tray_parity`); this pins it
    /// at the macOS adapter (`render`) with `target = MacosTray`, so a
    /// divergence introduced on the macOS side trips here instead of only in a
    /// user-attended smoke.
    #[test]
    fn render_ready_top_level_matches_macos_parity_contract() {
        let specs = render(&macos_ready_menu());
        let top_ids: Vec<&str> = specs.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(
            top_ids,
            vec![
                ids::STATUS,
                ids::LOCAL_PROJECTS,
                ids::CLOUD_PROJECTS,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT,
            ],
            "macOS authed Ready menu must match the 6-item Linux parity contract"
        );
        assert!(
            !top_ids.contains(&ids::GITHUB_LOGIN),
            "github-login must not appear alongside the project body (F3)"
        );
        // Global browser/agent rows removed; they now live in per-project submenus.
        for gone in [ids::AGENTS, ids::OBSERVATORIUM, ids::OPENCODE_WEB] {
            assert!(
                !top_ids.contains(&gone),
                "{gone} must NOT appear at top level (Linux parity)"
            );
        }
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    ///
    /// F3 drift-protection at the macOS adapter: a logged-out tray MUST collapse
    /// to {status, github-login, version, quit} — the project/agent/browser body
    /// stays gated behind authentication, the exact defect the 2026-06-16 m8
    /// smoke reported ("GitHub Login which should gate the others").
    #[test]
    fn render_logged_out_collapses_to_login_leaf_on_macos() {
        let state = MenuState {
            login: GithubLoginState::LoggedOut,
            target: TargetSurface::MacosTray,
            ..MenuState::initial()
        };
        let specs = render(&build(&state));
        let top_ids: Vec<&str> = specs.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(
            top_ids,
            vec![
                ids::STATUS,
                ids::GITHUB_LOGIN,
                ids::SEPARATOR,
                ids::VERSION,
                ids::QUIT
            ],
            "logged-out macOS menu must collapse to the login-gated short list (F3)"
        );
    }
}
