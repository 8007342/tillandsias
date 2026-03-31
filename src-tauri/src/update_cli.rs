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
//! The release workflow generates a `latest.json` with at least:
//! ```json
//! {
//!   "version": "0.1.46",
//!   "platforms": {
//!     "linux-x86_64": {
//!       "url": "https://github.com/…/Tillandsias-linux-x86_64.AppImage",
//!       "signature": "…"
//!     }
//!   }
//! }
//! ```
//!
//! The version field uses 3-part semver (matching `CARGO_PKG_VERSION`) so that
//! version comparison works correctly without false-positive "update available"
//! results.
//!
//! # Update mechanism
//!
//! For AppImage installs the update is applied by:
//! 1. Detecting the running AppImage path via `$APPIMAGE` env var.
//! 2. Downloading the artifact URL via in-process HTTP (`reqwest`).
//! 3. If the URL ends in `.tar.gz`: extract the archive to find the `.AppImage`
//!    inside.  If the URL ends in `.AppImage`: the download IS the new binary —
//!    no extraction step is needed.
//! 4. Making the new AppImage executable and atomically replacing the running
//!    one.
//!
//! If `$APPIMAGE` is not set the binary is not an AppImage and the download
//! step is skipped after a clear message to the user.

use std::io::Write as _;
use std::path::PathBuf;

use serde::Deserialize;
use tillandsias_core::format::human_bytes;

