//! Dynamic tray menu builder.
//!
//! Builds a hierarchical system tray menu from `TrayState`, reflecting
//! discovered projects, running environments, and their lifecycle states.
//!
//! ## Top-level structure (simplified-tray-ux)
//!
//! Implements five-stage menu structure based on application state:
//!
//! **Booting/Ready**: Verification + divider + version + quit
//! **NoAuth**: GitHub Login + divider + version + quit
//! **Authed**: Projects ▸ + divider + version + quit
//! **NetIssue**: GitHub Login + Projects ▸ + divider + version + quit
//!
//! @trace spec:simplified-tray-ux, spec:tray-app

use std::sync::atomic::{AtomicU64, Ordering};

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Runtime};
use tracing::debug;

use tillandsias_core::config::load_global_config;
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::state::TrayState;

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
/// @trace spec:simplified-tray-ux
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
    // @trace spec:simplified-tray-ux
    if !state.forge_available {
        return build_minimal_menu(app, state);
    }

    let mut menu = MenuBuilder::new(app);

    // Get watch path for local/remote projects
    // Uses the first watch path from config (default ~/src).
    // @trace spec:simplified-tray-ux
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

    let authenticated = !needs_github_login();

    // Build Home (local projects) submenu — always shown when authenticated
    // @trace spec:simplified-tray-ux
    if authenticated && !state.projects.is_empty() {
        let home_submenu = build_home_projects_submenu(app, state)?;
        menu = menu.item(&home_submenu);
    }

    // Build Cloud (remote projects) submenu — shown when authenticated and remote repos exist
    // @trace spec:simplified-tray-ux
    if authenticated && !state.remote_repos.is_empty() {
        let cloud_submenu = build_cloud_projects_submenu(app, state, &watch_path)?;
        menu = menu.item(&cloud_submenu);
    }

    // GitHub Login — show if not authenticated
    // @trace spec:simplified-tray-ux
    if !authenticated {
        menu = menu.item(
            &MenuItemBuilder::with_id(ids::GITHUB_LOGIN, i18n::t("menu.github.login"))
                .enabled(state.forge_available)
                .build(app)?,
        );
    }

    menu = menu.separator();

    // Version + attribution (disabled, visual signature only)
    // @trace spec:simplified-tray-ux
    let version = include_str!("../../VERSION").trim();
    let version_label = format!("v{} — by Tlatoāni", version);
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::static_id("version"), &version_label)
            .enabled(false)
            .build(app)?,
    );

    // Quit — always visible and enabled
    menu =
        menu.item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), i18n::t("menu.quit")).build(app)?);

    debug!(
        projects = state.projects.len(),
        remote_repos = state.remote_repos.len(),
        authenticated,
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
/// @trace spec:simplified-tray-ux
fn environment_status_label(state: &TrayState) -> String {
    // Check if environment is fully ready
    if state.forge_available {
        return "✅ Environment OK".to_string();
    }

    // Check if any builds are active
    if !state.active_builds.is_empty() {
        // Get the LATEST build (most recent stage)
        let latest_build = state.active_builds.last();

        let status_emoji = match latest_build.map(|b| b.image_name.as_str()) {
            Some("proxy") => "📦",
            Some("forge") => "📦",
            Some("git") => "📦",
            Some("inference") => "📦",
            Some("chromium-core") => "📦",
            Some("chromium-framework") => "📦",
            _ => "⚙️", // fallback
        };

        let stage_name = latest_build
            .map(|b| b.image_name.as_str())
            .unwrap_or("environment");

        return format!("{} Building {}...", status_emoji, stage_name);
    }

    // Check TrayIconState for failure state
    if state.tray_icon_state == TrayIconState::Dried {
        return "🌹 Unhealthy environment".to_string();
    }

    // Default: verifying
    "📋 Verifying environment...".to_string()
}


/// Build the Home submenu containing local projects.
/// Each project shows 4 action buttons: OpenCode, OpenCode Web, Claude, Maintenance.
/// @trace spec:simplified-tray-ux
fn build_home_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut home = SubmenuBuilder::new(app, i18n::t("menu.projects"));

    // List projects alphabetically
    let mut projects = state.projects.clone();
    projects.sort_by(|a, b| a.name.cmp(&b.name));

    for project in projects {
        let mut submenu = SubmenuBuilder::new(app, &project.name);

        // OpenCode — terminal-based IDE
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                ids::opencode_project(&project.path),
                "💻 OpenCode",
            )
            .enabled(state.forge_available)
            .build(app)?,
        );

        // OpenCode Web — browser-based IDE with browser isolation
        // @trace spec:browser-isolation-tray-integration
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                ids::opencode_web_project(&project.path),
                "🌐 OpenCode Web",
            )
            .enabled(state.forge_available)
            .build(app)?,
        );

        // Claude — AI assistant
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::claude_project(&project.path), "👽 Claude")
                .enabled(state.forge_available)
                .build(app)?,
        );

        // Maintenance — terminal access
        submenu = submenu.item(
            &MenuItemBuilder::with_id(
                ids::maintenance_project(&project.path),
                "🔧 Maintenance",
            )
            .enabled(state.forge_available)
            .build(app)?,
        );

        home = home.item(&submenu.build()?);
    }

    home.build()
}

