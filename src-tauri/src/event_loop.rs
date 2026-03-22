//! Main event loop using `tokio::select!`.
//!
//! Multiplexes scanner events, podman events, menu actions, and shutdown
//! signals into a single async loop that drives all tray state updates.

use tokio::sync::mpsc;
use tracing::{debug, error, info};

use tillandsias_core::event::{ContainerState, MenuCommand};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::project::ProjectChange;
use tillandsias_core::state::{ContainerInfo, TrayState};

use crate::handlers;

/// Callback for menu rebuilds after state changes.
pub type MenuRebuildFn = Box<dyn Fn(&TrayState) + Send + Sync>;

/// Run the main event loop. This drives the entire application.
///
/// Listens on four event sources via `tokio::select!`:
/// - Scanner: filesystem changes (project discovered/updated/removed)
/// - Podman events: container state changes
/// - Menu actions: user clicks in the tray menu
/// - Shutdown signal: SIGTERM/SIGINT
pub async fn run(
    mut state: TrayState,
    mut scanner_rx: mpsc::Receiver<ProjectChange>,
    mut podman_rx: mpsc::Receiver<tillandsias_podman::events::PodmanEvent>,
    mut menu_rx: mpsc::Receiver<MenuCommand>,
    on_state_change: MenuRebuildFn,
) {
    let mut allocator = GenusAllocator::new();

    info!("Event loop started");

    loop {
        tokio::select! {
            // Scanner: filesystem changes
            Some(change) = scanner_rx.recv() => {
                handle_scanner_event(change, &mut state);
                on_state_change(&state);
            }

            // Podman: container state changes
            Some(event) = podman_rx.recv() => {
                handle_podman_event(event, &mut state, &mut allocator);
                on_state_change(&state);
            }

            // Menu: user actions
            Some(command) = menu_rx.recv() => {
                match command {
                    MenuCommand::Quit => {
                        info!("Quit requested from menu");
                        handlers::shutdown_all(&state).await;
                        break;
                    }
                    MenuCommand::AttachHere { project_path } => {
                        match handlers::handle_attach_here(project_path, &mut state, &mut allocator).await {
                            Ok(_event) => {
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Attach Here failed");
                            }
                        }
                    }
                    MenuCommand::Start { project_path } => {
                        // Start is equivalent to Attach Here for now
                        match handlers::handle_attach_here(project_path, &mut state, &mut allocator).await {
                            Ok(_event) => {
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Start failed");
                            }
                        }
                    }
                    MenuCommand::Stop { container_name, genus: _ } => {
                        match handlers::handle_stop(container_name, &mut state, &mut allocator).await {
                            Ok(_event) => {
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Stop failed");
                            }
                        }
                    }
                    MenuCommand::Destroy { container_name, genus: _ } => {
                        match handlers::handle_destroy(container_name, &mut state, &mut allocator).await {
                            Ok(_event) => {
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Destroy failed");
                            }
                        }
                    }
                    MenuCommand::Settings => {
                        debug!("Settings requested (not yet implemented)");
                    }
                }
            }

            // All channels closed — nothing left to do
            else => {
                info!("All event channels closed");
                break;
            }
        }
    }

    info!("Event loop exited");
}

/// Process a scanner filesystem change event.
fn handle_scanner_event(change: ProjectChange, state: &mut TrayState) {
    match change {
        ProjectChange::Discovered(project) => {
            debug!(name = %project.name, "Project discovered");
            // Avoid duplicates
            if !state.projects.iter().any(|p| p.path == project.path) {
                state.projects.push(project);
            }
        }
        ProjectChange::Updated(project) => {
            debug!(name = %project.name, "Project updated");
            if let Some(existing) = state.projects.iter_mut().find(|p| p.path == project.path) {
                existing.project_type = project.project_type;
                existing.artifacts = project.artifacts;
            } else {
                state.projects.push(project);
            }
        }
        ProjectChange::Removed { path } => {
            debug!(?path, "Project removed");
            state.projects.retain(|p| p.path != path);
        }
    }
}

/// Process a podman container state change event.
fn handle_podman_event(
    event: tillandsias_podman::events::PodmanEvent,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) {
    debug!(
        container = %event.container_name,
        new_state = ?event.new_state,
        "Podman event"
    );

    // Find the container in our state
    if let Some(container) = state
        .running
        .iter_mut()
        .find(|c| c.name == event.container_name)
    {
        // Update state — transitions icon via lifecycle mapping
        container.state = event.new_state;

        // If container is now stopped/absent, remove it
        if matches!(
            event.new_state,
            ContainerState::Stopped | ContainerState::Absent
        ) {
            let name = event.container_name.clone();
            if let Some(pos) = state.running.iter().position(|c| c.name == name) {
                let removed = state.running.remove(pos);
                allocator.release(&removed.project_name, removed.genus);

                // Clear project genus if no more environments
                let still_running = state
                    .running
                    .iter()
                    .any(|c| c.project_name == removed.project_name);
                if !still_running {
                    if let Some(project) = state
                        .projects
                        .iter_mut()
                        .find(|p| p.name == removed.project_name)
                    {
                        project.assigned_genus = None;
                    }
                }
            }
        }
    } else if event.new_state == ContainerState::Running
        || event.new_state == ContainerState::Creating
    {
        // Unknown container with our prefix — discovered on startup or external
        if let Some((project_name, genus)) =
            ContainerInfo::parse_container_name(&event.container_name)
        {
            debug!(
                project = %project_name,
                genus = %genus.display_name(),
                "Discovered running container"
            );
            state.running.push(ContainerInfo {
                name: event.container_name,
                project_name,
                genus,
                state: event.new_state,
                port_range: (0, 0), // Unknown — will be updated on next inspect
            });
        }
    }
}
