//! AppImage desktop integration.
//!
//! When running as an AppImage (`$APPIMAGE` is set), self-install a `.desktop`
//! file and icon PNGs so GNOME shows the correct tillandsia icon instead of a
//! generic blue gear.
//!
//! Idempotent: only writes when the `.desktop` file is missing or stale
//! (i.e. `Exec=` path no longer matches the current `$APPIMAGE` location).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use tracing::{debug, info, warn};

// Icon PNGs embedded at compile time from src-tauri/icons/
const ICON_32: &[u8] = include_bytes!("../icons/32x32.png");
const ICON_128: &[u8] = include_bytes!("../icons/128x128.png");
const ICON_256: &[u8] = include_bytes!("../icons/icon.png");

/// Check if running as an AppImage and install desktop integration if needed.
///
/// This is called early in `main()` — after CLI parsing, before tray setup.
/// Failures are logged but never cause a crash; desktop integration is cosmetic.
pub fn ensure_desktop_integration() {
    let appimage_path = match std::env::var("APPIMAGE") {
        Ok(path) if !path.is_empty() => path,
        _ => {
            debug!("Not running as AppImage — skipping desktop integration");
            return;
        }
    };

    info!(appimage = %appimage_path, "AppImage detected — checking desktop integration");

    let data_home = dirs::data_dir().unwrap_or_else(|| {
        PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into())).join(".local/share")
    });

    let desktop_dir = data_home.join("applications");
    let desktop_file = desktop_dir.join("tillandsias.desktop");
    let icon_base = data_home.join("icons/hicolor");

    // Check staleness: skip if .desktop exists with the correct Exec= path
    if is_desktop_file_current(&desktop_file, &appimage_path) {
        debug!("Desktop integration already current — nothing to do");
        return;
    }

    // Write .desktop file
    if let Err(e) = write_desktop_file(&desktop_dir, &desktop_file, &appimage_path) {
        warn!(error = %e, "Failed to write .desktop file");
        return;
    }

    // Write icon PNGs
    write_icon(&icon_base, "32x32", ICON_32);
    write_icon(&icon_base, "128x128", ICON_128);
    write_icon(&icon_base, "256x256", ICON_256);

    // Refresh desktop database and icon cache
    refresh_caches(&desktop_dir, &icon_base);

    info!("Desktop integration installed");
}

/// Returns true if the `.desktop` file exists and its `Exec=` line matches
/// the current AppImage path.
fn is_desktop_file_current(desktop_file: &Path, appimage_path: &str) -> bool {
    let content = match fs::read_to_string(desktop_file) {
        Ok(c) => c,
        Err(_) => return false,
    };

    let expected_exec = format!("Exec={appimage_path}");
    content.lines().any(|line| line.trim() == expected_exec)
}

/// Write the `.desktop` file with the given `Exec=` path.
fn write_desktop_file(
    desktop_dir: &Path,
    desktop_file: &Path,
    appimage_path: &str,
) -> Result<(), String> {
    fs::create_dir_all(desktop_dir)
        .map_err(|e| format!("Cannot create {}: {e}", desktop_dir.display()))?;

    let content = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Tillandsias\n\
         Comment=Local development environments that just work\n\
         Exec={appimage_path}\n\
         Icon=tillandsias\n\
         Categories=Development;\n\
         Terminal=false\n\
         StartupWMClass=tillandsias-tray\n"
    );

    fs::write(desktop_file, &content)
        .map_err(|e| format!("Cannot write {}: {e}", desktop_file.display()))?;

    debug!(path = %desktop_file.display(), "Wrote .desktop file");
    Ok(())
}

/// Write a single icon PNG to the hicolor theme directory at the given size.
fn write_icon(icon_base: &Path, size: &str, data: &[u8]) {
    let dir = icon_base.join(size).join("apps");
    if let Err(e) = fs::create_dir_all(&dir) {
        warn!(error = %e, size, "Failed to create icon directory");
        return;
    }

    let path = dir.join("tillandsias.png");
    if let Err(e) = fs::write(&path, data) {
        warn!(error = %e, size, "Failed to write icon");
    } else {
        debug!(path = %path.display(), "Wrote icon");
    }
}

/// Run `update-desktop-database` and `gtk-update-icon-cache` to make
/// the integration visible immediately.
fn refresh_caches(desktop_dir: &Path, icon_base: &Path) {
    match Command::new("update-desktop-database")
        .arg(desktop_dir)
        .output()
    {
        Ok(output) if output.status.success() => {
            debug!("update-desktop-database succeeded");
        }
        Ok(output) => {
            debug!(
                status = %output.status,
                "update-desktop-database exited with non-zero status"
            );
        }
        Err(e) => {
            debug!(error = %e, "update-desktop-database not available");
        }
    }

    match Command::new("gtk-update-icon-cache")
        .arg(icon_base)
        .output()
    {
        Ok(output) if output.status.success() => {
            debug!("gtk-update-icon-cache succeeded");
        }
        Ok(output) => {
            debug!(
                status = %output.status,
                "gtk-update-icon-cache exited with non-zero status"
            );
        }
        Err(e) => {
            debug!(error = %e, "gtk-update-icon-cache not available");
        }
    }
}
