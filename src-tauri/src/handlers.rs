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
//!
//! @trace spec:podman-orchestration, spec:default-image, spec:tray-app

use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::sync::mpsc;
use tracing::{debug, error, info, instrument, warn};

use crate::strings;

use tillandsias_core::config::{GlobalConfig, cache_dir, load_global_config, load_project_config};
use tillandsias_core::event::{AppEvent, BuildProgressEvent, ContainerState};
use tillandsias_core::genus::GenusAllocator;
use tillandsias_core::state::{ContainerInfo, TrayState};
use tillandsias_core::tools::ToolAllocator;
use tillandsias_podman::PodmanClient;
use tillandsias_podman::launch::{ContainerLauncher, allocate_port_range};
use tillandsias_podman::query_occupied_ports;

/// Derive the forge image tag from the full 4-part version.
///
/// Uses `TILLANDSIAS_FULL_VERSION` (set by build.rs from the VERSION file)
/// which includes the build number (e.g., "0.1.97.83"). This ensures every
/// local build increment triggers a forge image rebuild.
// @trace spec:default-image, spec:versioning
pub(crate) fn forge_image_tag() -> String {
    format!("tillandsias-forge:v{}", env!("TILLANDSIAS_FULL_VERSION"))
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
            // Extract just the tag portion of current_tag for comparison
            // (handles both "tillandsias-forge:v0.1.97" and "localhost/tillandsias-forge:v0.1.97")
            let current_suffix = current_tag
                .rsplit_once(':')
                .map(|(_, tag)| tag)
                .unwrap_or(current_tag);
            stdout
                .lines()
                .filter(|line| {
                    let trimmed = line.trim();
                    // Match any tillandsias-forge image (with or without localhost/ prefix).
                    // Remove ALL old versioned tags AND the "latest" tag (build-image.sh
                    // re-creates it). Keep only the current version tag.
                    let is_forge = trimmed.contains("tillandsias-forge:");
                    let is_current = trimmed.ends_with(&format!(":{current_suffix}"));
                    is_forge && !is_current
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

    // Also clean up dangling (untagged) images left from builds
    let _ = tillandsias_podman::podman_cmd_sync()
        .args(["image", "prune", "-f"])
        .output();
}

/// Find the newest `tillandsias-forge:v*` image by parsing version numbers.
///
/// Returns `Some(tag)` if a forge image exists with a higher version than
/// `expected_tag`. Returns `None` if no newer image exists.
pub(crate) fn find_newer_forge_image(expected_tag: &str) -> Option<String> {
    let expected_version = expected_tag.strip_prefix("tillandsias-forge:v")?;
    let expected_parts: Vec<u64> = expected_version
        .split('.')
        .filter_map(|s| s.parse().ok())
        .collect();

    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=tillandsias-forge:v*",
        ])
        .output()
        .ok()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut newest_tag: Option<String> = None;
    let mut newest_parts: Vec<u64> = expected_parts.clone();

    for line in stdout.lines() {
        let tag = line.trim();
        if let Some(version_str) = tag.strip_prefix("tillandsias-forge:v") {
            let parts: Vec<u64> = version_str
                .split('.')
                .filter_map(|s| s.parse().ok())
                .collect();

            // Compare version parts lexicographically
            let is_newer = parts
                .iter()
                .zip(newest_parts.iter())
                .find(|(a, b)| a != b)
                .map(|(a, b)| a > b)
                .unwrap_or(parts.len() > newest_parts.len());

            if is_newer {
                newest_parts = parts;
                newest_tag = Some(tag.to_string());
            }
        }
    }

    newest_tag
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
                cmd.spawn()
                    .map(|_| ())
                    .map_err(|e| format!("gnome-terminal: {e}"))
            }
            Some(&"konsole") => {
                let mut cmd = std::process::Command::new("konsole");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args([
                    "-p",
                    &format!("tabtitle={title}"),
                    "-e",
                    "bash",
                    "-c",
                    command,
                ]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("konsole: {e}"))
            }
            Some(&"xterm") => {
                let mut cmd = std::process::Command::new("xterm");
                cmd.env_remove("LD_LIBRARY_PATH");
                cmd.env_remove("LD_PRELOAD");
                cmd.args(["-T", title, "-e", "bash", "-c", command]);
                cmd.spawn().map(|_| ()).map_err(|e| format!("xterm: {e}"))
            }
            _ => Err(
                "No terminal emulator found (tried ptyxis, gnome-terminal, konsole, xterm)".into(),
            ),
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS terminal fallback chain: try CLI terminals first, then AppleScript.
        // CLI terminals are preferred because they don't depend on AppleScript's
        // fragile app-scripting bridge (which breaks when default terminal changes).

        // 1. Ghostty — must use `open -na Ghostty.app` on macOS (direct CLI
        //    invocation is unsupported). Config uses --key=value syntax.
        if std::path::Path::new("/Applications/Ghostty.app").exists() {
            let mut args = vec![
                "-na".into(),
                "Ghostty.app".into(),
                "--args".into(),
                format!("--title={title}"),
                "-e".into(),
                "bash".into(),
                "-c".into(),
                command.into(),
            ];
            // --wait-after-command keeps the window open when the command exits,
            // so users can read output / errors before the window closes.
            args.insert(3, "--wait-after-command".into());
            match std::process::Command::new("open").args(&args).spawn() {
                Ok(_) => {
                    tracing::debug!(terminal = "Ghostty", "Opened terminal via open -na");
                    return Ok(());
                }
                Err(e) => {
                    tracing::warn!(terminal = "Ghostty", error = %e, "Ghostty launch failed, trying next");
                }
            }
        }

        // 2. Other CLI terminals — detected via `which`, launched directly.
        let cli_terminals: &[(&str, &dyn Fn(&str, &str) -> Vec<String>)] = &[
            ("kitty", &|cmd: &str, title: &str| {
                vec![
                    "--title".into(),
                    title.into(),
                    "bash".into(),
                    "-c".into(),
                    cmd.into(),
                ]
            }),
            ("alacritty", &|cmd: &str, title: &str| {
                vec![
                    "--title".into(),
                    title.into(),
                    "-e".into(),
                    "bash".into(),
                    "-c".into(),
                    cmd.into(),
                ]
            }),
            ("wezterm", &|cmd: &str, _title: &str| {
                vec![
                    "start".into(),
                    "--".into(),
                    "bash".into(),
                    "-c".into(),
                    cmd.into(),
                ]
            }),
        ];

        for (term, build_args) in cli_terminals {
            let found = std::process::Command::new("which")
                .arg(term)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|s| s.success());

            if !found {
                continue;
            }

            let args = build_args(command, title);
            match std::process::Command::new(term)
                .args(&args)
                .spawn()
            {
                Ok(_) => {
                    tracing::debug!(terminal = term, "Opened terminal via CLI");
                    return Ok(());
                }
                Err(e) => {
                    tracing::warn!(terminal = term, error = %e, "CLI terminal spawn failed, trying next");
                    continue;
                }
            }
        }

        // 2. AppleScript terminals — iTerm2 then Terminal.app.
        //    Use .output() (blocking) to detect failures and fall through.
        let escaped_cmd = command.replace('\\', "\\\\").replace('"', "\\\"");
        let escaped_title = title.replace('\\', "\\\\").replace('"', "\\\"");

        // iTerm2
        if std::path::Path::new("/Applications/iTerm.app").exists() {
            let script = format!(
                "tell app \"iTerm2\"\n\
                     create window with default profile command \"clear && {escaped_cmd}\"\n\
                     tell current session of current window\n\
                         set name to \"{escaped_title}\"\n\
                     end tell\n\
                     activate\n\
                 end tell"
            );
            if let Ok(out) = std::process::Command::new("osascript")
                .args(["-e", &script])
                .output()
            {
                if out.status.success() {
                    tracing::debug!(terminal = "iTerm2", "Opened terminal via AppleScript");
                    return Ok(());
                }
                let stderr = String::from_utf8_lossy(&out.stderr);
                tracing::warn!(terminal = "iTerm2", error = %stderr, "AppleScript failed, trying next");
            }
        }

        // Terminal.app — always available on macOS (last resort)
        // Note: `set custom title` requires `has custom title` on the tab,
        // but macOS 26+ removed that property. Use a try block so title-setting
        // is best-effort — the command still runs even if titling fails.
        let script = format!(
            "tell app \"Terminal\"\n\
                 do script \"clear && {escaped_cmd}\"\n\
                 activate\n\
             end tell"
        );
        match std::process::Command::new("osascript")
            .args(["-e", &script])
            .output()
        {
            Ok(out) if out.status.success() => {
                tracing::debug!(terminal = "Terminal.app", "Opened terminal via AppleScript");
                Ok(())
            }
            Ok(out) => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!(
                    "No terminal emulator worked (tried ghostty, kitty, alacritty, wezterm, iTerm2, Terminal.app). \
                     Last error: {stderr}"
                ))
            }
            Err(e) => Err(format!("osascript: {e}")),
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Windows: `start "<title>" cmd /k <command>`
        // The first positional argument to `start` is the window title.
        // For .sh scripts, invoke through bash instead of cmd.
        if command.ends_with(".sh") {
            std::process::Command::new("cmd")
                .args(["/c", "start", title, "bash", command])
                .spawn()
                .map(|_| ())
                .map_err(|e| format!("cmd: {e}"))
        } else {
            std::process::Command::new("cmd")
                .args(["/c", "start", title, "cmd", "/k", command])
                .spawn()
                .map(|_| ())
                .map_err(|e| format!("cmd: {e}"))
        }
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
        let script =
            format!("display notification \"{escaped_body}\" with title \"{escaped_summary}\"");
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
    crate::build_lock::acquire(image_name).map_err(|e| {
        error!(image = image_name, error = %e, "Cannot acquire build lock");
        strings::SETUP_ERROR
    })?;

    let source_dir = crate::embedded::write_image_sources().map_err(|e| {
        error!(image = image_name, error = %e, "Failed to extract embedded image sources to temp");
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = forge_image_tag();
    info!(script = %script.display(), image = image_name, tag = %tag, spec = "default-image, nix-builder", "Running embedded build-image.sh");

    // On Windows, .sh scripts can't be executed directly — invoke via bash.
    let mut cmd = if cfg!(target_os = "windows") {
        let mut c = std::process::Command::new("bash");
        c.arg(&script);
        c
    } else {
        std::process::Command::new(&script)
    };

    let output = cmd
        .arg(image_name)
        .args(["--tag", &tag, "--backend", "fedora"])
        .current_dir(&source_dir)
        // Clear AppImage library paths so toolbox, nix, and other host
        // binaries called by build-image.sh use host libraries.
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        // Pass the resolved podman path so build-image.sh can find podman
        // even when launched from Finder (which has a minimal PATH).
        .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
        .output()
        .map_err(|e| {
            error!(script = %script.display(), image = image_name, error = %e, "Failed to launch image build script");
            strings::SETUP_ERROR
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
            spec = "default-image, nix-builder",
            "Image build script failed"
        );
        return Err(strings::SETUP_ERROR.into());
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

/// Select the appropriate container profile for a forge launch based on the agent.
fn forge_profile(
    agent: tillandsias_core::config::SelectedAgent,
) -> tillandsias_core::container_profile::ContainerProfile {
    match agent {
        tillandsias_core::config::SelectedAgent::OpenCode => {
            tillandsias_core::container_profile::forge_opencode_profile()
        }
        tillandsias_core::config::SelectedAgent::Claude => {
            tillandsias_core::container_profile::forge_claude_profile()
        }
    }
}

/// Build a [`LaunchContext`] for forge and terminal launches.
///
/// Resolves all paths, secrets, and custom mounts needed by `build_podman_args()`.
/// Writes the GitHub token to a tmpfs-backed file for secure injection.
///
/// @trace spec:secret-rotation
fn build_launch_context(
    container_name: &str,
    project_path: &Path,
    project_name: &str,
    cache: &Path,
    port_range: (u16, u16),
    detached: bool,
    is_watch_root: bool,
    image_tag: &str,
) -> tillandsias_core::container_profile::LaunchContext {
    let (gh_dir, git_dir) = crate::launch::ensure_secrets_dirs(cache);
    let host_os = tillandsias_core::config::detect_host_os();

    // Claude credentials directory — always create so the mount works on first auth
    let claude_dir = dirs::home_dir()
        .map(|h| h.join(".claude"))
        .unwrap_or_else(|| PathBuf::from("/tmp/.claude"));
    if !claude_dir.exists() {
        std::fs::create_dir_all(&claude_dir).ok();
    }

    // Write GitHub token to tmpfs-backed file for secure container injection.
    // @trace spec:secret-rotation
    let token_file_path = match crate::secrets::retrieve_github_token() {
        Ok(Some(token)) => {
            match crate::token_files::write_token(container_name, &token) {
                Ok(path) => Some(path),
                Err(e) => {
                    warn!(
                        target: "secrets",
                        accountability = true,
                        category = "secrets",
                        spec = "secret-rotation",
                        "Failed to write token file for {container_name}: {e} — falling back to hosts.yml only"
                    );
                    None
                }
            }
        }
        Ok(None) => {
            debug!("No GitHub token in keyring — skipping token file");
            None
        }
        Err(e) => {
            warn!(
                target: "secrets",
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                "Keyring unavailable for token file: {e} — falling back to hosts.yml only"
            );
            None
        }
    };

    // Custom mounts from project config
    let project_config = tillandsias_core::config::load_project_config(project_path);

    tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.to_string(),
        project_path: project_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.to_path_buf(),
        port_range,
        host_os,
        detached,
        is_watch_root,
        claude_dir,
        gh_dir,
        git_dir,
        token_file_path,
        custom_mounts: project_config.mounts,
        image_tag: image_tag.to_string(),
        selected_language: tillandsias_core::config::load_global_config().i18n.language.clone(),
    }
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
#[instrument(skip(state, allocator, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "attach", spec = "podman-orchestration, default-image"))]
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

    // Ensure forge image is up to date — always invoke the build script
    // (it handles staleness internally via hash check and exits fast when current).
    let client = PodmanClient::new();
    let mut tag = forge_image_tag();

    // Check for a newer forge image (forward compatibility: a newer binary may
    // have built a newer image before the user downgraded).
    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(
            expected = %tag,
            found = %newer_tag,
            "Found a newer forge image than expected — using it"
        );
        tag = newer_tag;
    } else {
        // No newer image — ensure current version is built and up to date
        info!(tag = %tag, "Ensuring forge image is up to date...");

        // Notify event loop: build started (menu chip: ⏳ Building forge...)
        let _ = build_tx.try_send(BuildProgressEvent::Started {
            image_name: "forge".to_string(),
        });

        let build_result =
            tokio::task::spawn_blocking(|| run_build_image_script("forge")).await;

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
                    return Err(strings::ENV_NOT_READY.into());
                }
                info!(tag = %tag, spec = "default-image", "Image ready");
                // Prune older forge images after successful build
                prune_old_forge_images(&tag);
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
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                state.running.retain(|c| c.name != container_name);
                allocator.release(&project_name, genus);
                return Err(strings::SETUP_ERROR.into());
            }
        }
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
    let profile = forge_profile(selected_agent);
    let ctx = build_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        port_range,
        false, // interactive (-it), NOT detached
        is_watch_root,
        &tag,
    );
    let run_args = crate::launch::build_podman_args(&profile, &ctx);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

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

    // Accountability: log the secret mount summary for this container launch.
    // @trace spec:secret-rotation
    {
        let has_token_file = ctx.token_file_path.is_some();
        let has_gh = ctx.gh_dir.join("hosts.yml").exists();
        let has_claude_dir = ctx.claude_dir.exists();
        let token_detail = if has_token_file {
            "token-file(tmpfs,ro)"
        } else {
            "no-token-file"
        };
        let secret_summary = match (has_gh, has_claude_dir) {
            (true, true) => format!("{token_detail}, gh(ro), git(rw), claude-dir(rw)"),
            (true, false) => format!("{token_detail}, gh(ro), git(rw) | No Claude dir"),
            (false, true) => format!("{token_detail}, claude-dir(rw) | No GitHub token in hosts.yml"),
            (false, false) => format!("{token_detail} | No other secrets"),
        };
        info!(
            accountability = true,
            category = "secrets",
            safety = %secret_summary,
            spec = "environment-runtime, secret-rotation",
            "Environment {container_name} launched with secrets: {secret_summary}",
        );
    }

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
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "stop", spec = "podman-orchestration"))]
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
#[instrument(skip(state, allocator), fields(container = %container_name, operation = "destroy", spec = "podman-orchestration"))]
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
        spec = "podman-orchestration",
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
    let mut tag = forge_image_tag();
    // Use newer image if available (forward compatibility)
    if let Some(newer_tag) = find_newer_forge_image(&tag) {
        warn!(expected = %tag, found = %newer_tag, "Using newer forge image for terminal");
        tag = newer_tag;
    }
    if !client.image_exists(&tag).await {
        error!(tag = %tag, "Image not found when opening maintenance terminal");
        allocator.release(&project_name, genus);
        tool_allocator.release(&project_name, &display_emoji);
        return Err(strings::ENV_NOT_READY.into());
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

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

    let profile = tillandsias_core::container_profile::terminal_profile();
    let ctx = build_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        port_range,
        false, // interactive
        false, // not watch root
        &tag,
    );
    let run_args = crate::launch::build_podman_args(&profile, &ctx);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

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
            // Accountability: log the secret mount summary.
            {
                let has_gh = ctx.gh_dir.join("hosts.yml").exists();
                info!(
                    accountability = true,
                    category = "secrets",
                    safety = "gh(ro), git(rw) | Terminal profile, no Claude secrets",
                    spec = "environment-runtime",
                    "Maintenance terminal {container_name} launched | gh: {has_gh}",
                );
            }
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
        return Err(strings::ENV_NOT_READY.into());
    }

    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // Refresh hosts.yml from native keyring before terminal launch.
    crate::secrets::write_hosts_yml_from_keyring();

    // Allocate port range — check actual podman containers for conflicts
    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range((3000, 3019), &existing_ports);

    let container_name =
        tillandsias_core::state::ContainerInfo::container_name(&project_name, genus);

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

    // Use terminal profile with SrcRoot working dir for the root terminal
    let mut profile = tillandsias_core::container_profile::terminal_profile();
    profile.working_dir = Some(tillandsias_core::container_profile::WorkingDir::SrcRoot);

    // Build context: project_name="(all projects)" for the env var display,
    // is_watch_root=true so the watch path mounts at /home/forge/src directly.
    let ctx = build_launch_context(
        &container_name,
        &watch_path,
        "(all projects)",
        &cache,
        port_range,
        false, // interactive
        true,  // watch root — mount at /home/forge/src directly
        &tag,
    );
    let run_args = crate::launch::build_podman_args(&profile, &ctx);

    let mut podman_parts = vec![
        tillandsias_podman::find_podman_path().to_string(),
        "run".to_string(),
    ];
    podman_parts.extend(run_args);
    let podman_cmd = crate::launch::shell_quote_join(&podman_parts);

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
            // Accountability: log the secret mount summary.
            {
                let has_gh = ctx.gh_dir.join("hosts.yml").exists();
                info!(
                    accountability = true,
                    category = "secrets",
                    safety = "gh(ro), git(rw) | Root terminal, no Claude secrets",
                    spec = "environment-runtime",
                    "Root terminal {container_name} launched | gh: {has_gh}",
                );
            }
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
                    return Err(strings::ENV_NOT_READY.into());
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
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(tag = %tag, error = %e, "Image build task panicked (GitHub Login)");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "forge".to_string(),
                    reason: "Tillandsias is setting up".to_string(),
                });
                return Err(strings::SETUP_ERROR.into());
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
                strings::INSTALL_INCOMPLETE
            })?;

    // Set env vars that gh-auth-login.sh requires. open_terminal spawns a
    // child process that inherits these. They are set on the current process
    // (not a Command builder) because open_terminal's various terminal
    // backends all inherit the parent environment.
    // SAFETY: Tillandsias is single-threaded at this point in the menu handler;
    // the async runtime is on the same thread and no parallel env reads occur.
    unsafe {
        std::env::set_var("FORGE_IMAGE_TAG", forge_image_tag());
        std::env::set_var("PODMAN_PATH", tillandsias_podman::find_podman_path());
    }

    open_terminal(&script_path.display().to_string(), "GitHub Login")
        .map_err(|e| format!("Failed to open terminal: {e}"))
}

