//! Pre-built tray menu with five-stage state machine.
//!
//! Implements the menu shape defined by `simplified-tray-ux`. Every static
//! item is built once at app start; stage transitions toggle `set_enabled`
//! and update text on the same handles rather than rebuilding the whole
//! tree. Only the `Projects ▸` submenu rebuilds, and only when the
//! (project_set, include_remote) tuple actually changes.
//!
//! ```text
//! Booting    → Building [forge/proxy/git/inference]  | Lang | ver | sig | Quit
//! Ready      → Ready (≤2s)                          | Lang | ver | sig | Quit
//! NoAuth     → Sign in to GitHub                    | Lang | ver | sig | Quit
//! Authed     → Projects ▸                            | Lang | ver | sig | Quit
//! NetIssue   → Sign in / banner / Projects ▸         | Lang | ver | sig | Quit
//! ```
//!
//! @trace spec:simplified-tray-ux

use std::path::PathBuf;
use std::sync::Mutex;

use tauri::menu::{
    CheckMenuItem, CheckMenuItemBuilder, IsMenuItem, Menu, MenuBuilder, MenuItem,
    MenuItemBuilder, MenuItemKind, PredefinedMenuItem, Submenu, SubmenuBuilder,
};
use tauri::{AppHandle, Runtime};
use tracing::{debug, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::project::Project;
use tillandsias_core::state::{ContainerType, RemoteRepoInfo, TrayState};

use crate::github_health::CredentialHealth;
use crate::i18n;

// ─── Menu IDs ────────────────────────────────────────────────────────────────

/// Stable IDs used by `tray_menu`. Unlike the legacy menu these IDs do NOT
/// carry a generation suffix because the items are pre-built once and never
/// recycled across rebuilds — libappindicator's blank-label bug doesn't fire
/// here.
pub mod ids {
    pub const QUIT: &str = "tm.quit";
    pub const SIGN_IN: &str = "tm.sign-in";
    pub const READY: &str = "tm.ready";
    pub const BUILDING: &str = "tm.building";
    pub const NET_BANNER: &str = "tm.net-banner";
    pub const VERSION_LINE: &str = "tm.version";
    pub const SIGNATURE: &str = "tm.signature";
    pub const PROJECTS: &str = "tm.projects";
    pub const LANGUAGE: &str = "tm.language";
    pub const INCLUDE_REMOTE: &str = "tm.include-remote";

    /// Build "tm.launch:<project_path>" — full project_path encoded.
    pub fn launch(project_path: &std::path::Path) -> String {
        format!("tm.launch:{}", project_path.display())
    }

    /// Build "tm.maint:<project_path>".
    pub fn maint(project_path: &std::path::Path) -> String {
        format!("tm.maint:{}", project_path.display())
    }

    /// Build "tm.clone:<full_name>\t<name>".
    pub fn clone_repo(full_name: &str, name: &str) -> String {
        format!("tm.clone:{full_name}\t{name}")
    }

    /// Build "tm.lang:<code>" — language selector.
    pub fn select_lang(code: &str) -> String {
        format!("tm.lang:{code}")
    }

    /// Parse a tray_menu ID into (action, payload) if recognised.
    pub fn parse(id: &str) -> Option<(&str, &str)> {
        let stripped = id.strip_prefix("tm.")?;
        Some(stripped.split_once(':').unwrap_or((stripped, "")))
    }
}

// ─── Stage state machine ─────────────────────────────────────────────────────

/// One of the five lifecycle stages. Determines which top-level items are
/// enabled. See `docs/cheatsheets/tray-state-machine.md`.
///
/// @trace spec:simplified-tray-ux
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Stage {
    Booting,
    Ready,
    NoAuth,
    Authed,
    NetIssue,
}

/// Per-stage item visibility table. Pure data — exists so unit tests can
/// assert the stage→enabled mapping without instantiating Tauri.
///
/// @trace spec:simplified-tray-ux
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StageVisibility {
    pub building: bool,
    pub ready: bool,
    pub sign_in: bool,
    pub net_banner: bool,
    pub projects: bool,
}

impl StageVisibility {
    /// Map `Stage` → `StageVisibility`. Pure function, no Tauri dependency.
    ///
    /// @trace spec:simplified-tray-ux
    pub const fn for_stage(stage: Stage) -> Self {
        match stage {
            Stage::Booting => Self {
                building: true,
                ready: false,
                sign_in: false,
                net_banner: false,
                projects: false,
            },
            Stage::Ready => Self {
                building: false,
                ready: true,
                sign_in: false,
                net_banner: false,
                projects: false,
            },
            Stage::NoAuth => Self {
                building: false,
                ready: false,
                sign_in: true,
                net_banner: false,
                projects: false,
            },
            Stage::Authed => Self {
                building: false,
                ready: false,
                sign_in: false,
                net_banner: false,
                projects: true,
            },
            Stage::NetIssue => Self {
                building: false,
                ready: false,
                sign_in: true,
                net_banner: true,
                projects: true,
            },
        }
    }
}

/// Map a `CredentialHealth` probe result to a `Stage`. The mapping matches
/// the table in `docs/cheatsheets/tray-state-machine.md`.
///
/// @trace spec:simplified-tray-ux
pub fn stage_from_health(health: &CredentialHealth) -> Stage {
    match health {
        CredentialHealth::Authenticated => Stage::Authed,
        CredentialHealth::CredentialMissing | CredentialHealth::CredentialInvalid => Stage::NoAuth,
        CredentialHealth::GithubUnreachable { .. } => Stage::NetIssue,
    }
}

// ─── TrayMenu ────────────────────────────────────────────────────────────────

/// Cache key for the projects submenu rebuild gate.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct ProjectsCacheKey {
    local: Vec<String>,
    remote: Vec<String>,
    running_forges: Vec<String>,
    include_remote: bool,
}

