//! Menu action handlers for tray events.
//!
//! Implements the "Attach Here", "Stop", and "Destroy" workflows that
//! bridge tray menu clicks to podman operations and state updates.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tracing::{debug, info, warn};

use tillandsias_core::config::{cache_dir, data_dir, load_global_config, load_project_config, GlobalConfig};
use tillandsias_core::event::{AppEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_podman::launch::{allocate_port_range, ContainerLauncher};
use tillandsias_podman::PodmanClient;

const FORGE_IMAGE_TAG: &str = "tillandsias-forge:latest";

/// Detect a terminal emulator available on the host.
///
/// Tries, in order:
/// 1. `$TERMINAL` environment variable
/// 2. `x-terminal-emulator` (Debian/Ubuntu alternatives system)
/// 3. Common terminal emulators: gnome-terminal, konsole, alacritty, kitty,
///    foot, xfce4-terminal, xterm
///
/// Returns `None` if nothing is found.
fn detect_terminal() -> Option<String> {
    // 1. $TERMINAL env var
    if let Ok(term) = std::env::var("TERMINAL") {
        if !term.is_empty() {
            return Some(term);
        }
    }

    // 2. x-terminal-emulator (Debian/Ubuntu)
    // 3. Fallback list
    let candidates = [
        "x-terminal-emulator",
        "ptyxis",           // GNOME Terminal on Silverblue/Fedora 43+
        "gnome-terminal",
        "gnome-console",    // GNOME Console (kgx)
        "konsole",
        "alacritty",
        "kitty",
        "foot",
        "xfce4-terminal",
        "xterm",
    ];

    for candidate in &candidates {
        if which_sync(candidate) {
            return Some((*candidate).to_string());
        }
    }

    None
}

/// Synchronous check if a binary exists in PATH.
fn which_sync(name: &str) -> bool {
    std::process::Command::new("which")
        .arg(name)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Resolve the default image source directory.
///
/// Checks (in order):
/// 1. `images/default/` relative to the executable
/// 2. `~/.local/share/tillandsias/images/default/`
///
/// Returns `None` if neither location has a Containerfile.
fn resolve_image_source() -> Option<PathBuf> {
    // 1. Relative to executable (dev builds, bundled installs)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            // Try alongside the binary
            let candidate = exe_dir.join("images").join("default");
            if candidate.join("Containerfile").exists() {
                return Some(candidate);
            }
            // Try two levels up (target/debug/tillandsias-tray → project root)
            if let Some(root) = exe_dir.parent().and_then(|p| p.parent()) {
                let candidate = root.join("images").join("default");
                if candidate.join("Containerfile").exists() {
                    return Some(candidate);
                }
            }
        }
    }

    // 2. Installed data directory
    let data = data_dir().join("images").join("default");
    if data.join("Containerfile").exists() {
        return Some(data);
    }

    None
}

/// Build the `podman run -it --rm` argument list for interactive terminal mode.
fn build_interactive_run_args(
    container_name: &str,
    image: &str,
    project_path: &Path,
    cache_dir: &Path,
    port_range: (u16, u16),
) -> Vec<String> {
    let mut args = Vec::new();

    // Interactive + ephemeral (NOT detached — user gets terminal directly)
    args.push("-it".to_string());
    args.push("--rm".to_string());

    // Container name
    args.push("--name".to_string());
    args.push(container_name.to_string());

    // Non-negotiable security flags
    args.push("--cap-drop=ALL".to_string());
    args.push("--security-opt=no-new-privileges".to_string());
    args.push("--userns=keep-id".to_string());
    args.push("--security-opt=label=disable".to_string());

    // Port range mapping
    let port_mapping = format!(
        "{}-{}:{}-{}",
        port_range.0, port_range.1, port_range.0, port_range.1
    );
    args.push("-p".to_string());
    args.push(port_mapping);

    // Volume mounts
    // Project directory -> container workspace (rw)
    let project_mount = format!("{}:/home/forge/src", project_path.display());
    args.push("-v".to_string());
    args.push(project_mount);

    // Cache directory -> container cache
    let cache_mount = format!(
        "{}:/home/forge/.cache/tillandsias",
        cache_dir.display()
    );
    args.push("-v".to_string());
    args.push(cache_mount);

    // Container image (always last)
    args.push(image.to_string());

    args
}

