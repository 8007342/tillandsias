//! Main event loop using `tokio::select!`.
//!
//! Multiplexes scanner events, podman events, menu actions, and shutdown
//! signals into a single async loop that drives all tray state updates.

use tokio::sync::mpsc;
use tracing::{debug, error, info};

use std::time::Instant;

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::{ContainerState, MenuCommand};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::project::ProjectChange;
use tillandsias_core::state::{ContainerInfo, RemoteRepoInfo, TrayState};

use crate::{github, handlers};

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

    // Timer drives remote repos fetch — checks every 3s if cache is stale.
    // First fetch happens ~3s after startup (after initial tick is consumed).
    let mut remote_fetch_interval = tokio::time::interval(std::time::Duration::from_secs(3));
    remote_fetch_interval.tick().await; // consume first immediate tick

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
                    MenuCommand::Start { .. } => {
                        // Start variant kept for backwards compatibility but
                        // removed from the menu (was a duplicate of Attach Here).
                        debug!("Start command received but no longer shown in menu");
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
                    MenuCommand::Terminal { project_path } => {
                        info!(project = ?project_path, "Terminal requested");
                        if let Err(e) = handlers::handle_terminal(project_path, &state).await {
                            error!(error = %e, "Terminal failed");
                        }
                    }
                    MenuCommand::GitHubLogin => {
                        info!("GitHub Login requested");
                        if let Err(e) = handlers::handle_github_login(&state).await {
                            error!(error = %e, "GitHub Login failed");
                        } else {
                            // Invalidate remote repos cache so it refreshes
                            // on next menu open after auth completes.
                            state.invalidate_remote_repos_cache();
                            on_state_change(&state);
                        }
                    }
                    MenuCommand::RefreshRemoteProjects => {
                        info!("Remote projects refresh requested");
                        fetch_remote_repos(&mut state, &on_state_change).await;
                    }
                    MenuCommand::CloneProject { full_name, name } => {
                        info!(repo = %full_name, "Clone project requested");
                        handle_clone_project(&full_name, &name, &mut state, &on_state_change).await;
                    }
                    MenuCommand::Settings => {
                        // Settings is a Submenu now — this event won't fire from menu clicks.
                        // Kept for forward compatibility if Settings ever becomes actionable.
                        debug!("Settings command received");
                    }
                }
            }

            // Timer: check if remote repos cache needs refresh
            _ = remote_fetch_interval.tick() => {
                if !crate::menu::needs_github_login()
                    && state.remote_repos_cache_stale()
                    && !state.remote_repos_loading
                {
                    fetch_remote_repos(&mut state, &on_state_change).await;
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

/// Fetch remote GitHub repos into state cache.
async fn fetch_remote_repos(state: &mut TrayState, on_state_change: &MenuRebuildFn) {
    state.remote_repos_loading = true;
    state.remote_repos_error = None;
    on_state_change(state);

    match github::fetch_repos().await {
        Ok(repos) => {
            state.remote_repos = repos
                .into_iter()
                .map(|r| RemoteRepoInfo {
                    name: r.name,
                    full_name: r.full_name,
                })
                .collect();
            state.remote_repos_fetched_at = Some(Instant::now());
            state.remote_repos_error = None;
            info!(count = state.remote_repos.len(), "Remote repos cache updated");
        }
        Err(e) => {
            error!(error = %e, "Failed to fetch remote repos");
            state.remote_repos_error = Some(e);
        }
    }

    state.remote_repos_loading = false;
    on_state_change(state);
}

/// Handle cloning a remote project into the watched directory.
async fn handle_clone_project(
    full_name: &str,
    name: &str,
    state: &mut TrayState,
    on_state_change: &MenuRebuildFn,
) {
    // Set cloning state
    state.cloning_project = Some(name.to_string());
    on_state_change(state);

    // Determine target directory from config
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
    let target_dir = watch_path.join(name);

    match github::clone_repo(full_name, &target_dir).await {
        Ok(()) => {
            info!(repo = %full_name, target = %target_dir.display(), "Clone completed");
            // Scanner will detect the new directory automatically via filesystem events.
            // Invalidate remote repos cache so the cloned repo is filtered out.
            state.invalidate_remote_repos_cache();
        }
        Err(e) => {
            error!(repo = %full_name, error = %e, "Clone failed");
        }
    }

    // Clear cloning state
    state.cloning_project = None;
    on_state_change(state);
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
                if !still_running
                    && let Some(project) = state
                        .projects
                        .iter_mut()
                        .find(|p| p.name == removed.project_name)
                {
                    project.assigned_genus = None;
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
