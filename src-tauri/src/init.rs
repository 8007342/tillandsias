//! `tillandsias init` — pre-build container images.
//!
//! Builds the forge image (and any other standard images) so they're ready
//! before the user opens the tray. Uses the build lock to coordinate with
//! other processes (tray app, other init invocations).

use crate::build_lock;
use crate::embedded;

const FORGE_IMAGE: &str = "tillandsias-forge:latest";

/// Run the init command. Returns true on success.
pub fn run() -> bool {
    println!("Tillandsias init — preparing development environment");
    println!();

    // Check if forge image already exists
    if image_exists(FORGE_IMAGE) {
        println!("  ✓ Development environment already ready");
        println!();
        println!("Ready.");
        return true;
    }

    // Check if another build is running
    if build_lock::is_running("forge") {
        println!("  ⏳ Setup already in progress, waiting...");
        if let Err(e) = build_lock::wait_for_build("forge") {
            eprintln!("  [internal] Wait timed out: {e}");
            eprintln!("  ✗ Setup timed out. If this persists, please reinstall from https://github.com/8007342/tillandsias");
            return false;
        }
        if image_exists(FORGE_IMAGE) {
            println!("  ✓ Environment ready");
            println!();
            println!("Ready.");
            return true;
        }
        // Build finished but image still missing — fall through to build
    }

    // Acquire lock and build
    if let Err(e) = build_lock::acquire("forge") {
        // Another process grabbed the lock between our check and acquire — wait
        eprintln!("  [internal] Acquire failed: {e}");
        println!("  ⏳ Waiting for setup to complete...");
        if let Err(e) = build_lock::wait_for_build("forge") {
            eprintln!("  [internal] Wait timed out: {e}");
            eprintln!("  ✗ Setup timed out. If this persists, please reinstall from https://github.com/8007342/tillandsias");
            return false;
        }
        if image_exists(FORGE_IMAGE) {
            println!("  ✓ Environment ready");
            return true;
        }
    }

    println!("  Setting up development environment...");
    println!("  (This may take a few minutes on first run)");
    println!();

    let result = build_forge_image();

    // Always release the lock
    build_lock::release("forge");

    match result {
        Ok(()) => {
            println!();
            println!("  ✓ Development environment ready");
            println!();
            println!("Ready. Run: tillandsias");
            true
        }
        Err(e) => {
            eprintln!();
            eprintln!("  ✗ Setup failed: {e}");
            false
        }
    }
}

/// Build the forge image using the embedded build-image.sh script.
fn build_forge_image() -> Result<(), String> {
    let source_dir = embedded::write_image_sources()
        .map_err(|e| {
            eprintln!("  [internal] Failed to extract embedded image sources: {e}");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    let script = source_dir.join("scripts").join("build-image.sh");

    let status = std::process::Command::new(&script)
        .arg("forge")
        .current_dir(&source_dir)
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .map_err(|e| {
            eprintln!("  [internal] Failed to launch build script: {e}");
            "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias"
        })?;

    embedded::cleanup_image_sources();

    if status.success() {
        Ok(())
    } else {
        eprintln!("  [internal] Build script exited with code {}", status.code().unwrap_or(-1));
        Err("Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias".into())
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