/// Owner of every pre-built tray menu item. Constructed once at app setup;
/// mutated only via `set_stage` / `update_*` methods.
///
/// @trace spec:simplified-tray-ux
pub struct TrayMenu<R: Runtime> {
    pub root: Menu<R>,

    // Stage-toggleable items (top of menu).
    building_chip: MenuItem<R>,
    ready_indicator: MenuItem<R>,
    sign_in: MenuItem<R>,
    net_banner: MenuItem<R>,
    projects_submenu: Submenu<R>,
    include_remote_check: CheckMenuItem<R>,

    // Static signature trio + Quit (always enabled below the divider).
    // Held to keep the underlying handles alive for the lifetime of the menu;
    // some are only read via `refresh_static_labels` on language changes.
    language: Submenu<R>,
    #[allow(dead_code)]
    version_line: MenuItem<R>,
    signature_line: MenuItem<R>,
    quit: MenuItem<R>,

    // Cache for projects submenu rebuild gating.
    projects_cache: Mutex<ProjectsCacheKey>,
}

impl<R: Runtime> TrayMenu<R> {
    /// Pre-build every static item and return the assembled `Menu`.
    ///
    /// Layout (top → bottom):
    /// ```text
    /// 1. building_chip  | ready_indicator | sign_in   (one of these is enabled)
    /// 2. net_banner                                   (NetIssue only)
    /// 3. projects_submenu                             (Authed / NetIssue)
    /// 4. ────── separator ──────
    /// 5. language ▸
    /// 6. version (disabled)
    /// 7. signature (disabled)
    /// 8. quit
    /// ```
    ///
    /// @trace spec:simplified-tray-ux
    pub fn new(app: &AppHandle<R>) -> tauri::Result<Self> {
        let building_chip = MenuItemBuilder::with_id(ids::BUILDING, i18n::t("menu.building_idle"))
            .enabled(false)
            .build(app)?;

        let ready_indicator =
            MenuItemBuilder::with_id(ids::READY, i18n::t("menu.ready_transient"))
                .enabled(false)
                .build(app)?;

        let sign_in = MenuItemBuilder::with_id(ids::SIGN_IN, i18n::t("menu.sign_in_github"))
            .enabled(false)
            .build(app)?;

        let net_banner =
            MenuItemBuilder::with_id(ids::NET_BANNER, i18n::t("menu.github_unreachable_banner"))
                .enabled(false)
                .build(app)?;

        // Projects submenu — initially populated with the "Include remote" check
        // item only. Updated via `update_projects` once we have project data.
        let include_remote_check =
            CheckMenuItemBuilder::with_id(ids::INCLUDE_REMOTE, i18n::t("menu.include_remote"))
                .checked(false)
                .build(app)?;

        let projects_submenu = SubmenuBuilder::with_id(app, ids::PROJECTS, i18n::t("menu.projects"))
            .item(&include_remote_check)
            .separator()
            .item(
                &MenuItemBuilder::with_id("tm.no-local", i18n::t("menu.no_local_projects"))
                    .enabled(false)
                    .build(app)?,
            )
            .build()?;
        // Disabled by default — Booting/Ready/NoAuth keep it off.
        let _ = projects_submenu.set_enabled(false);

        let language = build_language_submenu(app)?;

        let version_line = MenuItemBuilder::with_id(
            ids::VERSION_LINE,
            format!("v{}", env!("TILLANDSIAS_FULL_VERSION")),
        )
        .enabled(false)
        .build(app)?;

        let signature_line = MenuItemBuilder::with_id(ids::SIGNATURE, i18n::t("menu.signature"))
            .enabled(false)
            .build(app)?;

        let quit = MenuItemBuilder::with_id(ids::QUIT, i18n::t("menu.quit")).build(app)?;

        // Assemble top-level menu in stage-machine order.
        let separator_top = PredefinedMenuItem::separator(app)?;

        let mut builder = MenuBuilder::new(app);
        builder = builder
            .item(&building_chip)
            .item(&ready_indicator)
            .item(&sign_in)
            .item(&net_banner)
            .item(&projects_submenu)
            .item(&separator_top)
            .item(&language)
            .item(&version_line)
            .item(&signature_line)
            .item(&quit);
        let root = builder.build()?;

        let me = Self {
            root,
            building_chip,
            ready_indicator,
            sign_in,
            net_banner,
            projects_submenu,
            include_remote_check,
            language,
            version_line,
            signature_line,
            quit,
            projects_cache: Mutex::new(ProjectsCacheKey::default()),
        };

        // Initial stage = Booting. Apply visibility so only the building chip is
        // enabled among the top three items.
        me.set_stage(Stage::Booting);

        Ok(me)
    }

