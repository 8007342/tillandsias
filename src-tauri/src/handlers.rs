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
//!   3. Secrets directory (rw) -- gh credentials (refreshed from OS keyring) + .gitconfig only
//!
//! NOT mounted (by design):
//!   - Host root filesystem or /
//!   - Other user projects (only the selected project)
//!   - System directories (/etc, /var, /usr)
//!   - Docker/Podman socket (no container-in-container)

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::sync::mpsc;
use tracing::{debug, error, info, instrument, warn};

use tillandsias_core::config::{GlobalConfig, cache_dir, load_global_config, load_project_config};
use tillandsias_core::event::{AppEvent, BuildProgressEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_core::tools::ToolAllocator;
use tillandsias_podman::PodmanClient;
use tillandsias_podman::launch::{ContainerLauncher, allocate_port_range};
use tillandsias_podman::query_occupied_ports;

/// Derive the forge image tag from the app's semver version.
///
/// At compile time `CARGO_PKG_VERSION` is the 3-part semver from Cargo.toml
/// (e.g., "0.1.72"). The returned tag is `tillandsias-forge:v0.1.72`.
///
/// This ensures each app version uses its own image — when the app updates
/// to a new version the old image is not silently reused.
pub(crate) fn forge_image_tag() -> String {
    format!("tillandsias-forge:v{}", env!("CARGO_PKG_VERSION"))
}

/// Check whether ANY versioned forge image (`tillandsias-forge:v*`) exists.
///
/// Used to distinguish "first time" builds (no previous image) from "update"
/// builds (upgrading from an older version).
pub(crate) fn any_versioned_forge_exists() -> bool {
    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=tillandsias-forge:v*",
        ])
        .output();

    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout.lines().any(|line| {
                let trimmed = line.trim();
                !trimmed.is_empty() && trimmed.starts_with("tillandsias-forge:v")
            })
        }
        Err(_) => false,
    }
}

/// Remove older `tillandsias-forge:v*` images, keeping only `current_tag`.
///
/// Best-effort — failures are logged but do not block operation.
pub(crate) fn prune_old_forge_images(current_tag: &str) {
    let output = tillandsias_podman::podman_cmd_sync()
        .args(["images", "--format", "{{.Repository}}:{{.Tag}}"])
        .output();

    let images_to_remove: Vec<String> = match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout
                .lines()
                .filter(|line| {
                    let trimmed = line.trim();
                    trimmed.starts_with("tillandsias-forge:v") && trimmed != current_tag
                })
                .map(|s| s.trim().to_string())
                .collect()
        }
        Err(e) => {
            warn!(error = %e, "Failed to list images for pruning");
            return;
        }
    };

    for image in &images_to_remove {
        info!(image = %image, "Pruning old forge image");
        let result = tillandsias_podman::podman_cmd_sync()
            .args(["rmi", image])
            .output();
        match result {
            Ok(o) if o.status.success() => {
                info!(image = %image, "Pruned old forge image");
            }
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                warn!(image = %image, stderr = %stderr, "Failed to prune old forge image");
            }
            Err(e) => {
                warn!(image = %image, error = %e, "Failed to prune old forge image");
            }
        }
    }
}

