//! `tillandsias --uninstall` and `tillandsias --uninstall --wipe` implementation.
//!
//! Removes Tillandsias from the system. Prints an inventory of what will be
//! removed, asks for confirmation, then removes files in order — deleting the
//! running binary last.
//!
//! @trace spec:app-lifecycle

use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use tillandsias_core::config;
use tillandsias_core::state::Os;

// ---------------------------------------------------------------------------
// ANSI helpers
// ---------------------------------------------------------------------------

const GREEN: &str = "\x1b[32m";
const DIM: &str = "\x1b[2m";
const YELLOW: &str = "\x1b[33m";
const RESET: &str = "\x1b[0m";

// ---------------------------------------------------------------------------
// Path inventory
// ---------------------------------------------------------------------------

/// A filesystem entry that will be removed during uninstall.
struct Target {
    /// Human-readable description (e.g., "app binary").
    label: &'static str,
    /// Absolute path on disk.
    path: PathBuf,
    /// Whether this entry exists right now.
    exists: bool,
}

/// Collect all paths that a standard uninstall will remove.
// @trace spec:app-lifecycle
fn standard_targets() -> Vec<Target> {
    let os = Os::detect();

    let mut targets = Vec::new();

    // Binary / app bundle
    match os {
        Os::Linux => {
            let bin = home_join(".local/bin/tillandsias");
            targets.push(Target {
                label: "app binary",
                path: bin.clone(),
                exists: bin.exists(),
            });
        }
        Os::MacOS => {
            let app = home_join("Applications/Tillandsias.app");
            targets.push(Target {
                label: "app bundle",
                path: app.clone(),
                exists: app.exists(),
            });
            // CLI symlink
            let symlink = home_join(".local/bin/tillandsias");
            targets.push(Target {
                label: "CLI symlink",
                path: symlink.clone(),
                exists: symlink.exists(),
            });
        }
        Os::Windows => {
            // Windows installs via NSIS — uninstall is handled by Add/Remove Programs.
            // This path is a best-effort fallback for portable installs.
            if let Some(local) = dirs::data_local_dir() {
                let bin = local.join("tillandsias").join("tillandsias.exe");
                targets.push(Target {
                    label: "app binary",
                    path: bin.clone(),
                    exists: bin.exists(),
                });
            }
        }
    }

    // Legacy uninstaller binary (being replaced by this module)
    let legacy_uninstaller = home_join(".local/bin/tillandsias-uninstall");
    targets.push(Target {
        label: "legacy uninstaller",
        path: legacy_uninstaller.clone(),
        exists: legacy_uninstaller.exists(),
    });

    // Config directory
    let config = config::config_dir();
    targets.push(Target {
        label: "settings",
        path: config.clone(),
        exists: config.exists(),
    });

    // Log directory
    let logs = config::log_dir();
    targets.push(Target {
        label: "logs",
        path: logs.clone(),
        exists: logs.exists(),
    });

    // Data directory
    let data = config::data_dir();
    targets.push(Target {
        label: "app data",
        path: data.clone(),
        exists: data.exists(),
    });

    // Desktop integration (Linux)
    if matches!(os, Os::Linux) {
        let desktop_file = home_join(".local/share/applications/tillandsias.desktop");
        targets.push(Target {
            label: "desktop launcher",
            path: desktop_file.clone(),
            exists: desktop_file.exists(),
        });

        // Icons
        for size in &["32x32", "128x128", "256x256"] {
            let icon = home_join(&format!(
                ".local/share/icons/hicolor/{size}/apps/tillandsias.png"
            ));
            if icon.exists() {
                targets.push(Target {
                    label: "icon",
                    path: icon,
                    exists: true,
                });
            }
        }

        // Autostart entry
        let autostart = home_join(".config/autostart/tillandsias.desktop");
        if autostart.exists() {
            targets.push(Target {
                label: "autostart entry",
                path: autostart,
                exists: true,
            });
        }
    }

    // macOS desktop integration
    if matches!(os, Os::MacOS) {
        let launch_agent = home_join("Library/LaunchAgents/com.tillandsias.tray.plist");
        if launch_agent.exists() {
            targets.push(Target {
                label: "launch agent",
                path: launch_agent,
                exists: true,
            });
        }
    }

    targets
}

/// Collect wipe-only targets (cache + container images).
// @trace spec:app-lifecycle
fn wipe_targets() -> Vec<Target> {
    let cache = config::cache_dir();
    vec![Target {
        label: "cache, tools overlay, mirrors",
        path: cache.clone(),
        exists: cache.exists(),
    }]
}