/// Handle "Claude Reset Credentials" — remove `~/.claude/` contents so next
/// container launch triggers re-authentication via Claude Code's own flow.
pub fn handle_claude_reset_credentials() -> Result<(), String> {
    let claude_dir = dirs::home_dir()
        .map(|h| h.join(".claude"))
        .ok_or("Cannot determine home directory")?;

    if !claude_dir.exists() {
        info!("Claude credentials directory does not exist, nothing to reset");
        return Ok(());
    }

    // Remove contents but keep the directory (it's always mounted)
    match std::fs::read_dir(&claude_dir) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    std::fs::remove_dir_all(&path).ok();
                } else {
                    std::fs::remove_file(&path).ok();
                }
            }
            info!("Claude credentials cleared — next launch will re-authenticate");
            send_notification("Tillandsias", "Claude credentials cleared. Next launch will prompt for authentication.");
            Ok(())
        }
        Err(e) => Err(format!("Failed to read Claude credentials directory: {e}")),
    }
}

/// Detect the document root for a web container.
///
/// Checks subdirectories in priority order:
///   1. `public/`   — Hugo, Rails, Vite default
///   2. `dist/`     — Webpack, Parcel, Rollup default
///   3. `build/`    — Create React App default
///   4. `_site/`    — Jekyll, Eleventy default
///   5. `out/`      — Next.js static export
///   6. Project root — fallback
///
/// Returns the absolute path to the detected document root.
pub fn detect_document_root(project_path: &Path) -> PathBuf {
    let candidates = ["public", "dist", "build", "_site", "out"];
    for name in &candidates {
        let candidate = project_path.join(name);
        if candidate.is_dir() {
            debug!(
                project = %project_path.display(),
                document_root = %candidate.display(),
                "Auto-detected document root"
            );
            return candidate;
        }
    }
    debug!(
        project = %project_path.display(),
        "No standard output directory found, using project root as document root"
    );
    project_path.to_path_buf()
}

