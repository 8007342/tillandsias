//! Menu action handlers for tray events.
//!
//! Implements the "Attach Here", "Stop", and "Destroy" workflows that
//! bridge tray menu clicks to podman operations and state updates.

use std::path::PathBuf;
use std::time::Duration;

use tracing::{debug, info, warn};

use tillandsias_core::config::{cache_dir, load_global_config, load_project_config, GlobalConfig};
use tillandsias_core::event::{AppEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_podman::launch::{allocate_port_range, ContainerLauncher};
use tillandsias_podman::PodmanClient;

/// Handle the "Attach Here" action: allocate a genus, create container,
/// update tray state with bud icon.
pub async fn handle_attach_here(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    info!(project = %project_name, "Attach Here requested");

    // Allocate a genus
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    debug!(project = %project_name, genus = %genus.display_name(), "Genus allocated");

    // Load and merge configuration
    let global_config = load_global_config();
    let project_config = load_project_config(&project_path);
    let resolved = global_config.merge_with_project(&project_config);

    // Allocate port range
    let existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    let base_port = GlobalConfig::parse_port_range(&resolved.port_range)
        .unwrap_or((3000, 3099));
    let port_range = allocate_port_range(base_port, &existing_ports);

    // Pre-register container in bud state immediately so the tray shows
    // "Preparing environment..." with the bud icon while the image pull
    // and container start happen asynchronously.
    let container_name = ContainerInfo::container_name(&project_name, genus);
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range,
    };
    state.running.push(placeholder);
    info!(container = %container_name, "Preparing environment... (bud state)");

    // Launch container with a 60s timeout to prevent indefinite hangs
    // (covers image pull + container creation).
    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);
    let cache = cache_dir();

    let launch_result = tokio::time::timeout(
        Duration::from_secs(60),
        launcher.launch(&project_name, genus, &resolved, &project_path, &cache, port_range),
    )
    .await;

    let container_info = match launch_result {
        Ok(Ok(info)) => info,
        Ok(Err(e)) => {
            // Launch failed — remove placeholder from state
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            return Err(format!("Container launch failed: {e}"));
        }
        Err(_) => {
            // Timeout — remove placeholder and try to clean up
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            warn!(container = %container_name, "Container launch timed out after 60s");
            return Err("Container launch timed out (60s). Check image availability and network.".to_string());
        }
    };

    // Update placeholder with real container info
    if let Some(running) = state.running.iter_mut().find(|c| c.name == container_info.name) {
        running.state = container_info.state;
        running.port_range = container_info.port_range;
    }

    info!(
        container = %container_info.name,
        genus = %genus.display_name(),
        port_range = ?port_range,
        "Container launched (bud state)"
    );

    // Mark project as having an assigned genus
    if let Some(project) = state.projects.iter_mut().find(|p| p.path == project_path) {
        project.assigned_genus = Some(genus);
    }

    Ok(AppEvent::ContainerStateChange {
        container_name: container_info.name,
        new_state: ContainerState::Creating,
    })
}

/// Handle the "Stop" action: graceful stop with SIGTERM -> 10s -> SIGKILL,
/// update icon to dried bloom during shutdown.
pub async fn handle_stop(
    container_name: String,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    info!(container = %container_name, "Stop requested");

    // Update state to stopping (dried icon)
    if let Some(container) = state.running.iter_mut().find(|c| c.name == container_name) {
        container.state = ContainerState::Stopping;
    }

    // Perform graceful stop
    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);

    launcher
        .stop(&container_name)
        .await
        .map_err(|e| format!("Stop failed: {e}"))?;

    // Remove from running state and release genus
    if let Some(pos) = state.running.iter().position(|c| c.name == container_name) {
        let container = state.running.remove(pos);
        allocator.release(&container.project_name, container.genus);

        // Clear assigned genus from project if no more environments
        let still_running = state
            .running
            .iter()
            .any(|c| c.project_name == container.project_name);
        if !still_running {
            if let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
            {
                project.assigned_genus = None;
            }
        }

        info!(container = %container_name, "Container stopped and removed from state");
    }

    Ok(AppEvent::ContainerStateChange {
        container_name,
        new_state: ContainerState::Stopped,
    })
}

/// Handle the "Destroy" action: 5-second safety delay, then stop + remove cache.
/// Project source in ~/src is NEVER touched.
pub async fn handle_destroy(
    container_name: String,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    info!(container = %container_name, "Destroy requested (5s safety hold)");

    // 5-second safety confirmation delay
    tokio::time::sleep(Duration::from_secs(5)).await;

    // Parse project name from container name
    let (project_name, _genus) = ContainerInfo::parse_container_name(&container_name)
        .ok_or_else(|| format!("Cannot parse container name: {container_name}"))?;

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);
    let cache = cache_dir();

    launcher
        .destroy(&container_name, &cache, &project_name)
        .await
        .map_err(|e| format!("Destroy failed: {e}"))?;

    // Remove from running state and release genus
    if let Some(pos) = state.running.iter().position(|c| c.name == container_name) {
        let container = state.running.remove(pos);
        allocator.release(&container.project_name, container.genus);

        // Clear assigned genus from project if no more environments
        let still_running = state
            .running
            .iter()
            .any(|c| c.project_name == container.project_name);
        if !still_running {
            if let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
            {
                project.assigned_genus = None;
            }
        }
    }

    info!(container = %container_name, "Container destroyed (cache cleaned)");

    Ok(AppEvent::ContainerStateChange {
        container_name,
        new_state: ContainerState::Absent,
    })
}

/// Graceful application shutdown: stop all managed containers.
pub async fn shutdown_all(state: &TrayState) {
    info!(
        count = state.running.len(),
        "Shutting down: stopping all managed containers"
    );

    let client = PodmanClient::new();
    let launcher = ContainerLauncher::new(client);

    for container in &state.running {
        match launcher.stop(&container.name).await {
            Ok(()) => info!(container = %container.name, "Container stopped"),
            Err(e) => warn!(container = %container.name, error = %e, "Failed to stop container on shutdown"),
        }
    }

    info!("All containers stopped, shutdown complete");
}
