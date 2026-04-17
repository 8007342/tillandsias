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

    /// Build an "attach here" menu item ID for a project path.
    pub fn attach_here(project_path: &std::path::Path) -> String {
        gen_id(&format!("attach:{}", project_path.display()))
    }

    /// Build a "terminal" menu item ID for a project path.
    pub fn terminal(project_path: &std::path::Path) -> String {
        gen_id(&format!("terminal:{}", project_path.display()))
    }

    /// Build a "serve here" menu item ID for a project path.
    pub fn serve_here(project_path: &std::path::Path) -> String {
        gen_id(&format!("serve:{}", project_path.display()))
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
        "{}/ \u{2014} {}",
        watch_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| watch_path.display().to_string()),
        i18n::t("menu.attach_here")
    );
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::attach_here(&watch_path), &src_label)
            .enabled(state.forge_available)
            .build(app)?,
    );

    // Global root terminal — 🛠️ is reserved for this item and MUST NOT appear in TOOL_EMOJIS.
    menu = menu.item(
        &MenuItemBuilder::with_id(ids::root_terminal(), i18n::t("menu.root_terminal"))
            .enabled(state.forge_available)
            .build(app)?,
    );

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

/// Build the Projects submenu containing only inactive per-project submenus.
///
/// "Inactive" means no running containers belong to the project.
/// Active projects are promoted inline to the top-level menu instead.
///
/// When the inactive list is empty and projects exist (all are active),
/// this function is not called. When no projects are discovered at all,
/// this is called with an empty slice and shows "No projects detected".
///
/// `forge_available` gates "Attach Here" and "Maintenance" — both require the
/// forge image to be present. When `false`, those items are disabled.
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
        // Inactive projects have no running containers so we pass a TrayState-like
        // view with an empty running list. Rather than threading a full TrayState
        // reference just for the emoji logic, we use a zero-running sentinel directly.
        // build_project_submenu uses state.running to find emojis — passing state
        // with the real running list is still correct here: inactive projects won't
        // match any running container by name, so they'll render with plain labels.
        for project in inactive {
            let attach_label = format!("\u{1F331} {}", i18n::t("menu.attach_here"));
            let submenu = SubmenuBuilder::new(app, &project.name)
                .item(
                    &MenuItemBuilder::with_id(ids::attach_here(&project.path), &attach_label)
                        .enabled(forge_available)
                        .build(app)?,
                )
                .item(
                    &MenuItemBuilder::with_id(
                        ids::terminal(&project.path),
                        i18n::t("menu.maintenance"),
                    )
                    .enabled(forge_available)
                    .build(app)?,
                )
                .build()?;
            projects = projects.item(&submenu);
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

    // Version and credit at the bottom of Settings
    settings = settings.separator();
    let version = include_str!("../../VERSION").trim();
    settings = settings.item(
        &MenuItemBuilder::with_id(
            ids::static_id("version"),
            i18n::tf("menu.version", &[("version", version)]),
        )
        .enabled(false)
        .build(app)?,
    );
    settings = settings.item(
        &MenuItemBuilder::with_id(ids::static_id("credit"), i18n::t("menu.credit"))
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

    // Available agents: OpenCode, Claude
    let agents: &[(SelectedAgent, &str)] = &[
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

    let maintenance_running = !tool_emojis.is_empty();

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

    // "Attach Here" — primary action (opens OpenCode)
    // Idle: 🌱 Attach Here (clickable, gated on forge_available)
    // Running: 🌺 Blooming (genus flower, disabled — prevents re-launch)
    let (attach_label, attach_enabled) = if let Some(genus) = project.assigned_genus {
        (
            format!("{} {}", genus.flower(), i18n::t("menu.blooming")),
            false,
        )
    } else {
        (
            format!("\u{1F331} {}", i18n::t("menu.attach_here")),
            state.forge_available,
        ) // 🌱
    };
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::attach_here(&project.path), &attach_label)
            .enabled(attach_enabled)
            .build(app)?,
    );

    // Maintenance menu item.
    // When running: show the first maintenance container's tool emoji.
    // When idle: show pick icon (⛏️).
    // Gated on forge_available — requires the image to launch.
    let maintenance_word = i18n::t("menu.maintenance"); // already includes ⛏️ emoji
    let maintenance_label = if maintenance_running {
        let tool = tool_emojis.first().copied().unwrap_or("\u{26CF}\u{FE0F}");
        // Replace the default ⛏️ prefix with the running tool emoji
        format!("{tool} Maintenance")
    } else {
        maintenance_word.to_string()
    };
    // "Maintenance" — opens bash in a forge container
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::terminal(&project.path), &maintenance_label)
            .enabled(state.forge_available)
            .build(app)?,
    );

    // "Serve Here" — launch a web server container for static files.
    // Running: 🔗 Serving (disabled — prevents duplicate)
    // Idle: 🔗 Serve Here (clickable — always enabled; web image is separate from forge)
    let serve_label = if web_running {
        format!("\u{1F517} {}", i18n::t("menu.serving")) // 🔗 Serving
    } else {
        i18n::t("menu.serve_here").to_string() // 🔗 Serve Here
    };
    submenu = submenu.item(
        &MenuItemBuilder::with_id(ids::serve_here(&project.path), &serve_label)
            .enabled(!web_running)
            .build(app)?,
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
