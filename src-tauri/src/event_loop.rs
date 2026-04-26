//! Main event loop using `tokio::select!`.
//!
//! Multiplexes scanner events, podman events, menu actions, and shutdown
//! signals into a single async loop that drives all tray state updates.
//!
//! @trace spec:tray-app, spec:podman-orchestration

use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::config::{load_global_config, save_selected_language};
use tillandsias_core::event::{BuildProgressEvent, ContainerState, MenuCommand};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::project::{ArtifactStatus, Project, ProjectChange, ProjectType};
use tillandsias_core::state::{
    BuildProgress, BuildStatus, ContainerInfo, ContainerType, RemoteRepoInfo, TrayState,
};
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
    // @trace spec:app-lifecycle
    // AppHandle is required so MenuCommand::Quit can call app_handle.exit(0)
    // after shutdown_all(), triggering RunEvent::ExitRequested { code: Some(0) }
    // which the main.rs handler recognises as an explicit exit.
    app_handle: tauri::AppHandle<tauri::Wry>,
) {
    let mut allocator = GenusAllocator::new();
    let mut tool_allocator = ToolAllocator::new();

    // Seed allocators from containers discovered during startup (graceful restart).
    // Without this, allocate() would not know pre-existing genera/tools are taken and
    // could assign a duplicate genus or tool when the user clicks menu items.
    allocator.seed_from_running(&state.running);
    tool_allocator.seed_from_running(&state.running);

    info!(spec = "tray-app", "Event loop started");

    // Timer drives remote repos fetch — checks periodically if cache is stale.
    // Backs off on errors to avoid spamming (3s → 30s → 300s).
    let mut remote_fetch_interval = tokio::time::interval(Duration::from_secs(5));
    remote_fetch_interval.tick().await; // consume first immediate tick
    let mut remote_fetch_errors: u32 = 0;

    // Channel used by the 10s fadeout tasks to trigger a prune rebuild.
    // We store the sender here so we can clone it for spawned tasks.
    // The receiver is a separate local that we select on.
    let (prune_tx, mut prune_rx) = mpsc::channel::<()>(32);

    // Proxy health check timer — restarts the proxy if it crashed.
    // @trace spec:proxy-container
    let mut proxy_health_interval = tokio::time::interval(Duration::from_secs(60));
    proxy_health_interval.tick().await; // consume first immediate tick

    // @trace spec:tray-app, spec:podman-orchestration, spec:simplified-tray-ux, knowledge:lang/rust-async
    loop {
        tokio::select! {
            // @trace spec:simplified-tray-ux
            // `biased;` polls branches in source order. We deliberately
            // declare `menu_rx` first below so MenuCommand::Quit is
            // serviced within the spec's 5-second budget even when other
            // channels (scanner / podman / build progress) are very busy.
            //
            // Without `biased;` tokio randomises branch poll order which
            // is good for fairness on the hot path but bad for human-
            // perceived responsiveness on Quit.
            biased;

            // Menu: user actions — TOP priority under `biased;` so Quit
            // and Language are always serviced within the 5s budget
            // regardless of how busy the other channels are.
            // @trace spec:simplified-tray-ux
            Some(command) = menu_rx.recv() => {
                match command {
                    MenuCommand::Quit => {
                        // @trace spec:app-lifecycle, spec:opencode-web-session
                        // Single owner of cleanup: stop every container, tear down
                        // the enclave network, close every webview, then ask Tauri
                        // to exit. The RunEvent::ExitRequested handler in main.rs
                        // sees code=Some(0) and finalises without re-running
                        // shutdown_all.
                        info!(spec = "app-lifecycle", "Quit requested — running shutdown_all");
                        handlers::shutdown_all(&state).await;
                        // @trace spec:tray-host-control-socket
                        // Tear down the control socket AFTER container shutdown so
                        // any final tray↔consumer messages can flush before the
                        // listener disappears.
                        crate::shutdown_control_socket().await;
                        info!(spec = "app-lifecycle", "shutdown_all complete — requesting Tauri exit");
                        app_handle.exit(0);
                        break;
                    }
                    MenuCommand::AttachHere { project_path } => {
                        // CLI-only: `tillandsias <path>` still drives this. The tray
                        // never emits AttachHere — it emits Launch instead.
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
                    MenuCommand::GitHubLogin => {
                        info!("GitHub Login requested");
                        if let Err(e) = handlers::handle_github_login(&state, build_tx.clone()).await {
                            error!(error = %e, "GitHub Login failed");
                        } else {
                            // Invalidate remote repos cache so it refreshes
                            // on next menu open after auth completes.
                            state.invalidate_remote_repos_cache();
                            prune_completed_builds(&mut state);
                            // @trace spec:simplified-tray-ux
                            // Re-probe credentials so the stage transitions out
                            // of NoAuth / NetIssue once the new token lands.
                            crate::reprobe_credentials(app_handle.clone());
                            on_state_change(&state);
                        }
                    }
                    MenuCommand::RefreshRemoteProjects => {
                        info!("Remote projects refresh requested");
                        fetch_remote_repos(&mut state, &on_state_change).await;
                    }
                    MenuCommand::CloneProject { full_name, name } => {
                        info!(repo = %full_name, "Clone project requested");
                        handle_clone_project(&full_name, &name, &mut state, &mut allocator, build_tx.clone(), &on_state_change).await;
                    }
                    MenuCommand::SelectLanguage { language } => {
                        info!(language = %language, "Language selection changed");
                        save_selected_language(&language);
                        // Reload i18n strings for the new locale and rebuild menu.
                        crate::i18n::reload(&language);
                        // @trace spec:simplified-tray-ux
                        // Refresh the static label set on the pre-built menu so
                        // the new locale takes effect without a full rebuild.
                        crate::refresh_menu_labels();
                        on_state_change(&state);
                    }
                    // @trace spec:simplified-tray-ux
                    MenuCommand::Launch { project_path } => {
                        info!(spec = "simplified-tray-ux", project = ?project_path, "Launch — routing to opencode-web forge");
                        // Tray Launch is opencode-web only (per spec). Reuses the
                        // existing forge if running; spawns one otherwise.
                        match handlers::handle_attach_web(project_path, &mut state, &mut allocator, build_tx.clone()).await {
                            Ok(_event) => {
                                prune_completed_builds(&mut state);
                                on_state_change(&state);
                            }
                            Err(e) => warn!(error = %e, "Launch failed"),
                        }
                    }
                    // @trace spec:simplified-tray-ux
                    MenuCommand::MaintenanceTerminal { project_path } => {
                        info!(spec = "simplified-tray-ux", project = ?project_path, "MaintenanceTerminal — exec into running forge");
                        match handlers::handle_maintenance_terminal(project_path).await {
                            Ok(()) => debug!("Maintenance terminal launched"),
                            Err(e) => {
                                warn!(error = %e, "Maintenance terminal failed");
                                handlers::send_notification("Tillandsias", &e);
                            }
                        }
                    }
                }
            }

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

            // Proxy health check: restart the proxy if it crashed (60-second interval).
            // Only checks when forge/maintenance containers are running (no point
            // keeping the proxy alive if nothing uses it).
            // @trace spec:proxy-container
            _ = proxy_health_interval.tick() => {
                let has_forge_containers = state.running.iter().any(|c| {
                    matches!(c.container_type,
                        ContainerType::Forge | ContainerType::Maintenance
                    )
                });
                if has_forge_containers {
                    let client = tillandsias_podman::PodmanClient::new();
                    let proxy_running = match client.inspect_container("tillandsias-proxy").await {
                        Ok(inspect) => inspect.state == "running",
                        Err(_) => false,
                    };
                    if !proxy_running {
                        warn!(
                            accountability = true,
                            category = "proxy",
                            spec = "proxy-container",
                            "Proxy container not running — restarting"
                        );
                        if let Err(e) = handlers::ensure_infrastructure_ready(&state, build_tx.clone()).await {
                            error!(spec = "proxy-container", error = %e, "Infrastructure restart failed");
                        }
                    }
                }
            }

            // All channels closed — nothing left to do
            else => {
                info!(spec = "tray-app", "All event channels closed");
                break;
            }
        }
    }

    info!(spec = "tray-app", "Event loop exited");
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
                image_name: image_name.clone(),
                status: BuildStatus::InProgress,
                started_at: Instant::now(),
                completed_at: None,
            });
            // Forge builds (either variant) make the image temporarily unavailable.
            if is_forge_build(&image_name) {
                state.forge_available = false;
            }
        }
        BuildProgressEvent::Completed { image_name } => {
            if let Some(entry) = state
                .active_builds
                .iter_mut()
                .find(|b| b.image_name == image_name)
            {
                entry.status = BuildStatus::Completed;
                entry.completed_at = Some(Instant::now());
            }
            // Forge build completed — image is now ready.
            if is_forge_build(&image_name) {
                state.forge_available = true;
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
            if let Some(entry) = state
                .active_builds
                .iter_mut()
                .find(|b| b.image_name == image_name)
            {
                entry.status = BuildStatus::Failed(reason);
                entry.completed_at = Some(Instant::now());
            }
            // Forge build failed — image remains unavailable; keep forge_available false.
        }
    }
}

