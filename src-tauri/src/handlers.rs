//! Menu action handlers for tray events.
//!
//! Implements the "Attach Here", "Stop", and "Destroy" workflows that
//! bridge tray menu clicks to podman operations and state updates.
//!
//! # Container Security Model (audited 2026-03-23)
//!
//! Every container launched by this module (Attach Here, Ground/Terminal,
//! GitHub Login) enforces the following non-negotiable security flags:
//!
//!   --cap-drop=ALL              Drop all Linux capabilities
//!   --security-opt=no-new-privileges  No privilege escalation (suid, etc.)
//!   --userns=keep-id            Map host UID into container (no root)
//!   --security-opt=label=disable  Disable SELinux relabeling (needed for
//!                                 bind mounts on Silverblue)
//!   --rm                        Ephemeral: container removed on exit
//!
//! Volume mounts are limited to:
//!   1. Project directory (rw) -- user's own files, mounted at /home/forge/src/<name>
//!   2. Cache directory (rw)   -- ~/.cache/tillandsias for tool persistence
//!   3. Secrets directory (rw) -- gh credentials + .gitconfig only
//!
//! NOT mounted (by design):
//!   - Host root filesystem or /
//!   - Other user projects (only the selected project)
//!   - System directories (/etc, /var, /usr)
//!   - Docker/Podman socket (no container-in-container)

use std::path::{Path, PathBuf};
use std::time::Duration;

use tracing::{debug, info, instrument, warn};

