//! `tillandsias --update` implementation.
//!
//! Fetches the latest version from the configured update endpoint, compares it
//! against the current binary version, and applies the update if one is
//! available. Runs entirely in a blocking context — the Tauri event loop is
//! never constructed.
//!
//! # Update endpoint
//!
//! The endpoint is the same one configured in `tauri.conf.json` for the
//! background auto-updater:
//!   `https://github.com/8007342/tillandsias/releases/latest/download/latest.json`
//!
//! # latest.json shape
//!
//! Tauri's GitHub release provider produces a `latest.json` with at least:
//! ```json
//! {
//!   "version": "0.1.46.28",
//!   "platforms": {
//!     "linux-x86_64": {
//!       "url": "https://github.com/…/Tillandsias_0.1.46.28_amd64.AppImage.tar.gz",
//!       "signature": "…"
//!     }
//!   }
//! }
//! ```
//!
//! # Update mechanism
//!
//! For AppImage installs the update is applied by:
//! 1. Detecting the running AppImage path via `$APPIMAGE` env var.
//! 2. Downloading the `.AppImage.tar.gz` with `curl`.
//! 3. Extracting the new AppImage alongside the current one.
//! 4. Atomically replacing the current AppImage with the new one.
//!
//! If `$APPIMAGE` is not set the binary is not an AppImage and the download
//! step is skipped after a clear message to the user.

use std::path::PathBuf;

use serde::Deserialize;

/// The update manifest endpoint. Mirrors `tauri.conf.json` plugins.updater.endpoints[0].
const UPDATE_ENDPOINT: &str =
    "https://github.com/8007342/tillandsias/releases/latest/download/latest.json";

/// Current version, baked in at compile time from Cargo.toml.
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

// ---------------------------------------------------------------------------
// JSON shapes
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct LatestJson {
    version: String,
    platforms: std::collections::HashMap<String, PlatformEntry>,
}

#[derive(Debug, Deserialize)]
struct PlatformEntry {
    url: String,
    #[allow(dead_code)]
    signature: String,
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Run the `--update` CLI command. Returns `true` on success (up-to-date or
/// update applied), `false` on error.
pub fn run() -> bool {
    println!("  Tillandsias v{CURRENT_VERSION}");
    println!("  Checking for updates...");
    println!("  Endpoint: {UPDATE_ENDPOINT}");

    // Fetch latest.json
    let json_text = match fetch_url(UPDATE_ENDPOINT) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("  Error: failed to fetch update manifest: {e}");
            return false;
        }
    };

    // Parse
    let manifest: LatestJson = match serde_json::from_str(&json_text) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("  Error: failed to parse update manifest: {e}");
            return false;
        }
    };

    let latest = manifest.version.trim_start_matches('v');
    let current = CURRENT_VERSION.trim_start_matches('v');

    if !is_newer(latest, current) {
        println!("  Already up to date.");
        return true;
    }

    println!("  Update available: v{latest}");

    // Detect platform key (Tauri uses "linux-x86_64", "darwin-x86_64", etc.)
    let platform_key = detect_platform_key();
    let entry = match manifest.platforms.get(&platform_key) {
        Some(e) => e,
        None => {
            eprintln!(
                "  Error: no update artifact found for platform '{platform_key}' in manifest"
            );
            eprintln!("  Available platforms: {:?}", manifest.platforms.keys().collect::<Vec<_>>());
            return false;
        }
    };

    // Detect whether we are running as an AppImage
    let appimage_path = std::env::var("APPIMAGE").ok().map(PathBuf::from);
    if appimage_path.is_none() {
        println!("  Note: $APPIMAGE is not set — not running as an AppImage.");
        println!("  Download the new version manually from:");
        println!("    {}", entry.url);
        // Still report success: the check itself succeeded.
        return true;
    }
    let appimage_path = appimage_path.unwrap();

    // Download the update archive
    println!("  Downloading...");
    let archive_path = match download_update(&entry.url) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  Error: download failed: {e}");
            return false;
        }
    };
    let archive_size = std::fs::metadata(&archive_path)
        .map(|m| m.len())
        .unwrap_or(0);
    println!("  Downloaded ({})", human_bytes(archive_size));

    // Extract and replace
    println!("  Applying update...");
    if let Err(e) = apply_appimage_update(&archive_path, &appimage_path) {
        eprintln!("  Error: failed to apply update: {e}");
        // Clean up temp archive
        let _ = std::fs::remove_file(&archive_path);
        return false;
    }

    // Clean up temp archive
    let _ = std::fs::remove_file(&archive_path);

    println!("  Updated to v{latest}");
    println!("  Restart the application to use the new version.");
    true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Fetch a URL with curl and return the body as a String.
fn fetch_url(url: &str) -> Result<String, String> {
    let output = std::process::Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--fail",
            "--location", // follow redirects
            "--max-time",
            "30",
            url,
        ])
        .output()
        .map_err(|e| format!("curl not found or failed to spawn: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("curl error: {stderr}"));
    }

    String::from_utf8(output.stdout).map_err(|e| format!("response is not valid UTF-8: {e}"))
}

/// Download a URL to a temporary file and return its path.
fn download_update(url: &str) -> Result<PathBuf, String> {
    let tmp = std::env::temp_dir().join("tillandsias-update.tar.gz");

    let status = std::process::Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--fail",
            "--location",
            "--progress-bar",
            "--output",
            tmp.to_str().unwrap_or("/tmp/tillandsias-update.tar.gz"),
            url,
        ])
        .status()
        .map_err(|e| format!("curl not found or failed to spawn: {e}"))?;

    if !status.success() {
        return Err("curl exited with non-zero status".to_string());
    }

    Ok(tmp)
}

