//! Dynamic tray menu builder.
//!
//! Builds a hierarchical system tray menu from `TrayState`, reflecting
//! discovered projects, running environments, and their lifecycle states.

use std::sync::atomic::{AtomicU64, Ordering};

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Runtime};
use tracing::debug;

use tillandsias_core::config::load_global_config;
use tillandsias_core::state::TrayState;

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
    pub const REFRESH_REMOTE_PROJECTS: &str = "refresh-remote-projects";

    /// Build an "attach here" menu item ID for a project path.
    pub fn attach_here(project_path: &std::path::Path) -> String {
        gen_id(&format!("attach:{}", project_path.display()))
    }

    /// Build a "terminal" menu item ID for a project path.
    pub fn terminal(project_path: &std::path::Path) -> String {
        gen_id(&format!("terminal:{}", project_path.display()))
    }

    /// Build a "stop" menu item ID for a container.
    pub fn stop(container_name: &str) -> String {
        gen_id(&format!("stop:{container_name}"))
    }

    /// Build a "destroy" menu item ID for a container.
    pub fn destroy(container_name: &str) -> String {
        gen_id(&format!("destroy:{container_name}"))
    }

    /// Build a "clone" menu item ID encoding both full_name and name.
    pub fn clone_project(full_name: &str, name: &str) -> String {
        gen_id(&format!("clone:{full_name}\t{name}"))
    }

    /// Build a menu item ID with generation suffix for non-actionable items.
    pub fn static_id(name: &str) -> String {
        gen_id(name)
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
pub fn build_tray_menu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Menu<R>> {
    // Bump generation so all IDs are unique (avoids libappindicator blank label bug)
    MENU_GENERATION.fetch_add(1, Ordering::Relaxed);

    let mut menu = MenuBuilder::new(app);

    // Permanent "~/src/ — Attach Here" entry at the top.
    // Uses the first watch path from config (default ~/src).
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

    let src_label = format!(
        "{}/ \u{2014} Attach Here",
        watch_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| watch_path.display().to_string())
    );
    menu =
        menu.item(&MenuItemBuilder::with_id(ids::attach_here(&watch_path), &src_label).build(app)?);

    menu = menu.separator();

    // Section: Discovered projects
    if state.projects.is_empty() {
        menu = menu.item(
            &MenuItemBuilder::with_id(ids::static_id("no-projects"), "No projects detected")
                .enabled(false)
                .build(app)?,
        );
    } else {
        for project in &state.projects {
            let project_submenu = build_project_submenu(app, project, state)?;
            menu = menu.item(&project_submenu);
        }
    }

    // Separator
    menu = menu.separator();

    // Section: Running environments
    if state.running.is_empty() {
        menu = menu.item(
            &MenuItemBuilder::with_id(ids::static_id("no-running"), "No running environments")
                .enabled(false)
                .build(app)?,
        );
    } else {
        let running_submenu = SubmenuBuilder::new(app, "Running Environments");
        let mut running_sub = running_submenu;

        for container in &state.running {
            let lifecycle = container.lifecycle();
            let label = format!(
                "{} {} [{}]",
                lifecycle_emoji(lifecycle),
                container.project_name,
                container.genus.display_name()
            );

            let container_sub = SubmenuBuilder::new(app, &label)
                .item(&MenuItemBuilder::with_id(ids::stop(&container.name), "Stop").build(app)?)
                .item(
                    &MenuItemBuilder::with_id(ids::destroy(&container.name), "Destroy (hold 5s)")
                        .build(app)?,
                )
                .build()?;

            running_sub = running_sub.item(&container_sub);
        }

        menu = menu.item(&running_sub.build()?);
    }

    // Separator
    menu = menu.separator();

    // Settings submenu — contains GitHub Login/Refresh and Remote Projects
    let settings_submenu = build_settings_submenu(app, state, &watch_path)?;
    menu = menu.item(&settings_submenu);

    menu = menu.item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), "Quit Tillandsias").build(app)?);

    debug!(
        projects = state.projects.len(),
        running = state.running.len(),
        remote_repos = state.remote_repos.len(),
        "Menu rebuilt"
    );

    menu.build()
}

/// Build the Settings submenu containing GitHub Login/Refresh and Remote Projects.
fn build_settings_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
    watch_path: &std::path::Path,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut settings = SubmenuBuilder::new(app, "Settings");

    let authenticated = !needs_github_login();

    // GitHub Login / GitHub Login Refresh
    let github_label = if authenticated {
        "GitHub Login Refresh"
    } else {
        "GitHub Login"
    };
    settings = settings
        .item(&MenuItemBuilder::with_id(gen_id(ids::GITHUB_LOGIN), github_label).build(app)?);

    // Remote Projects submenu — only when authenticated
    if authenticated {
        settings = settings.separator();
        let remote_submenu = build_remote_projects_submenu(app, state, watch_path)?;
        settings = settings.item(&remote_submenu);
    }

    settings.build()
}