use tillandsias_core::config::{GlobalConfig, cache_dir, load_global_config, load_project_config};
use tillandsias_core::event::{AppEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_podman::PodmanClient;
use tillandsias_podman::launch::{ContainerLauncher, allocate_port_range};
use tillandsias_podman::query_occupied_ports;

pub(crate) const FORGE_IMAGE_TAG: &str = "tillandsias-forge:latest";

/// Detect the host operating system by reading `/etc/os-release`.
/// Returns a human-readable string like "Fedora Silverblue 43".
fn detect_host_os() -> String {
    if let Ok(content) = std::fs::read_to_string("/etc/os-release") {
        let mut name = String::new();
        let mut version = String::new();
        let mut variant = String::new();
        for line in content.lines() {
            if let Some(val) = line.strip_prefix("NAME=") {
                name = val.trim_matches('"').to_string();
            } else if let Some(val) = line.strip_prefix("VERSION_ID=") {
                version = val.trim_matches('"').to_string();
            } else if let Some(val) = line.strip_prefix("VARIANT=") {
                variant = val.trim_matches('"').to_string();
            }
        }
        if !variant.is_empty() {
            format!("{name} {variant} {version}")
        } else {
            format!("{name} {version}")
        }
    } else {
        "Unknown OS".to_string()
    }
}

/// Open a terminal window running a command.
/// Uses the platform's default terminal — not a zoo of emulators.
///
/// On GNOME (ptyxis), launches a standalone instance so the tray app
/// doesn't depend on an existing terminal window. The command runs
/// directly (not wrapped in `bash -c`) so interactive TTY works.
fn open_terminal(command: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        // Try common Linux terminals in order of likelihood.
        // Each entry: (binary, args-before-command, uses-exec-flag).
        // ptyxis -s: standalone instance (doesn't reuse existing window).
        // ptyxis -x: execute command directly (not via bash -c wrapper).
        let terminals: &[(&str, &[&str])] = &[
            ("ptyxis", &["--new-window", "-x"]), // GNOME (Silverblue) — new window + execute
            ("gnome-terminal", &["--", "bash", "-c"]), // GNOME
            ("konsole", &["-e", "bash", "-c"]),  // KDE
            ("xterm", &["-e", "bash", "-c"]),    // Fallback
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
                return cmd.spawn().map(|_| ()).map_err(|e| format!("{term}: {e}"));
            }
        }

        Err("No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)".into())
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: osascript to open Terminal.app with a command
        std::process::Command::new("osascript")
            .args([
                "-e",
                &format!("tell app \"Terminal\" to do script \"{}\"", command),
            ])
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

/// Run `build-image.sh` from the embedded binary scripts.
///
/// Extracts image sources + build scripts to temp, executes, cleans up.
/// No filesystem scripts are trusted — everything comes from the signed binary.
fn run_build_image_script(image_name: &str) -> Result<(), String> {
    // Check if another process is already building this image
    if crate::build_lock::is_running(image_name) {
        info!(image = image_name, "Build already in progress, waiting...");
        crate::build_lock::wait_for_build(image_name)?;
        return Ok(());
    }

    // Acquire build lock
    crate::build_lock::acquire(image_name)
        .map_err(|e| format!("Cannot acquire build lock: {e}"))?;

    let source_dir = crate::embedded::write_image_sources()
        .map_err(|e| format!("Failed to extract image sources: {e}"))?;

    let script = source_dir.join("scripts").join("build-image.sh");
    info!(script = %script.display(), image = image_name, "Running embedded build-image.sh");

    let output = std::process::Command::new(&script)
        .arg(image_name)
        .current_dir(&source_dir)
        .output()
        .map_err(|e| format!("Failed to run build-image.sh: {e}"))?;

    // Clean up temp files and release lock regardless of result
    crate::embedded::cleanup_image_sources();
    crate::build_lock::release(image_name);

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

    // Signal handling: --init provides a proper init process (tini) that
    // forwards signals and reaps zombies. When a terminal is closed,
    // SIGHUP → init → SIGTERM to all children → clean shutdown.
    args.push("--init".to_string());
    args.push("--stop-timeout=10".to_string());

    // Port range mapping
    let port_mapping = format!(
        "{}-{}:{}-{}",
        port_range.0, port_range.1, port_range.0, port_range.1
    );
    args.push("-p".to_string());
    args.push(port_mapping);

    // Volume mounts
    // Project directory -> container workspace at src/<project-name>/
    // Preserves hierarchy so OpenCode shows src/<project>:main
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());
    let project_mount = format!(
        "{}:/home/forge/src/{}",
        project_path.display(),
        project_name
    );
    args.push("-v".to_string());
    args.push(project_mount);

    // Cache directory -> container cache
    let cache_mount = format!("{}:/home/forge/.cache/tillandsias", cache_dir.display());
    args.push("-v".to_string());
    args.push(cache_mount);

    // Secrets directory — git config, gh auth, ssh keys
    let secrets_dir = cache_dir.join("secrets");
    std::fs::create_dir_all(secrets_dir.join("gh")).ok();
    let git_dir = secrets_dir.join("git");
    std::fs::create_dir_all(&git_dir).ok();
    // Ensure .gitconfig FILE exists inside the git dir
    let gitconfig_path = git_dir.join(".gitconfig");
    if !gitconfig_path.exists() {
        std::fs::File::create(&gitconfig_path).ok();
    }

    // GitHub CLI credentials (read-only — containers shouldn't modify auth state)
    let gh_mount = format!(
        "{}:/home/forge/.config/gh:ro",
        secrets_dir.join("gh").display()
    );
    args.push("-v".to_string());
    args.push(gh_mount);

    // Git config — mount directory read-only. Tell git via GIT_CONFIG_GLOBAL.
    let git_mount = format!(
        "{}:/home/forge/.config/tillandsias-git:ro",
        git_dir.display()
    );
    args.push("-v".to_string());
    args.push(git_mount);
    args.push("-e".to_string());
    args.push("GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig".to_string());

    // Container image (always last)
    args.push(image.to_string());

    args
}

