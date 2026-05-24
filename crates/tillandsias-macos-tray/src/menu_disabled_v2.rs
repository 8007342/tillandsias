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
        build, GithubLoginState, MenuState, MenuStructure, ProjectEntry, SelectedAgent,
        TargetSurface, ids,
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
        let obs = specs
            .iter()
            .find(|s| s.id == ids::OBSERVATORIUM)
            .expect("Observatorium present");
        assert!(!obs.enabled, "Observatorium must be disabled on macOS v1");
        assert_eq!(obs.tooltip, ids::V2_DISABLED_REASON);
    }

    /// @trace spec:macos-native-tray.ui.gui-passthrough-v2@v1
    #[test]
    fn render_marks_opencode_web_disabled_with_v2_tooltip_on_macos() {
        let specs = render(&macos_ready_menu());
        let web = specs
            .iter()
            .find(|s| s.id == ids::OPENCODE_WEB)
            .expect("OpenCode Web present");
        assert!(!web.enabled);
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
        // Each project becomes a sub-menu with attach + maintenance children.
        assert_eq!(projects.children[0].children.len(), 2);
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_propagates_checkmarks_for_agents() {
        let specs = render(&macos_ready_menu());
        let agents = specs.iter().find(|s| s.id == ids::AGENTS).expect("agents");
        assert_eq!(agents.children.len(), 3);
        // Default selected agent is Claude in macos_ready_menu().
        assert!(
            agents
                .children
                .iter()
                .find(|c| c.id == ids::AGENT_CLAUDE)
                .unwrap()
                .checked
        );
        assert!(
            !agents
                .children
                .iter()
                .find(|c| c.id == ids::AGENT_CODEX)
                .unwrap()
                .checked
        );
    }

    /// @trace spec:macos-native-tray.ui.menu-parity@v1
    #[test]
    fn render_propagates_disabled_reason_into_tooltip() {
        let specs = render(&macos_ready_menu());
        let observ = specs
            .iter()
            .find(|s| s.id == ids::OBSERVATORIUM)
            .expect("present");
        assert!(!observ.tooltip.is_empty(), "tooltip must carry v2 reason");
    }
}
