//! `tillandsias --init` — pre-build all container images.
//!
//! Builds proxy, forge, git, and inference images so they're ready
//! before the user opens the tray. Uses the build lock to coordinate.
//!
//! @trace spec:init-command, spec:proxy-container, spec:git-mirror-service, spec:inference-container, spec:init-incremental-builds

use serde::{Deserialize, Serialize};

use crate::build_lock;
use crate::embedded;
use crate::handlers::{
    chromium_core_image_tag, chromium_framework_image_tag, forge_image_tag, git_image_tag,
    inference_image_tag, proxy_image_tag, prune_old_images,
};
use crate::i18n;
use crate::strings;

/// State file for tracking init build progress across runs.
/// @trace spec:init-incremental-builds
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct ImageBuildStatus {
    status: String, // "success", "failed", "pending"
    tag: String,
    log_path: Option<String>,
}

/// Top-level state for init builds.
/// @trace spec:init-incremental-builds
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct InitBuildState {
    version: String,
    last_run: String,
    images: std::collections::HashMap<String, ImageBuildStatus>,
}

/// Load build state from cache file. Returns default state if file doesn't exist or is invalid.
/// @trace spec:init-incremental-builds
fn load_build_state() -> InitBuildState {
    let cache_dir = dirs::cache_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("tillandsias");
    let state_file = cache_dir.join("init-build-state.json");

    if !state_file.exists() {
        return InitBuildState::default();
    }

    match std::fs::read_to_string(&state_file) {
        Ok(contents) => match serde_json::from_str::<InitBuildState>(&contents) {
            Ok(state) => state,
            Err(e) => {
                eprintln!("  [init] Warning: Failed to parse state file: {e}");
                InitBuildState::default()
            }
        },
        Err(_) => InitBuildState::default(),
    }
}

/// Save build state to cache file atomically (write to temp, then rename).
/// @trace spec:init-incremental-builds
fn save_build_state(state: &InitBuildState) {
    let cache_dir = dirs::cache_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("tillandsias");
    let _ = std::fs::create_dir_all(&cache_dir);

    let state_file = cache_dir.join("init-build-state.json");
    let temp_file = cache_dir.join("init-build-state.json.tmp");

    match serde_json::to_string_pretty(state) {
        Ok(json) => {
            if let Err(e) = std::fs::write(&temp_file, json) {
                eprintln!("  [init] Warning: Failed to write temp state: {e}");
                return;
            }
            if let Err(e) = std::fs::rename(&temp_file, &state_file) {
                eprintln!("  [init] Warning: Failed to save state file: {e}");
            }
        }
        Err(e) => {
            eprintln!("  [init] Warning: Failed to serialize state: {e}");
        }
    }
}

