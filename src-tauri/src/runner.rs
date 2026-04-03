//! CLI container runner with user-friendly output.
//!
//! Launched when the user runs `tillandsias <path>`. Checks/builds the
//! image, prints formatted progress, then execs `podman run -it --rm`
//! with inherited stdio so the container terminal passes through.
//!
//! @trace spec:cli-mode, spec:podman-orchestration, spec:default-image

use std::path::{Path, PathBuf};

use tillandsias_core::config::{
    GlobalConfig, SelectedAgent, cache_dir, load_global_config, load_project_config,
};
use tillandsias_core::genus::TillandsiaGenus;
use tillandsias_core::state::ContainerInfo;
use tillandsias_podman::PodmanClient;

use crate::i18n;
use crate::strings;

/// Map a short image name to a full image tag.
///
/// For "forge", returns the versioned tag (e.g., `tillandsias-forge:v0.1.72`).
/// For other names or full tags (containing `:` or `/`), passes through as-is.
fn image_tag(name: &str) -> String {
    // If the name already contains a colon or slash, treat it as a full tag.
    if name.contains(':') || name.contains('/') {
        name.to_string()
    } else if name == "forge" {
        crate::handlers::forge_image_tag()
    } else {
        format!("tillandsias-{name}:latest")
    }
}

/// Run `build-image.sh` from the embedded binary scripts.
///
/// Extracts image sources + build scripts to temp, executes with inherited
/// stdio so the user sees progress, then cleans up.
fn run_build_image_script(image_name: &str, debug: bool) -> Result<(), String> {
    // Check if another process (e.g., tillandsias --init) is already building
    if crate::build_lock::is_running(image_name) {
        println!("  {}", i18n::t("cli.waiting_setup"));
        crate::build_lock::wait_for_build(image_name).map_err(|e| {
            if debug {
                eprintln!("  [debug] Build wait timed out: {e}");
            }
            strings::SETUP_ERROR
        })?;
        return Ok(());
    }

    crate::build_lock::acquire(image_name).map_err(|e| {
        if debug {
            eprintln!("  [debug] Cannot acquire build lock: {e}");
        }
        strings::SETUP_ERROR
    })?;

    let source_dir = crate::embedded::write_image_sources().map_err(|e| {
        if debug {
            eprintln!("  [debug] Failed to extract embedded image sources: {e}");
        }
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = crate::handlers::forge_image_tag();

    if debug {
        println!(
            "  [debug] Running embedded: {} --tag {}",
            script.display(),
            tag
        );
    }

    // On Windows, call podman build directly instead of going through bash.
    // Git Bash's MSYS2 doesn't initialize properly from native Windows processes.
    #[cfg(target_os = "windows")]
    {
        let containerfile = source_dir.join("images").join("default").join("Containerfile");
        let context_dir = source_dir.join("images").join("default");

        if debug {
            println!(
                "  [debug] Running podman build --tag {} -f {}",
                tag,
                containerfile.display()
            );
        }

        let status = tillandsias_podman::podman_cmd_sync()
            .args(["build", "--tag", &tag, "-f"])
            .arg(&containerfile)
            .arg(&context_dir)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .map_err(|e| {
                eprintln!("  [debug] Failed to launch podman build: {e}");
                strings::SETUP_ERROR
            })?;

        crate::embedded::cleanup_image_sources();
        crate::build_lock::release(image_name);

        if status.success() {
            crate::handlers::prune_old_forge_images(&tag);
            return Ok(());
        } else {
            if debug {
                eprintln!(
                    "  [debug] podman build exited with code {}",
                    status.code().unwrap_or(-1)
                );
            }
            return Err(strings::SETUP_ERROR.into());
        }
    }

    // On Unix, use the build-image.sh script (handles nix + fedora backends).
    #[cfg(not(target_os = "windows"))]
    {
    let mut cmd = std::process::Command::new(&script);

    let status = cmd
        .arg(image_name)
        .args(["--tag", &tag, "--backend", "fedora"])
        .current_dir(&source_dir)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        // Pass the resolved podman path so build-image.sh can find podman
        // even when launched from Finder (which has a minimal PATH).
        .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [debug] Failed to launch build script: {e}");
            strings::SETUP_ERROR
        })?;

    crate::embedded::cleanup_image_sources();
    crate::build_lock::release(image_name);

    if status.success() {
        // Prune older versioned forge images to reclaim disk space
        crate::handlers::prune_old_forge_images(&tag);
        Ok(())
    } else {
        if debug {
            eprintln!(
                "  [debug] Build script exited with code {}",
                status.code().unwrap_or(-1)
            );
        }
        Err(strings::SETUP_ERROR.into())
    }
    } // #[cfg(not(target_os = "windows"))]
}

