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
//! Projects ▸          (always present; contains all per-project submenus)
//! Running ▸           (only when containers are active)
//! Activity ▸          (only when builds are active but nothing is running)
//! ─────────
//! Settings ▸
//! Tillandsias v{ver} ▸  (About: version · credit · quit)
//! ```

use std::sync::atomic::{AtomicU64, Ordering};

use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
use tauri::{AppHandle, Runtime};
use tracing::debug;

use tillandsias_core::config::load_global_config;
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::state::{BuildStatus, ContainerType, TrayState};

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

    /// Build the root terminal menu item ID.
    pub fn root_terminal() -> String {
        gen_id("root-terminal")
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

    // Decay state: podman unavailable — show minimal error menu
    if state.tray_icon_state == TrayIconState::Decay {
        return build_decay_menu(app);
    }

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

    // Global root terminal — 🛠️ is reserved for this item and MUST NOT appear in TOOL_EMOJIS.
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::root_terminal(), "\u{1F6E0}\u{FE0F} Root").build(app)?,
    );

    menu = menu.separator();

    // Projects submenu — all per-project submenus collected under one entry.
    let projects_submenu = build_projects_submenu(app, state)?;
    menu = menu.item(&projects_submenu);

    // Running Environments submenu — only shown when containers are active.
    if !state.running.is_empty() {
        let running_submenu = build_running_submenu(app, state)?;
        menu = menu.item(&running_submenu);
    } else if !state.active_builds.is_empty() {
        // Activity submenu — build chips only, no running containers.
        let activity_submenu = build_activity_submenu(app, state)?;
        menu = menu.item(&activity_submenu);
    }

    menu = menu.separator();

    // Settings submenu — contains GitHub Login/Refresh and Remote Projects.
    let settings_submenu = build_settings_submenu(app, state, &watch_path)?;
    menu = menu.item(&settings_submenu);

    // About submenu — version, credit, and Quit grouped at the bottom.
    let about_submenu = build_about_submenu(app)?;
    menu = menu.item(&about_submenu);

    debug!(
        projects = state.projects.len(),
        running = state.running.len(),
        remote_repos = state.remote_repos.len(),
        active_builds = state.active_builds.len(),
        "Menu rebuilt"
    );

    menu.build()
}

/// Build the minimal Decay menu shown when podman is not available.
///
/// Contains only:
/// - Error item (disabled) explaining podman is unavailable
/// - Separator
/// - About submenu (version · credit · quit)
fn build_decay_menu<R: Runtime>(
    app: &AppHandle<R>,
) -> tauri::Result<tauri::menu::Menu<R>> {
    let mut menu = MenuBuilder::new(app);

    menu = menu.item(
        &MenuItemBuilder::with_id(
            ids::static_id("podman-unavailable"),
            "Podman is not available",
        )
        .enabled(false)
        .build(app)?,
    );

    menu = menu.separator();

    let about_submenu = build_about_submenu(app)?;
    menu = menu.item(&about_submenu);

    debug!("Decay menu built (podman unavailable)");

    menu.build()
}

/// Build the Projects submenu containing all per-project submenus.
///
/// Always present. When no projects are discovered, contains a single
/// disabled "No projects detected" item.
fn build_projects_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut projects = SubmenuBuilder::new(app, "Projects");

    if state.projects.is_empty() {
        projects = projects.item(
            &MenuItemBuilder::with_id(ids::static_id("no-projects"), "No projects detected")
                .enabled(false)
                .build(app)?,
        );
    } else {
        for project in &state.projects {
            let project_submenu = build_project_submenu(app, project, state)?;
            projects = projects.item(&project_submenu);
        }
    }

    projects.build()
}

