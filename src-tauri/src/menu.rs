//! Dynamic tray menu builder.
//!
//! Builds a hierarchical system tray menu from `TrayState`, reflecting
//! discovered projects, running environments, and their lifecycle states.
//!
//! ## Top-level structure
//!
//! ```text
//! ~/src/ — Attach Here
//! 🛠️ Root
//! ─────────
//! tetris        🔧🌸  ▸  (active project — promoted inline)
//! cool-app      🌸    ▸  (active project — promoted inline)
//! Projects ▸           (only inactive projects; omitted when all are active)
//! ⏳ Building forge... (inline build chips, disabled)
//! ─────────
//! Settings ▸
//! Quit Tillandsias
//! ```
//!
//! @trace spec:tray-app

use std::sync::atomic::{AtomicU64, Ordering};

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Runtime};
use tracing::debug;

use tillandsias_core::config::{SelectedAgent, load_global_config};
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::state::{BuildStatus, ContainerType, TrayState};

use crate::i18n;

/// Generation counter for menu rebuilds.
///
/// libappindicator (Linux tray) caches menu item IDs across rebuilds.
/// Reusing the same ID causes blank labels. Appending a generation suffix
/// makes every rebuild's IDs unique.
static MENU_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Suffix the current generation to a menu ID to avoid libappindicator caching bugs.
fn gen_id(base: &str) -> String {
    let generation = MENU_GENERATION.load(Ordering::Relaxed);
    format!("{base}#{generation}")
}

/// Menu item ID constants for event dispatching.
pub mod ids {
    use super::gen_id;

    pub const QUIT: &str = "quit";
    pub const SETTINGS: &str = "settings";
    pub const GITHUB_LOGIN: &str = "github-login";
    pub const CLAUDE_RESET_CREDENTIALS: &str = "claude-reset-credentials";
    pub const REFRESH_REMOTE_PROJECTS: &str = "refresh-remote-projects";

    /// Build an "opencode project" menu item ID for a project path.
    /// @trace spec:tray-minimal-ux
    pub fn opencode_project(project_path: &std::path::Path) -> String {
        gen_id(&format!("opencode:{}", project_path.display()))
    }

    /// Build an "opencode web project" menu item ID for a project path.
    /// Launches OpenCode Web in a browser-isolation container.
    /// @trace spec:browser-isolation-tray-integration
    pub fn opencode_web_project(project_path: &std::path::Path) -> String {
        gen_id(&format!("opencode-web:{}", project_path.display()))
    }

    /// Build a "claude project" menu item ID for a project path.
    /// @trace spec:tray-minimal-ux
    pub fn claude_project(project_path: &std::path::Path) -> String {
        gen_id(&format!("claude:{}", project_path.display()))
    }

    /// Build a "maintenance project" menu item ID for a project path.
    /// @trace spec:tray-minimal-ux
    pub fn maintenance_project(project_path: &std::path::Path) -> String {
        gen_id(&format!("maintenance:{}", project_path.display()))
    }

    /// Build an "attach here" menu item ID for a project path.
    /// @deprecated Use opencode_project, opencode_web_project, claude_project, or maintenance_project instead.
    pub fn attach_here(project_path: &std::path::Path) -> String {
        gen_id(&format!("attach:{}", project_path.display()))
    }

    /// Build a "terminal" menu item ID for a project path.
    /// @deprecated Use maintenance_project instead.
    pub fn terminal(project_path: &std::path::Path) -> String {
        gen_id(&format!("terminal:{}", project_path.display()))
    }

    /// Build a "serve here" menu item ID for a project path.
    /// @deprecated Serve Here is no longer offered in the menu.
    pub fn serve_here(project_path: &std::path::Path) -> String {
        gen_id(&format!("serve:{}", project_path.display()))
    }

    /// Build a "stop project" menu item ID for a project path.
    ///
    /// Used by the OpenCode Web per-project Stop entry to tear down the
    /// persistent `tillandsias-<project>-forge` container without requiring
    /// the caller to know the container name.
    ///
    /// @trace spec:opencode-web-session, spec:tray-app
    pub fn stop_project(project_path: &std::path::Path) -> String {
        gen_id(&format!("stop-project:{}", project_path.display()))
    }

