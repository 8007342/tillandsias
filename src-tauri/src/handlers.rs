//! Menu action handlers for tray events.
//!
//! Implements the "Attach Here", "Stop", and "Destroy" workflows that
//! bridge tray menu clicks to podman operations and state updates.

use std::path::{Path, PathBuf};
use std::time::Duration;

use tracing::{debug, info, warn, instrument};

use tillandsias_core::config::{cache_dir, data_dir, load_global_config, load_project_config, GlobalConfig};
use tillandsias_core::event::{AppEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_podman::launch::{allocate_port_range, ContainerLauncher};
use tillandsias_podman::PodmanClient;

const FORGE_IMAGE_TAG: &str = "tillandsias-forge:latest";

/// Open a terminal window running a command.
/// Uses the platform's default terminal — not a zoo of emulators.
fn open_terminal(command: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        // Try common Linux terminals in order of likelihood
        let terminals: &[(&str, &[&str])] = &[
            ("ptyxis", &["--", "bash", "-c"]),     // GNOME (Silverblue)
            ("gnome-terminal", &["--", "bash", "-c"]), // GNOME
            ("konsole", &["-e", "bash", "-c"]),     // KDE
            ("xterm", &["-e", "bash", "-c"]),       // Fallback
        ];

        for (term, args) in terminals {
            if std::process::Command::new("which")
                .arg(term)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
            {
                let mut cmd = std::process::Command::new(term);
                for arg in *args {
                    cmd.arg(arg);
                }
                cmd.arg(command);
                return cmd
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .map(|_| ())
                    .map_err(|e| format!("{term}: {e}"));
            }
        }

        Err("No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)".into())
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: osascript to open Terminal.app with a command
        std::process::Command::new("osascript")
            .args(["-e", &format!("tell app \"Terminal\" to do script \"{}\"", command)])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("osascript: {e}"))
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/c", "start", "cmd", "/k", command])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("cmd: {e}"))
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        Err("Unsupported platform for terminal launch".into())
    }
}

/// Resolve the project root directory (where scripts/build-image.sh lives).
///
/// Checks (in order):
/// 1. Two levels up from the executable (target/debug/ layout)
/// 2. Alongside the executable
/// 3. `~/.local/share/tillandsias/` (installed layout)
fn resolve_project_root() -> Option<PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            // target/debug/tillandsias-tray -> project root (two levels up)
            if let Some(root) = exe_dir.parent().and_then(|p| p.parent()) {
                if root.join("scripts").join("build-image.sh").exists() {
                    return Some(root.to_path_buf());
                }
            }
            // Alongside the binary
            if exe_dir.join("scripts").join("build-image.sh").exists() {
                return Some(exe_dir.to_path_buf());
            }
        }
    }

    // Installed data directory
    let data = data_dir();
    if data.join("scripts").join("build-image.sh").exists() {
        return Some(data);
    }

    None
}

/// Run `scripts/build-image.sh` to ensure the forge image is built and loaded.
///
/// The script handles staleness detection, nix build inside the builder
/// toolbox, podman load, and tagging. Returns Ok(()) if the image is
/// available afterward.
fn run_build_image_script(image_name: &str) -> Result<(), String> {
    let root = resolve_project_root()
        .ok_or("Cannot find project root (scripts/build-image.sh not found)")?;

    let script = root.join("scripts").join("build-image.sh");
    info!(script = %script.display(), image = image_name, "Running build-image.sh");

    let output = std::process::Command::new(&script)
        .arg(image_name)
        .current_dir(&root)
        .output()
        .map_err(|e| format!("Failed to run build-image.sh: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(format!(
            "build-image.sh failed (exit {}):\n{stdout}\n{stderr}",
            output.status.code().unwrap_or(-1)
        ));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    debug!(output = %stdout, "build-image.sh completed");
    Ok(())
}

/// Build `podman run` argument list.
/// From tray: detached (`-d`). From CLI: interactive (`-it`).
fn build_run_args(
    container_name: &str,
    image: &str,
    project_path: &Path,
    cache_dir: &Path,
    port_range: (u16, u16),
    detached: bool,
) -> Vec<String> {
    let mut args = Vec::new();

    if detached {
        // Tray mode: run in background, user manages via tray menu
        args.push("-d".to_string());
    } else {
        // CLI mode: interactive, user gets terminal directly
        args.push("-it".to_string());
    }
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
#[instrument(skip(state, allocator), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "attach"))]
pub async fn handle_attach_here(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
) -> Result<AppEvent, String> {
    let start = std::time::Instant::now();
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

    // If image doesn't exist, try building it via bundled build-image.sh
    let client = PodmanClient::new();

    if !client.image_exists(FORGE_IMAGE_TAG).await {
        info!(tag = FORGE_IMAGE_TAG, "Image not found, building...");
        let build_result = tokio::task::spawn_blocking(|| {
            run_build_image_script("forge")
        }).await;

        match build_result {
            Ok(Ok(())) => {
                // Verify the image actually exists now
                if !client.image_exists(FORGE_IMAGE_TAG).await {
                    state.running.retain(|c| c.name != container_name);
                    allocator.release(&project_name, genus);
                    return Err(format!(
                        "Image {} still not found after build-image.sh completed",
                        FORGE_IMAGE_TAG
                    ));
                }
                info!(tag = FORGE_IMAGE_TAG, "Image built successfully");
            }
            Ok(Err(e)) => {
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(format!(
                    "Failed to build image {}: {}",
                    FORGE_IMAGE_TAG, e
                ));
            }
            Err(e) => {
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(format!(
                    "Image build task panicked: {}",
                    e
                ));
            }
        }
    } else {
        info!(tag = FORGE_IMAGE_TAG, "Image ready");
    }

    // Ensure cache directories exist
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // Build the full `podman run -it --rm ...` command string.
    // We open a terminal window running this command — the terminal provides
    // the TTY, podman passes it to the container, opencode gets a real terminal.
    let run_args = build_run_args(
        &container_name,
        FORGE_IMAGE_TAG,
        &project_path,
        &cache,
        port_range,
        false, // interactive (-it), NOT detached
    );

    let mut podman_parts = vec!["podman".to_string(), "run".to_string()];
    podman_parts.extend(run_args);
    let podman_cmd = podman_parts.join(" ");

    // Open a terminal window running the podman command.
    // When the user exits OpenCode, the container dies (--rm), terminal closes.
    if let Err(e) = open_terminal(&podman_cmd) {
        state.running.retain(|c| c.name != container_name);
        allocator.release(&project_name, genus);
        return Err(format!("Failed to open terminal: {e}"));
    }

    info!(
        container = %container_name,
        genus = %genus.display_name(),
        port_range = ?port_range,
        "Terminal opened with OpenCode"
    );

    // Mark project as having an assigned genus
    if let Some(project) = state.projects.iter_mut().find(|p| p.path == project_path) {
        project.assigned_genus = Some(genus);
    }

    let elapsed = start.elapsed();
    info!(
        duration_secs = elapsed.as_secs_f64(),
        container = %container_name,
        "Attach Here completed"
    );

    Ok(AppEvent::ContainerStateChange {
        container_name: container_name.clone(),
        new_state: ContainerState::Creating,
    })
}

/// Handle the "Stop" action: graceful stop with SIGTERM -> 10s -> SIGKILL,
/// update icon to dried bloom during shutdown.
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "stop"))]
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
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "destroy"))]
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