/// Extract a `.AppImage.tar.gz` archive and atomically replace the running
/// AppImage binary.
///
/// The archive is expected to contain a single `.AppImage` file at its root.
fn apply_appimage_update(
    archive_path: &std::path::Path,
    appimage_path: &std::path::Path,
) -> Result<(), String> {
    let tmp_dir = std::env::temp_dir().join("tillandsias-update-extract");
    let _ = std::fs::remove_dir_all(&tmp_dir);
    std::fs::create_dir_all(&tmp_dir)
        .map_err(|e| format!("failed to create temp extract dir: {e}"))?;

    // Extract
    let status = std::process::Command::new("tar")
        .args([
            "--extract",
            "--gzip",
            "--file",
            archive_path.to_str().unwrap_or(""),
            "--directory",
            tmp_dir.to_str().unwrap_or(""),
        ])
        .status()
        .map_err(|e| format!("tar not found or failed to spawn: {e}"))?;

    if !status.success() {
        return Err("tar extraction failed".to_string());
    }

    // Find the extracted .AppImage file
    let new_appimage = find_appimage_in_dir(&tmp_dir)?;

    // Make it executable
    use std::os::unix::fs::PermissionsExt;
    let mut perms = std::fs::metadata(&new_appimage)
        .map_err(|e| format!("cannot stat extracted AppImage: {e}"))?
        .permissions();
    perms.set_mode(0o755);
    std::fs::set_permissions(&new_appimage, perms)
        .map_err(|e| format!("cannot chmod extracted AppImage: {e}"))?;

    // Atomic replace: rename new AppImage over the current one.
    // On Linux this is atomic at the filesystem level when src and dst are
    // on the same filesystem — which they are if $APPIMAGE is in $HOME and
    // /tmp is also on the same mount. If not, we fall back to copy+replace.
    if std::fs::rename(&new_appimage, appimage_path).is_err() {
        // Cross-device fallback: copy then rename via a sibling temp file.
        let sibling = appimage_path.with_extension("update-tmp");
        std::fs::copy(&new_appimage, &sibling)
            .map_err(|e| format!("failed to copy new AppImage: {e}"))?;
        std::fs::rename(&sibling, appimage_path)
            .map_err(|e| format!("failed to replace AppImage: {e}"))?;
    }

    // Clean up extract dir
    let _ = std::fs::remove_dir_all(&tmp_dir);

    Ok(())
}

/// Walk a directory and return the path of the first `.AppImage` file found.
fn find_appimage_in_dir(dir: &std::path::Path) -> Result<PathBuf, String> {
    for entry in std::fs::read_dir(dir)
        .map_err(|e| format!("cannot read extract dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("directory read error: {e}"))?;
        let path = entry.path();
        if path
            .extension()
            .map(|ext| ext.eq_ignore_ascii_case("AppImage"))
            .unwrap_or(false)
        {
            return Ok(path);
        }
        // Recurse one level (some archives nest files in a subdirectory)
        if path.is_dir() {
            if let Ok(inner) = find_appimage_in_dir(&path) {
                return Ok(inner);
            }
        }
    }
    Err("no .AppImage file found in update archive".to_string())
}

/// Detect the Tauri platform key for this binary (e.g. "linux-x86_64").
fn detect_platform_key() -> String {
    let os = if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        "unknown"
    };

    let arch = if cfg!(target_arch = "x86_64") {
        "x86_64"
    } else if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "x86_64"
    };

    format!("{os}-{arch}")
}

/// Compare two semver-like version strings. Returns `true` if `a` is strictly
/// newer than `b`. Handles the 4-part `Major.Minor.Change.Build` scheme used
/// by Tillandsias as well as standard 3-part semver.
fn is_newer(a: &str, b: &str) -> bool {
    let parse = |s: &str| -> Vec<u64> {
        s.split('.').filter_map(|p| p.parse().ok()).collect()
    };
    let va = parse(a);
    let vb = parse(b);
    va > vb
}

/// Human-readable byte count.
fn human_bytes(bytes: u64) -> String {
    const GB: u64 = 1_073_741_824;
    const MB: u64 = 1_048_576;
    const KB: u64 = 1_024;
    if bytes >= GB {
        format!("{:.1} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.1} KB", bytes as f64 / KB as f64)
    } else {
        format!("{bytes} B")
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_newer_detects_newer_version() {
        assert!(is_newer("0.1.46.28", "0.1.45.27"));
        assert!(is_newer("0.2.0.0", "0.1.99.99"));
        assert!(is_newer("1.0.0.0", "0.9.9.9"));
    }

    #[test]
    fn is_newer_same_version_is_not_newer() {
        assert!(!is_newer("0.1.45.27", "0.1.45.27"));
    }

    #[test]
    fn is_newer_older_version_is_not_newer() {
        assert!(!is_newer("0.1.44.26", "0.1.45.27"));
    }

    #[test]
    fn is_newer_three_part_semver() {
        assert!(is_newer("0.2.0", "0.1.99"));
        assert!(!is_newer("0.1.0", "0.1.0"));
    }

    #[test]
    fn detect_platform_key_returns_known_os() {
        let key = detect_platform_key();
        assert!(
            key.starts_with("linux") || key.starts_with("darwin") || key.starts_with("windows"),
            "unexpected platform key: {key}"
        );
    }
}