    /// Build a "clone" menu item ID encoding both full_name and name.
    pub fn clone_project(full_name: &str, name: &str) -> String {
        gen_id(&format!("clone:{full_name}\t{name}"))
    }

    /// Build the root terminal menu item ID.
    pub fn root_terminal() -> String {
        gen_id("root-terminal")
    }

    /// Build a menu item ID with generation suffix for non-actionable items.
    pub fn static_id(name: &str) -> String {
        gen_id(name)
    }

    /// Build an agent selection menu item ID.
    pub fn select_agent(agent_name: &str) -> String {
        gen_id(&format!("select-agent:{agent_name}"))
    }

    /// Build a language selection menu item ID.
    pub fn select_lang(code: &str) -> String {
        gen_id(&format!("select-lang:{code}"))
    }

    /// Strip the generation suffix from a menu ID for dispatch matching.
    /// "attach:/path#42" -> "attach:/path"
    pub fn strip_gen(id: &str) -> &str {
        id.rsplit_once('#').map(|(base, _)| base).unwrap_or(id)
    }

    /// Parse a (generation-stripped) menu item ID into its action and payload.
    pub fn parse(id: &str) -> Option<(&str, &str)> {
        strip_gen(id).split_once(':')
    }
}

/// Build the complete tray menu from current application state.
/// @trace spec:tray-minimal-ux
pub fn build_tray_menu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Menu<R>> {
    // Bump generation so all IDs are unique (avoids libappindicator blank label bug)
    MENU_GENERATION.fetch_add(1, Ordering::Relaxed);

    // Dried state: podman unavailable — show minimal error menu
    if state.tray_icon_state == TrayIconState::Dried {
        return build_dried_menu(app);
    }

    // Minimal UX: show simplified menu until environment is ready
    // @trace spec:tray-minimal-ux
    if !state.forge_available {
        return build_minimal_menu(app, state);
    }

    let mut menu = MenuBuilder::new(app);

    // Get watch path for remote projects cloud menu — but don't create a top-level "Attach Here" entry.
    // Uses the first watch path from config (default ~/src).
    // @trace spec:tray-minimal-ux
    let global_config = load_global_config();
    let watch_path = global_config
        .scanner
        .watch_paths
        .first()
        .cloned()
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".to_string()))
                .join("src")
        });

    // Global root terminal — 🛠️ is reserved for this item and MUST NOT appear in TOOL_EMOJIS.
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::root_terminal(), i18n::t("menu.root_terminal"))
            .enabled(state.forge_available)
            .build(app)?,
    );

    // Cloud — show remote projects if authenticated and repos exist
    // @trace spec:tray-minimal-ux
    let authenticated = !needs_github_login();
    if authenticated && !state.remote_repos.is_empty() {
        let cloud_submenu = build_remote_projects_submenu(app, state, &watch_path)?;
        menu = menu.item(&cloud_submenu);
    }

    // GitHub login — show if not authenticated
    // @trace spec:tray-minimal-ux
    if !authenticated {
        menu = menu.item(
            &MenuItemBuilder::with_id(ids::GITHUB_LOGIN, i18n::t("menu.github.login"))
                .enabled(state.forge_available)
                .build(app)?,
        );
    }

    menu = menu.separator();

    // Split projects into active (has running containers) and inactive.
    let active_projects: Vec<&tillandsias_core::project::Project> = state
        .projects
        .iter()
        .filter(|p| state.running.iter().any(|c| c.project_name == p.name))
        .collect();
    let inactive_projects: Vec<&tillandsias_core::project::Project> = state
        .projects
        .iter()
        .filter(|p| !state.running.iter().any(|c| c.project_name == p.name))
        .collect();

    // Active projects — promoted inline at the top level.
    for project in &active_projects {
        let project_submenu = build_project_submenu(app, project, state)?;
        menu = menu.item(&project_submenu);
    }

    // Projects submenu — only inactive projects.
    // Omitted entirely when every discovered project is active.
    if !inactive_projects.is_empty() || state.projects.is_empty() {
        let projects_submenu =
            build_inactive_projects_submenu(app, &inactive_projects, state.forge_available)?;
        menu = menu.item(&projects_submenu);
    }

    // Build chips — inline disabled items, always at the top level.
    for build in &state.active_builds {
        let label = build_chip_label(build);
        menu = menu.item(
            &MenuItemBuilder::with_id(
                ids::static_id(&format!("build-chip-{}", build.image_name)),
                &label,
            )
            .enabled(false)
            .build(app)?,
        );
    }

    menu = menu.separator();

    // Settings submenu — contains GitHub Login/Refresh, Remote Projects, version, credit.
    let settings_submenu = build_settings_submenu(app, state, &watch_path)?;
    menu = menu.item(&settings_submenu);

    // Quit — always visible at top level
    menu =
        menu.item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), i18n::t("menu.quit")).build(app)?);

    debug!(
        projects = state.projects.len(),
        active_inline = active_projects.len(),
        inactive_in_submenu = inactive_projects.len(),
        running = state.running.len(),
        remote_repos = state.remote_repos.len(),
        active_builds = state.active_builds.len(),
        "Menu rebuilt"
    );

    menu.build()
}

