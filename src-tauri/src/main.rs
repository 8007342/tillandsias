#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod cli;
mod event_loop;
mod handlers;
mod logging;
mod menu;
mod runner;
mod updater;

use std::sync::{Arc, Mutex};

use tauri::tray::TrayIconBuilder;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::MenuCommand;
use tillandsias_core::state::{ContainerInfo, Os, PlatformInfo, TrayState};
use tillandsias_podman::{detect_gpu_devices, PodmanClient, PodmanEventStream};
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

    // If CLI attach mode, run the container runner and exit — no tray app.
    if let cli::CliMode::Attach { path, image, debug } = cli_mode {
        // Initialize tracing for file logging (CLI output uses println!)
        let _log_guard = logging::init();
        let success = runner::run(path, &image, debug);
        std::process::exit(if success { 0 } else { 1 });
    }

    // --- Tray mode below ---

    // Initialize tracing — dual output (stderr if TTY + file appender) in all builds.
    // Hold the guard so the non-blocking file writer flushes on shutdown.
    let _log_guard = logging::init();

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
            let tray = TrayIconBuilder::new()
                .tooltip("Tillandsias")
                .menu(&tray_menu)
                .on_menu_event({
                    let menu_tx = menu_tx.clone();
                    let app_handle = app_handle.clone();
                    move |_app, event| {
                        let id = event.id().as_ref();
                        debug!(menu_id = %id, "Menu event received");

                        // Quit fast-path — exit immediately, no channel round-trip
                        if id == menu::ids::QUIT {
                            info!("Quit requested");
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
                }

                if !has_podman {
                    warn!("Podman not found. Install podman to use Tillandsias.");
                }

                if Os::detect().needs_podman_machine() && !has_machine {
                    warn!("Podman Machine not running. Start it with: podman machine start");
                }

                // Discover existing containers on startup
                if has_podman {
                    match client.list_containers("tillandsias-").await {
                        Ok(containers) => {
                            let mut s = state_for_loop.lock().unwrap();
                            for entry in containers {
                                if let Some((project_name, genus)) =
                                    ContainerInfo::parse_container_name(&entry.name)
                                {
                                    let container_state = match entry.state.as_str() {
                                        "running" => {
                                            tillandsias_core::event::ContainerState::Running
                                        }
                                        "created" | "configured" => {
                                            tillandsias_core::event::ContainerState::Creating
                                        }
                                        _ => tillandsias_core::event::ContainerState::Stopped,
                                    };
                                    s.running.push(ContainerInfo {
                                        name: entry.name,
                                        project_name,
                                        genus,
                                        state: container_state,
                                        port_range: (0, 0),
                                    });
                                }
                            }
                            info!(count = s.running.len(), "Discovered existing containers");
                        }
                        Err(e) => {
                            warn!(error = %e, "Failed to discover existing containers");
                        }
                    }
                }

                // Set up scanner
                let global_config = load_global_config();
                let scanner_config =
                    ScannerConfig::from_core_config(&global_config.scanner);
                let mut scanner = Scanner::new(scanner_config);

                // Initial scan
                let initial_changes = scanner.initial_scan();
                {
                    let mut s = state_for_loop.lock().unwrap();
                    for change in initial_changes {
                        if let tillandsias_core::project::ProjectChange::Discovered(
                            project,
                        ) = change
                        {
                            if !s.projects.iter().any(|p| p.path == project.path) {
                                s.projects.push(project);
                            }
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
                        // Update shared state
                        {
                            let mut s = state_for_rebuild.lock().unwrap();
                            s.projects.clone_from(&new_state.projects);
                            s.running.clone_from(&new_state.running);
                        }

                        // Rebuild tray menu
                        rebuild_menu(&app_for_rebuild, &state_for_rebuild);
                    });

                event_loop::run(
                    loop_state,
                    scanner_rx,
                    podman_rx,
                    menu_rx,
                    on_state_change,
                )
                .await;
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tillandsias")
        .run(move |_app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                info!("Exit requested");
                let _ = shutdown_tx.blocking_send(());
            }
        });
}

/// Rebuild the tray menu from current state and apply it to the tray icon.
fn rebuild_menu(app_handle: &tauri::AppHandle, state: &Arc<Mutex<TrayState>>) {
    let s = state.lock().unwrap();
    match menu::build_tray_menu(app_handle, &s) {
        Ok(new_menu) => {
            if let Some(tray_lock) = TRAY_ICON.get() {
                if let Ok(tray) = tray_lock.lock() {
                    let _ = tray.set_menu(Some(new_menu));
                    debug!(
                        projects = s.projects.len(),
                        running = s.running.len(),
                        "Tray menu rebuilt"
                    );
                }
            }
        }
        Err(e) => {
            error!(error = %e, "Failed to rebuild tray menu");
        }
    }
}

/// Dispatch a menu click ID to the appropriate `MenuCommand`.
fn handle_menu_click(id: &str, tx: &mpsc::Sender<MenuCommand>, _app: &tauri::AppHandle) {
    let command = match id {
        menu::ids::QUIT => None, // Handled via fast-path above
        menu::ids::GITHUB_LOGIN => Some(MenuCommand::GitHubLogin),
        menu::ids::SETTINGS => Some(MenuCommand::Settings),
        _ => {
            if let Some((action, payload)) = menu::ids::parse(id) {
                match action {
                    "attach" => Some(MenuCommand::AttachHere {
                        project_path: payload.into(),
                    }),
                    "terminal" => Some(MenuCommand::Terminal {
                        project_path: payload.into(),
                    }),
                    "start" => Some(MenuCommand::Start {
                        project_path: payload.into(),
                    }),
                    "stop" => {
                        if let Some((_, genus)) =
                            ContainerInfo::parse_container_name(payload)
                        {
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
                        if let Some((_, genus)) =
                            ContainerInfo::parse_container_name(payload)
                        {
                            Some(MenuCommand::Destroy {
                                container_name: payload.to_string(),
                                genus,
                            })
                        } else {
                            warn!(id, "Cannot parse container name from destroy action");
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
