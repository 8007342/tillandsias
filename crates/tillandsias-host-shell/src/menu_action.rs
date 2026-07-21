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
    /// Intentional EPHEMERAL RESET (windows-260717-4): wipe the guest
    /// (unregister the WSL distro / delete the VZ boot artifacts / tear down
    /// the podman enclave) and reprovision from scratch. Destructive by
    /// design; the only cost is one re-authentication.
    ResetGuest,
    /// Per-project attach with an explicit agent (from the per-project submenu).
    Attach {
        scope: ProjectScope,
        name: String,
        agent: SelectedAgent,
    },
    Maintain {
        scope: ProjectScope,
        name: String,
    },
    /// OpenCode Web launched for a specific project.
    ProjectOpenCodeWeb {
        scope: ProjectScope,
        name: String,
    },
    /// Observatorium launched for a specific project.
    ProjectObservatorium {
        scope: ProjectScope,
        name: String,
    },
    CloudOverflow,
    Retry,
    OpenLog,
    // Legacy global-picker actions — kept so old dispatch paths compile, but
    // no longer emitted by the menu. Will be removed in a future cleanup.
    OpenObservatorium,
    OpenOpenCodeWeb,
    SelectAgent(SelectedAgent),
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
        ids::RESET_GUEST => MenuAction::ResetGuest,
        // Legacy global-picker IDs — still handled for backward compat.
        ids::OBSERVATORIUM => MenuAction::OpenObservatorium,
        ids::OPENCODE_WEB => MenuAction::OpenOpenCodeWeb,
        ids::AGENT_CLAUDE => MenuAction::SelectAgent(SelectedAgent::Claude),
        ids::AGENT_CODEX => MenuAction::SelectAgent(SelectedAgent::Codex),
        ids::AGENT_OPENCODE => MenuAction::SelectAgent(SelectedAgent::OpenCode),
        ids::AGENT_ANTIGRAVITY => MenuAction::SelectAgent(SelectedAgent::Antigravity),
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

    // Per-agent attach verbs (Linux-parity per-project leaves).
    if let Some(name) = after_scope.strip_suffix(".claude") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
            agent: SelectedAgent::Claude,
        });
    }
    if let Some(name) = after_scope.strip_suffix(".codex") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
            agent: SelectedAgent::Codex,
        });
    }
    if let Some(name) = after_scope.strip_suffix(".opencode") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
            agent: SelectedAgent::OpenCode,
        });
    }
    if let Some(name) = after_scope.strip_suffix(".antigravity") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
            agent: SelectedAgent::Antigravity,
        });
    }
    if let Some(name) = after_scope.strip_suffix(".opencode-web") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::ProjectOpenCodeWeb {
            scope,
            name: name.to_string(),
        });
    }
    if let Some(name) = after_scope.strip_suffix(".observatorium") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::ProjectObservatorium {
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
    // Legacy .attach verb — maps to Claude (default agent).
    if let Some(name) = after_scope.strip_suffix(".attach") {
        if name.is_empty() {
            return None;
        }
        return Some(MenuAction::Attach {
            scope,
            name: name.to_string(),
            agent: SelectedAgent::Claude,
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
        // windows-260717-4: the ephemeral-reset leaf resolves for every tray.
        assert_eq!(resolve(ids::RESET_GUEST), MenuAction::ResetGuest);
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
        // Linux-parity (2026-07-11): the shared tray menu must offer
        // Antigravity too — the headless supports `--antigravity`.
        assert_eq!(
            resolve(ids::AGENT_ANTIGRAVITY),
            MenuAction::SelectAgent(SelectedAgent::Antigravity)
        );
    }

    #[test]
    fn resolves_per_project_agent_verbs() {
        use SelectedAgent::*;
        for (verb, agent) in [
            ("claude", Claude),
            ("codex", Codex),
            ("opencode", OpenCode),
            ("antigravity", Antigravity),
        ] {
            assert_eq!(
                resolve(&format!("project.local.myapp.{verb}")),
                MenuAction::Attach {
                    scope: ProjectScope::Local,
                    name: "myapp".to_string(),
                    agent
                }
            );
            assert_eq!(
                resolve(&format!("project.cloud.octocat-repo.{verb}")),
                MenuAction::Attach {
                    scope: ProjectScope::Cloud,
                    name: "octocat-repo".to_string(),
                    agent
                }
            );
        }
    }

    #[test]
    fn resolves_per_project_web_and_observatorium() {
        assert_eq!(
            resolve("project.local.myapp.opencode-web"),
            MenuAction::ProjectOpenCodeWeb {
                scope: ProjectScope::Local,
                name: "myapp".to_string()
            }
        );
        assert_eq!(
            resolve("project.cloud.octocat-repo.observatorium"),
            MenuAction::ProjectObservatorium {
                scope: ProjectScope::Cloud,
                name: "octocat-repo".to_string()
            }
        );
    }

    #[test]
    fn resolves_per_project_maintenance() {
        assert_eq!(
            resolve("project.cloud.octocat-repo.maintenance"),
            MenuAction::Maintain {
                scope: ProjectScope::Cloud,
                name: "octocat-repo".to_string()
            }
        );
    }

    /// Legacy .attach verb still resolves (defaults to Claude).
    #[test]
    fn resolves_legacy_attach_verb_as_claude() {
        assert_eq!(
            resolve("project.local.myapp.attach"),
            MenuAction::Attach {
                scope: ProjectScope::Local,
                name: "myapp".to_string(),
                agent: SelectedAgent::Claude,
            }
        );
    }

    /// Project basenames can contain dots; the verb suffix must still parse.
    #[test]
    fn resolves_project_name_with_dots() {
        assert_eq!(
            resolve("project.local.my.dotted.app.claude"),
            MenuAction::Attach {
                scope: ProjectScope::Local,
                name: "my.dotted.app".to_string(),
                agent: SelectedAgent::Claude,
            }
        );
    }

    #[test]
    fn submenu_header_and_unknown_ids_are_inert() {
        // Bare submenu header (no verb) is not actionable.
        assert_eq!(resolve("project.local.myapp"), MenuAction::Inert);
        // Unknown scope.
        assert_eq!(resolve("project.weird.myapp.claude"), MenuAction::Inert);
        // Empty name.
        assert_eq!(resolve("project.local..claude"), MenuAction::Inert);
        // Disabled/informational ids.
        assert_eq!(resolve(ids::STATUS), MenuAction::Inert);
        assert_eq!(resolve(ids::VERSION), MenuAction::Inert);
        assert_eq!(resolve(ids::LOCAL_PROJECTS_EMPTY), MenuAction::Inert);
        // Totally unknown.
        assert_eq!(resolve("nonsense"), MenuAction::Inert);
    }
}