/// Handle "Serve Here" — launch a minimal web server container for static files.
///
/// # Security model
/// - Image: `tillandsias-web:latest` (httpd on port 8080, no dev tools)
/// - Only the detected document root is mounted, read-only (`/var/www:ro`)
/// - NO secrets mounted: no gh credentials, no git config, no Claude directory, no API keys
/// - Port binds to `127.0.0.1` only (localhost)
/// - Full security flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`
///
/// # Container naming
/// `tillandsias-<project>-web` — no genus allocation. Only one web container per project.
///
/// # Port allocation
/// Base port 8080, increments if occupied. Separate range from forge containers (3000-3019).
#[instrument(skip(state, build_tx), fields(project = %project_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "unknown".to_string()), operation = "serve", spec = "podman-orchestration"))]
pub async fn handle_serve_here(
    project_path: PathBuf,
    state: &mut TrayState,
    build_tx: mpsc::Sender<BuildProgressEvent>,
) -> Result<(), String> {
    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    info!(project = %project_name, "Serve Here requested");

    let container_name = tillandsias_core::state::ContainerInfo::web_container_name(&project_name);

    // Don't-relaunch guard: if a web container for this project is already running,
    // notify the user and return early instead of spawning a second server.
    if let Some(existing) = state.running.iter().find(|c| c.name == container_name) {
        let port = existing.port_range.0;
        let msg = format!("Already serving — open http://localhost:{port}");
        info!(project = %project_name, port, "Don't-relaunch guard fired — web container already running");
        send_notification("Tillandsias", &msg);
        return Err(format!(
            "Web server for '{project_name}' is already running on port {port}"
        ));
    }

    // Load project config for document_root and port overrides
    let project_config = tillandsias_core::config::load_project_config(&project_path);

    // Detect document root — check per-project config override first, then auto-detect
    let document_root = if let Some(ref web_cfg) = project_config.web {
        if let Some(ref explicit_root) = web_cfg.document_root {
            let override_path = project_path.join(explicit_root);
            if override_path.is_dir() {
                debug!(project = %project_name, document_root = %override_path.display(), "Using explicit document root from config");
                override_path
            } else {
                warn!(project = %project_name, path = %override_path.display(), "Configured web.document_root does not exist, falling back to auto-detection");
                detect_document_root(&project_path)
            }
        } else {
            detect_document_root(&project_path)
        }
    } else {
        detect_document_root(&project_path)
    };

    // Allocate port — base 8080, increment on conflict.
    // Web containers use a separate port space from forge containers (3000-3019).
    let configured_base_port = project_config
        .web
        .as_ref()
        .and_then(|w| w.port)
        .unwrap_or(8080);
    let base_port = (configured_base_port, configured_base_port); // single-port "range"

    let mut existing_ports: Vec<(u16, u16)> = state.running.iter().map(|c| c.port_range).collect();
    existing_ports.extend(query_occupied_ports());
    let port_range = allocate_port_range(base_port, &existing_ports);
    let port = port_range.0;

    // Check that the web image exists; build it if missing (same pattern as forge in handle_attach_here)
    let web_image = "tillandsias-web:latest";
    let client = PodmanClient::new();
    if !client.image_exists(web_image).await {
        info!(image = web_image, "Web image not found, building...");
        let _ = build_tx.try_send(BuildProgressEvent::Started {
            image_name: "Web server".to_string(),
        });
        let build_result = tokio::task::spawn_blocking(|| run_build_image_script("web")).await;
        match build_result {
            Ok(Ok(())) => {
                if !client.image_exists(web_image).await {
                    error!(image = web_image, "Web image still not found after build");
                    let _ = build_tx.try_send(BuildProgressEvent::Failed {
                        image_name: "Web server".to_string(),
                        reason: "Web server image not ready".to_string(),
                    });
                    return Err("Web server image is not ready yet".into());
                }
                let _ = build_tx.try_send(BuildProgressEvent::Completed {
                    image_name: "Web server".to_string(),
                });
            }
            Ok(Err(ref e)) => {
                error!(image = web_image, error = %e, "Web image build failed");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "Web server".to_string(),
                    reason: "Web server image build failed".to_string(),
                });
                return Err(strings::SETUP_ERROR.into());
            }
            Err(ref e) => {
                error!(image = web_image, error = %e, "Web image build task panicked");
                let _ = build_tx.try_send(BuildProgressEvent::Failed {
                    image_name: "Web server".to_string(),
                    reason: "Web server image build failed".to_string(),
                });
                return Err(strings::SETUP_ERROR.into());
            }
        }
    }

    // Pre-register in state so the tray shows 🔗 Serving immediately
    let sentinel_genus = tillandsias_core::genus::TillandsiaGenus::ALL[0];
    let placeholder = tillandsias_core::state::ContainerInfo {
        name: container_name.clone(),
        project_name: project_name.clone(),
        genus: sentinel_genus,
        state: tillandsias_core::event::ContainerState::Creating,
        port_range,
        container_type: tillandsias_core::state::ContainerType::Web,
        display_emoji: "\u{1F517}".to_string(), // 🔗
    };
    state.running.push(placeholder);

    // Build `podman run` command for the web container.
    //
    // Security guarantees (audited 2026-03-29):
    //   - --cap-drop=ALL             No Linux capabilities
    //   - --security-opt=no-new-privileges  No suid escalation
    //   - --userns=keep-id           Rootless, host UID mapped
    //   - --security-opt=label=disable  Bind mount on Silverblue
    //   - --rm                       Ephemeral, removed on exit
    //   - Only mount: document_root → /var/www:ro (read-only)
    //   - Port: 127.0.0.1:<port>:8080 — localhost only, no external exposure
    //   - NO secrets mounted (no gh, no git, no claude, no API keys)
    let podman_bin = tillandsias_podman::find_podman_path();
    let podman_cmd = format!(
        "{podman_bin} run -it --rm --init --stop-timeout=10 \
        --name {container_name} \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --userns=keep-id \
        --security-opt=label=disable \
        -p 127.0.0.1:{port}:8080 \
        -v {}:/var/www:ro \
        {web_image}",
        document_root.display(),
    );

    // Window title uses the chain link emoji to distinguish from forge windows
    let title = format!("\u{1F517} {project_name}"); // 🔗 <project>

    info!(
        container = %container_name,
        port,
        document_root = %document_root.display(),
        "Launching web server"
    );

    match open_terminal(&podman_cmd, &title) {
        Ok(()) => {
            info!(
                container = %container_name,
                port,
                "Web server terminal opened — serving at http://localhost:{port}"
            );
            Ok(())
        }
        Err(e) => {
            state.running.retain(|c| c.name != container_name);
            Err(format!("Failed to open web server terminal: {e}"))
        }
    }
}