/// Build the Running Environments submenu.
///
/// Each running container gets its own submenu with Stop and Destroy actions.
/// Active build chips are appended after the container items when present.
fn build_running_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut running_sub = SubmenuBuilder::new(app, "Running Environments");

    for container in &state.running {
        let label = format!(
            "{} {} [{}]",
            container.display_emoji,
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

    // Build chips appended inside Running when present.
    if !state.active_builds.is_empty() {
        running_sub = running_sub.separator();
        for build in &state.active_builds {
            let label = build_chip_label(build);
            running_sub = running_sub.item(
                &MenuItemBuilder::with_id(
                    ids::static_id(&format!("build-chip-{}", build.image_name)),
                    &label,
                )
                .enabled(false)
                .build(app)?,
            );
        }
    }

    running_sub.build()
}

/// Build the Activity submenu shown when builds are active but nothing is running.
fn build_activity_submenu<R: Runtime>(
    app: &AppHandle<R>,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let mut activity = SubmenuBuilder::new(app, "Activity");

    for build in &state.active_builds {
        let label = build_chip_label(build);
        activity = activity.item(
            &MenuItemBuilder::with_id(
                ids::static_id(&format!("build-chip-{}", build.image_name)),
                &label,
            )
            .enabled(false)
            .build(app)?,
        );
    }

    activity.build()
}

/// Build the About submenu containing version, credit, and Quit.
///
/// Label uses the full 4-part version so the user can see the version
/// without expanding the submenu.
fn build_about_submenu<R: Runtime>(
    app: &AppHandle<R>,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    let version = include_str!("../../VERSION").trim();
    let submenu_label = format!("Tillandsias v{version}");

    let about = SubmenuBuilder::new(app, &submenu_label)
        .item(
            &MenuItemBuilder::with_id(
                ids::static_id("version"),
                format!("Tillandsias v{version}"),
            )
            .enabled(false)
            .build(app)?,
        )
        .item(
            &MenuItemBuilder::with_id(ids::static_id("credit"), "by Tlatoāni")
                .enabled(false)
                .build(app)?,
        )
        .separator()
        .item(&MenuItemBuilder::with_id(gen_id(ids::QUIT), "Quit Tillandsias").build(app)?)
        .build()?;

    Ok(about)
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
        "\u{1F512} GitHub Login Refresh"
    } else {
        "\u{1F511} GitHub Login"
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
            &MenuItemBuilder::with_id(
                ids::static_id("cloning-status"),
                format!("Cloning {cloning_name}..."),
            )
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
                &MenuItemBuilder::with_id(
                    ids::static_id("remote-all-local"),
                    "All repos cloned locally",
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

/// Build a submenu for a single project.
fn build_project_submenu<R: Runtime>(
    app: &AppHandle<R>,
    project: &tillandsias_core::project::Project,
    state: &TrayState,
) -> tauri::Result<tauri::menu::Submenu<R>> {
    // Collect display emojis for running containers of this project, separated by type
    let tool_emojis: Vec<&str> = state
        .running
        .iter()
        .filter(|c| c.project_name == project.name && c.container_type == ContainerType::Maintenance)
        .map(|c| c.display_emoji.as_str())
        .collect();
    let flower_emojis: Vec<&str> = state
        .running
        .iter()
        .filter(|c| c.project_name == project.name && c.container_type == ContainerType::Forge)
        .map(|c| c.display_emoji.as_str())
        .collect();

    let maintenance_running = !tool_emojis.is_empty();

    // Project label: name first, emojis as suffix. Tools then flowers.
    // Idle: plain name. Running: "project-name  🔧🪛🌸"
    let label = if tool_emojis.is_empty() && flower_emojis.is_empty() {
        project.name.clone()
    } else {
        let suffix: String = [tool_emojis.join(""), flower_emojis.join("")].concat();
        format!("{}  {}", project.name, suffix)
    };

    let mut submenu = SubmenuBuilder::new(app, &label);

    // "Attach Here" — primary action (opens OpenCode)
    // Idle: 🌱 Attach Here (clickable)
    // Running: 🌺 Blooming (genus flower, disabled — prevents re-launch)
    let (attach_label, attach_enabled) = if let Some(genus) = project.assigned_genus {
        (format!("{} Blooming", genus.flower()), false)
    } else {
        ("\u{1F331} Attach Here".to_string(), true) // 🌱
    };
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::attach_here(&project.path), &attach_label)
            .enabled(attach_enabled)
            .build(app)?,
    );

    // Maintenance menu item.
    // When running: show the first maintenance container's tool emoji.
    // When idle: show pick icon (⛏️).
    let maintenance_label = if maintenance_running {
        let tool = tool_emojis.first().copied().unwrap_or("\u{26CF}\u{FE0F}");
        format!("{tool} Maintenance")
    } else {
        "\u{26CF}\u{FE0F} Maintenance".to_string() // ⛏️ pick — idle
    };
    // "Maintenance" — opens bash in a forge container
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::terminal(&project.path), &maintenance_label).build(app)?
    );

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
                "\u{26CF}\u{FE0F} Setting up Maintenance...".to_string()
            } else {
                format!("\u{23F3} Building {}...", build.image_name)
            }
        }
        BuildStatus::Completed => format!("\u{2705} {} ready", build.image_name),
        BuildStatus::Failed(_) => format!("\u{274C} {} build failed", build.image_name),
    }
}

/// Check if GitHub authentication is needed.
/// Returns true if no gh credentials exist in the native keyring or secrets cache.
pub(crate) fn needs_github_login() -> bool {
    // Check keyring first — token may exist there without a hosts.yml on disk.
    if let Ok(Some(_)) = crate::secrets::retrieve_github_token() {
        return false;
    }
    // Fallback: check the plain text file.
    let cache = tillandsias_core::config::cache_dir();
    let gh_hosts = cache.join("secrets").join("gh").join("hosts.yml");
    !gh_hosts.exists()
}