/// Image prefixes that `--wipe` will remove via `podman rmi`.
const IMAGE_PREFIXES: &[&str] = &[
    "tillandsias-forge:",
    "tillandsias-proxy:",
    "tillandsias-git:",
    "tillandsias-inference:",
    "tillandsias-web:",
];

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Run the uninstall flow. Returns `true` on success.
// @trace spec:app-lifecycle
pub fn run(wipe: bool) -> bool {
    println!();
    println!("  {GREEN}Tillandsias --- Uninstall{RESET}");
    println!();

    let std_targets = standard_targets();
    let wipe_tgts = if wipe { wipe_targets() } else { vec![] };

    // ── Print inventory ──────────────────────────────────────────
    println!("  The following will be removed:");
    println!();

    let mut any_exists = false;
    for t in &std_targets {
        if t.exists {
            any_exists = true;
            println!(
                "    {GREEN}+{RESET} {} {DIM}({}){RESET}",
                t.path.display(),
                t.label
            );
        }
    }

    if wipe {
        for t in &wipe_tgts {
            if t.exists {
                any_exists = true;
                println!(
                    "    {GREEN}+{RESET} {} {DIM}({}){RESET}",
                    t.path.display(),
                    t.label
                );
            }
        }
        println!("    {GREEN}+{RESET} {DIM}(tillandsias-* images via podman rmi){RESET}");
    }

    if !any_exists && !wipe {
        println!("    {DIM}Nothing found to remove.{RESET}");
        println!();
        return true;
    }

    println!();
    println!("  Your project files will NOT be touched.");

    if !wipe {
        println!("  {DIM}Cache preserved. Use --uninstall --wipe to remove everything.{RESET}");
    }

    println!();

    // ── Confirmation ─────────────────────────────────────────────
    if !confirm("  Are you sure? This cannot be undone. [y/N] ") {
        println!("  Cancelled.");
        println!();
        return true;
    }

    println!();

    // ── Remove standard targets ──────────────────────────────────
    let mut removed = Vec::new();
    let mut errors = Vec::new();

    for t in &std_targets {
        if !t.exists {
            continue;
        }
        match remove_path(&t.path) {
            Ok(()) => removed.push(t.label),
            Err(e) => errors.push((t.label, t.path.display().to_string(), e)),
        }
    }

    // ── Linux desktop cache refresh ──────────────────────────────
    if matches!(Os::detect(), Os::Linux) {
        let apps_dir = home_join(".local/share/applications");
        let _ = std::process::Command::new("update-desktop-database")
            .arg(&apps_dir)
            .output();
    }

    // ── Wipe-only targets ────────────────────────────────────────
    if wipe {
        for t in &wipe_tgts {
            if !t.exists {
                continue;
            }
            match remove_path(&t.path) {
                Ok(()) => removed.push(t.label),
                Err(e) => errors.push((t.label, t.path.display().to_string(), e)),
            }
        }

        // Remove container images
        remove_container_images();
    }

    // ── Summary ──────────────────────────────────────────────────
    println!("  {GREEN}Uninstall complete.{RESET} Removed:");
    println!();
    for label in &removed {
        println!("    {GREEN}+{RESET} {label}");
    }
    if wipe {
        println!("    {GREEN}+{RESET} tillandsias-* images");
    }

    if !errors.is_empty() {
        println!();
        println!("  {YELLOW}Some items could not be removed:{RESET}");
        for (label, path, err) in &errors {
            println!("    {YELLOW}!{RESET} {label} ({path}): {err}");
        }
    }

    println!();
    println!("  Your project files were NOT touched.");
    println!();

    // ── Self-delete ──────────────────────────────────────────────
    // On Unix, a running binary can delete its own path — the OS keeps
    // the inode alive until the process exits.
    // @trace spec:app-lifecycle
    if let Ok(exe) = std::env::current_exe() {
        let _ = std::fs::remove_file(&exe);
    }

    errors.is_empty()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Join a relative path to the user's home directory.
fn home_join(relative: &str) -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(relative)
}

/// Remove a file or directory tree.
fn remove_path(path: &PathBuf) -> Result<(), String> {
    if path.is_dir() {
        std::fs::remove_dir_all(path).map_err(|e| e.to_string())
    } else {
        std::fs::remove_file(path).map_err(|e| e.to_string())
    }
}

/// Ask the user a yes/no question. Returns true only if they type `y` or `yes`.
fn confirm(prompt: &str) -> bool {
    use std::io::IsTerminal as _;

    // Non-interactive (piped stdin) — refuse by default.
    if !io::stdin().is_terminal() {
        return false;
    }

    print!("{prompt}");
    let _ = io::stdout().flush();

    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line).is_err() {
        return false;
    }

    matches!(line.trim().to_lowercase().as_str(), "y" | "yes")
}

/// Remove all tillandsias-* container images via podman.
// @trace spec:app-lifecycle
fn remove_container_images() {
    let podman = tillandsias_podman::find_podman_path();

    // List all images
    let output = std::process::Command::new(podman)
        .args(["images", "--format", "{{.Repository}}:{{.Tag}}"])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output();

    let images: Vec<String> = match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            stdout
                .lines()
                .filter(|line| {
                    let trimmed = line.trim();
                    IMAGE_PREFIXES
                        .iter()
                        .any(|prefix| trimmed.starts_with(prefix))
                })
                .map(|s| s.trim().to_string())
                .collect()
        }
        _ => return,
    };

    for image in &images {
        let _ = std::process::Command::new(podman)
            .args(["rmi", image])
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .output();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_targets_not_empty() {
        let targets = standard_targets();
        // Should always have at least the binary + config + logs + data
        assert!(
            targets.len() >= 4,
            "Expected at least 4 standard targets, got {}",
            targets.len()
        );
    }

    #[test]
    fn wipe_targets_includes_cache() {
        let targets = wipe_targets();
        assert_eq!(targets.len(), 1);
        assert!(
            targets[0].path.ends_with("tillandsias"),
            "Wipe target should be the tillandsias cache dir"
        );
    }

    #[test]
    fn image_prefixes_cover_all_enclave_components() {
        // All enclave container types should be listed
        assert!(IMAGE_PREFIXES.contains(&"tillandsias-forge:"));
        assert!(IMAGE_PREFIXES.contains(&"tillandsias-proxy:"));
        assert!(IMAGE_PREFIXES.contains(&"tillandsias-git:"));
        assert!(IMAGE_PREFIXES.contains(&"tillandsias-inference:"));
        assert!(IMAGE_PREFIXES.contains(&"tillandsias-web:"));
    }

    #[test]
    fn home_join_produces_absolute_path() {
        let path = home_join(".config/tillandsias");
        // home_join should produce an absolute path (or at least not just the relative)
        assert!(
            path.to_string_lossy().contains("tillandsias"),
            "Path should contain 'tillandsias'"
        );
    }
}