/// Build the minimal Dried menu shown when podman is not available.
///
/// Contains only:
/// - Error item (disabled) explaining podman is unavailable
/// - Separator
/// - Quit
fn build_dried_menu<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<tauri::menu::Menu<R>> {
    let mut menu = MenuBuilder::new(app);

    menu = menu.item(
        &MenuItemBuilder::with_id(
            ids::static_id("podman-unavailable"),
            i18n::t("errors.podman_unavailable"),
        )
        .enabled(false)
        .build(app)?,
    );

    menu = menu.separator();
    menu =
        menu.item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), i18n::t("menu.quit")).build(app)?);

    debug!("Dried menu built (podman unavailable)");

    menu.build()
}

/// Build the minimal tray menu shown during environment verification.
/// Shows only: status item, divider, version, quit.
/// @trace spec:tray-minimal-ux
fn build_minimal_menu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Menu<R>> {
    let mut menu = MenuBuilder::new(app);

    // Status item — shows environment verification state
    let status_label = environment_status_label(state);
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::static_id("env-status"), &status_label)
            .enabled(false)
            .build(app)?,
    );

    menu = menu.separator();

    // Version + attribution
    let version = format!("Tillandsias v{}", env!("TILLANDSIAS_FULL_VERSION"));
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::static_id("version"), &version)
            .enabled(false)
            .build(app)?,
    );

    // Quit — always visible and enabled
    menu =
        menu.item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), i18n::t("menu.quit")).build(app)?);

    menu.build()
}

/// Generate the environment status label based on current state.
/// @trace spec:tray-minimal-ux
fn environment_status_label(state: &TrayState) -> String {
    // Check if environment is fully ready
    if state.forge_available {
        return "✅ Environment OK".to_string();
    }

    // Check if any builds are active
    if !state.active_builds.is_empty() {
        let mut icons = String::new();
        let mut stages = Vec::new();

        for build in &state.active_builds {
            let name = build.image_name.as_str();
            if name == "proxy" {
                icons.push_str("🌐");
                stages.push("Network");
            } else if name == "forge" {
                icons.push_str("🔧");
                stages.push("Forge");
            } else if name == "git" {
                icons.push_str("🪞");
                stages.push("Mirror");
            } else if name == "inference" {
                icons.push_str("🧠");
                stages.push("Inference");
            } else if name == "chromium-core" {
                icons.push_str("🌐");
                stages.push("Browser");
            } else if name == "chromium-framework" {
                icons.push_str("🌐");
                stages.push("Framework");
            } else {
                icons.push_str("⚙️");
            }
        }

        if !stages.is_empty() {
            let stages_str = stages.join(" + ");
            return format!("{} Building {}...", icons, stages_str);
        }
        return format!("{} Building enclave...", icons);
    }

    // Check TrayIconState for failure state
    if state.tray_icon_state == TrayIconState::Dried {
        return "🌹 Unhealthy environment".to_string();
    }

    // Default: verifying
    "☐ Verifying environment...".to_string()
}