/// Open a terminal window running a command with a custom title.
/// Uses the platform's default terminal — not a zoo of emulators.
///
/// On GNOME (ptyxis), launches a standalone instance so the tray app
/// doesn't depend on an existing terminal window. The command runs
/// directly (not wrapped in `bash -c`) so interactive TTY works.
fn open_terminal(command: &str, title: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        // Try common Linux terminals in order of likelihood.
        // Each entry: (binary, title-args, command-args).
        // ptyxis -s: standalone instance (doesn't reuse existing window).
        // ptyxis -x: execute command directly (not via bash -c wrapper).
        //
        // Title is passed before the command execution flags so each
        // terminal window carries a meaningful name matching the tray label.

        // Check which terminal is available
        let terminal_names = ["ptyxis", "gnome-terminal", "konsole", "xterm"];
        let found_term = terminal_names.iter().find(|&&term| {
            std::process::Command::new("which")
                .arg(term)
                .env_remove("LD_LIBRARY_PATH")
                .env_remove("LD_PRELOAD")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        });

        match found_term {
            Some(&"ptyxis") => {
                // ptyxis: -T <title> -s --new-window -x <command>
                // -s = standalone process (no D-Bus handoff to existing instance)
                // --new-window = own window (not a tab in someone else's window)
                // -x = execute command directly
                // All three flags together ensure each terminal launch is fully independent.
                let mut cmd = std::process::Command::new("ptyxis");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-T", title, "-s", "--new-window", "-x", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("ptyxis: {e}"))
            }
            Some(&"gnome-terminal") => {
                let mut cmd = std::process::Command::new("gnome-terminal");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["--title", title, "--", "bash", "-c", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("gnome-terminal: {e}"))
            }
            Some(&"konsole") => {
                let mut cmd = std::process::Command::new("konsole");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-p", &format!("tabtitle={title}"), "-e", "bash", "-c", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("konsole: {e}"))
            }
            Some(&"xterm") => {
                let mut cmd = std::process::Command::new("xterm");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-T", title, "-e", "bash", "-c", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("xterm: {e}"))
            }
            _ => {
                Err("No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)".into())
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: osascript to open Terminal.app with a command.
        // Escape backslashes and quotes to prevent AppleScript injection
        // via crafted directory names.
        // Title is embedded via a `set custom title` call — best-effort.
        let escaped_cmd = command.replace('\\', "\\\\").replace('"', "\\\"");
        let escaped_title = title.replace('\\', "\\\\").replace('"', "\\\"");
        std::process::Command::new("osascript")
            .args([
                "-e",
                &format!(
                    "tell app \"Terminal\" to do script \"{escaped_cmd}\"\n\
                     tell app \"Terminal\" to set custom title of front window to \"{escaped_title}\""
                ),
            ])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("osascript: {e}"))
    }

    #[cfg(target_os = "windows")]
    {
        // Windows: `start "<title>" cmd /k <command>`
        // The first positional argument to `start` is the window title.
        std::process::Command::new("cmd")
            .args(["/c", "start", title, "cmd", "/k", command])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("cmd: {e}"))
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        Err("Unsupported platform for terminal launch".into())
    }
}