/// Returns true if the build image name corresponds to a forge image build.
///
/// Both "Forge" (first-time) and "Updated Forge" (update) are forge builds.
/// The check is intentionally broad so future variants (e.g., with version
/// suffixes) are still recognised.
fn is_forge_build(image_name: &str) -> bool {
    image_name == "Forge" || image_name == "Updated Forge"
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
///
/// After a successful clone, automatically launches the forge for the new
/// project so the user gets immediate visual feedback (blooming flower) that
/// the checkout worked and the environment is ready.
async fn handle_clone_project(
    full_name: &str,
    name: &str,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
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
            // Invalidate remote repos cache so the cloned repo is filtered out.
            state.invalidate_remote_repos_cache();

            // Pre-insert the cloned project into state so handle_attach_here can
            // find it immediately, before the scanner emits a Discovered event.
            // The scanner's dedup guard will skip it when it catches up.
            if !state.projects.iter().any(|p| p.path == target_dir) {
                state.projects.push(Project {
                    name: name.to_string(),
                    path: target_dir.clone(),
                    project_type: ProjectType::Unknown,
                    artifacts: ArtifactStatus::default(),
                    assigned_genus: None,
                });
                debug!(project = %name, "Pre-inserted cloned project into state");
            }

            // Auto-launch the forge for the newly cloned project.
            // Errors are logged but do not affect clone success.
            match handlers::handle_attach_here(target_dir, state, allocator, build_tx).await {
                Ok(_) => {
                    info!(project = %name, "Forge auto-launched after clone");
                }
                Err(e) => {
                    error!(project = %name, error = %e, "Auto-launch after clone failed — user can attach manually");
                }
            }
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
///
/// @trace spec:podman-orchestration
fn handle_podman_event(
    event: tillandsias_podman::events::PodmanEvent,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    tool_allocator: &mut ToolAllocator,
) {
    debug!(
        container = %event.container_name,
        new_state = ?event.new_state,
        spec = "podman-orchestration",
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

            // @trace spec:git-mirror-service
            // When a forge (or opencode-web) container stops, its last push
            // to the enclave mirror has landed. Fast-forward the host
            // working copy at <watch_path>/<project> so what the user sees
            // on disk matches what's on GitHub. Skips gracefully when the
            // host is dirty, diverged, or absent — never clobbers user work.
            if let Some(c) = state.running.iter().find(|c| c.name == name)
                && matches!(
                    c.container_type,
                    ContainerType::Forge
                        | ContainerType::OpenCodeWeb
                        | ContainerType::Maintenance
                ) {
                    let project_name = c.project_name.clone();
                    let mirror_root = tillandsias_core::config::cache_dir().join("mirrors");
                    let mirror_dir = mirror_root.join(&project_name);
                    let global_config = load_global_config();
                    for watch_path in &global_config.scanner.watch_paths {
                        let host = watch_path.join(&project_name);
                        if host.exists() {
                            let result = crate::mirror_sync::sync_project(
                                &project_name,
                                &mirror_dir,
                                &host,
                            );
                            debug!(
                                spec = "git-mirror-service",
                                project = %project_name,
                                host = %host.display(),
                                outcome = ?result,
                                "mirror -> host sync on forge stop"
                            );
                            break;
                        }
                    }
                }

            if let Some(pos) = state.running.iter().position(|c| c.name == name) {
                let removed = state.running.remove(pos);
                allocator.release(&removed.project_name, removed.genus);
                // Release tool emoji if this was a Maintenance container
                if removed.container_type == ContainerType::Maintenance
                    && !removed.display_emoji.is_empty()
                {
                    tool_allocator.release(&removed.project_name, &removed.display_emoji);
                }

                // Clear project genus if no more environments
                let still_has_forge = state
                    .running
                    .iter()
                    .any(|c| {
                        c.project_name == removed.project_name
                            && matches!(
                                c.container_type,
                                ContainerType::Forge | ContainerType::Maintenance
                            )
                    });
                if !still_has_forge
                    && let Some(project) = state
                        .projects
                        .iter_mut()
                        .find(|p| p.name == removed.project_name)
                    {
                        project.assigned_genus = None;
                    }

                    // @trace spec:git-mirror-service, spec:persistent-git-service
                    // Git service container is intentionally NOT stopped here.
                    // It is tray-session-scoped infrastructure (like proxy +
                    // inference): kept alive across forge launches so the next
                    // "Attach Here" for this project skips the ~3s git-image
                    // staleness check + container-start cycle. The mirror cache
                    // on disk persists either way; running the daemon costs
                    // ~10 MB RAM per project, which is negligible compared to
                    // the latency win on every relaunch.
                    //
                    // Cleanup happens in two places:
                    //   - `shutdown_all` (app exit) — stops every git-service
                    //     present in state.running, not just those whose forge
                    //     is still alive at exit time.
                    //   - `EnclaveCleanupGuard` (CLI mode, runner.rs) — stops
                    //     git-service on `tillandsias <project>` exit since
                    //     CLI mode is one-shot and has no tray to host the
                    //     persistent service.
            }
        }
    } else if event.new_state == ContainerState::Running
        || event.new_state == ContainerState::Creating
    {
        // Unknown container with our prefix — discovered on startup or external.
        // Try git service naming first, then web, then genus-based.
        // @trace spec:git-mirror-service
        if let Some(project_name) = ContainerInfo::parse_git_service_container_name(&event.container_name) {
            debug!(
                project = %project_name,
                "Discovered running git service container"
            );
            let sentinel_genus = tillandsias_core::genus::TillandsiaGenus::ALL[0];
            state.running.push(ContainerInfo {
                name: event.container_name,
                project_name,
                genus: sentinel_genus,
                state: event.new_state,
                port_range: (0, 0),
                container_type: ContainerType::GitService,
                display_emoji: String::new(), // Git service is invisible in the menu
            });
        } else if let Some(project_name) = ContainerInfo::parse_web_container_name(&event.container_name) {
            debug!(
                project = %project_name,
                "Discovered running web container"
            );
            // Web containers use a sentinel genus (first in the list); the real
            // display emoji is the chain link. Genus is never shown for Web type.
            let sentinel_genus = tillandsias_core::genus::TillandsiaGenus::ALL[0];
            state.running.push(ContainerInfo {
                name: event.container_name,
                project_name,
                genus: sentinel_genus,
                state: event.new_state,
                port_range: (0, 0), // Unknown — will be updated on next inspect
                container_type: ContainerType::Web,
                display_emoji: "\u{1F517}".to_string(), // 🔗
            });
        } else if let Some((project_name, genus)) =
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

