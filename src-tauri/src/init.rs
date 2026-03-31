//! `tillandsias --init` — pre-build container images.
//!
//! Builds the forge image (and any other standard images) so they're ready
//! before the user opens the tray. Uses the build lock to coordinate with
//! other processes (tray app, other init invocations).
//!
//! @trace spec:init-command

use crate::build_lock;
use crate::embedded;
use crate::handlers::{forge_image_tag, prune_old_forge_images};
use crate::i18n;
use crate::strings;

/// Run the init command. Returns true on success.
pub fn run() -> bool {
    println!("{}", i18n::t("init.preparing"));
    println!();

    let tag = forge_image_tag();

    // Check if forge image already exists
    if image_exists(&tag) {
        println!("  {}", i18n::t("init.already_ready"));
        println!();
        println!("{}", i18n::t("init.ready"));
        return true;
    }

    // Check if another build is running
    if build_lock::is_running("forge") {
        println!("  {}", i18n::t("init.setup_in_progress"));
        if let Err(e) = build_lock::wait_for_build("forge") {
            eprintln!("  [internal] Wait timed out: {e}");
            eprintln!("  {}", i18n::t("init.setup_timed_out"));
            return false;
        }
        if image_exists(&tag) {
            println!("  {}", i18n::t("init.env_ready"));
            println!();
            println!("{}", i18n::t("init.ready"));
            return true;
        }
        // Build finished but image still missing — fall through to build
    }

    // Acquire lock and build
    if let Err(e) = build_lock::acquire("forge") {
        // Another process grabbed the lock between our check and acquire — wait
        eprintln!("  [internal] Acquire failed: {e}");
        println!("  {}", i18n::t("init.waiting"));
        if let Err(e) = build_lock::wait_for_build("forge") {
            eprintln!("  [internal] Wait timed out: {e}");
            eprintln!("  {}", i18n::t("init.setup_timed_out"));
            return false;
        }
        if image_exists(&tag) {
            println!("  {}", i18n::t("init.env_ready"));
            return true;
        }
    }

    println!("  {}", i18n::t("init.setting_up"));
    println!("  {}", i18n::t("init.first_run_note"));
    println!();

    let result = build_forge_image();

    // Always release the lock
    build_lock::release("forge");

    match result {
        Ok(()) => {
            println!();
            println!("  {}", i18n::t("init.dev_env_ready"));
            println!();
            println!("{}", i18n::t("init.ready_run"));
            true
        }
        Err(e) => {
            eprintln!();
            eprintln!("  {}", i18n::tf("init.setup_failed", &[("error", &e)]));
            false
        }
    }
}

/// Build the forge image using the embedded build-image.sh script.
fn build_forge_image() -> Result<(), String> {
    let source_dir = embedded::write_image_sources().map_err(|e| {
        eprintln!("  [internal] Failed to extract embedded image sources: {e}");
        strings::SETUP_ERROR
    })?;

    let script = source_dir.join("scripts").join("build-image.sh");
    let tag = forge_image_tag();

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

    embedded::cleanup_image_sources();

    if status.success() {
        // Prune older versioned forge images to reclaim disk space
        prune_old_forge_images(&tag);
        Ok(())
    } else {
        eprintln!(
            "  [internal] Build script exited with code {}",
            status.code().unwrap_or(-1)
        );
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