/// Send a desktop notification (best-effort, non-blocking).
///
/// Uses `notify-send` on Linux, `osascript` on macOS.
/// Silently ignored on failure — notifications are advisory only.
fn send_notification(summary: &str, body: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("notify-send")
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .args([summary, body])
            .spawn();
    }

    #[cfg(target_os = "macos")]
    {
        let escaped_summary = summary.replace('"', "\\\"");
        let escaped_body = body.replace('"', "\\\"");
        let script = format!(
            "display notification \"{escaped_body}\" with title \"{escaped_summary}\""
        );
        let _ = std::process::Command::new("osascript")
            .args(["-e", &script])
            .spawn();
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // Windows and other platforms: no-op
        let _ = (summary, body);
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
        .map_err(|e| {
            error!(image = image_name, error = %e, "Cannot acquire build lock");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    let source_dir = crate::embedded::write_image_sources()
        .map_err(|e| {
            error!(image = image_name, error = %e, "Failed to extract embedded image sources to temp");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = forge_image_tag();
    info!(script = %script.display(), image = image_name, tag = %tag, "Running embedded build-image.sh");

    let output = std::process::Command::new(&script)
        .arg(image_name)
        .args(["--tag", &tag])
        .current_dir(&source_dir)
        // Clear AppImage library paths so toolbox, nix, and other host
        // binaries called by build-image.sh use host libraries.
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output()
        .map_err(|e| {
            error!(script = %script.display(), image = image_name, error = %e, "Failed to launch image build script");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    // Clean up temp files and release lock regardless of result
    crate::embedded::cleanup_image_sources();
    crate::build_lock::release(image_name);

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        error!(
            image = image_name,
            exit_code = output.status.code().unwrap_or(-1),
            stdout = %stdout,
            stderr = %stderr,
            "Image build script failed"
        );
        return Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    debug!(output = %stdout, "build-image.sh completed");

    // Prune older versioned forge images to reclaim disk space
    prune_old_forge_images(&tag);

    Ok(())
}

/// Public wrapper around `run_build_image_script` for use from `main.rs`
/// launch-time forge auto-build.
pub fn run_build_image_script_pub(image_name: &str) -> Result<(), String> {
    run_build_image_script(image_name)
}

/// Build `podman run` argument list.
/// From tray: detached (`-d`). From CLI: interactive (`-it`).
///
/// When `is_watch_root` is true, the project path is the watch root itself
/// (e.g., `~/src/`) and is mounted directly at `/home/forge/src/` instead of
/// being nested as `/home/forge/src/<name>/`.
fn build_run_args(
    container_name: &str,
    image: &str,
    project_path: &Path,
    cache_dir: &Path,
    port_range: (u16, u16),
    detached: bool,
    is_watch_root: bool,
    agent: tillandsias_core::config::SelectedAgent,
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

    // GPU passthrough (Linux only)
    if cfg!(target_os = "linux") {
        for flag in tillandsias_podman::detect_gpu_devices() {
            args.push(flag);
        }
    }

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
    //
    // Watch-root case: mount the entire watch path at /home/forge/src/ directly
    // so all project subdirectories appear as /home/forge/src/<project>/.
    let project_mount = if is_watch_root {
        format!("{}:/home/forge/src", project_path.display())
    } else {
        let project_name = project_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "project".to_string());
        format!(
            "{}:/home/forge/src/{}",
            project_path.display(),
            project_name
        )
    };
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

    // Agent selection — tells the entrypoint which coding agent to launch
    args.push("-e".to_string());
    args.push(format!("TILLANDSIAS_AGENT={}", agent.as_env_str()));

    // Claude API key — injected from OS keyring when present
    if let Ok(Some(api_key)) = crate::secrets::retrieve_claude_api_key() {
        args.push("-e".to_string());
        args.push(format!("ANTHROPIC_API_KEY={api_key}"));
    }

    // Claude Code credentials — persists auth across container restarts
    let claude_dir = secrets_dir.join("claude");
    std::fs::create_dir_all(&claude_dir).ok();
    let claude_mount = format!("{}:/home/forge/.claude:rw", claude_dir.display());
    args.push("-v".to_string());
    args.push(claude_mount);

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
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "attach"))]
pub async fn handle_attach_here(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<AppEvent, String> {
    let start = std::time::Instant::now();
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    info!(project = %project_name, "Attach Here requested");

    // Don't-relaunch guard: if a container for this project is already running,
    // notify the user and return early instead of spawning a second environment.
    if let Some(existing) = state
        .running
        .iter()
        .find(|c| c.project_name == project_name)
    {
        let flower = existing.genus.flower();
        let title = format!("{flower} {project_name}");
        let msg = format!("Already running — look for '{title}' in your windows");
        info!(project = %project_name, "Don't-relaunch guard fired — environment already running");
        send_notification("Tillandsias", &msg);
        return Err(format!(
            "Environment for '{project_name}' is already running as '{title}'"
        ));
    }

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
    let display_emoji = genus.flower().to_string();
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Forge,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    info!(container = %container_name, "Preparing environment... (bud state)");

    // If image doesn't exist, try building it via bundled build-image.sh
    let client = PodmanClient::new();
    let tag = forge_image_tag();

    if !client.image_exists(&tag).await {
        info!(tag = %tag, "Image not found, building...");

        // Notify event loop: build started (menu chip: ⏳ Building forge...)
        let _ = build_tx.try_send(BuildProgressEvent::Started {
            image_name: "forge".to_string(),
        });

        let build_result = tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                // Verify the image actually exists now
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build completed");
                    let _ = build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: "forge".to_string(),
                        reason: "Development environment not ready yet".to_string(),
                    });
                    state.running.retain(|c| c.name != container_name);
                    allocator.release(&project_name, genus);
                    return Err(
                        "Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes.".into()
                    );
                }
                info!(tag = %tag, "Image built successfully");
                // Notify event loop: build completed (menu chip: ✅ forge ready)
                let _ = build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: "forge".to_string(),
                });
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into());
            }
        }
    } else {
        info!(tag = %tag, "Image ready");
    }

    // Ensure cache directories exist
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // Refresh hosts.yml from native keyring so the container gets
    // a current GitHub token without plain text lingering on disk.
    crate::secrets::write_hosts_yml_from_keyring();

    // Detect whether the project path IS the watch root (e.g., ~/src/) rather
    // than a project inside it. When true, mount at /home/forge/src/ directly
    // instead of nesting as /home/forge/src/src/.
    let is_watch_root = global_config
        .scanner
        .watch_paths
        .iter()
        .any(|wp| wp == &project_path);

    // Build the full `podman run -it --rm ...` command string.
    // We open a terminal window running this command — the terminal provides
    // the TTY, podman passes it to the container, opencode gets a real terminal.
    let selected_agent = global_config.agent.selected;
    let run_args = build_run_args(
        &container_name,
        &tag,
        &project_path,
        &cache,
        port_range,
        false, // interactive (-it), NOT detached
        is_watch_root,
        selected_agent,
    );

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = podman_parts.join(" ");

    // Build window title: "<flower> <project_name>" — matches the tray menu label.
    let title = format!("{} {}", display_emoji, project_name);

    // Open a terminal window running the podman command.
    // When the user exits OpenCode, the container dies (--rm), terminal closes.
    if let Err(e) = open_terminal(&podman_cmd, &title) {
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

/// Handle "Maintenance" — open fish/bash in a forge container for the project.
///
/// Each maintenance terminal gets its own genus-named container, following the
/// same naming convention as forge containers (`tillandsias-{project}-{genus}`).
/// Multiple maintenance terminals per project are allowed — each allocates a
/// unique genus from the pool.
pub async fn handle_terminal(
    project_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    tool_allocator: &mut ToolAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    info!(project = %project_name, "Opening maintenance terminal");

    // Allocate a genus — each maintenance terminal gets its own unique name
    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| format!("All genera exhausted for project {project_name}"))?;

    // Allocate a tool emoji for this maintenance terminal
    let display_emoji = tool_allocator
        .allocate(&project_name)
        .unwrap_or(tillandsias_core::tools::TOOL_EMOJIS[0])
        .to_string();

    debug!(project = %project_name, genus = %genus.display_name(), tool = %display_emoji, "Genus and tool allocated for maintenance terminal");

    let client = PodmanClient::new();
    let tag = forge_image_tag();
    if !client.image_exists(&tag).await {
        error!(tag = %tag, "Image not found when opening maintenance terminal");
        allocator.release(&project_name, genus);
        tool_allocator.release(&project_name, &display_emoji);
        return Err("Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes.".into());
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

    // Refresh hosts.yml from native keyring before terminal launch.
    crate::secrets::write_hosts_yml_from_keyring();

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    // Use genus-based container name (same convention as forge containers)
    let container_name = ContainerInfo::container_name(&project_name, genus);

    // Pre-register container in state so the tray shows it immediately
    let placeholder = ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Maintenance,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    info!(container = %container_name, tool = %display_emoji, "Maintenance terminal registered (bud state)");

    let git_dir = secrets_dir.join("git");
    let claude_dir = secrets_dir.join("claude");
    std::fs::create_dir_all(&claude_dir).ok();
    let host_os = tillandsias_core::config::detect_host_os();
    let selected_agent = load_global_config().agent.selected;
    let podman_bin = tillandsias_podman::find_podman_path();

    // Claude API key — injected from OS keyring when present
    let claude_api_key_arg = match crate::secrets::retrieve_claude_api_key() {
        Ok(Some(key)) => format!("-e ANTHROPIC_API_KEY={key} "),
        _ => String::new(),
    };

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
        -e TILLANDSIAS_AGENT={} \
        {}\
        -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
        -p {}-{}:{}-{} \
        -v {}:/home/forge/src/{} \
        -v {}:/home/forge/.cache/tillandsias \
        -v {}:/home/forge/.config/gh:ro \
        -v {}:/home/forge/.config/tillandsias-git:ro \
        -v {}:/home/forge/.claude:rw \
        {}",
        container_name,
        project_name,
        project_name,
        host_os,
        selected_agent.as_env_str(),
        claude_api_key_arg,
        port_range.0,
        port_range.1,
        port_range.0,
        port_range.1,
        project_path.display(),
        project_name,
        cache.display(),
        secrets_dir.join("gh").display(),
        git_dir.display(),
        claude_dir.display(),
        tag,
    );

    // Window title uses the allocated tool emoji — unique per terminal
    let title = format!("{} {}", display_emoji, project_name);

    // Notify event loop: maintenance setup in progress (menu chip: ⛏️ Setting up Maintenance...)
    let _ = build_tx.try_send(BuildProgressEvent::Started {
        image_name: "Maintenance".to_string(),
    });

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            // Terminal launched — notify completed so chip shows briefly
            let _ = build_tx.try_send(BuildProgressEvent::Completed {
                image_name: "Maintenance".to_string(),
            });
            info!(
                container = %container_name,
                genus = %genus.display_name(),
                port_range = ?port_range,
                "Maintenance terminal opened"
            );
            Ok(())
        }
        Err(e) => {
            // Clean up: remove from state and release genus + tool
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            tool_allocator.release(&project_name, &display_emoji);
            let _ = build_tx.try_send(BuildProgressEvent::Failed {
                image_name: "Maintenance".to_string(),
                reason: e.clone(),
            });
            Err(format!("Failed to open terminal: {e}"))
        }
    }
}

