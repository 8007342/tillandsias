//! CLI container runner with user-friendly output.
//!
//! Launched when the user runs `tillandsias <path>`. Checks/builds the
//! image, prints formatted progress, then execs `podman run -it --rm`
//! with inherited stdio so the container terminal passes through.

use std::path::{Path, PathBuf};

use tillandsias_core::config::{cache_dir, data_dir, load_global_config, load_project_config, GlobalConfig};
use tillandsias_core::genus::TillandsiaGenus;
use tillandsias_core::state::ContainerInfo;
use tillandsias_podman::PodmanClient;

/// Map a short image name to a full image tag.
fn image_tag(name: &str) -> String {
    // If the name already contains a colon or slash, treat it as a full tag.
    if name.contains(':') || name.contains('/') {
        name.to_string()
    } else {
        format!("tillandsias-{name}:latest")
    }
}

/// Resolve the image source directory for building.
///
/// Checks (in order):
/// 1. `images/<name>/` relative to the executable
/// 2. `~/.local/share/tillandsias/images/<name>/`
fn resolve_image_source(name: &str) -> Option<PathBuf> {
    // Relative to executable (dev builds, bundled installs)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let candidate = exe_dir.join("images").join(name);
            if candidate.join("Containerfile").exists() {
                return Some(candidate);
            }
            // Two levels up for target/debug/ layout
            if let Some(root) = exe_dir.parent().and_then(|p| p.parent()) {
                let candidate = root.join("images").join(name);
                if candidate.join("Containerfile").exists() {
                    return Some(candidate);
                }
            }
        }
    }

    // Installed data directory
    let data = data_dir().join("images").join(name);
    if data.join("Containerfile").exists() {
        return Some(data);
    }

    None
}

/// Get the image size in human-readable form via `podman image inspect`.
fn image_size_display(tag: &str) -> String {
    let output = std::process::Command::new("podman")
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
    let mut args = Vec::new();

    // Interactive + ephemeral
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

    // Volume mounts
    let project_mount = format!("{}:/home/forge/src", project_path.display());
    args.push("-v".to_string());
    args.push(project_mount);

    let cache_mount = format!("{}:/home/forge/.cache/tillandsias", cache.display());
    args.push("-v".to_string());
    args.push(cache_mount);

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
/// Returns `true` on success, `false` on failure.
pub fn run(path: PathBuf, image_name: &str, debug: bool) -> bool {
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

    let image_exists = rt.block_on(client.image_exists(&tag));

    if image_exists {
        let size = image_size_display(&tag);
        println!("  \u{2713} Image cached ({size})");
    } else {
        // Try to build the image from source
        let source_name = if image_name.contains(':') || image_name.contains('/') {
            "default"
        } else {
            image_name
        };

        let image_source = resolve_image_source(source_name)
            .or_else(|| resolve_image_source("default"));

        match image_source {
            Some(source_dir) => {
                println!("  Building image... (this takes ~60s on first run)");

                let containerfile = source_dir.join("Containerfile");
                let containerfile_str = containerfile.to_string_lossy().to_string();
                let context_str = source_dir.to_string_lossy().to_string();

                if debug {
                    println!("  [debug] Containerfile: {containerfile_str}");
                    println!("  [debug] Context: {context_str}");
                }

                let build_result = rt.block_on(
                    client.build_image(&containerfile_str, &tag, &context_str),
                );

                match build_result {
                    Ok(()) => {
                        let size = image_size_display(&tag);
                        println!("  \u{2713} Image built ({size})");
                    }
                    Err(e) => {
                        eprintln!("  \u{2717} Image build failed: {e}");
                        return false;
                    }
                }
            }
            None => {
                eprintln!("  \u{2717} Image not found and no Containerfile available to build it");
                eprintln!();
                eprintln!("  Expected: images/{source_name}/Containerfile");
                eprintln!("       or:  ~/.local/share/tillandsias/images/{source_name}/Containerfile");
                return false;
            }
        }
    }

    // Load config for port range
    let global_config = load_global_config();
    let project_config = load_project_config(&project_path);
    let resolved = global_config.merge_with_project(&project_config);
    let base_port = GlobalConfig::parse_port_range(&resolved.port_range)
        .unwrap_or((3000, 3099));

    // Use Aeranthos genus for CLI mode (no allocator needed)
    let genus = TillandsiaGenus::Aeranthos;
    let container_name = ContainerInfo::container_name(&project_name, genus);

    // Ensure cache directory exists
    let cache = cache_dir();
    std::fs::create_dir_all(&cache).ok();

    let run_args = build_run_args(
        &container_name,
        &tag,
        &project_path,
        &cache,
        base_port,
    );

    println!();
    println!("Starting environment...");
    println!("  Name:   {container_name}");
    println!(
        "  Ports:  {}-{}",
        base_port.0, base_port.1
    );
    println!("  Mount:  {display_path} \u{2192} /home/forge/src");
    println!(
        "  Cache:  {}",
        tilde_path(&cache)
    );

    if debug {
        println!();
        println!("  [debug] podman run {}", run_args.join(" "));
    }

    println!();
    println!("Launching... (Ctrl+C to stop)");
    println!();

    // Execute podman with inherited stdio — terminal passes through.
    // Using .status() blocks until the container exits.
    let status = std::process::Command::new("podman")
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
    if let Some(home) = dirs::home_dir() {
        if let Ok(suffix) = path.strip_prefix(&home) {
            return format!("~/{}", suffix.display());
        }
    }
    path.display().to_string()
}