/// Build the "Remote Projects" submenu populated from the cached repo list.
fn build_remote_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
    watch_path: &std::path::Path,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut submenu = SubmenuBuilder::new(app, "Remote Projects");

    // Show cloning state if active
    if let Some(ref cloning_name) = state.cloning_project {
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::static_id("cloning-status"), &format!("Cloning {cloning_name}..."))
                .enabled(false)
                .build(app)?,
        );
        submenu = submenu.separator();
    }

    // Show loading state
    if state.remote_repos_loading {
        submenu = submenu.item(
            &MenuItemBuilder::with_id(ids::static_id("remote-loading"), "Loading...")
                .enabled(false)
                .build(app)?,
        );
        return submenu.build();
    }

    // Show error state
    if let Some(ref error) = state.remote_repos_error {
        let label = if error.contains("No GitHub credentials") {
            "Login to GitHub first".to_string()
        } else {
            "Could not fetch repos".to_string()
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
                &MenuItemBuilder::with_id(ids::static_id("remote-loading"), "Loading...")
                    .enabled(false)
                    .build(app)?,
            );
        } else {
            submenu = submenu.item(
                &MenuItemBuilder::with_id(ids::static_id("remote-all-local"), "All repos cloned locally")
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

/// Build a submenu for a single project.
fn build_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    project: &tillandsias_core::project::Project,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let running_count = state
        .running
        .iter()
        .filter(|c| c.project_name == project.name)
        .count();

    let label = if running_count > 0 {
        format!("{} ({})", project.name, running_count)
    } else {
        project.name.clone()
    };

    let mut submenu = SubmenuBuilder::new(app, &label);

    // "Attach Here" — primary action (opens OpenCode)
    // Prefix with lifecycle emoji: 🌺 if a container is running for this project, 🌱 otherwise
    let attach_label = if running_count > 0 {
        "\u{1F33A} Attach Here" // 🌺 bloom — environment running
    } else {
        "\u{1F331} Attach Here" // 🌱 seedling — idle
    };
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::attach_here(&project.path), attach_label).build(app)?,
    );

    // "🌱 Ground" — opens bash in a forge container
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::terminal(&project.path), "\u{1F331} Ground").build(app)?,
    );

    // Per-project running environments
    let project_containers: Vec<_> = state
        .running
        .iter()
        .filter(|c| c.project_name == project.name)
        .collect();

    if !project_containers.is_empty() {
        submenu = submenu.separator();
        for container in project_containers {
            let lifecycle = container.lifecycle();
            let item_label = format!(
                "{} {} — {}",
                lifecycle_emoji(lifecycle),
                container.genus.display_name(),
                lifecycle_label(lifecycle),
            );
            submenu = submenu.item(
                &MenuItemBuilder::with_id(ids::stop(&container.name), &item_label).build(app)?,
            );
        }
    }

    submenu.build()
}

/// Map plant lifecycle to a status emoji for the menu.
fn lifecycle_emoji(lifecycle: tillandsias_core::genus::PlantLifecycle) -> &'static str {
    use tillandsias_core::genus::PlantLifecycle;
    match lifecycle {
        PlantLifecycle::Bud => "\u{1F331}",   // seedling
        PlantLifecycle::Bloom => "\u{1F33A}", // hibiscus
        PlantLifecycle::Dried => "\u{1F342}", // fallen leaf
        PlantLifecycle::Pup => "\u{1F33F}",   // herb
    }
}

/// Human-readable lifecycle label.
fn lifecycle_label(lifecycle: tillandsias_core::genus::PlantLifecycle) -> &'static str {
    use tillandsias_core::genus::PlantLifecycle;
    match lifecycle {
        PlantLifecycle::Bud => "Starting",
        PlantLifecycle::Bloom => "Running",
        PlantLifecycle::Dried => "Stopping",
        PlantLifecycle::Pup => "Rebuilding",
    }
}

/// Check if GitHub authentication is needed.
/// Returns true if no gh credentials exist in the secrets cache.
pub(crate) fn needs_github_login() -> bool {
    let cache = tillandsias_core::config::cache_dir();
    let gh_hosts = cache.join("secrets").join("gh").join("hosts.yml");
    !gh_hosts.exists()
}