use crate::i18n;
use crate::update_log;

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
    // Install rustls crypto provider before any reqwest calls.
    // Tauri normally does this during its setup, but --update runs before Tauri.
    let _ = rustls::crypto::ring::default_provider().install_default();

    // Rotate the audit log if it has grown too large — do this once at the
    // start of each run so the file never exceeds the threshold by more than
    // one entry.
    update_log::append_entry("---"); // separator between update sessions

    // Show full 4-part version for display, but compare using 3-part below
    const FULL_VERSION: &str = env!("TILLANDSIAS_FULL_VERSION");
    println!(
        "  {}",
        i18n::tf("update.version", &[("version", FULL_VERSION)])
    );
    println!("  {}", i18n::t("update.checking"));

    // Fetch latest.json
    let json_text = match fetch_url(UPDATE_ENDPOINT) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("  Error: failed to fetch update manifest: {e}");
            update_log::append_entry(&format!(
                "ERROR: failed to fetch update manifest: {e}"
            ));
            return false;
        }
    };

    // Parse
    let manifest: LatestJson = match serde_json::from_str(&json_text) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("  Error: failed to parse update manifest: {e}");
            update_log::append_entry(&format!(
                "ERROR: failed to parse update manifest: {e}"
            ));
            return false;
        }
    };

    let latest = manifest.version.trim_start_matches('v');
    let current = CURRENT_VERSION.trim_start_matches('v');

    if !is_newer(latest, current) {
        println!("  {}", i18n::t("update.up_to_date"));
        update_log::append_entry(&format!(
            "UPDATE CHECK: v{current} — already up to date"
        ));
        return true;
    }

    println!("  {}", i18n::tf("update.available", &[("version", latest)]));
    update_log::append_entry(&format!(
        "UPDATE CHECK: v{current} \u{2192} v{latest} available"
    ));

    // Detect platform key (Tauri uses "linux-x86_64", "darwin-x86_64", etc.)
    let platform_key = detect_platform_key();
    let entry = match manifest.platforms.get(&platform_key) {
        Some(e) => e,
        None => {
            eprintln!(
                "  Error: no update artifact found for platform '{platform_key}' in manifest"
            );
            eprintln!(
                "  Available platforms: {:?}",
                manifest.platforms.keys().collect::<Vec<_>>()
            );
            update_log::append_entry(&format!(
                "ERROR: no artifact for platform '{platform_key}'"
            ));
            return false;
        }
    };

    // Detect whether we are running as an AppImage
    let appimage_path = std::env::var("APPIMAGE").ok().map(PathBuf::from);
    if appimage_path.is_none() {
        println!("  Note: $APPIMAGE is not set — not running as an AppImage.");
        println!("  Download the new version manually from:");
        println!("    {}", entry.url);
        update_log::append_entry(&format!(
            "UPDATE CHECK: v{current} \u{2192} v{latest} available (manual download required — not an AppImage)"
        ));
        // Still report success: the check itself succeeded.
        return true;
    }
    let appimage_path = appimage_path.unwrap();

    // Download the update archive
    println!("  {}", i18n::t("update.downloading"));
    let archive_path = match download_update(&entry.url) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("  Error: download failed: {e}");
            update_log::append_entry(&format!("ERROR: download failed: {e}"));
            return false;
        }
    };
    let archive_size = std::fs::metadata(&archive_path)
        .map(|m| m.len())
        .unwrap_or(0);
    println!(
        "  {}",
        i18n::tf("update.downloaded", &[("size", &human_bytes(archive_size))])
    );
    update_log::append_entry(&format!(
        "DOWNLOAD: {} from {}",
        human_bytes(archive_size),
        entry.url
    ));

    // Extract (if tar.gz) or use directly (if raw AppImage), then replace
    println!("  {}", i18n::t("update.applying"));
    if let Err(e) = apply_appimage_update(&archive_path, &appimage_path, &entry.url) {
        eprintln!("  Error: failed to apply update: {e}");
        update_log::append_entry(&format!("ERROR: failed to apply update: {e}"));
        // Clean up temp archive
        let _ = std::fs::remove_file(&archive_path);
        return false;
    }

    // Clean up temp archive
    let _ = std::fs::remove_file(&archive_path);

    // Compute SHA256 of the newly installed binary and log the apply event.
    let sha = update_log::sha256_file(&appimage_path)
        .unwrap_or_else(|_| "(sha256 unavailable)".to_string());
    update_log::append_entry(&format!(
        "APPLIED: v{current} \u{2192} v{latest} (replaced {}) SHA256: {sha}",
        appimage_path.display()
    ));

    println!("  {}", i18n::tf("update.updated", &[("version", latest)]));
    println!("  {}", i18n::t("update.restart_note"));
    true
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Fetch a URL and return the body as a String.
///
/// Uses `reqwest` with rustls so no system `libcurl` or `libnghttp2` is
/// touched — safe to call from inside an AppImage where `LD_LIBRARY_PATH`
/// points at bundled (possibly mismatched) `.so` files.
fn fetch_url(url: &str) -> Result<String, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("failed to build tokio runtime: {e}"))?;

    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| format!("failed to build HTTP client: {e}"))?;

        let response = client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {e}"))?;

        if !response.status().is_success() {
            return Err(format!("HTTP error: {}", response.status()));
        }

        response
            .text()
            .await
            .map_err(|e| format!("failed to read response body: {e}"))
    })
}

/// Download a URL to a temporary file and return its path.
///
/// The temp file is named to match the URL extension (`.AppImage` or
/// `.tar.gz`) so that [`apply_appimage_update`] can detect the format.
///
/// Uses `reqwest` with rustls — no system `libcurl` involved, safe inside
/// an AppImage regardless of `LD_LIBRARY_PATH`.
fn download_update(url: &str) -> Result<PathBuf, String> {
    // Choose a temp filename that preserves the extension so the apply step
    // can determine whether extraction is needed.
    let filename = if url.ends_with(".AppImage") {
        "tillandsias-update.AppImage"
    } else {
        "tillandsias-update.tar.gz"
    };
    let tmp = std::env::temp_dir().join(filename);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("failed to build tokio runtime: {e}"))?;

    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(300)) // large file, generous timeout
            .build()
            .map_err(|e| format!("failed to build HTTP client: {e}"))?;

        let response = client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("HTTP request failed: {e}"))?;

        if !response.status().is_success() {
            return Err(format!("HTTP error: {}", response.status()));
        }

        let bytes = response
            .bytes()
            .await
            .map_err(|e| format!("failed to read response body: {e}"))?;

        let mut file =
            std::fs::File::create(&tmp).map_err(|e| format!("failed to create temp file: {e}"))?;
        file.write_all(&bytes)
            .map_err(|e| format!("failed to write download to disk: {e}"))?;

        Ok(tmp.clone())
    })
}