/// Update a single image's status in the build state.
/// @trace spec:init-incremental-builds
fn update_image_status(
    state: &mut InitBuildState,
    image_name: &str,
    tag: &str,
    status: &str,
    log_path: Option<String>,
) {
    use std::collections::hash_map::Entry;
    match state.images.entry(image_name.to_string()) {
        Entry::Occupied(mut entry) => {
            entry.get_mut().status = status.to_string();
            entry.get_mut().tag = tag.to_string();
            entry.get_mut().log_path = log_path;
        }
        Entry::Vacant(entry) => {
            entry.insert(ImageBuildStatus {
                status: status.to_string(),
                tag: tag.to_string(),
                log_path,
            });
        }
    }
    state.last_run = format!(
        "{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    );
    state.version = env!("TILLANDSIAS_FULL_VERSION").to_string();
}

/// All image types to build, in order.
/// Proxy first (foundation), then forge (main), then git + inference,
/// then browser containers for OpenCode Web isolation.
/// @trace spec:init-incremental-builds, spec:browser-isolation-core
type ImageDef = (&'static str, fn() -> String);
const IMAGE_TYPES: &[ImageDef] = &[
    ("proxy", proxy_image_tag),
    ("forge", forge_image_tag),
    ("git", git_image_tag),
    ("inference", inference_image_tag),
    ("chromium-core", chromium_core_image_tag),
    ("chromium-framework", chromium_framework_image_tag),
];

/// Run the init command. When `force` is true, rebuild even if images exist.
/// When `debug` is true, capture build logs and display failed build tails.
/// @trace spec:init-incremental-builds
pub fn run_with_force(force: bool, debug: bool) -> bool {
    println!("{}", i18n::t("init.preparing"));
    println!();

    // On macOS/Windows, podman requires a VM (podman machine).
    // Init and start it before any image builds.
    // @trace spec:podman-orchestration
    if tillandsias_core::state::Os::detect().needs_podman_machine() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime for podman machine");
        let client = tillandsias_podman::PodmanClient::new();

        if !rt.block_on(client.has_machine()) {
            println!("  Initializing container runtime...");
            rt.block_on(client.init_machine());
        }
        if !rt.block_on(client.is_machine_running()) {
            println!("  Starting container runtime...");
            if !rt.block_on(client.start_machine()) {
                eprintln!("  \u{2717} Container runtime failed to start.");
                eprintln!("  Try manually: podman machine init && podman machine start");
                return false;
            }
            // Wait for API to be ready
            rt.block_on(client.wait_for_ready(10));
        }
    }

    // Always invoke the build script for each image — it handles staleness
    // internally via hash check and exits fast when up to date.
    // @trace spec:forge-staleness
    println!("  {}", i18n::t("init.setting_up"));
    println!("  {}", i18n::t("init.first_run_note"));
    println!();

    let source_dir = match embedded::write_image_sources() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("  [internal] Failed to extract embedded image sources: {e}");
            return false;
        }
    };

    let script = source_dir.join("scripts").join("build-image.sh");
    if !script.exists() {
        eprintln!("  [internal] Script not found at: {}", script.display());
        return false;
    }

    // Load build state for incremental builds
    // @trace spec:init-incremental-builds
    let mut build_state = load_build_state();
    let mut all_success = true;
    let mut failed_logs: Vec<(String, String)> = Vec::new();

    for (image_name, tag_fn) in IMAGE_TYPES {
        let tag = tag_fn();

        // Check if image was already built successfully (incremental build)
        // @trace spec:init-incremental-builds
        if !force
            && let Some(status) = build_state.images.get(*image_name)
            && status.status == "success"
            && image_exists(&tag)
        {
            println!(
                "  {}",
                i18n::tf(
                    "init.build.skipping",
                    &[("name", image_name), ("tag", &tag)]
                )
            );
            continue;
        }

        // Remove existing image if force-rebuilding
        if force && image_exists(&tag) {
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rmi", "--force", &tag])
                .output();
        }

        println!(
            "  {}",
            i18n::tf("init.build.building", &[("name", image_name)])
        );

        // Acquire build lock for this image type
        if build_lock::is_running(image_name) {
            println!("    {}", i18n::t("init.build.waiting_for_build"));
            if let Err(e) = build_lock::wait_for_build(image_name) {
                eprintln!("    [internal] Wait timed out: {e}");
                all_success = false;
                update_image_status(&mut build_state, image_name, &tag, "failed", None);
                save_build_state(&build_state);
                continue;
            }
            if image_exists(&tag) {
                println!(
                    "  {}",
                    i18n::tf(
                        "init.build.image_ready",
                        &[("name", image_name), ("tag", &tag)]
                    )
                );
                update_image_status(&mut build_state, image_name, &tag, "success", None);
                save_build_state(&build_state);
                continue;
            }
        }

        let _ = build_lock::acquire(image_name);

        // Build with inherited stdio so the user sees progress
        // In debug mode, capture output to log file using tee
        // @trace spec:init-command, spec:init-incremental-builds
        let log_path = if debug {
            Some(format!("/tmp/tillandsias-init-{image_name}.log"))
        } else {
            None
        };

        #[cfg(not(target_os = "windows"))]
        let status = if debug {
            let log = log_path.as_ref().unwrap();
            let cmd = format!(
                "{} {} --tag {} --backend fedora 2>&1 | tee {}",
                script.display(),
                image_name,
                tag,
                log
            );
            std::process::Command::new("bash")
                .arg("-c")
                .arg(&cmd)
                .current_dir(&source_dir)
                .env_remove("LD_LIBRARY_PATH")
                .env_remove("LD_PRELOAD")
                .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
                .stdin(std::process::Stdio::inherit())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status()
        } else {
            std::process::Command::new(&script)
                .arg(*image_name)
                .args(["--tag", &tag, "--backend", "fedora"])
                .current_dir(&source_dir)
                .env_remove("LD_LIBRARY_PATH")
                .env_remove("LD_PRELOAD")
                .env("PODMAN_PATH", tillandsias_podman::find_podman_path())
                .stdin(std::process::Stdio::inherit())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status()
        };

        #[cfg(target_os = "windows")]
        let status = {
            let image_dir = match *image_name {
                "proxy" => "proxy",
                "git" => "git",
                "inference" => "inference",
                _ => "default",
            };
            let containerfile = source_dir
                .join("images")
                .join(image_dir)
                .join("Containerfile");
            let context_dir = source_dir.join("images").join(image_dir);

            tillandsias_podman::podman_cmd_sync()
                .args(["build", "--tag", &tag, "-f"])
                .arg(&containerfile)
                .arg(&context_dir)
                .stdin(std::process::Stdio::inherit())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status()
        };

        build_lock::release(image_name);

        match status {
            Ok(s) if s.success() => {
                println!(
                    "  {}",
                    i18n::tf(
                        "init.build.build_success",
                        &[("name", image_name), ("tag", &tag)]
                    )
                );
                update_image_status(&mut build_state, image_name, &tag, "success", log_path);
                // Prune old images after each successful build
                prune_old_images();
            }
            Ok(s) => {
                eprintln!(
                    "  {}",
                    i18n::tf(
                        "init.build.build_failed",
                        &[
                            ("name", image_name),
                            ("code", &s.code().unwrap_or(-1).to_string()),
                        ]
                    )
                );
                all_success = false;
                update_image_status(
                    &mut build_state,
                    image_name,
                    &tag,
                    "failed",
                    log_path.clone(),
                );
                if let Some(ref log) = log_path {
                    failed_logs.push((image_name.to_string(), log.clone()));
                }
            }
            Err(e) => {
                eprintln!(
                    "  {}",
                    i18n::tf(
                        "init.build.build_error",
                        &[("name", image_name), ("error", &e.to_string())]
                    )
                );
                all_success = false;
                update_image_status(
                    &mut build_state,
                    image_name,
                    &tag,
                    "failed",
                    log_path.clone(),
                );
                if let Some(ref log) = log_path {
                    failed_logs.push((image_name.to_string(), log.clone()));
                }
            }
        }
        save_build_state(&build_state);
    }

    embedded::cleanup_image_sources();

    // Clean up any leftover buildah containers from builds
    // @trace spec:default-image
    let _ = std::process::Command::new("buildah")
        .args(["rm", "--all"])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    // Prune old images after building new ones
    prune_old_images();

    // @tombstone obsolete:layered-tools-overlay
    // Tools overlay build removed during --init — agents are now baked into the forge image.
    // Safe to delete after v0.1.163.
    // Previously: Built tools overlay after forge image ready.
    /*
    if all_success {
        println!();
        println!("  {}", i18n::t("init.build.tools_overlay"));
        // ... tools overlay build logic (removed) ...
    }
    */

    // @trace spec:enclave-network, spec:init-command
    if all_success {
        println!();
        println!("  {}", i18n::t("init.build.enclave_title"));
        println!("  {}", i18n::t("init.build.proxy_desc"));
        println!("  {}", i18n::t("init.build.forge_desc"));
        println!("  {}", i18n::t("init.build.git_desc"));
        println!("  {}", i18n::t("init.build.inference_desc"));
    }

    // Show failed build logs in debug mode
    // @trace spec:init-incremental-builds
    if debug && !failed_logs.is_empty() {
        println!();
        eprintln!("  {}", i18n::t("init.build.failed_logs_header"));
        for (image_name, log_path) in &failed_logs {
            eprintln!(
                "\n  --- Failed build log for {} (last 10 lines) ---",
                image_name
            );
            let _ = std::process::Command::new("tail")
                .args(["-10", log_path])
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status();
        }
    }

    println!();
    if all_success {
        println!("{}", i18n::t("init.ready_run"));
    } else {
        eprintln!("  {}", i18n::t("init.build.some_failed"));
    }
    all_success
}