    /// Apply the stage-machine visibility for `stage`. Calls `set_enabled`
    /// on every stage-toggleable handle to match the spec's table. Static
    /// items (language, version, signature, quit) are left untouched —
    /// they're always enabled (or always disabled, in version/signature's
    /// case) regardless of stage.
    ///
    /// Tauri 2 does not expose `set_visible` for native menus on every
    /// platform; we emulate hide-by-disable. On platforms with quirky menu
    /// redraw, disabled items still appear but cannot be clicked, which
    /// matches the spec's stated guarantees.
    ///
    /// @trace spec:simplified-tray-ux
    pub fn set_stage(&self, stage: Stage) {
        let v = StageVisibility::for_stage(stage);
        let _ = self.building_chip.set_enabled(v.building);
        let _ = self.ready_indicator.set_enabled(v.ready);
        let _ = self.sign_in.set_enabled(v.sign_in);
        let _ = self.net_banner.set_enabled(v.net_banner);
        let _ = self.projects_submenu.set_enabled(v.projects);
        debug!(spec = "simplified-tray-ux", ?stage, ?v, "Stage applied");
    }

    /// Update the building chip text (e.g., "Building [forge, proxy]").
    /// Idempotent — no-op when the new label matches the current one.
    ///
    /// Pass `None` to restore the idle building label.
    ///
    /// @trace spec:simplified-tray-ux
    pub fn update_building_chip(&self, in_progress_images: &[&str]) {
        let label = if in_progress_images.is_empty() {
            i18n::t("menu.building_idle").to_string()
        } else {
            i18n::tf(
                "menu.building_chip",
                &[("images", &in_progress_images.join(", "))],
            )
        };
        if let Err(e) = self.building_chip.set_text(&label) {
            debug!(error = %e, "set_text on building chip failed (cosmetic)");
        }
    }