/// Get the image size in human-readable form via `podman image inspect`.
fn image_size_display(tag: &str) -> String {
    let output = tillandsias_podman::podman_cmd_sync()
        .args(["image", "inspect", tag, "--format", "{{.Size}}"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let size_str = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if let Ok(bytes) = size_str.parse::<u64>() {
                let mb = bytes / (1024 * 1024);
                format!("{mb} MB")
            } else {
                "unknown size".to_string()
            }
        }
        _ => "unknown size".to_string(),
    }
}

/// Build a [`LaunchContext`] for CLI mode.
///
/// @trace spec:secret-rotation
fn build_cli_launch_context(
    container_name: &str,
    project_path: &Path,
    project_name: &str,
    cache: &Path,
    port_range: (u16, u16),
    image_tag: &str,
) -> tillandsias_core::container_profile::LaunchContext {
    let (gh_dir, git_dir) = crate::launch::ensure_secrets_dirs(cache);
    let host_os = tillandsias_core::config::detect_host_os();

    // Refresh hosts.yml from native keyring before container launch.
    crate::secrets::write_hosts_yml_from_keyring();

    // Claude credentials directory — always create so the mount works on first auth
    let claude_dir = dirs::home_dir()
        .map(|h| h.join(".claude"))
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp/.claude"));
    if !claude_dir.exists() {
        std::fs::create_dir_all(&claude_dir).ok();
    }

    // Write GitHub token to tmpfs-backed file for secure container injection.
    // @trace spec:secret-rotation
    let token_file_path = match crate::secrets::retrieve_github_token() {
        Ok(Some(token)) => match crate::token_files::write_token(container_name, &token) {
            Ok(path) => Some(path),
            Err(e) => {
                eprintln!("  Warning: token file write failed ({e}), using hosts.yml only");
                None
            }
        },
        _ => None,
    };

    // Custom mounts from project config
    let project_config = load_project_config(project_path);

    tillandsias_core::container_profile::LaunchContext {
        container_name: container_name.to_string(),
        project_path: project_path.to_path_buf(),
        project_name: project_name.to_string(),
        cache_dir: cache.to_path_buf(),
        port_range,
        host_os,
        detached: false,
        is_watch_root: false,
        claude_dir,
        gh_dir,
        git_dir,
        token_file_path,
        custom_mounts: project_config.mounts,
        image_tag: image_tag.to_string(),
        selected_language: tillandsias_core::config::load_global_config().i18n.language.clone(),
    }
}

