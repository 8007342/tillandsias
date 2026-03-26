//! Main event loop using `tokio::select!`.
//!
//! Multiplexes scanner events, podman events, menu actions, and shutdown
//! signals into a single async loop that drives all tray state updates.

use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use tracing::{debug, error, info};

use tillandsias_core::config::load_global_config;
use tillandsias_core::event::{BuildProgressEvent, ContainerState, MenuCommand};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::project::ProjectChange;
use tillandsias_core::state::{BuildProgress, BuildStatus, ContainerInfo, ContainerType, RemoteRepoInfo, TrayState};
use tillandsias_core::tools::ToolAllocator;

use crate::{github, handlers};

/// Duration a completed build chip remains visible in the menu before being pruned.
const BUILD_CHIP_FADEOUT: Duration = Duration::from_secs(10);

/// Callback for menu rebuilds after state changes.
pub type MenuRebuildFn = Box<dyn Fn(&TrayState) + Send + Sync>;

/// Run the main event loop. This drives the entire application.
///
/// Listens on five event sources via `tokio::select!`:
/// - Scanner: filesystem changes (project discovered/updated/removed)
/// - Podman events: container state changes
/// - Menu actions: user clicks in the tray menu
/// - Build progress: image/maintenance build state transitions
/// - Shutdown signal: SIGTERM/SIGINT
///
/// `build_tx` is cloned and forwarded to handlers so they can report build
/// progress back into this loop via `build_rx`.
pub async fn run(
    mut state: TrayState,
    mut scanner_rx: mpsc::Receiver<ProjectChange>,
    mut podman_rx: mpsc::Receiver<tillandsias_podman::events::PodmanEvent>,
    mut menu_rx: mpsc::Receiver<MenuCommand>,
    mut build_rx: mpsc::Receiver<BuildProgressEvent>,
    build_tx: mpsc::Sender<BuildProgressEvent>,
    on_state_change: MenuRebuildFn,
) {
    let mut allocator = GenusAllocator::new();
    let mut tool_allocator = ToolAllocator::new();

    // Seed allocators from containers discovered during startup (graceful restart).
    // Without this, allocate() would not know pre-existing genera/tools are taken and
    // could assign a duplicate genus or tool when the user clicks menu items.
    allocator.seed_from_running(&state.running);
    tool_allocator.seed_from_running(&state.running);

    info!("Event loop started");

    // Timer drives remote repos fetch — checks periodically if cache is stale.
    // Backs off on errors to avoid spamming (3s → 30s → 300s).
    let mut remote_fetch_interval = tokio::time::interval(Duration::from_secs(5));
    remote_fetch_interval.tick().await; // consume first immediate tick
    let mut remote_fetch_errors: u32 = 0;

    // Channel used by the 10s fadeout tasks to trigger a prune rebuild.
    // We store the sender here so we can clone it for spawned tasks.
    // The receiver is a separate local that we select on.
    let (prune_tx, mut prune_rx) = mpsc::channel::<()>(32);

    loop {
        tokio::select! {
            // Scanner: filesystem changes
            Some(change) = scanner_rx.recv() => {
                handle_scanner_event(change, &mut state);
                prune_completed_builds(&mut state);
                on_state_change(&state);
            }

            // Podman: container state changes
            Some(event) = podman_rx.recv() => {
                handle_podman_event(event, &mut state, &mut allocator, &mut tool_allocator);
                prune_completed_builds(&mut state);
                on_state_change(&state);
            }

            // Build progress: image/maintenance build state transitions
            Some(event) = build_rx.recv() => {
                handle_build_progress_event(event, &mut state, prune_tx.clone());
                prune_completed_builds(&mut state);
                on_state_change(&state);
            }

            // Prune trigger: 10s fadeout timer fired for a completed build chip
            Some(()) = prune_rx.recv() => {
                prune_completed_builds(&mut state);
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
                        match handlers::handle_attach_here(project_path, &mut state, &mut allocator, build_tx.clone()).await {
                            Ok(_event) => {
                                prune_completed_builds(&mut state);
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
                                prune_completed_builds(&mut state);
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
                                prune_completed_builds(&mut state);
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Destroy failed");
                            }
                        }
                    }
                    MenuCommand::Terminal { project_path } => {
                        info!(project = ?project_path, "Terminal requested");
                        match handlers::handle_terminal(project_path, &mut state, &mut allocator, &mut tool_allocator, build_tx.clone()).await {
                            Ok(()) => {
                                prune_completed_builds(&mut state);
                                on_state_change(&state);
                            }
                            Err(e) => {
                                error!(error = %e, "Terminal failed");
                            }
                        }
                    }
                    MenuCommand::GitHubLogin => {
                        info!("GitHub Login requested");
                        if let Err(e) = handlers::handle_github_login(&state, build_tx.clone()).await {
                            error!(error = %e, "GitHub Login failed");
                        } else {
                            // Invalidate remote repos cache so it refreshes
                            // on next menu open after auth completes.
                            state.invalidate_remote_repos_cache();
                            prune_completed_builds(&mut state);
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
                    && state.remote_repos_error.is_none() // don't retry on error (wait for cache invalidation)
                {
                    fetch_remote_repos(&mut state, &on_state_change).await;
                    if state.remote_repos_error.is_some() {
                        remote_fetch_errors += 1;
                        // Exponential backoff: 30s, 60s, 120s, max 300s
                        let backoff = std::cmp::min(30 * (1 << remote_fetch_errors.min(4)), 300);
                        remote_fetch_interval = tokio::time::interval(Duration::from_secs(backoff));
                        remote_fetch_interval.tick().await;
                        debug!(backoff_secs = backoff, errors = remote_fetch_errors, "Remote fetch backing off");
                    } else {
                        remote_fetch_errors = 0;
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

/// Handle a `BuildProgressEvent` sent by a spawned build task.
///
/// - `Started`: push a new `BuildProgress` with `InProgress` status (replacing
///   any previous failed entry for the same image so stale chips don't pile up).
/// - `Completed`: mark the entry as `Completed`, record `completed_at`, and
///   spawn a one-shot 10-second timer that sends a prune trigger.
/// - `Failed`: mark the entry as `Failed`; the chip persists until the next
///   build attempt clears it via `Started`.
fn handle_build_progress_event(
    event: BuildProgressEvent,
    state: &mut TrayState,
    prune_tx: mpsc::Sender<()>,
) {
    match event {
        BuildProgressEvent::Started { image_name } => {
            // Remove any existing entry for this image (clears stale failed chips)
            state.active_builds.retain(|b| b.image_name != image_name);
            state.active_builds.push(BuildProgress {
                image_name,
                status: BuildStatus::InProgress,
                started_at: Instant::now(),
                completed_at: None,
            });
        }
        BuildProgressEvent::Completed { image_name } => {
            if let Some(entry) = state.active_builds.iter_mut().find(|b| b.image_name == image_name) {
                entry.status = BuildStatus::Completed;
                entry.completed_at = Some(Instant::now());
            }
            // Schedule single-fire 10s fadeout so the chip is removed after the
            // grace period without any polling or periodic menu rebuilds.
            tokio::task::spawn(async move {
                tokio::time::sleep(BUILD_CHIP_FADEOUT).await;
                // Best-effort send — if the receiver is gone the app is shutting down.
                let _ = prune_tx.send(()).await;
            });
        }
        BuildProgressEvent::Failed { image_name, reason } => {
            if let Some(entry) = state.active_builds.iter_mut().find(|b| b.image_name == image_name) {
                entry.status = BuildStatus::Failed(reason);
                entry.completed_at = Some(Instant::now());
            }
        }
    }
}

/// Remove build chips that have been `Completed` for longer than `BUILD_CHIP_FADEOUT`.
///
/// Called before every `on_state_change` so that any stale chips are cleaned up
/// at natural state transitions without needing a separate periodic timer.
fn prune_completed_builds(state: &mut TrayState) {
    state.active_builds.retain(|b| {
        if let BuildStatus::Completed = &b.status {
            // Keep if completed within the fadeout window
            b.completed_at
                .map(|t| t.elapsed() < BUILD_CHIP_FADEOUT)
                .unwrap_or(true)
        } else {
            // InProgress and Failed entries are kept
            true
        }
    });
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
            info!(
                count = state.remote_repos.len(),
                "Remote repos cache updated"
            );
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
    tool_allocator: &mut ToolAllocator,
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
                // Release tool emoji if this was a Maintenance container
                if removed.container_type == ContainerType::Maintenance && !removed.display_emoji.is_empty() {
                    tool_allocator.release(&removed.project_name, &removed.display_emoji);
                }

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
                container_type: ContainerType::Forge, // Default for discovered containers
                display_emoji: genus.flower().to_string(), // Default to flower for discovered containers
            });
        }
    }
}
