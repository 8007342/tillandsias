//! Portable menu-click resolution shared by the native trays.
//!
//! The OS trays correlate a click back to a stable string id — either a
//! constant from [`crate::menu_state::ids`] or a dynamic
//! `project.<scope>.<name>.<verb>` id minted by
//! `menu_state::build_project_submenu`. This module maps those ids to a typed
//! [`MenuAction`] so the Windows (Win32 `WM_COMMAND`) and macOS (AppKit
//! target/action) dispatch paths share ONE resolution table instead of each
//! re-parsing id strings. Keeping it here is the convergence point: a new
//! menu id is wired once, for every tray.
//!
//! @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray

#![allow(dead_code)]

use crate::menu_state::{SelectedAgent, ids};

/// Which project list a clicked project entry came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectScope {
    Local,
    Cloud,
}

impl ProjectScope {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "local" => Some(ProjectScope::Local),
            "cloud" => Some(ProjectScope::Cloud),
            _ => None,
        }
    }
}

/// A resolved, typed tray action. `Inert` covers disabled/informational items
/// (status line, version footer, empty placeholders) and any unrecognised id —
/// the trays simply do nothing for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuAction {
    Quit,
    GithubLogin,
    OpenObservatorium,
    OpenOpenCodeWeb,
    SelectAgent(SelectedAgent),
    Attach { scope: ProjectScope, name: String },
    Maintain { scope: ProjectScope, name: String },
    CloudOverflow,
    Retry,
    OpenLog,
    Inert,
}

/// Resolve a menu item's stable string id to a typed [`MenuAction`].
///
/// Unknown ids and non-actionable headers resolve to [`MenuAction::Inert`].
///
/// @trace spec:host-shell-architecture
pub fn resolve(id: &str) -> MenuAction {
    match id {
        ids::QUIT => MenuAction::Quit,
        ids::GITHUB_LOGIN => MenuAction::GithubLogin,
        ids::OBSERVATORIUM => MenuAction::OpenObservatorium,
        ids::OPENCODE_WEB => MenuAction::OpenOpenCodeWeb,
        ids::AGENT_CLAUDE => MenuAction::SelectAgent(SelectedAgent::Claude),
        ids::AGENT_CODEX => MenuAction::SelectAgent(SelectedAgent::Codex),
        ids::AGENT_OPENCODE => MenuAction::SelectAgent(SelectedAgent::OpenCode),
        ids::CLOUD_PROJECTS_OVERFLOW => MenuAction::CloudOverflow,
        "retry" => MenuAction::Retry,
        "open-log" => MenuAction::OpenLog,
        other => resolve_project(other).unwrap_or(MenuAction::Inert),
    }
}

/// Parse a dynamic `project.<scope>.<name>.<verb>` id. The project name may
/// itself contain dots (a `~/src` directory basename like `my.app`), so the
/// scope is taken as the first segment and the verb as the trailing suffix;
/// everything between is the name.
fn resolve_project(id: &str) -> Option<MenuAction> {
    let rest = id.strip_prefix("project.")?;
    let (scope_str, after_scope) = rest.split_once('.')?;
    let scope = ProjectScope::parse(scope_str)?;
    if let Some(name) = after_scope.strip_suffix(".attach") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
        });
    }
    if let Some(name) = after_scope.strip_suffix(".maintenance") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Maintain {
            scope,
            name: name.to_string(),
        });
    }
    // A bare `project.<scope>.<name>` is the submenu header — not actionable.
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_static_ids() {
        assert_eq!(resolve(ids::QUIT), MenuAction::Quit);
        assert_eq!(resolve(ids::GITHUB_LOGIN), MenuAction::GithubLogin);
        assert_eq!(resolve(ids::OBSERVATORIUM), MenuAction::OpenObservatorium);
        assert_eq!(resolve(ids::OPENCODE_WEB), MenuAction::OpenOpenCodeWeb);
        assert_eq!(
            resolve(ids::CLOUD_PROJECTS_OVERFLOW),
            MenuAction::CloudOverflow
        );
        assert_eq!(resolve("retry"), MenuAction::Retry);
        assert_eq!(resolve("open-log"), MenuAction::OpenLog);
    }

    #[test]
    fn resolves_agent_selection() {
        assert_eq!(
            resolve(ids::AGENT_CLAUDE),
            MenuAction::SelectAgent(SelectedAgent::Claude)
        );
        assert_eq!(
            resolve(ids::AGENT_CODEX),
            MenuAction::SelectAgent(SelectedAgent::Codex)
        );
        assert_eq!(
            resolve(ids::AGENT_OPENCODE),
            MenuAction::SelectAgent(SelectedAgent::OpenCode)
        );
    }

    #[test]
    fn resolves_project_attach_and_maintenance() {
        assert_eq!(
            resolve("project.local.myapp.attach"),
            MenuAction::Attach {
                scope: ProjectScope::Local,
                name: "myapp".to_string()
            }
        );
        assert_eq!(
            resolve("project.cloud.octocat-repo.maintenance"),
            MenuAction::Maintain {
                scope: ProjectScope::Cloud,
                name: "octocat-repo".to_string()
            }
        );
    }

    /// Project basenames can contain dots; the verb suffix must still parse.
    #[test]
    fn resolves_project_name_with_dots() {
        assert_eq!(
            resolve("project.local.my.dotted.app.attach"),
            MenuAction::Attach {
                scope: ProjectScope::Local,
                name: "my.dotted.app".to_string()
            }
        );
    }

    #[test]
    fn submenu_header_and_unknown_ids_are_inert() {
        // Bare submenu header (no verb) is not actionable.
        assert_eq!(resolve("project.local.myapp"), MenuAction::Inert);
        // Unknown scope.
        assert_eq!(resolve("project.weird.myapp.attach"), MenuAction::Inert);
        // Empty name.
        assert_eq!(resolve("project.local..attach"), MenuAction::Inert);
        // Disabled/informational ids.
        assert_eq!(resolve(ids::STATUS), MenuAction::Inert);
        assert_eq!(resolve(ids::VERSION), MenuAction::Inert);
        assert_eq!(resolve(ids::LOCAL_PROJECTS_EMPTY), MenuAction::Inert);
        // Totally unknown.
        assert_eq!(resolve("nonsense"), MenuAction::Inert);
    }
}