/// Run the CLI attach workflow.
///
/// When `bash` is true, the container entrypoint is overridden with `/bin/bash`
/// for troubleshooting (no default tools/IDE launched).
///
/// `agent_override` lets `--opencode` / `--claude` flags override the
/// configured agent for this session. Ignored when `bash` is true.
///
/// Returns `true` on success, `false` on failure.
pub fn run(
    path: PathBuf,
    image_name: &str,
    debug: bool,
    bash: bool,
    agent_override: Option<SelectedAgent>,
) -> bool {
    // Resolve and validate the project path.
    // AppImage changes CWD to its FUSE mount — resolve relative paths against
    // $OWD (Original Working Directory) so `tillandsias .` works correctly.
    // @trace spec:cli-mode
    let resolved = if path.is_relative() {
        if let Ok(owd) = std::env::var("OWD") {
            PathBuf::from(owd).join(&path)
        } else {
            path.clone()
        }
    } else {
        path.clone()
    };

    let project_path = match resolved.canonicalize() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Error: cannot resolve path '{}': {e}", path.display());
            return false;
        }
    };

    if !project_path.is_dir() {
        eprintln!("Error: '{}' is not a directory", project_path.display());
        return false;
    }

    let project_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    // Display the tilde-collapsed path for readability
    let display_path = tilde_path(&project_path);

    // Print the welcome banner before any other output — only in interactive mode.
    crate::cli::print_welcome_banner(debug);

    println!();
    println!("{}", i18n::tf("cli.attaching", &[("name", &project_name)]));

    // Resolve image
    let tag = image_tag(image_name);

    println!();
    println!("{}", i18n::tf("cli.checking_image", &[("tag", &tag)]));

    // Check if image exists
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

    let client = PodmanClient::new();

    // Verify podman is available
    let has_podman = rt.block_on(client.is_available());
    if !has_podman {
        eprintln!("{}", i18n::t("errors.no_podman"));
        return false;
    }

    // On macOS/Windows, ensure podman machine is initialized and running
    if tillandsias_core::state::Os::detect().needs_podman_machine() {
        if !rt.block_on(client.has_machine()) {
            if debug {
                eprintln!("  [debug] No podman machine found, initializing...");
            }
            rt.block_on(client.init_machine());
        }
        if !rt.block_on(client.is_machine_running()) {
            if debug {
                eprintln!("  [debug] Starting podman machine...");
            }
            if !rt.block_on(client.start_machine()) {
                eprintln!("  Podman machine failed to start. Try: podman machine init && podman machine start");
                return false;
            }
            // Wait for API to be ready
            rt.block_on(client.wait_for_ready(5));
        }
    }

    // Try to build image via build-image.sh if available (dev mode).
    // Falls back to checking if image already exists (installed mode).
    let source_name = if image_name.contains(':') || image_name.contains('/') {
        "forge"
    } else {
        image_name
    };

    // Try embedded build script (always available in the signed binary)
    println!("  {}", i18n::t("cli.ensuring_image"));
    if let Err(e) = run_build_image_script(source_name, debug)
        && debug
    {
        eprintln!("  Build script failed: {e}");
    }

    // Verify image exists
    let image_exists = rt.block_on(client.image_exists(&tag));
    if image_exists {
        let size = image_size_display(&tag);
        println!("{}", i18n::tf("cli.image_ready", &[("size", &size)]));
    } else {
        eprintln!("  \u{2717} {}", i18n::t("errors.env_not_ready"));
        return false;
    }

    // Load config for port range
    let global_config = load_global_config();
    let project_config = load_project_config(&project_path);
    let resolved = global_config.merge_with_project(&project_config);
    let base_port = GlobalConfig::parse_port_range(&resolved.port_range).unwrap_or((3000, 3019));

    // Use Aeranthos genus for CLI mode (no allocator needed)
    let genus = TillandsiaGenus::Aeranthos;
    let container_name = ContainerInfo::container_name(&project_name, genus);

    // Ensure cache directory exists
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    // Select profile based on mode: --bash uses terminal profile, otherwise forge.
    // --opencode / --claude override the configured agent for this session.
    let selected_agent = agent_override.unwrap_or(global_config.agent.selected);
    let profile = if bash {
        tillandsias_core::container_profile::terminal_profile()
    } else {
        match selected_agent {
            SelectedAgent::OpenCode => {
                tillandsias_core::container_profile::forge_opencode_profile()
            }
            SelectedAgent::Claude => {
                tillandsias_core::container_profile::forge_claude_profile()
            }
        }
    };

    let ctx = build_cli_launch_context(
        &container_name,
        &project_path,
        &project_name,
        &cache,
        base_port,
        &tag,
    );
    let run_args = crate::launch::build_podman_args(&profile, &ctx);

    println!();
    if bash {
        println!("{}", i18n::t("cli.starting_terminal"));
    } else {
        println!("{}", i18n::t("cli.starting_env"));
    }
    println!("  Name:   {container_name}");
    println!("  Ports:  {}-{}", base_port.0, base_port.1);
    let proj_display = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());
    println!("  Mount:  {display_path} \u{2192} /home/forge/src/{proj_display}");
    println!("  Cache:  {}", tilde_path(&cache));

    // @trace spec:secret-management
    // Show credential mounts transparently so users know what is shared
    println!();
    println!("  Credentials shared with this environment:");
    if ctx.token_file_path.is_some() {
        println!("    Token:    tmpfs (RAM only, read-only, deleted on stop)");
    } else {
        println!("    Token:    not available (GitHub login may be needed)");
    }
    println!("    Git auth: protocol + username (no token in this file)");
    println!("    Git ID:   {} <from .gitconfig>",
        tilde_path(&ctx.git_dir.join(".gitconfig")));
    if profile.secrets.iter().any(|s| s.kind == tillandsias_core::container_profile::SecretKind::ClaudeDir) {
        println!("    Claude:   ~/.claude/ (session credentials, read-write)");
    }

    if debug {
        println!();
        let debug_cmd: Vec<_> = run_args.iter().map(|a| {
            if a.contains(' ') { format!("'{a}'") } else { a.clone() }
        }).collect();
        println!("  [debug] podman run {}", debug_cmd.join(" "));
    }

    println!();
    println!("{}", i18n::t("cli.launching"));
    println!();

    // Execute podman with inherited stdio — terminal passes through.
    // Using .status() blocks until the container exits.
    let status = tillandsias_podman::podman_cmd_sync()
        .arg("run")
        .args(&run_args)
        .status();

    println!();

    // Clean up token file after container exits (CLI mode runs synchronously).
    // @trace spec:secret-rotation
    crate::token_files::delete_token(&container_name);

    match status {
        Ok(s) => {
            println!("{}", i18n::t("cli.env_stopped"));
            s.success()
        }
        Err(e) => {
            eprintln!("Error: failed to run podman: {e}");
            false
        }
    }
}

