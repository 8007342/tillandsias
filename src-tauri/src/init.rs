//! `tillandsias --init` — pre-build all container images.
//!
//! Builds proxy, forge, git, and inference images so they're ready
//! before the user opens the tray. Uses the build lock to coordinate.
//!
//! @trace spec:init-command, spec:proxy-container, spec:git-mirror-service, spec:inference-container

use crate::build_lock;
use crate::embedded;
use crate::handlers::{
    forge_image_tag, git_image_tag, inference_image_tag, proxy_image_tag, prune_old_images,
};
use crate::i18n;
use crate::image_builder::ImageBuilder;
use crate::strings;

/// All image types to build, in order.
/// Proxy first (foundation), then forge (main), then git + inference.
const IMAGE_TYPES: &[(&str, fn() -> String)] = &[
    ("proxy", proxy_image_tag),
    ("forge", forge_image_tag),
    ("git", git_image_tag),
    ("inference", inference_image_tag),
];

/// Run the init command. When `force` is true, rebuild even if images exist.
pub fn run_with_force(force: bool) -> bool {
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

    // Image builds are driven directly from Rust via ImageBuilder
    // @trace spec:direct-podman-calls

    let mut all_success = true;

    for (image_name, tag_fn) in IMAGE_TYPES {
        let tag = tag_fn();

        // Remove existing image if force-rebuilding
        if force && image_exists(&tag) {
            let _ = tillandsias_podman::podman_cmd_sync()
                .args(["rmi", "--force", &tag])
                .output();
        }

        println!("  {}", i18n::tf("init.build.building", &[("name", image_name)]));

        // Acquire build lock for this image type
        if build_lock::is_running(image_name) {
            println!("    {}", i18n::t("init.build.waiting_for_build"));
            if let Err(e) = build_lock::wait_for_build(image_name) {
                eprintln!("    [internal] Wait timed out: {e}");
                all_success = false;
                continue;
            }
            if image_exists(&tag) {
                println!("  {}", i18n::tf("init.build.image_ready", &[("name", image_name), ("tag", &tag)]));
                continue;
            }
        }

        let _ = build_lock::acquire(image_name);

        // Build using ImageBuilder (direct podman, no bash script intermediary)
        // @trace spec:direct-podman-calls
        let builder = ImageBuilder::new(source_dir.clone(), image_name.to_string(), tag.clone());
        let build_result = builder.build_image();

        build_lock::release(image_name);

        match build_result {
            Ok(()) => {
                println!("  {}", i18n::tf("init.build.build_success", &[("name", image_name), ("tag", &tag)]));
            }
            Err(e) => {
                eprintln!(
                    "  {}",
                    i18n::tf("init.build.build_error", &[("name", image_name), ("error", &e)])
                );
                all_success = false;
            }
        }
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

    // Tools overlay tombstoned — agents (claude, opencode, openspec) are
    // hard-installed in the forge image at /usr/local/bin/. No overlay build
    // required during --init.
    // @trace spec:tombstone-tools-overlay, spec:init-command

    // @trace spec:enclave-network, spec:init-command
    if all_success {
        println!();
        println!("  {}", i18n::t("init.build.enclave_title"));
        println!("  {}", i18n::t("init.build.proxy_desc"));
        println!("  {}", i18n::t("init.build.forge_desc"));
        println!("  {}", i18n::t("init.build.git_desc"));
        println!("  {}", i18n::t("init.build.inference_desc"));
    }

    println!();
    if all_success {
        println!("{}", i18n::t("init.ready_run"));
    } else {
        eprintln!("  {}", i18n::t("init.build.some_failed"));
    }
    all_success
}

/// Entry point for `tillandsias --init` (no --force).
#[allow(dead_code)] // CLI entry point — called from main when --init has no --force flag
pub fn run() -> bool {
    run_with_force(false)
}

/// Build the forge image without the init banner/flow.
/// Used by --github-login to build inline before running the auth script.
#[allow(dead_code)] // API surface — used by --github-login CLI path
pub fn run_build_only() -> Result<(), String> {
    let source_dir = embedded::write_image_sources().map_err(|e| {
        eprintln!("  [internal] Failed to extract embedded image sources: {e}");
        strings::SETUP_ERROR
    })?;

    let tag = forge_image_tag();

    // Build using ImageBuilder (direct podman, no bash script intermediary)
    // @trace spec:direct-podman-calls, spec:init-command
    let builder = ImageBuilder::new(source_dir.clone(), "forge".to_string(), tag);
    builder.build_image()?;

    embedded::cleanup_image_sources();
    prune_old_images();
    Ok(())
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
