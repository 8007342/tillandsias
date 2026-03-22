#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod event_loop;
mod handlers;
mod menu;
mod updater;

use std::sync::{Arc, Mutex};

use tauri::tray::TrayIconBuilder;
use tauri::RunEvent;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::MenuCommand;
use tillandsias_core::state::{ContainerInfo, Os, PlatformInfo, TrayState};
use tillandsias_podman::{detect_gpu_devices, PodmanClient, PodmanEventStream};
use tillandsias_scanner::{Scanner, ScannerConfig};

use updater::UpdateState;

fn main() {
    // Initialize tracing for debug builds
    #[cfg(debug_assertions)]
    {
        use tracing_subscriber::EnvFilter;
        tracing_subscriber::fmt()
            .with_env_filter(
                EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| EnvFilter::new("tillandsias=debug")),
            )
            .init();
    }

    info!("Tillandsias starting");

    // Detect platform
    let platform = PlatformInfo {
        os: Os::detect(),
        has_podman: false, // Will be checked async
        has_podman_machine: false,
        gpu_devices: detect_gpu_devices()
            .iter()
            .map(|d| d.replace("--device=", ""))
            .collect(),
    };

    let initial_state = TrayState::new(platform);
    let state = Arc::new(Mutex::new(initial_state));

    // Channels for the event loop
    let (menu_tx, menu_rx) = mpsc::channel::<MenuCommand>(64);
    let (shutdown_tx, shutdown_rx) = mpsc::channel::<()>(1);

    let menu_tx_for_tray = menu_tx.clone();
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

            // Build initial tray icon with tooltip
            let tray_menu = {
                let s = state_for_setup.lock().unwrap();
                menu::build_tray_menu(&app_handle, &s)?
            };

            let _tray = TrayIconBuilder::new()
                .tooltip("Tillandsias")
                .menu(&tray_menu)
                .on_menu_event({
                    let menu_tx = menu_tx_for_tray.clone();
                    move |_app, event| {
                        let id = event.id().as_ref();
                        debug!(menu_id = %id, "Menu event");
                        handle_menu_click(id, &menu_tx);
                    }
                })
                .build(app)?;

            // Spawn the async runtime tasks
            let state_for_loop = state_for_setup.clone();

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
                    return;
                }

                if Os::detect().needs_podman_machine() && !has_machine {
                    warn!("Podman Machine not running. Start it with: podman machine start");
                }

                // Discover existing containers on startup
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

                // Clone state for the rebuild callback
                let state_for_rebuild = state_for_loop.clone();

                // Run main event loop
                let loop_state = { state_for_loop.lock().unwrap().clone() };

                let on_state_change: event_loop::MenuRebuildFn =
                    Box::new(move |new_state: &TrayState| {
                        // Update shared state
                        let mut s = state_for_rebuild.lock().unwrap();
                        s.projects.clone_from(&new_state.projects);
                        s.running.clone_from(&new_state.running);

                        debug!("State changed, menu rebuild needed");
                    });

                event_loop::run(
                    loop_state,
                    scanner_rx,
                    podman_rx,
                    menu_rx,
                    shutdown_rx,
                    on_state_change,
                )
                .await;
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tillandsias")
        .run(move |_app, event| {
            if let RunEvent::ExitRequested { .. } = event {
                info!("Exit requested");
                let _ = shutdown_tx.blocking_send(());
            }
        });
}

/// Dispatch a menu click ID to the appropriate `MenuCommand`.
fn handle_menu_click(id: &str, tx: &mpsc::Sender<MenuCommand>) {
    let command = match id {
        menu::ids::QUIT => Some(MenuCommand::Quit),
        menu::ids::SETTINGS => Some(MenuCommand::Settings),
        _ => {
            if let Some((action, payload)) = menu::ids::parse(id) {
                match action {
                    "attach" => Some(MenuCommand::AttachHere {
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
                            warn!(
                                id,
                                "Cannot parse container name from destroy action"
                            );
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