/// Run the GitHub login flow interactively in the current terminal.
///
/// Extracts the embedded `gh-auth-login.sh` script to a temp file and
/// executes it with inherited stdio so the user can authenticate directly.
///
/// Returns `true` on success, `false` on failure.
pub fn run_github_login() -> bool {
    crate::cli::print_welcome_banner(false);

    let script_path = match crate::embedded::write_temp_script(
        "gh-auth-login.sh",
        crate::embedded::GH_AUTH_LOGIN,
    ) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("Error: failed to extract login script: {e}");
            return false;
        }
    };

    // Clean AppImage environment so podman works correctly.
    // AppImage injects LD_LIBRARY_PATH/LD_PRELOAD that break subprocesses.
    let status = std::process::Command::new("bash")
        .arg(&script_path)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
        .env("FORGE_IMAGE_TAG", crate::handlers::forge_image_tag())
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status();

    // Clean up temp script
    std::fs::remove_file(&script_path).ok();

    match status {
        Ok(s) => s.success(),
        Err(e) => {
            eprintln!("Error: failed to run login script: {e}");
            false
        }
    }
}

/// Collapse a path's home directory prefix to `~` for display.
fn tilde_path(path: &Path) -> String {
    if let Some(home) = dirs::home_dir()
        && let Ok(suffix) = path.strip_prefix(&home)
    {
        return format!("~/{}", suffix.display());
    }
    path.display().to_string()
}
