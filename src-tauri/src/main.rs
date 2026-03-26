#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod build_lock;
mod cleanup;
mod cli;
#[cfg(target_os = "linux")]
mod desktop;
mod embedded;
mod event_loop;
mod github;
mod handlers;
mod init;
mod logging;
mod menu;
mod runner;
mod secrets;
mod singleton;
mod update_cli;
mod updater;

use std::sync::{Arc, Mutex};

use tauri::tray::TrayIconBuilder;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::{BuildProgressEvent, MenuCommand};
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::icons;
use tillandsias_core::state::{ContainerInfo, Os, PlatformInfo, TrayState};
use tillandsias_podman::{PodmanClient, PodmanEventStream, detect_gpu_devices};
use tillandsias_scanner::{Scanner, ScannerConfig};

use updater::UpdateState;

/// Global tray icon handle — needed for dynamic menu rebuilds.
/// Set once during setup, never replaced.
static TRAY_ICON: std::sync::OnceLock<Mutex<tauri::tray::TrayIcon>> = std::sync::OnceLock::new();

fn main() {
    // Parse CLI arguments first — before any heavy initialization.
    let cli_mode = match cli::parse() {
        Some(mode) => mode,
        None => {
            // --help was printed, exit cleanly
            std::process::exit(0);
        }
    };

    // Init mode — pre-build images and exit.
    if matches!(cli_mode, cli::CliMode::Init) {
        let success = init::run();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Stats mode — print disk usage report and exit.
    if matches!(cli_mode, cli::CliMode::Stats) {
        let success = cleanup::run_stats();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Clean mode — remove stale artifacts and exit.
    if matches!(cli_mode, cli::CliMode::Clean) {
        let success = cleanup::run_clean();
        std::process::exit(if success { 0 } else { 1 });
    }

    // Update mode — check for updates and apply if available, then exit.
    if matches!(cli_mode, cli::CliMode::Update) {
        let success = update_cli::run();
        std::process::exit(if success { 0 } else { 1 });
    }

    // If CLI attach mode, run the container runner and exit — no tray app.
    if let cli::CliMode::Attach {
        path,
        image,
        debug,
        bash,
    } = cli_mode
    {
        // Initialize tracing for file logging (CLI output uses println!)
        let _log_guard = logging::init();
        let success = runner::run(path, &image, debug, bash);
        std::process::exit(if success { 0 } else { 1 });
    }

    // --- Tray mode below ---

    // Initialize tracing — dual output (stderr if TTY + file appender) in all builds.
    // Hold the guard so the non-blocking file writer flushes on shutdown.
    let _log_guard = logging::init();

    // AppImage desktop integration — install .desktop file and icons on first run.
    // Must happen after logging init (so we can trace) and before tray setup
    // (so the icon is available when GNOME processes the tray window).
    #[cfg(target_os = "linux")]
    desktop::ensure_desktop_integration();

    // Singleton guard — only one tray instance at a time.
    // If another instance is already running, exit silently.
    if singleton::try_acquire().is_err() {
        std::process::exit(0);
    }

    info!("Tillandsias starting");

    // Detect platform
    let platform = PlatformInfo {
        os: Os::detect(),
        has_podman: false,
        has_podman_machine: false,
        gpu_devices: detect_gpu_devices()
            .iter()
            .map(|d| d.replace("--device=", ""))
            .collect(),
    };

    let initial_state = TrayState::new(platform);
    let state = Arc::new(Mutex::new(initial_state));

    // Channel for menu commands → event loop
    let (menu_tx, menu_rx) = mpsc::channel::<MenuCommand>(64);
    let (shutdown_tx, _shutdown_rx) = mpsc::channel::<()>(1);

    // Channel for build progress events (handlers → event loop)
    let (build_tx, build_rx) = mpsc::channel::<BuildProgressEvent>(64);

    let state_for_setup = state.clone();

    let update_state = UpdateState::default();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(update_state.clone())
        .setup(move |app| {
            let app_handle = app.handle().clone();

            // Spawn updater background tasks
            updater::spawn_update_tasks(&app_handle, update_state);

            // Build initial tray menu
            let tray_menu = {
                let s = state_for_setup.lock().unwrap();
                menu::build_tray_menu(&app_handle, &s)?
            };

            // Build tray icon — store handle so it persists and callbacks remain active
            // Icon bytes come from the SVG→PNG build pipeline (Ionantha bud = idle state)
            let icon = tauri::image::Image::from_bytes(icons::tray_icon_png(TrayIconState::Base))
                .expect("embedded tray icon is valid PNG");

            let tray = TrayIconBuilder::new()
                .icon(icon)
                .tooltip("Tillandsias")
                .menu(&tray_menu)
                .on_menu_event({
                    let menu_tx = menu_tx.clone();
                    let app_handle = app_handle.clone();
                    move |_app, event| {
                        let raw_id = event.id().as_ref();
                        let id = menu::ids::strip_gen(raw_id);
                        debug!(menu_id = %id, "Menu event received");

                        // Quit fast-path — exit immediately, no channel round-trip
                        if id == menu::ids::QUIT {
                            info!("Quit requested");
                            singleton::release();
                            std::process::exit(0);
                        }

                        handle_menu_click(id, &menu_tx, &app_handle);
                    }
                })
                .build(app)?;

            // Store tray handle globally so it persists and can be used for menu rebuilds
            let _ = TRAY_ICON.set(Mutex::new(tray));

            // Spawn async runtime tasks
            let state_for_loop = state_for_setup.clone();
            let app_handle_for_loop = app_handle.clone();

            tauri::async_runtime::spawn(async move {
                // Migrate existing plain text GitHub token to native keyring.
                // Idempotent — no-op if already migrated or keyring unavailable.
                secrets::migrate_token_to_keyring();

                // Check podman availability
                let client = PodmanClient::new();
                let has_podman = client.is_available().await;
                let has_machine = if Os::detect().needs_podman_machine() {
                    client.is_machine_running().await
                } else {
                    false
                };

                {
                    let mut s = state_for_loop.lock().unwrap();
                    s.platform.has_podman = has_podman;
                    s.platform.has_podman_machine = has_machine;
                    s.has_podman = has_podman;
                    if !has_podman {
                        s.tray_icon_state = TrayIconState::Decay;
                    }
                }

                if !has_podman {
                    warn!("Podman not found. Install podman to use Tillandsias.");
                    // Set Decay icon immediately
                    if let Some(tray_lock) = TRAY_ICON.get()
                        && let Ok(tray) = tray_lock.lock()
                    {
                        if let Ok(icon) = tauri::image::Image::from_bytes(
                            icons::tray_icon_png(TrayIconState::Decay),
                        ) {
                            let _ = tray.set_icon(Some(icon));
                        }
                    }
                    // Rebuild menu to show Decay state
                    rebuild_menu(&app_handle_for_loop, &state_for_loop);
                }

                if Os::detect().needs_podman_machine() && !has_machine {
                    warn!("Podman Machine not running. Start it with: podman machine start");
                }

                // Discover existing containers on startup (graceful restart)
                //
                // Containers surviving a previous session are discovered here and
                // restored into state.running so the menu shows the correct flower
                // icons and lifecycle states immediately. Only running/creating
                // containers are restored — stopped/exited ones are ignored.
                if has_podman {
                    match client.list_containers("tillandsias-").await {
                        Ok(containers) => {
                            let mut s = state_for_loop.lock().unwrap();
                            for entry in containers {
                                // Map podman state strings to ContainerState.
                                // Skip anything that is not actively running or starting.
                                let container_state = match entry.state.as_str() {
                                    "running" => tillandsias_core::event::ContainerState::Running,
                                    "created" | "configured" => {
                                        tillandsias_core::event::ContainerState::Creating
                                    }
                                    // exited, stopped, dead, removing, paused, unknown — skip.
                                    _ => continue,
                                };

                                // Container name encodes project + genus; skip if unparseable.
                                if let Some((project_name, genus)) =
                                    ContainerInfo::parse_container_name(&entry.name)
                                {
                                    s.running.push(ContainerInfo {
                                        name: entry.name,
                                        project_name,
                                        genus,
                                        state: container_state,
                                        port_range: (0, 0),
                                        container_type: tillandsias_core::state::ContainerType::Forge, // Default for discovered containers
                                        display_emoji: genus.flower().to_string(), // Default to flower for discovered containers
                                    });
                                }
                            }
                            info!(count = s.running.len(), "Restored running containers from prior session");
                        }
                        Err(e) => {
                            warn!(error = %e, "Failed to discover existing containers on startup");
                        }
                    }
                }

                // Launch-time forge image check — build automatically if absent
                if has_podman {
                    let forge_client = tillandsias_podman::PodmanClient::new();
                    if !forge_client.image_exists(handlers::FORGE_IMAGE_TAG).await {
                        info!(tag = handlers::FORGE_IMAGE_TAG, "Forge image absent at launch — triggering auto-build");

                        // Notify the event loop and update the icon to Building
                        let _ = build_tx.try_send(BuildProgressEvent::Started {
                            image_name: "forge".to_string(),
                        });
                        {
                            let mut s = state_for_loop.lock().unwrap();
                            s.active_builds.push(tillandsias_core::state::BuildProgress {
                                image_name: "forge".to_string(),
                                status: tillandsias_core::state::BuildStatus::InProgress,
                                started_at: std::time::Instant::now(),
                                completed_at: None,
                            });
                            s.tray_icon_state = TrayIconState::Building;
                        }
                        if let Some(tray_lock) = TRAY_ICON.get()
                            && let Ok(tray) = tray_lock.lock()
                        {
                            if let Ok(icon) = tauri::image::Image::from_bytes(
                                icons::tray_icon_png(TrayIconState::Building),
                            ) {
                                let _ = tray.set_icon(Some(icon));
                            }
                        }
                        rebuild_menu(&app_handle_for_loop, &state_for_loop);

                        // Run the build (blocking in a worker thread)
                        let build_result =
                            tokio::task::spawn_blocking(|| handlers::run_build_image_script_pub("forge")).await;

                        match build_result {
                            Ok(Ok(())) => {
                                info!(tag = handlers::FORGE_IMAGE_TAG, "Forge image built at launch");
                                let _ = build_tx.try_send(BuildProgressEvent::Completed {
                                    image_name: "forge".to_string(),
                                });
                            }
                            Ok(Err(ref e)) => {
                                warn!(error = %e, "Auto forge build failed at launch");
                                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                                    image_name: "forge".to_string(),
                                    reason: e.clone(),
                                });
                            }
                            Err(ref e) => {
                                warn!(error = %e, "Auto forge build task panicked at launch");
                                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                                    image_name: "forge".to_string(),
                                    reason: format!("Build task panicked: {e}"),
                                });
                            }
                        }
                    } else {
                        info!(tag = handlers::FORGE_IMAGE_TAG, "Forge image present at launch");
                    }
                }

                // Set up scanner
                let global_config = load_global_config();
                let scanner_config = ScannerConfig::from_core_config(&global_config.scanner);
                let mut scanner = Scanner::new(scanner_config);

                // Initial scan
                let initial_changes = scanner.initial_scan();
                {
                    let mut s = state_for_loop.lock().unwrap();
                    for change in initial_changes {
                        if let tillandsias_core::project::ProjectChange::Discovered(project) =
                            change
                            && !s.projects.iter().any(|p| p.path == project.path)
                        {
                            s.projects.push(project);
                        }
                    }
                    info!(count = s.projects.len(), "Initial project scan complete");
                }

                // Rebuild menu after initial scan
                rebuild_menu(&app_handle_for_loop, &state_for_loop);

                // Start scanner watcher
                let (scanner_tx, scanner_rx) = mpsc::channel(256);
                let _scanner_task = tauri::async_runtime::spawn(async move {
                    if let Err(e) = scanner.watch(scanner_tx).await {
                        error!(error = ?e, "Scanner watcher failed");
                    }
                });

                // Start podman event stream
                let (podman_tx, podman_rx) = mpsc::channel(256);
                let podman_event_stream = PodmanEventStream::new("tillandsias-");
                let _podman_task = tauri::async_runtime::spawn(async move {
                    podman_event_stream.stream(podman_tx).await;
                });

                // Run main event loop
                let loop_state = { state_for_loop.lock().unwrap().clone() };

                let state_for_rebuild = state_for_loop.clone();
                let app_for_rebuild = app_handle_for_loop.clone();

                let on_state_change: event_loop::MenuRebuildFn =
                    Box::new(move |new_state: &TrayState| {
                        // Compute new icon state before acquiring the lock
                        let new_icon_state = new_state.compute_icon_state();

                        // Update shared state and detect icon transition
                        let old_icon_state = {
                            let mut s = state_for_rebuild.lock().unwrap();
                            let old = s.tray_icon_state;
                            s.projects.clone_from(&new_state.projects);
                            s.running.clone_from(&new_state.running);
                            s.has_podman = new_state.has_podman;
                            s.tray_icon_state = new_icon_state;
                            s.remote_repos.clone_from(&new_state.remote_repos);
                            s.remote_repos_fetched_at = new_state.remote_repos_fetched_at;
                            s.remote_repos_loading = new_state.remote_repos_loading;
                            s.cloning_project.clone_from(&new_state.cloning_project);
                            s.remote_repos_error
                                .clone_from(&new_state.remote_repos_error);
                            s.active_builds.clone_from(&new_state.active_builds);
                            old
                        };

                        // Update tray icon if state changed
                        if new_icon_state != old_icon_state {
                            if let Some(tray_lock) = TRAY_ICON.get()
                                && let Ok(tray) = tray_lock.lock()
                            {
                                match tauri::image::Image::from_bytes(
                                    icons::tray_icon_png(new_icon_state),
                                ) {
                                    Ok(icon) => {
                                        let _ = tray.set_icon(Some(icon));
                                        debug!(
                                            old = ?old_icon_state,
                                            new = ?new_icon_state,
                                            "Tray icon updated"
                                        );
                                    }
                                    Err(e) => {
                                        error!(error = %e, "Failed to build tray icon image");
                                    }
                                }
                            }
                        }

                        // Rebuild tray menu
                        rebuild_menu(&app_for_rebuild, &state_for_rebuild);
                    });

                event_loop::run(loop_state, scanner_rx, podman_rx, menu_rx, build_rx, build_tx, on_state_change).await;
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tillandsias")
        .run(move |_app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                info!("Exit requested");
                singleton::release();
                let _ = shutdown_tx.blocking_send(());
            }
        });
}

