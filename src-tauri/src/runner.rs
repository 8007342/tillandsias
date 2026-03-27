//! CLI container runner with user-friendly output.
//!
//! Launched when the user runs `tillandsias <path>`. Checks/builds the
//! image, prints formatted progress, then execs `podman run -it --rm`
//! with inherited stdio so the container terminal passes through.

use std::path::{Path, PathBuf};

use tillandsias_core::config::{GlobalConfig, cache_dir, load_global_config, load_project_config};
use tillandsias_core::genus::TillandsiaGenus;
use tillandsias_core::state::ContainerInfo;
use tillandsias_podman::PodmanClient;

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
    // Check if another process (e.g., tillandsias init) is already building
    if crate::build_lock::is_running(image_name) {
        println!("  Waiting for environment setup to complete...");
        crate::build_lock::wait_for_build(image_name)
            .map_err(|e| {
                if debug {
                    eprintln!("  [debug] Build wait timed out: {e}");
                }
                "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
            })?;
        return Ok(());
    }

    crate::build_lock::acquire(image_name)
        .map_err(|e| {
            if debug {
                eprintln!("  [debug] Cannot acquire build lock: {e}");
            }
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    let source_dir = crate::embedded::write_image_sources()
        .map_err(|e| {
            if debug {
                eprintln!("  [debug] Failed to extract embedded image sources: {e}");
            }
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = crate::handlers::forge_image_tag();

    if debug {
        println!("  [debug] Running embedded: {} --tag {}", script.display(), tag);
    }

    let status = std::process::Command::new(&script)
        .arg(image_name)
        .args(["--tag", &tag])
        .current_dir(&source_dir)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [debug] Failed to launch build script: {e}");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    crate::embedded::cleanup_image_sources();
    crate::build_lock::release(image_name);

    if status.success() {
        // Prune older versioned forge images to reclaim disk space
        crate::handlers::prune_old_forge_images(&tag);
        Ok(())
    } else {
        if debug {
            eprintln!("  [debug] Build script exited with code {}", status.code().unwrap_or(-1));
        }
        Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into())
    }
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

/// Build podman run args for interactive CLI mode.
fn build_run_args(
    container_name: &str,
    image: &str,
    project_path: &Path,
    cache: &Path,
    port_range: (u16, u16),
) -> Vec<String> {
    // Derive project name for env vars
    let proj_name = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());

    let host_os = tillandsias_core::config::detect_host_os();

    let mut args = vec![
        "-it".to_string(),
        "--rm".to_string(),
        "--init".to_string(),
        "--stop-timeout=10".to_string(),
        "--name".to_string(),
        container_name.to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "--security-opt=label=disable".to_string(),
        // Environment variables for the welcome script
        "-e".to_string(),
        format!("TILLANDSIAS_PROJECT={proj_name}"),
        "-e".to_string(),
        format!("TILLANDSIAS_HOST_OS={host_os}"),
    ];

    // GPU passthrough (Linux only)
    if cfg!(target_os = "linux") {
        for flag in tillandsias_podman::detect_gpu_devices() {
            args.push(flag);
        }
    }

    // Port range
    let port_mapping = format!(
        "{}-{}:{}-{}",
        port_range.0, port_range.1, port_range.0, port_range.1
    );
    args.push("-p".to_string());
    args.push(port_mapping);

    // Volume mounts — mount at src/<project-name>/ to preserve hierarchy
    let project_mount = format!("{}:/home/forge/src/{}", project_path.display(), proj_name);
    args.push("-v".to_string());
    args.push(project_mount);

    let cache_mount = format!("{}:/home/forge/.cache/tillandsias", cache.display());
    args.push("-v".to_string());
    args.push(cache_mount);

    // Secrets directory — git config, gh auth
    let secrets_dir = cache.join("secrets");
    std::fs::create_dir_all(secrets_dir.join("gh")).ok();

    // Refresh hosts.yml from native keyring before container launch.
    crate::secrets::write_hosts_yml_from_keyring();
    let git_dir = secrets_dir.join("git");
    std::fs::create_dir_all(&git_dir).ok();
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

    // Git config — mount directory read-only, point git via GIT_CONFIG_GLOBAL
    let git_mount = format!(
        "{}:/home/forge/.config/tillandsias-git:ro",
        git_dir.display()
    );
    args.push("-v".to_string());
    args.push(git_mount);
    args.push("-e".to_string());
    args.push("GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig".to_string());

    // Agent selection — tells the entrypoint which coding agent to launch
    let selected_agent = tillandsias_core::config::load_global_config().agent.selected;
    args.push("-e".to_string());
    args.push(format!("TILLANDSIAS_AGENT={}", selected_agent.as_env_str()));

    // Claude Code credentials — persists auth across container restarts
    let claude_dir = secrets_dir.join("claude");
    std::fs::create_dir_all(&claude_dir).ok();
    let claude_mount = format!("{}:/home/forge/.claude:rw", claude_dir.display());
    args.push("-v".to_string());
    args.push(claude_mount);

    // Custom mounts from project config
    let project_config = load_project_config(project_path);
    for mount in &project_config.mounts {
        let mount_str = format!("{}:{}:{}", mount.host, mount.container, mount.mode);
        args.push("-v".to_string());
        args.push(mount_str);
    }

    // Image (always last)
    args.push(image.to_string());

    args
}

/// Run the CLI attach workflow.
///
/// When `bash` is true, the container entrypoint is overridden with `/bin/bash`
/// for troubleshooting (no default tools/IDE launched).
///
/// Returns `true` on success, `false` on failure.
pub fn run(path: PathBuf, image_name: &str, debug: bool, bash: bool) -> bool {
    // Resolve and validate the project path
    let project_path = match path.canonicalize() {
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

    println!();
    println!("Tillandsias \u{2014} Attaching to {project_name}");

    // Resolve image
    let tag = image_tag(image_name);

    println!();
    println!("Checking image... {tag}");

    // Check if image exists
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Failed to create tokio runtime");

    let client = PodmanClient::new();

    // Verify podman is available
    let has_podman = rt.block_on(client.is_available());
    if !has_podman {
        eprintln!("Error: podman is not installed or not in PATH");
        return false;
    }

    // Try to build image via build-image.sh if available (dev mode).
    // Falls back to checking if image already exists (installed mode).
    let source_name = if image_name.contains(':') || image_name.contains('/') {
        "forge"
    } else {
        image_name
    };

    // Try embedded build script (always available in the signed binary)
    println!("  Ensuring image is up to date...");
    if let Err(e) = run_build_image_script(source_name, debug)
        && debug
    {
        eprintln!("  Build script failed: {e}");
    }

    // Verify image exists
    let image_exists = rt.block_on(client.image_exists(&tag));
    if image_exists {
        let size = image_size_display(&tag);
        println!("  \u{2713} Image ready ({size})");
    } else {
        eprintln!("  \u{2717} Development environment not ready yet. Tillandsias will set it up automatically — please try again in a few minutes.");
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

    let mut run_args = build_run_args(&container_name, &tag, &project_path, &cache, base_port);

    // --bash mode: launch fish shell (skipping the OpenCode entrypoint).
    // Start in the project directory so the user lands in the right place.
    if bash {
        let project_name = project_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "src".to_string());
        let image_arg = run_args.pop().expect("run_args always ends with image");
        run_args.push("--entrypoint".to_string());
        run_args.push("fish".to_string());
        run_args.push("-w".to_string());
        run_args.push(format!("/home/forge/src/{project_name}"));
        run_args.push(image_arg);
    }

    println!();
    if bash {
        println!("Starting terminal (fish shell)...");
    } else {
        println!("Starting environment...");
    }
    println!("  Name:   {container_name}");
    println!("  Ports:  {}-{}", base_port.0, base_port.1);
    let proj_display = project_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "project".to_string());
    println!("  Mount:  {display_path} \u{2192} /home/forge/src/{proj_display}");
    println!("  Cache:  {}", tilde_path(&cache));

    if debug {
        println!();
        println!("  [debug] podman run {}", run_args.join(" "));
    }

    println!();
    println!("Launching... (Ctrl+C to stop)");
    println!();

    // Execute podman with inherited stdio — terminal passes through.
    // Using .status() blocks until the container exits.
    let status = tillandsias_podman::podman_cmd_sync()
        .arg("run")
        .args(&run_args)
        .status();

    println!();

    match status {
        Ok(s) => {
            println!("Environment stopped.");
            s.success()
        }
        Err(e) => {
            eprintln!("Error: failed to run podman: {e}");
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