/// Build the Projects submenu containing only inactive per-project submenus.
///
/// "Inactive" means no running containers belong to the project.
/// Active projects are promoted inline to the top-level menu instead.
///
/// When the inactive list is empty and projects exist (all are active),
/// this function is not called. When no projects are discovered at all,
/// this is called with an empty slice and shows "No projects detected".
///
/// Each inactive project shows 4 action buttons:
/// - 💻 OpenCode (terminal-based)
/// - 🌐 OpenCode Web (browser-based with browser isolation)
/// - 👽 Claude (AI assistant)
/// - 🔧 Maintenance (terminal access)
///
/// All actions require `forge_available`. When `false`, all items are disabled.
/// @trace spec:tray-minimal-ux
fn build_inactive_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    inactive: &[&tillandsias_core::project::Project],
    forge_available: bool,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut projects = SubmenuBuilder::new(app, i18n::t("menu.projects"));

    if inactive.is_empty() {
        projects = projects.item(
            &MenuItemBuilder::with_id(ids::static_id("no-projects"), i18n::t("menu.no_projects"))
                .enabled(false)
                .build(app)?,
        );
    } else {
        for project in inactive {
            let mut submenu = SubmenuBuilder::new(app, &project.name);

            // OpenCode — terminal-based IDE
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::opencode_project(&project.path),
                    "💻 OpenCode",
                )
                .enabled(forge_available)
                .build(app)?,
            );

            // OpenCode Web — browser-based IDE with browser isolation
            // @trace spec:browser-isolation-tray-integration
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::opencode_web_project(&project.path),
                    "🌐 OpenCode Web",
                )
                .enabled(forge_available)
                .build(app)?,
            );

            // Claude — AI assistant
            submenu = submenu.item(
                &MenuItemBuilder::with_id(ids::claude_project(&project.path), "👽 Claude")
                    .enabled(forge_available)
                    .build(app)?,
            );

            // Maintenance — terminal access
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::maintenance_project(&project.path),
                    "🔧 Maintenance",
                )
                .enabled(forge_available)
                .build(app)?,
            );

            projects = projects.item(&submenu.build()?);
        }
    }

    projects.build()
}

/// Build the Settings submenu containing GitHub Login/Refresh and Remote Projects.
fn build_settings_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
    watch_path: &std::path::Path,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut settings = SubmenuBuilder::new(app, i18n::t("menu.settings"));

    let authenticated = !needs_github_login();

    // GitHub submenu — contains Login/Refresh and (when authenticated) Remote Projects
    let github_label = if authenticated {
        i18n::t("menu.github.login_refresh")
    } else {
        i18n::t("menu.github.login")
    };
    let mut github = SubmenuBuilder::new(app, i18n::t("menu.github.label"));
    github = github.item(
        &MenuItemBuilder::with_id(gen_id(ids::GITHUB_LOGIN), github_label)
            .enabled(state.forge_available)
            .build(app)?,
    );
    if authenticated {
        github = github.separator();
        let remote_submenu = build_remote_projects_submenu(app, state, watch_path)?;
        github = github.item(&remote_submenu);
    }
    settings = settings.item(&github.build()?);

    // Seedlings submenu — agent selection (OpenCode / Claude)
    settings = settings.separator();
    let seedlings_submenu = build_seedlings_submenu(app)?;
    settings = settings.item(&seedlings_submenu);

    // Language submenu — locale selection
    // @trace spec:tray-app
    let language_submenu = build_language_submenu(app)?;
    settings = settings.item(&language_submenu);

    // Version and attribution at the bottom of Settings
    // @trace spec:tray-minimal-ux
    settings = settings.separator();
    let version = include_str!("../../VERSION").trim();
    let version_label = format!("v{} - By Tlatoāni", version);
    settings = settings.item(
        &MenuItemBuilder::with_id(ids::static_id("version"), &version_label)
            .enabled(false)
            .build(app)?,
    );

    settings.build()
}