    /// Rebuild the `Projects ▸` submenu — only when the (local set, remote
    /// set, include_remote) tuple actually changes. The cache key is held
    /// internally so callers can invoke this freely on every state tick.
    ///
    /// @trace spec:simplified-tray-ux
    pub fn update_projects(
        &self,
        app: &AppHandle<R>,
        state: &TrayState,
        include_remote: bool,
    ) -> tauri::Result<()> {
        // Compute a stable cache key. Sort to defeat scanner-emitted
        // ordering jitter.
        let mut local: Vec<String> =
            state.projects.iter().map(|p| p.name.clone()).collect();
        local.sort();
        let mut remote: Vec<String> = state
            .remote_repos
            .iter()
            .map(|r| r.name.clone())
            .collect();
        remote.sort();
        let mut running_forges: Vec<String> = state
            .running
            .iter()
            .filter(|c| matches!(c.container_type, ContainerType::OpenCodeWeb))
            .map(|c| c.project_name.clone())
            .collect();
        running_forges.sort();

        let key = ProjectsCacheKey {
            local,
            remote,
            running_forges,
            include_remote,
        };

        {
            let cache = self.projects_cache.lock().unwrap();
            if *cache == key {
                return Ok(());
            }
        }

        // Wipe existing items and rebuild content. The submenu handle stays
        // the same — only its children change.
        // Capture an owned list of children first so the `items()` borrow drops
        // before we call `remove`.
        let existing: Vec<_> = self.projects_submenu.items()?;
        for kind in existing {
            // `kind` is a MenuItemKind enum — pass through `IsMenuItem` impl.
            let _ = remove_kind(&self.projects_submenu, &kind);
        }

        // Always-present header: Include remote checkbox + separator.
        // Re-uses the long-lived check handle so the click-event ID is stable.
        self.include_remote_check.set_checked(include_remote)?;
        self.projects_submenu.append(&self.include_remote_check)?;
        let sep1 = PredefinedMenuItem::separator(app)?;
        self.projects_submenu.append(&sep1)?;

        let local_projects = &state.projects;
        if local_projects.is_empty() {
            let placeholder = MenuItemBuilder::with_id(
                "tm.no-local",
                i18n::t("menu.no_local_projects"),
            )
            .enabled(false)
            .build(app)?;
            self.projects_submenu.append(&placeholder)?;
        } else {
            let mut sorted: Vec<&Project> = local_projects.iter().collect();
            sorted.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            for project in sorted {
                let sub = build_local_project_submenu(app, project, state)?;
                self.projects_submenu.append(&sub)?;
            }
        }

        if include_remote {
            let watch_path = first_watch_path();
            let local_names: Vec<String> = state
                .projects
                .iter()
                .map(|p| p.name.clone())
                .collect();
            let remote_only: Vec<&RemoteRepoInfo> = state
                .remote_repos
                .iter()
                .filter(|r| {
                    !local_names.contains(&r.name) && !watch_path.join(&r.name).exists()
                })
                .collect();

            let sep2 = PredefinedMenuItem::separator(app)?;
            self.projects_submenu.append(&sep2)?;

            if remote_only.is_empty() {
                let placeholder = MenuItemBuilder::with_id(
                    "tm.no-remote",
                    i18n::t("menu.no_remote_projects"),
                )
                .enabled(false)
                .build(app)?;
                self.projects_submenu.append(&placeholder)?;
            } else {
                for repo in remote_only {
                    let sub = build_remote_project_submenu(app, repo)?;
                    self.projects_submenu.append(&sub)?;
                }
            }
        }

        // Commit the cache key only after the rebuild succeeds.
        let mut cache = self.projects_cache.lock().unwrap();
        *cache = key;
        Ok(())
    }