/// Handle the global "🛠️ Root" terminal — open fish at the src/ root directory.
///
/// Identical lifecycle to `handle_terminal` but scoped to the entire `~/src/`
/// watch path rather than a single project sub-directory.
///
/// - Container name: `tillandsias-src-<genus>` (project_name = "src")
/// - Working directory inside container: `/home/forge/src`
/// - Volume mount: `<watch_path>:/home/forge/src` (entire src tree, rw)
/// - Window title: `🛠️ Root`
/// - The `🛠️` emoji is reserved for this item and is absent from `TOOL_EMOJIS`.
pub async fn handle_root_terminal(
    watch_path: PathBuf,
    state: &mut TrayState,
    allocator: &mut GenusAllocator,
    _tool_allocator: &mut ToolAllocator,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    // Use a fixed project name for the root terminal so the container name is
    // stable and recognisable: tillandsias-src-<genus>
    let project_name = "src".to_string();

    info!("Opening root terminal at src/");

    let genus = allocator
        .allocate(&project_name)
        .ok_or_else(|| "All genera exhausted for root terminal".to_string())?;

    // Reserve the 🛠️ emoji as the display emoji — it is NOT drawn from the pool.
    let display_emoji = "\u{1F6E0}\u{FE0F}".to_string();

    debug!(genus = %genus.display_name(), "Genus allocated for root terminal");

    let client = PodmanClient::new();
    let tag = forge_image_tag();
    if !client.image_exists(&tag).await {
        error!(tag = %tag, "Image not found when opening root terminal");
        allocator.release(&project_name, genus);
        return Err("Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes.".into());
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

    // Refresh hosts.yml from native keyring before terminal launch.
    crate::secrets::write_hosts_yml_from_keyring();

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    let container_name = tillandsias_core::state::ContainerInfo::container_name(&project_name, genus);

    // Pre-register container in state so the tray shows it immediately
    let placeholder = tillandsias_core::state::ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus,
        state: tillandsias_core::event::ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Maintenance,
        display_emoji: display_emoji.clone(),
    };
    state.running.push(placeholder);
    info!(container = %container_name, "Root terminal registered (bud state)");

    let git_dir = secrets_dir.join("git");
    let claude_dir = secrets_dir.join("claude");
    std::fs::create_dir_all(&claude_dir).ok();
    let host_os = tillandsias_core::config::detect_host_os();
    let selected_agent = load_global_config().agent.selected;
    let podman_bin = tillandsias_podman::find_podman_path();

    // Claude API key — injected from OS keyring when present
    let claude_api_key_arg = match crate::secrets::retrieve_claude_api_key() {
        Ok(Some(key)) => format!("-e ANTHROPIC_API_KEY={key} "),
        _ => String::new(),
    };

    let podman_cmd = format!(
        "{podman_bin} run -it --rm --init --stop-timeout=10 \
        --name {} \
        --security-opt=label=disable \
        --userns=keep-id \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --entrypoint fish \
        -w /home/forge/src \
        -e TILLANDSIAS_PROJECT='(all projects)' \
        -e TILLANDSIAS_HOST_OS='{}' \
        -e TILLANDSIAS_AGENT={} \
        {}\
        -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
        -p {}-{}:{}-{} \
        -v {}:/home/forge/src \
        -v {}:/home/forge/.cache/tillandsias \
        -v {}:/home/forge/.config/gh:ro \
        -v {}:/home/forge/.config/tillandsias-git:ro \
        -v {}:/home/forge/.claude:rw \
        {}",
        container_name,
        host_os,
        selected_agent.as_env_str(),
        claude_api_key_arg,
        port_range.0,
        port_range.1,
        port_range.0,
        port_range.1,
        watch_path.display(),
        cache.display(),
        secrets_dir.join("gh").display(),
        git_dir.display(),
        claude_dir.display(),
        tag,
    );

    let title = "\u{1F6E0}\u{FE0F} Root".to_string();

    // Notify event loop: maintenance setup in progress
    let _ = build_tx.try_send(BuildProgressEvent::Started {
        image_name: "Maintenance".to_string(),
    });

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            let _ = build_tx.try_send(BuildProgressEvent::Completed {
                image_name: "Maintenance".to_string(),
            });
            info!(
                container = %container_name,
                genus = %genus.display_name(),
                port_range = ?port_range,
                "Root terminal opened"
            );
            Ok(())
        }
        Err(e) => {
            state.running.retain(|c| c.name != container_name);
            allocator.release(&project_name, genus);
            let _ = build_tx.try_send(BuildProgressEvent::Failed {
                image_name: "Maintenance".to_string(),
                reason: e.clone(),
            });
            Err(format!("Failed to open root terminal: {e}"))
        }
    }
}

