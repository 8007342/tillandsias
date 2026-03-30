//! `tillandsias --stats` and `tillandsias --clean` implementation.
//!
//! These commands print to stdout and exit — they never enter the Tauri event loop.

use std::path::{Path, PathBuf};

use tillandsias_core::config;
use tillandsias_core::format::human_bytes;

use crate::i18n;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Return the size of a directory tree (in bytes), or 0 if it doesn't exist.
///
/// Uses a pure-Rust recursive walk via `std::fs` — no platform-specific CLI flags.
fn dir_size_bytes(path: &Path) -> u64 {
    if !path.exists() {
        return 0;
    }
    fn walk(dir: &Path) -> u64 {
        let mut total: u64 = 0;
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return 0,
        };
        for entry in entries.flatten() {
            let ft = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };
            if ft.is_file() || ft.is_symlink() {
                total += entry.metadata().map(|m| m.len()).unwrap_or(0);
            } else if ft.is_dir() {
                total += walk(&entry.path());
            }
        }
        total
    }
    walk(path)
}

/// Return the size of a single file in bytes, or 0 if it doesn't exist.
fn file_size_bytes(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Home directory path.
fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".to_string()))
}

/// Platform-aware installed binary path.
///
/// - Linux: `~/.local/bin/.tillandsias-bin`
/// - macOS: `/usr/local/bin/tillandsias` (or `~/Applications/Tillandsias.app` bundle)
fn installed_binary_path() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        // Check app bundle first, fall back to /usr/local/bin
        let app_bundle = home().join("Applications/Tillandsias.app");
        if app_bundle.exists() {
            return app_bundle;
        }
        PathBuf::from("/usr/local/bin/tillandsias")
    }
    #[cfg(not(target_os = "macos"))]
    {
        home().join(".local/bin/.tillandsias-bin")
    }
}

/// Run a podman command synchronously, returning (stdout, success).
fn podman_run(args: &[&str]) -> (String, bool) {
    let output = tillandsias_podman::podman_cmd_sync().args(args).output();
    match output {
        Ok(o) => (String::from_utf8_lossy(&o.stdout).to_string(), o.status.success()),
        Err(_) => (String::new(), false),
    }
}

// ---------------------------------------------------------------------------
// --stats
// ---------------------------------------------------------------------------

pub fn run_stats() -> bool {
    println!("{}", i18n::t("stats.title"));
    println!();

    let mut total_bytes: u64 = 0;

    // --- Podman images ---
    let (images_out, podman_ok) = podman_run(&[
        "images",
        "--format",
        "{{.Repository}}:{{.Tag}}\t{{.Size}}",
    ]);

    if podman_ok {
        let relevant: Vec<&str> = images_out
            .lines()
            .filter(|l| {
                let lower = l.to_lowercase();
                lower.contains("tillandsias") || lower.contains("macuahuitl")
            })
            .collect();

        if relevant.is_empty() {
            println!("  {}", i18n::t("stats.images_none"));
        } else {
            println!("  Images:");
            for line in &relevant {
                println!("    {line}");
            }
        }
    } else {
        println!("  {}", i18n::t("stats.images_no_podman"));
    }
    println!();

    // --- Podman containers ---
    let (ps_out, ps_ok) = podman_run(&[
        "ps",
        "-a",
        "--filter",
        "name=tillandsias-",
        "--format",
        "{{.Names}}\t{{.Status}}",
    ]);

    if ps_ok {
        let containers: Vec<&str> = ps_out.lines().filter(|l| !l.trim().is_empty()).collect();
        if containers.is_empty() {
            println!("  {}", i18n::t("stats.containers_none"));
        } else {
            println!("  Containers:");
            for line in &containers {
                println!("    {line}");
            }
        }
    } else {
        println!("  {}", i18n::t("stats.containers_no_podman"));
    }
    println!();

    // --- Nix cache ---
    let cache = config::cache_dir();
    let nix_path = cache.join("nix");
    let nix_bytes = dir_size_bytes(&nix_path);
    total_bytes += nix_bytes;
    if nix_bytes > 0 {
        println!(
            "  Nix cache:       {} ({})",
            nix_path.display(),
            human_bytes(nix_bytes)
        );
    } else {
        println!("  Nix cache:       (not present)");
    }

    // --- Cargo registry cache ---
    let cargo_path = cache.join("cargo-registry");
    let cargo_bytes = dir_size_bytes(&cargo_path);
    total_bytes += cargo_bytes;
    if cargo_bytes > 0 {
        println!(
            "  Cargo cache:     {} ({})",
            cargo_path.display(),
            human_bytes(cargo_bytes)
        );
    } else {
        println!("  Cargo cache:     (not present)");
    }

    // --- Installed binary ---
    let bin_path = installed_binary_path();
    let bin_bytes = file_size_bytes(&bin_path);
    total_bytes += bin_bytes;
    if bin_bytes > 0 {
        println!(
            "  Installed binary: {} ({})",
            bin_path.display(),
            human_bytes(bin_bytes)
        );
    } else {
        println!(
            "  Installed binary: (not installed at {})",
            bin_path.display()
        );
    }

    println!();
    println!("  {}", i18n::tf("stats.total", &[("size", &human_bytes(total_bytes))]));
    println!("  {}", i18n::t("stats.podman_note"));

    true
}