/// Apply a downloaded AppImage update, replacing the running AppImage binary.
///
/// Two artifact formats are supported, detected by `download_url`:
///
/// - **Raw `.AppImage`** — Tauri v2 Linux: the downloaded file IS the new
///   binary. No extraction needed; just make it executable and replace.
/// - **`.tar.gz` archive** — legacy / macOS-derived path: extract the archive
///   to find the `.AppImage` inside, then replace.
fn apply_appimage_update(
    download_path: &std::path::Path,
    appimage_path: &std::path::Path,
    download_url: &str,
) -> Result<(), String> {
    let new_appimage: PathBuf = if download_url.ends_with(".AppImage") {
        // Raw AppImage — the downloaded file is the replacement binary.
        download_path.to_path_buf()
    } else {
        // tar.gz archive — extract and find the .AppImage inside.
        let tmp_dir = std::env::temp_dir().join("tillandsias-update-extract");
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir)
            .map_err(|e| format!("failed to create temp extract dir: {e}"))?;

        let status = std::process::Command::new("tar")
            .args([
                "--extract",
                "--gzip",
                "--file",
                download_path.to_str().unwrap_or(""),
                "--directory",
                tmp_dir.to_str().unwrap_or(""),
            ])
            .status()
            .map_err(|e| format!("tar not found or failed to spawn: {e}"))?;

        if !status.success() {
            return Err("tar extraction failed".to_string());
        }

        find_appimage_in_dir(&tmp_dir)?
    };

    // Make it executable (Unix only — Windows doesn't need this)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&new_appimage)
            .map_err(|e| format!("cannot stat new AppImage: {e}"))?
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&new_appimage, perms)
            .map_err(|e| format!("cannot chmod new AppImage: {e}"))?;
    }

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

    // Clean up extract dir (only exists for tar.gz path; harmless if absent)
    let _ = std::fs::remove_dir_all(std::env::temp_dir().join("tillandsias-update-extract"));

    Ok(())
}

/// Walk a directory and return the path of the first `.AppImage` file found.
fn find_appimage_in_dir(dir: &std::path::Path) -> Result<PathBuf, String> {
    for entry in std::fs::read_dir(dir).map_err(|e| format!("cannot read extract dir: {e}"))? {
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
///
/// When the two versions have different part counts (e.g., `0.1.65.38` vs
/// `0.1.65`), comparison is limited to the shorter length so that a 4-part
/// remote version with the same semver prefix is NOT considered newer than
/// the 3-part local version. This avoids perpetual "update available" when
/// `CARGO_PKG_VERSION` (3-part) matches the semver base of `latest.json`
/// (4-part).
fn is_newer(a: &str, b: &str) -> bool {
    let parse = |s: &str| -> Vec<u64> { s.split('.').filter_map(|p| p.parse().ok()).collect() };
    let va = parse(a);
    let vb = parse(b);
    let len = va.len().min(vb.len());
    // Compare only the shared prefix (typically Major.Minor.Change)
    va[..len] > vb[..len]
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
    fn is_newer_four_part_vs_three_part_same_base_is_not_newer() {
        // 4-part remote with same semver prefix as 3-part local → NOT newer.
        // This is the critical fix: CARGO_PKG_VERSION is 3-part, latest.json
        // version is 4-part. Without prefix comparison, the updater would
        // always report an update available.
        assert!(!is_newer("0.1.65.38", "0.1.65"));
        assert!(!is_newer("0.1.65.0", "0.1.65"));
    }

    #[test]
    fn is_newer_four_part_vs_three_part_higher_base_is_newer() {
        assert!(is_newer("0.2.0.1", "0.1.65"));
        assert!(is_newer("0.1.66.1", "0.1.65"));
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