/// Build the "Remote Projects" submenu populated from the cached repo list.
fn build_remote_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
    watch_path: &std::path::Path,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut submenu = SubmenuBuilder::new(app, &i18n::t("menu.github.remote_projects"));

    // Show cloning state if active
    if let Some(ref cloning_name) = state.cloning_project {
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                ids::static_id("cloning-status"),
                i18n::tf("menu.github.cloning", &[("name", cloning_name)]),
            )
            .enabled(false)
            .build(app)?,
        );
        submenu = submenu.separator();
    }

    // Show loading state
    if state.remote_repos_loading {
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                ids::static_id("remote-loading"),
                i18n::t("menu.github.loading"),
            )
            .enabled(false)
            .build(app)?,
        );
        return submenu.build();
    }

    // Show error state
    if let Some(ref error) = state.remote_repos_error {
        let label = if error.contains("No GitHub credentials") {
            i18n::t("menu.github.login_first").to_string()
        } else {
            i18n::t("menu.github.could_not_fetch").to_string()
        };
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::static_id("remote-error"), &label)
                .enabled(false)
                .build(app)?,
        );
        return submenu.build();
    }

    // Filter repos: exclude those that already exist locally
    let local_names: Vec<String> = state.projects.iter().map(|p| p.name.clone()).collect();

    let remote_only: Vec<_> = state
        .remote_repos
        .iter()
        .filter(|repo| {
            let exists_in_projects = local_names.contains(&repo.name);
            let exists_on_disk = watch_path.join(&repo.name).exists();
            !exists_in_projects && !exists_on_disk
        })
        .collect();

    if remote_only.is_empty() {
        if state.remote_repos.is_empty() && state.remote_repos_fetched_at.is_none() {
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::static_id("remote-loading"),
                    i18n::t("menu.github.loading"),
                )
                .enabled(false)
                .build(app)?,
            );
        } else {
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::static_id("remote-all-local"),
                    i18n::t("menu.github.all_cloned"),
                )
                .enabled(false)
                .build(app)?,
            );
        }
    } else {
        for repo in remote_only {
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::clone_project(&repo.full_name, &repo.name),
                    &repo.name,
                )
                .build(app)?,
            );
        }
    }

    submenu.build()
}

/// Build the "Seedlings" submenu for AI agent selection.
///
/// Lists available agents with a pin emoji on the currently selected one.
/// Clicking an agent triggers `MenuCommand::SelectAgent`.
fn build_seedlings_submenu<R: Runtime>(
    app: &AppHandle<R>,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let global_config = load_global_config();
    let selected = global_config.agent.selected;

    let mut submenu = SubmenuBuilder::new(app, i18n::t("menu.seedlings"));

    // Available agents: OpenCode Web (default), OpenCode, Claude.
    // OpenCode Web is first so the default choice is at the top.
    // @trace spec:opencode-web-session, spec:tray-app
    let agents: &[(SelectedAgent, &str)] = &[
        (SelectedAgent::OpenCodeWeb, "OpenCode Web"),
        (SelectedAgent::OpenCode, "OpenCode"),
        (SelectedAgent::Claude, "Claude"),
    ];

    for &(agent, name) in agents {
        let label = if agent == selected {
            format!("\u{1F4CC} {name}") // 📌 pin for selected
        } else {
            name.to_string()
        };
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::select_agent(agent.as_env_str()), &label).build(app)?,
        );
    }

    // Claude Reset Credentials — only shown when ~/.claude/ has content
    let claude_dir = dirs::home_dir().map(|h| h.join(".claude"));
    let has_claude_credentials = claude_dir
        .as_ref()
        .is_some_and(|d| d.exists() && d.read_dir().is_ok_and(|mut r| r.next().is_some()));
    if has_claude_credentials {
        submenu = submenu.separator();
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                gen_id(ids::CLAUDE_RESET_CREDENTIALS),
                i18n::t("menu.claude.reset_credentials"),
            )
            .build(app)?,
        );
    }

    submenu.build()
}

/// Build the "Language" submenu for locale selection.
///
/// Lists all supported languages in their native script with a pin emoji
/// on the currently selected one. Clicking a language triggers
/// `MenuCommand::SelectLanguage`.
///
/// @trace spec:tray-app
fn build_language_submenu<R: Runtime>(
    app: &AppHandle<R>,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let global_config = load_global_config();
    let selected = &global_config.i18n.language;

    let mut submenu = SubmenuBuilder::new(app, i18n::t("menu.language"));

    // All supported languages with native names.
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
            format!("\u{1F4CC} {name}") // 📌
        } else {
            name.to_string()
        };
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::select_lang(code), &label).build(app)?,
        );
    }

    submenu.build()
}