/// Build the Cloud submenu containing remote projects (minus those already cloned locally).
/// Each project shows 4 action buttons with clone prefix: OpenCode, OpenCode Web, Claude, Maintenance.
/// All actions require cloning first if the project doesn't exist locally.
/// @trace spec:simplified-tray-ux
fn build_cloud_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
    watch_path: &std::path::Path,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut cloud = SubmenuBuilder::new(app, i18n::t("menu.cloud_projects"));

    // Show cloning state if active
    if let Some(ref cloning_name) = state.cloning_project {
        cloud = cloud.item(
            &MenuItemBuilder::with_id(
                ids::static_id("cloning-status"),
                i18n::tf("menu.github.cloning", &[("name", cloning_name)]),
            )
            .enabled(false)
            .build(app)?,
        );
        cloud = cloud.separator();
    }

    // Show loading state
    if state.remote_repos_loading {
        cloud = cloud.item(
            &MenuItemBuilder::with_id(
                ids::static_id("remote-loading"),
                i18n::t("menu.github.loading"),
            )
            .enabled(false)
            .build(app)?,
        );
        return cloud.build();
    }

    // Show error state
    if let Some(ref error) = state.remote_repos_error {
        let label = if error.contains("No GitHub credentials") {
            i18n::t("menu.github.login_first").to_string()
        } else {
            i18n::t("menu.github.could_not_fetch").to_string()
        };
        cloud = cloud.item(
            &MenuItemBuilder::with_id(ids::static_id("remote-error"), &label)
                .enabled(false)
                .build(app)?,
        );
        return cloud.build();
    }

    // Filter repos: exclude those that already exist locally
    let local_names: Vec<String> = state.projects.iter().map(|p| p.name.clone()).collect();

    let mut remote_only: Vec<_> = state
        .remote_repos
        .iter()
        .filter(|repo| {
            let exists_in_projects = local_names.contains(&repo.name);
            let exists_on_disk = watch_path.join(&repo.name).exists();
            !exists_in_projects && !exists_on_disk
        })
        .collect();

    // Sort alphabetically
    remote_only.sort_by(|a, b| a.name.cmp(&b.name));

    if remote_only.is_empty() {
        if state.remote_repos.is_empty() && state.remote_repos_fetched_at.is_none() {
            cloud = cloud.item(
                &MenuItemBuilder::with_id(
                    ids::static_id("remote-loading"),
                    i18n::t("menu.github.loading"),
                )
                .enabled(false)
                .build(app)?,
            );
        } else {
            cloud = cloud.item(
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
            let mut submenu = SubmenuBuilder::new(app, &repo.name);

            // OpenCode (clone+) — terminal-based IDE
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::clone_project(&repo.full_name, &repo.name),
                    "💻 OpenCode (clone+)",
                )
                .enabled(state.forge_available)
                .build(app)?,
            );

            // OpenCode Web (clone+) — browser-based IDE
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::clone_project(&format!("{}/web", repo.full_name), &repo.name),
                    "🌐 OpenCode Web (clone+)",
                )
                .enabled(state.forge_available)
                .build(app)?,
            );

            // Claude (clone+) — AI assistant
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::clone_project(&format!("{}/claude", repo.full_name), &repo.name),
                    "👽 Claude (clone+)",
                )
                .enabled(state.forge_available)
                .build(app)?,
            );

            // Maintenance (clone+) — terminal access
            submenu = submenu.item(
                &MenuItemBuilder::with_id(
                    ids::clone_project(&format!("{}/maintenance", repo.full_name), &repo.name),
                    "🔧 Maintenance (clone+)",
                )
                .enabled(state.forge_available)
                .build(app)?,
            );

            cloud = cloud.item(&submenu.build()?);
        }
    }

    cloud.build()
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