// ---------------------------------------------------------------------------
// --clean
// ---------------------------------------------------------------------------

pub fn run_clean() -> bool {
    println!("{}", i18n::t("clean.title"));
    println!();

    let mut anything_cleaned = false;

    // --- Dangling podman images ---
    let (prune_out, prune_ok) = podman_run(&["image", "prune", "-f"]);
    if prune_ok {
        let pruned: Vec<&str> = prune_out.lines().filter(|l| !l.trim().is_empty()).collect();
        if pruned.is_empty() {
            println!("  Images:     no dangling images to remove");
        } else {
            anything_cleaned = true;
            println!("  Images:     removed {} dangling image(s)", pruned.len());
            for line in &pruned {
                println!("    {line}");
            }
        }
    } else {
        println!("  Images:     (podman not available — skipped)");
    }

    // --- Stopped tillandsias containers ---
    let (stopped_out, stopped_ok) = podman_run(&[
        "ps",
        "-a",
        "--filter",
        "name=tillandsias-",
        "--filter",
        "status=exited",
        "--format",
        "{{.Names}}",
    ]);

    if stopped_ok {
        let names: Vec<&str> = stopped_out
            .lines()
            .filter(|l| !l.trim().is_empty())
            .collect();

        if names.is_empty() {
            println!("  Containers: no stopped tillandsias containers");
        } else {
            anything_cleaned = true;
            println!("  Containers: removing {} stopped container(s)...", names.len());
            for name in &names {
                let (_, ok) = podman_run(&["rm", name]);
                if ok {
                    println!("    removed: {name}");
                } else {
                    println!("    failed to remove: {name}");
                }
            }
        }
    } else {
        println!("  Containers: (podman not available — skipped)");
    }

    // --- Nix cache ---
    let nix_path = config::cache_dir().join("nix");
    if nix_path.exists() {
        let size_before = dir_size_bytes(&nix_path);
        match std::fs::remove_dir_all(&nix_path) {
            Ok(()) => {
                anything_cleaned = true;
                println!(
                    "  Nix cache:  removed {} ({})",
                    nix_path.display(),
                    human_bytes(size_before)
                );
            }
            Err(e) => {
                println!(
                    "  Nix cache:  failed to remove {}: {e}",
                    nix_path.display()
                );
            }
        }
    } else {
        println!("  Nix cache:  (not present)");
    }

    println!();
    if anything_cleaned {
        println!("{}", i18n::t("clean.complete"));
    } else {
        println!("{}", i18n::t("clean.nothing"));
    }

    true
}