/// Handle the "Attach Here" action: build image if needed, open terminal
/// with an interactive container.
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
    let _resolved = global_config.merge_with_project(&project_config);

    // Allocate port range
    let existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    let base_port = GlobalConfig::parse_port_range(&_resolved.port_range)
        .unwrap_or((3000, 3099));
    let port_range = allocate_port_range(base_port, &existing_ports);

    // Pre-register container in bud state immediately so the tray shows
    // "Preparing environment..." with the bud icon while the image build
    // and terminal launch happen.
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

    // Resolve image source and ensure image is built
    let client = PodmanClient::new();

    let image_source = resolve_image_source();
    if let Some(ref source_dir) = image_source {
        let containerfile = source_dir.join("Containerfile");
        let containerfile_str = containerfile.to_string_lossy().to_string();
        let context_dir_str = source_dir.to_string_lossy().to_string();

        info!(tag = FORGE_IMAGE_TAG, source = %context_dir_str, "Ensuring image is built");

        let build_result = tokio::time::timeout(
            Duration::from_secs(300), // Image builds can take a while
            client.ensure_image_built(FORGE_IMAGE_TAG, &containerfile_str, &context_dir_str),
        )
        .await;

        match build_result {
            Ok(Ok(())) => {
                info!(tag = FORGE_IMAGE_TAG, "Image ready");
            }
            Ok(Err(e)) => {
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(format!("Image build failed: {e}"));
            }
            Err(_) => {
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err("Image build timed out (300s).".to_string());
            }
        }
    } else {
        // No local image source found — check if image already exists
        if !client.image_exists(FORGE_IMAGE_TAG).await {
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            return Err(format!(
                "Image {} not found and no Containerfile source available. \
                 Expected images/default/Containerfile relative to executable \
                 or in ~/.local/share/tillandsias/images/default/",
                FORGE_IMAGE_TAG
            ));
        }
    }

    // Detect terminal emulator
    let terminal = detect_terminal().ok_or_else(|| {
        state.running.retain(|c| c.name != container_name);
        allocator.release(&project_name, genus);
        "No terminal emulator found. Set $TERMINAL or install one of: \
         gnome-terminal, konsole, alacritty, kitty, foot, xfce4-terminal, xterm"
            .to_string()
    })?;

    debug!(terminal = %terminal, "Detected terminal emulator");

    // Ensure cache directories exist
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // Build the podman run command for interactive mode
    let run_args = build_interactive_run_args(
        &container_name,
        FORGE_IMAGE_TAG,
        &project_path,
        &cache,
        port_range,
    );

    // Build the full podman command string
    let mut podman_cmd_parts = vec!["podman".to_string(), "run".to_string()];
    podman_cmd_parts.extend(run_args);
    let podman_cmd = podman_cmd_parts.join(" ");

    // Spawn the terminal with the podman run command.
    // When the user exits OpenCode, the container dies (--rm).
    let spawn_result = spawn_terminal(&terminal, &podman_cmd);

    match spawn_result {
        Ok(()) => {
            info!(
                container = %container_name,
                terminal = %terminal,
                genus = %genus.display_name(),
                port_range = ?port_range,
                "Terminal launched with interactive container"
            );
        }
        Err(e) => {
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            return Err(format!("Failed to spawn terminal: {e}"));
        }
    }

    // Mark project as having an assigned genus
    if let Some(project) = state.projects.iter_mut().find(|p| p.path == project_path) {
        project.assigned_genus = Some(genus);
    }

    Ok(AppEvent::ContainerStateChange {
        container_name: container_name.clone(),
        new_state: ContainerState::Creating,
    })
}

/// Spawn a terminal emulator running a command.
///
/// Different terminals have different argument conventions for running
/// a command. Most accept `-e <command>`, but gnome-terminal uses `--`.
fn spawn_terminal(terminal: &str, command: &str) -> Result<(), String> {
    let mut cmd = std::process::Command::new(terminal);

    // Different terminals have different argument conventions
    if terminal.contains("gnome-terminal") {
        cmd.arg("--").arg("bash").arg("-c").arg(command);
    } else if terminal.contains("ptyxis") {
        // ptyxis (GNOME Terminal on Silverblue) uses -- for command separation
        cmd.arg("--").arg("bash").arg("-c").arg(command);
    } else if terminal.contains("konsole") {
        cmd.arg("-e").arg("bash").arg("-c").arg(command);
    } else {
        // Most terminals: -e command
        cmd.arg("-e").arg("bash").arg("-c").arg(command);
    }

    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());

    cmd.spawn()
        .map(|_| ())
        .map_err(|e| format!("{terminal}: {e}"))
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