    /// Returns the current state of the "Include remote" check item.
    /// Defaults to `false` if the underlying call fails.
    ///
    /// @trace spec:simplified-tray-ux
    pub fn include_remote_checked(&self) -> bool {
        self.include_remote_check.is_checked().unwrap_or(false)
    }

    /// Reference accessors — used by the unit tests and main.rs to rebuild
    /// references when an external caller (i18n reload) changes labels.
    ///
    /// @trace spec:simplified-tray-ux
    pub fn refresh_static_labels(&self) {
        let _ = self.building_chip.set_text(i18n::t("menu.building_idle"));
        let _ = self
            .ready_indicator
            .set_text(i18n::t("menu.ready_transient"));
        let _ = self.sign_in.set_text(i18n::t("menu.sign_in_github"));
        let _ = self
            .net_banner
            .set_text(i18n::t("menu.github_unreachable_banner"));
        let _ = self.projects_submenu.set_text(i18n::t("menu.projects"));
        let _ = self
            .include_remote_check
            .set_text(i18n::t("menu.include_remote"));
        let _ = self.language.set_text(i18n::t("menu.language"));
        let _ = self.signature_line.set_text(i18n::t("menu.signature"));
        let _ = self.quit.set_text(i18n::t("menu.quit"));
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Remove a `MenuItemKind` from a submenu. `Submenu::remove` takes a
/// `&dyn IsMenuItem<R>`, not a `MenuItemKind`, so we dispatch on the
/// variant.
fn remove_kind<R: Runtime>(
    submenu: &Submenu<R>,
    kind: &MenuItemKind<R>,
) -> tauri::Result<()> {
    match kind {
        MenuItemKind::MenuItem(m) => submenu.remove(m as &dyn IsMenuItem<R>),
        MenuItemKind::Submenu(s) => submenu.remove(s as &dyn IsMenuItem<R>),
        MenuItemKind::Predefined(p) => submenu.remove(p as &dyn IsMenuItem<R>),
        MenuItemKind::Check(c) => submenu.remove(c as &dyn IsMenuItem<R>),
        MenuItemKind::Icon(i) => submenu.remove(i as &dyn IsMenuItem<R>),
    }
}

/// Configured first watch path (defaults to `~/src`).
fn first_watch_path() -> PathBuf {
    let global_config = load_global_config();
    global_config
        .scanner
        .watch_paths
        .first()
        .cloned()
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".to_string()))
                .join("src")
        })
}

/// Build a per-local-project submenu: Launch + Maintenance terminal.
/// The Maintenance terminal item is disabled when no opencode-web forge is
/// running for the project.
///
/// @trace spec:simplified-tray-ux
fn build_local_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    project: &Project,
    state: &TrayState,
) -> tauri::Result<Submenu<R>> {
    let forge_running = state.running.iter().any(|c| {
        c.project_name == project.name
            && matches!(c.container_type, ContainerType::OpenCodeWeb)
    });

    let label = if forge_running {
        format!("🌺 {}", project.name)
    } else {
        project.name.clone()
    };

    let launch_item = MenuItemBuilder::with_id(ids::launch(&project.path), i18n::t("menu.launch"))
        .build(app)?;

    let maint_item = MenuItemBuilder::with_id(
        ids::maint(&project.path),
        i18n::t("menu.maintenance_terminal"),
    )
    .enabled(forge_running)
    .build(app)?;

    SubmenuBuilder::new(app, &label)
        .item(&launch_item)
        .item(&maint_item)
        .build()
}