/// Build a submenu for a single project.
/// @trace spec:tray-minimal-ux
fn build_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    project: &tillandsias_core::project::Project,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    // Collect display emojis for running containers of this project, separated by type
    let tool_emojis: Vec<&str> = state
        .running
        .iter()
        .filter(|c| {
            c.project_name == project.name && c.container_type == ContainerType::Maintenance
        })
        .map(|c| c.display_emoji.as_str())
        .collect();
    let flower_emojis: Vec<&str> = state
        .running
        .iter()
        .filter(|c| c.project_name == project.name && c.container_type == ContainerType::Forge)
        .map(|c| c.display_emoji.as_str())
        .collect();
    let web_running = state
        .running
        .iter()
        .any(|c| c.project_name == project.name && c.container_type == ContainerType::Web);
    // Persistent opencode-web forge container for this project — drives the
    // per-project "Stop" menu entry. Distinct from ContainerType::Web (static
    // httpd) and from ContainerType::Forge (ephemeral CLI sessions).
    // @trace spec:browser-isolation-tray-integration
    let opencode_web_running = state
        .running
        .iter()
        .any(|c| c.project_name == project.name && c.container_type == ContainerType::OpenCodeWeb);

    // Project label: name first, emojis as suffix. Tools then flowers, then web globe.
    // Idle: plain name. Running: "project-name  🔧🪛🌸🔗"
    let label = if tool_emojis.is_empty() && flower_emojis.is_empty() && !web_running {
        project.name.clone()
    } else {
        let web_suffix = if web_running { "\u{1F517}" } else { "" }; // 🔗
        let suffix: String = [
            tool_emojis.join(""),
            flower_emojis.join(""),
            web_suffix.to_string(),
        ]
        .concat();
        format!("{}  {}", project.name, suffix)
    };

    let mut submenu = SubmenuBuilder::new(app, &label);

    // OpenCode — terminal-based IDE
    // All actions require the forge image to be available.
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::opencode_project(&project.path), "💻 OpenCode")
            .enabled(state.forge_available)
            .build(app)?,
    );

    // OpenCode Web — browser-based IDE with browser isolation
    // Launches in a chromium-core container for security isolation.
    // @trace spec:browser-isolation-tray-integration
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::opencode_web_project(&project.path), "🌐 OpenCode Web")
            .enabled(state.forge_available)
            .build(app)?,
    );

    // Claude — AI assistant
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::claude_project(&project.path), "👽 Claude")
            .enabled(state.forge_available)
            .build(app)?,
    );

    // Maintenance — terminal access to the project environment
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::maintenance_project(&project.path), "🔧 Maintenance")
            .enabled(state.forge_available)
            .build(app)?,
    );

    // "Stop" — only shown when a persistent OpenCode Web (forge) container is
    // running for this project. Allows stopping the container without stopping
    // other project activities.
    // @trace spec:browser-isolation-tray-integration
    if opencode_web_running {
        submenu = submenu.separator();
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::stop_project(&project.path), i18n::t("menu.stop"))
                .build(app)?,
        );
    }

    submenu.build()
}

/// Build the display label for a build progress chip.
///
/// - `InProgress` with `image_name == "Maintenance"`: special label "⛏️ Setting up Maintenance..."
/// - `InProgress` otherwise: `"⏳ Building {image_name}..."`
/// - `Completed`: `"✅ {image_name} ready"`
/// - `Failed`: `"❌ {image_name} build failed"`
fn build_chip_label(build: &tillandsias_core::state::BuildProgress) -> String {
    match &build.status {
        BuildStatus::InProgress => {
            if build.image_name == "Maintenance" {
                i18n::t("menu.build.maintenance_setup").to_string()
            } else {
                i18n::tf("menu.build.in_progress", &[("name", &build.image_name)])
            }
        }
        BuildStatus::Completed => i18n::tf("menu.build.completed", &[("name", &build.image_name)]),
        BuildStatus::Failed(_) => i18n::tf("menu.build.failed", &[("name", &build.image_name)]),
    }
}

/// Check if GitHub authentication is needed.
///
/// Returns `true` when the OS keyring has no GitHub OAuth token, OR when the
/// keyring itself is unavailable. In either case the UI must surface a login
/// prompt: we cannot authenticate without a token, and we no longer keep any
/// on-disk fallback to fall through to.
///
/// @trace spec:native-secrets-store
pub(crate) fn needs_github_login() -> bool {
    !matches!(crate::secrets::retrieve_github_token(), Ok(Some(_)))
}