/// Handle "GitHub Login" — build forge image if missing, then run gh-auth-login.sh.
///
/// On first launch the forge image does not exist yet. Rather than failing with
/// "Cannot find build-image.sh", this handler builds the image first (same
/// pipeline as Attach Here) and shows a progress chip in the tray while it
/// waits. Only after the image is confirmed present does it open the terminal.
///
/// No filesystem scripts are trusted — everything comes from the signed binary.
pub async fn handle_github_login(
    _state: &TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    info!("GitHub Login: checking forge image");

    let client = PodmanClient::new();
    let tag = forge_image_tag();

    if !client.image_exists(&tag).await {
        info!(tag = %tag, "Forge image missing — building before GitHub Login");

        // Show "Building environment..." chip in tray menu
        let _ = build_tx.try_send(BuildProgressEvent::Started {
            image_name: "forge".to_string(),
        });

        let build_result = tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

        match build_result {
            Ok(Ok(())) => {
                // Verify the image actually exists now
                if !client.image_exists(&tag).await {
                    error!(tag = %tag, "Image still not found after build completed (GitHub Login)");
                    let _ = build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: "forge".to_string(),
                        reason: "Development environment not ready yet".to_string(),
                    });
                    return Err("Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes.".into());
                }
                info!(
                    tag = %tag,
                    "Image built successfully — proceeding with GitHub Login"
                );
                let _ = build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: "forge".to_string(),
                });
            }
            Ok(Err(ref e)) => {
                error!(tag = %tag, error = %e, "Image build failed (GitHub Login)");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                return Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked (GitHub Login)");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                return Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into());
            }
        }
    } else {
        info!(
            tag = %tag,
            "Forge image present — proceeding with GitHub Login"
        );
    }

    info!("GitHub Login: extracting embedded script to temp");

    let script_path =
        crate::embedded::write_temp_script("gh-auth-login.sh", crate::embedded::GH_AUTH_LOGIN)
            .map_err(|e| {
                error!(error = %e, "Failed to extract embedded gh-auth-login.sh to temp");
                "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias"
            })?;

    open_terminal(&script_path.display().to_string(), "GitHub Login")
        .map_err(|e| format!("Failed to open terminal: {e}"))
}