/// Rebuild the tray menu from current state and apply it to the tray icon.
fn rebuild_menu(app_handle: &tauri::AppHandle, state: &Arc<Mutex<TrayState>>) {
    let s = state.lock().unwrap();
    match menu::build_tray_menu(app_handle, &s) {
        Ok(new_menu) => {
            if let Some(tray_lock) = TRAY_ICON.get()
                && let Ok(tray) = tray_lock.lock()
            {
                let _ = tray.set_menu(Some(new_menu));
                debug!(
                    projects = s.projects.len(),
                    running = s.running.len(),
                    "Tray menu rebuilt"
                );
            }
        }
        Err(e) => {
            error!(error = %e, "Failed to rebuild tray menu");
        }
    }
}

/// Dispatch a menu click ID to the appropriate `MenuCommand`.
fn handle_menu_click(id: &str, tx: &mpsc::Sender<MenuCommand>, _app: &tauri::AppHandle) {
    // Strip the generation suffix (e.g., "quit#5" -> "quit") added to avoid
    // libappindicator's menu ID caching bug that causes blank labels.
    let id = menu::ids::strip_gen(id);

    let command = match id {
        menu::ids::QUIT => None, // Handled via fast-path above
        menu::ids::GITHUB_LOGIN => Some(MenuCommand::GitHubLogin),
        menu::ids::SETTINGS => Some(MenuCommand::Settings),
        menu::ids::REFRESH_REMOTE_PROJECTS => Some(MenuCommand::RefreshRemoteProjects),
        "root-terminal" => Some(MenuCommand::RootTerminal),
        _ => {
            if let Some((action, payload)) = menu::ids::parse(id) {
                match action {
                    "attach" => Some(MenuCommand::AttachHere {
                        project_path: payload.into(),
                    }),
                    "terminal" => Some(MenuCommand::Terminal {
                        project_path: payload.into(),
                    }),
                    // "start" ID no longer emitted from menu but kept
                    // for safety in case external callers use it.
                    "start" => Some(MenuCommand::Start {
                        project_path: payload.into(),
                    }),
                    "stop" => {
                        if let Some((_, genus)) = ContainerInfo::parse_container_name(payload) {
                            Some(MenuCommand::Stop {
                                container_name: payload.to_string(),
                                genus,
                            })
                        } else {
                            warn!(id, "Cannot parse container name from stop action");
                            None
                        }
                    }
                    "destroy" => {
                        if let Some((_, genus)) = ContainerInfo::parse_container_name(payload) {
                            Some(MenuCommand::Destroy {
                                container_name: payload.to_string(),
                                genus,
                            })
                        } else {
                            warn!(id, "Cannot parse container name from destroy action");
                            None
                        }
                    }
                    "clone" => {
                        // Payload format: "<full_name>\t<name>"
                        if let Some((full_name, name)) = payload.split_once('\t') {
                            Some(MenuCommand::CloneProject {
                                full_name: full_name.to_string(),
                                name: name.to_string(),
                            })
                        } else {
                            warn!(id, "Cannot parse clone project from menu ID");
                            None
                        }
                    }
                    _ => {
                        debug!(action, "Unknown menu action");
                        None
                    }
                }
            } else {
                None
            }
        }
    };

    if let Some(cmd) = command {
        let _ = tx.try_send(cmd);
    }
}