/// Remove orphaned tillandsias containers not tracked in state.
///
/// Queries podman for all containers matching `tillandsias-*`, then removes
/// any that are not present in our in-memory state. Skips infrastructure
/// toolboxes (builder, windows, etc.).
async fn cleanup_stale_containers(state: &TrayState) {
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "ps",
            "-a",
            "--filter",
            "name=tillandsias-",
            "--format",
            "{{.Names}}",
        ])
        .output();

    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let known_names: Vec<&str> = state.running.iter().map(|c| c.name.as_str()).collect();

        for name in stdout.lines() {
            let name = name.trim();
            if name.is_empty() {
                continue;
            }
            if name.ends_with("-builder") || name.ends_with("-windows") {
                continue;
            }
            if known_names.contains(&name) {
                continue;
            }

            warn!(container = %name, "Removing stale container");
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rm", "-f", name])
                .output();
        }
    }
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

    // Clean up orphaned containers before allocating resources
    cleanup_stale_containers(state).await;

    // Allocate a genus
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    debug!(project = %project_name, genus = %genus.display_name(), "Genus allocated");

    // Load and merge configuration
    let global_config = load_global_config();
    let project_config = load_project_config(&project_path);
    let _resolved = global_config.merge_with_project(&project_config);

    // Allocate port range — merge in-memory state with actual podman containers
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let base_port = GlobalConfig::parse_port_range(&_resolved.port_range).unwrap_or((3000, 3019));
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
        let build_result = tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

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
                return Err(format!("Failed to build image {}: {}", FORGE_IMAGE_TAG, e));
            }
            Err(e) => {
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(format!("Image build task panicked: {}", e));
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

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
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
        if !still_running
            && let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
        {
            project.assigned_genus = None;
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
        if !still_running
            && let Some(project) = state
                .projects
                .iter_mut()
                .find(|p| p.name == container.project_name)
        {
            project.assigned_genus = None;
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
            Err(e) => {
                warn!(container = %container.name, error = %e, "Failed to stop container on shutdown")
            }
        }
    }

    info!("All containers stopped, shutdown complete");
}

/// Handle "Terminal" — open bash in a forge container for the project.
pub async fn handle_terminal(project_path: PathBuf, _state: &TrayState) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    info!(project = %project_name, "Opening terminal");

    let client = PodmanClient::new();
    if !client.image_exists(FORGE_IMAGE_TAG).await {
        return Err("Forge image not found. Run ./build.sh --install first.".into());
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();
    let secrets_dir = cache.join("secrets");
    std::fs::create_dir_all(secrets_dir.join("gh")).ok();
    std::fs::create_dir_all(secrets_dir.join("git")).ok();
    let gitconfig_path = secrets_dir.join("git").join(".gitconfig");
    if !gitconfig_path.exists() {
        std::fs::File::create(&gitconfig_path).ok();
    }

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = _state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    let container_name = format!("tillandsias-{}-terminal", project_name);

    let git_dir = secrets_dir.join("git");
    let host_os = detect_host_os();
    let podman_bin = tillandsias_podman::find_podman_path();
    let podman_cmd = format!(
        "{podman_bin} run -it --rm --init --stop-timeout=10 \
        --name {} \
        --security-opt=label=disable \
        --userns=keep-id \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --entrypoint fish \
        -w /home/forge/src/{} \
        -e TILLANDSIAS_PROJECT={} \
        -e TILLANDSIAS_HOST_OS='{}' \
        -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
        -p {}-{}:{}-{} \
        -v {}:/home/forge/src/{} \
        -v {}:/home/forge/.cache/tillandsias \
        -v {}:/home/forge/.config/gh:ro \
        -v {}:/home/forge/.config/tillandsias-git:ro \
        {}",
        container_name,
        project_name,
        project_name,
        host_os,
        port_range.0,
        port_range.1,
        port_range.0,
        port_range.1,
        project_path.display(),
        project_name,
        cache.display(),
        secrets_dir.join("gh").display(),
        git_dir.display(),
        FORGE_IMAGE_TAG,
    );

    open_terminal(&podman_cmd).map_err(|e| format!("Failed to open terminal: {e}"))
}

/// Handle "GitHub Login" — extract embedded gh-auth-login.sh to temp and run it.
/// No filesystem scripts are trusted — everything comes from the signed binary.
pub async fn handle_github_login(_state: &TrayState) -> Result<(), String> {
    info!("GitHub Login: extracting embedded script to temp");

    let script_path =
        crate::embedded::write_temp_script("gh-auth-login.sh", crate::embedded::GH_AUTH_LOGIN)
            .map_err(|e| format!("Failed to extract gh-auth-login.sh: {e}"))?;

    open_terminal(&script_path.display().to_string())
        .map_err(|e| format!("Failed to open terminal: {e}"))
}