/// Entry point for `tillandsias --init` (no --force, no debug).
#[allow(dead_code)] // CLI entry point — called from main when --init has no --force flag
pub fn run() -> bool {
    run_with_force(false, false)
}

/// Build the forge image without the init banner/flow.
/// Used by --github-login to build inline before running the auth script.
#[allow(dead_code)] // API surface — used by --github-login CLI path
pub fn run_build_only() -> Result<(), String> {
    let source_dir = embedded::write_image_sources().map_err(|e| {
        eprintln!("  [internal] Failed to extract embedded image sources: {e}");
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = forge_image_tag();

    #[cfg(not(target_os = "windows"))]
    let status = std::process::Command::new(&script)
        .arg("forge")
        .args(["--tag", &tag, "--backend", "fedora"])
        .current_dir(&source_dir)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [internal] Failed to launch build script: {e}");
            strings::SETUP_ERROR
        })?;

    #[cfg(target_os = "windows")]
    let status = {
        let containerfile = source_dir
            .join("images")
            .join("default")
            .join("Containerfile");
        let context_dir = source_dir.join("images").join("default");
        tillandsias_podman::podman_cmd_sync()
            .args(["build", "--tag", &tag, "-f"])
            .arg(&containerfile)
            .arg(&context_dir)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .map_err(|e| {
                eprintln!("  [internal] Failed to launch podman build: {e}");
                strings::SETUP_ERROR
            })?
    };

    embedded::cleanup_image_sources();

    if status.success() {
        prune_old_images();
        Ok(())
    } else {
        Err(strings::SETUP_ERROR.into())
    }
}

/// Check if a podman image exists.
fn image_exists(tag: &str) -> bool {
    tillandsias_podman::podman_cmd_sync()
        .args(["image", "exists", tag])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