/// Handle "Claude Login" — prompt user for Anthropic API key and store in keyring.
///
/// Opens a terminal running a small embedded script that reads the key
/// interactively (hidden input) and writes it to a temp file. We then
/// poll for the temp file, read the key, store it in the native keyring,
/// and delete the temp file.
pub async fn handle_claude_login() -> Result<(), String> {
    info!("Claude Login: extracting embedded script to temp");

    let script_path = crate::embedded::write_temp_script(
        "claude-api-key-prompt.sh",
        crate::embedded::CLAUDE_API_KEY_PROMPT,
    )
    .map_err(|e| {
        error!(error = %e, "Failed to extract embedded claude-api-key-prompt.sh to temp");
        "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias"
    })?;

    open_terminal(&script_path.display().to_string(), "Claude Login")?;

    // Poll for the temp file containing the API key.
    // The script writes to $XDG_RUNTIME_DIR/tillandsias-claude-key (or /tmp/).
    let temp_key_path = std::env::var("XDG_RUNTIME_DIR")
        .map(|d| std::path::PathBuf::from(d).join("tillandsias-claude-key"))
        .unwrap_or_else(|_| std::path::PathBuf::from("/tmp/tillandsias-claude-key"));

    // Wait up to 5 minutes for the user to enter the key.
    // Check every 2 seconds. The file only appears after they press Enter.
    let max_attempts = 150; // 150 * 2s = 300s = 5 min
    for _ in 0..max_attempts {
        tokio::time::sleep(Duration::from_secs(2)).await;

        if temp_key_path.exists() {
            match std::fs::read_to_string(&temp_key_path) {
                Ok(key) => {
                    let key = key.trim().to_string();

                    // Clean up temp file immediately
                    let _ = std::fs::remove_file(&temp_key_path);

                    if key.is_empty() {
                        info!("Claude Login: user entered empty key, skipping");
                        return Ok(());
                    }

                    // Store in keyring
                    match crate::secrets::store_claude_api_key(&key) {
                        Ok(()) => {
                            info!("Claude API key stored in native keyring");
                            send_notification(
                                "Tillandsias",
                                "Claude API key saved successfully",
                            );
                            return Ok(());
                        }
                        Err(e) => {
                            error!(error = %e, "Failed to store Claude API key in keyring");
                            return Err(format!("Failed to save API key: {e}"));
                        }
                    }
                }
                Err(e) => {
                    let _ = std::fs::remove_file(&temp_key_path);
                    return Err(format!("Failed to read temp key file: {e}"));
                }
            }
        }
    }

    // Timeout — user didn't enter a key within 5 minutes
    info!("Claude Login: timed out waiting for API key");
    Ok(())
}