/// Build a per-remote-project submenu: just "Clone & Launch".
///
/// @trace spec:simplified-tray-ux
fn build_remote_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    repo: &RemoteRepoInfo,
) -> tauri::Result<Submenu<R>> {
    let clone_item = MenuItemBuilder::with_id(
        ids::clone_repo(&repo.full_name, &repo.name),
        i18n::t("menu.clone_and_launch"),
    )
    .build(app)?;

    SubmenuBuilder::new(app, &repo.name)
        .item(&clone_item)
        .build()
}

/// Build the language selector submenu. Same set of locales as the legacy
/// menu — a pin emoji marks the currently selected one.
///
/// @trace spec:simplified-tray-ux
fn build_language_submenu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<Submenu<R>> {
    let global_config = load_global_config();
    let selected = global_config.i18n.language.clone();

    let mut submenu = SubmenuBuilder::with_id(app, ids::LANGUAGE, i18n::t("menu.language"));

    let languages: &[(&str, &str)] = &[
        ("en", "English"),
        ("es", "Espa\u{00F1}ol"),
        ("ja", "\u{65E5}\u{672C}\u{8A9E}"),
        ("zh-Hant", "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}"),
        ("zh-Hans", "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"),
        ("ar", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"),
        ("ko", "\u{D55C}\u{AD6D}\u{C5B4}"),
        ("hi", "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"),
        ("ta", "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}"),
        ("te", "\u{0C24}\u{0C46}\u{0C32}\u{0C41}\u{0C17}\u{0C41}"),
        ("fr", "Fran\u{00E7}ais"),
        ("pt", "Portugu\u{00EA}s"),
        ("it", "Italiano"),
        ("ro", "Rom\u{00E2}n\u{0103}"),
        ("ru", "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"),
        ("nah", "N\u{0101}huatl"),
        ("de", "Deutsch"),
    ];

    for &(code, name) in languages {
        let label = if code == selected {
            format!("\u{1F4CC} {name}")
        } else {
            name.to_string()
        };
        let item = MenuItemBuilder::with_id(ids::select_lang(code), &label).build(app)?;
        submenu = submenu.item(&item);
    }

    submenu.build()
}

// ─── Click dispatch ──────────────────────────────────────────────────────────

/// Cleanly dispatch a tray-menu click ID to a `MenuCommand`. Unknown IDs
/// fall through to `None`. Caller logs and ignores `None`.
///
/// @trace spec:simplified-tray-ux
pub fn dispatch_click(id: &str) -> Option<tillandsias_core::event::MenuCommand> {
    use tillandsias_core::event::MenuCommand;

    match id {
        ids::QUIT => Some(MenuCommand::Quit),
        ids::SIGN_IN => Some(MenuCommand::GitHubLogin),
        ids::INCLUDE_REMOTE => {
            // Toggling logic requires reading the current check state; the
            // caller (main.rs) does that and dispatches IncludeRemoteToggle
            // with the resolved value.
            None
        }
        _ => {
            let (action, payload) = ids::parse(id)?;
            match action {
                "launch" => Some(MenuCommand::Launch {
                    project_path: payload.into(),
                }),
                "maint" => Some(MenuCommand::MaintenanceTerminal {
                    project_path: payload.into(),
                }),
                "clone" => {
                    let (full_name, name) = payload.split_once('\t')?;
                    Some(MenuCommand::CloneProject {
                        full_name: full_name.to_string(),
                        name: name.to_string(),
                    })
                }
                "lang" => Some(MenuCommand::SelectLanguage {
                    language: payload.to_string(),
                }),
                other => {
                    warn!(spec = "simplified-tray-ux", action = other, "Unknown tray_menu action");
                    None
                }
            }
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Stage → visibility mapping must match the spec's table exactly.
    /// @trace spec:simplified-tray-ux
    #[test]
    fn stage_visibility_table_matches_spec() {
        // Booting: only the building chip.
        let v = StageVisibility::for_stage(Stage::Booting);
        assert!(v.building);
        assert!(!v.ready);
        assert!(!v.sign_in);
        assert!(!v.net_banner);
        assert!(!v.projects);

        // Ready: only the transient ready indicator.
        let v = StageVisibility::for_stage(Stage::Ready);
        assert!(!v.building);
        assert!(v.ready);
        assert!(!v.sign_in);
        assert!(!v.net_banner);
        assert!(!v.projects);

        // NoAuth: only sign-in.
        let v = StageVisibility::for_stage(Stage::NoAuth);
        assert!(!v.building);
        assert!(!v.ready);
        assert!(v.sign_in);
        assert!(!v.net_banner);
        assert!(!v.projects);

        // Authed: only Projects.
        let v = StageVisibility::for_stage(Stage::Authed);
        assert!(!v.building);
        assert!(!v.ready);
        assert!(!v.sign_in);
        assert!(!v.net_banner);
        assert!(v.projects);

        // NetIssue: sign-in + banner + projects.
        let v = StageVisibility::for_stage(Stage::NetIssue);
        assert!(!v.building);
        assert!(!v.ready);
        assert!(v.sign_in);
        assert!(v.net_banner);
        assert!(v.projects);
    }

    /// CredentialHealth → Stage mapping must match the cheatsheet table.
    /// @trace spec:simplified-tray-ux
    #[test]
    fn credential_health_to_stage_mapping() {
        assert_eq!(
            stage_from_health(&CredentialHealth::Authenticated),
            Stage::Authed
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::CredentialMissing),
            Stage::NoAuth
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::CredentialInvalid),
            Stage::NoAuth
        );
        assert_eq!(
            stage_from_health(&CredentialHealth::GithubUnreachable {
                reason: "DNS failure".to_string()
            }),
            Stage::NetIssue
        );
    }

    /// Click dispatch maps action prefixes to the correct MenuCommand
    /// variant. Unknown / malformed IDs return None.
    /// @trace spec:simplified-tray-ux
    #[test]
    fn dispatch_click_known_actions() {
        use tillandsias_core::event::MenuCommand;

        assert!(matches!(
            dispatch_click(ids::QUIT),
            Some(MenuCommand::Quit)
        ));
        assert!(matches!(
            dispatch_click(ids::SIGN_IN),
            Some(MenuCommand::GitHubLogin)
        ));

        let id = ids::launch(std::path::Path::new("/tmp/foo"));
        match dispatch_click(&id) {
            Some(MenuCommand::Launch { project_path }) => {
                assert_eq!(project_path, std::path::PathBuf::from("/tmp/foo"));
            }
            other => panic!("expected Launch, got {other:?}"),
        }

        let id = ids::maint(std::path::Path::new("/tmp/bar"));
        match dispatch_click(&id) {
            Some(MenuCommand::MaintenanceTerminal { project_path }) => {
                assert_eq!(project_path, std::path::PathBuf::from("/tmp/bar"));
            }
            other => panic!("expected MaintenanceTerminal, got {other:?}"),
        }

        let id = ids::clone_repo("octocat/foo", "foo");
        match dispatch_click(&id) {
            Some(MenuCommand::CloneProject { full_name, name }) => {
                assert_eq!(full_name, "octocat/foo");
                assert_eq!(name, "foo");
            }
            other => panic!("expected CloneProject, got {other:?}"),
        }

        let id = ids::select_lang("ja");
        match dispatch_click(&id) {
            Some(MenuCommand::SelectLanguage { language }) => assert_eq!(language, "ja"),
            other => panic!("expected SelectLanguage, got {other:?}"),
        }

        // Include-remote returns None — the caller resolves it from the
        // CheckMenuItem's actual state.
        assert!(dispatch_click(ids::INCLUDE_REMOTE).is_none());
        // Unknown action prefix.
        assert!(dispatch_click("tm.bogus:foo").is_none());
    }
}
