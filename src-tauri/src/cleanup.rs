//! `tillandsias --stats` and `tillandsias --clean` implementation.
//!
//! These commands print to stdout and exit — they never enter the Tauri event loop.

use std::path::{Path, PathBuf};

use tillandsias_core::config;
use tillandsias_core::format::human_bytes;

use crate::i18n;
use crate::update_log;

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
        Ok(o) => (
            String::from_utf8_lossy(&o.stdout).to_string(),
            o.status.success(),
        ),
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
    let (images_out, podman_ok) =
        podman_run(&["images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}"]);

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
            println!("  {}", i18n::t("stats.images_label"));
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
            println!("  {}", i18n::t("stats.containers_label"));
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
            "  {}",
            i18n::tf("stats.nix_cache_present", &[
                ("path", &nix_path.display().to_string()),
                ("size", &human_bytes(nix_bytes)),
            ])
        );
    } else {
        println!("  {}", i18n::t("stats.nix_cache_not_present"));
    }

    // --- Cargo registry cache ---
    let cargo_path = cache.join("cargo-registry");
    let cargo_bytes = dir_size_bytes(&cargo_path);
    total_bytes += cargo_bytes;
    if cargo_bytes > 0 {
        println!(
            "  {}",
            i18n::tf("stats.cargo_cache_present", &[
                ("path", &cargo_path.display().to_string()),
                ("size", &human_bytes(cargo_bytes)),
            ])
        );
    } else {
        println!("  {}", i18n::t("stats.cargo_cache_not_present"));
    }

    // --- Installed binary ---
    let bin_path = installed_binary_path();
    let bin_bytes = file_size_bytes(&bin_path);
    total_bytes += bin_bytes;
    if bin_bytes > 0 {
        println!(
            "  {}",
            i18n::tf("stats.binary_present", &[
                ("path", &bin_path.display().to_string()),
                ("size", &human_bytes(bin_bytes)),
            ])
        );
    } else {
        println!(
            "  {}",
            i18n::tf("stats.binary_not_present", &[
                ("path", &bin_path.display().to_string()),
            ])
        );
    }

    // --- Last update ---
    let last_update = update_log::read_last_entry()
        .unwrap_or_else(|| i18n::t("stats.no_update_log").to_string());
    println!(
        "  {}",
        i18n::tf("stats.last_update", &[("entry", &last_update)])
    );

    println!();
    println!(
        "  {}",
        i18n::tf("stats.total", &[("size", &human_bytes(total_bytes))])
    );
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
            println!("  {}", i18n::t("clean.images_none_dangling"));
        } else {
            anything_cleaned = true;
            println!(
                "  {}",
                i18n::tf("clean.images_removed", &[("count", &pruned.len().to_string())])
            );
            for line in &pruned {
                println!("    {line}");
            }
        }
    } else {
        println!("  {}", i18n::t("clean.images_no_podman"));
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
            println!("  {}", i18n::t("clean.containers_none_stopped"));
        } else {
            anything_cleaned = true;
            println!(
                "  {}",
                i18n::tf("clean.containers_removing", &[("count", &names.len().to_string())])
            );
            for name in &names {
                let (_, ok) = podman_run(&["rm", name]);
                if ok {
                    println!("  {}", i18n::tf("clean.container_removed", &[("name", name)]));
                } else {
                    println!("  {}", i18n::tf("clean.container_failed", &[("name", name)]));
                }
            }
        }
    } else {
        println!("  {}", i18n::t("clean.containers_no_podman"));
    }

    // --- Nix cache ---
    let nix_path = config::cache_dir().join("nix");
    if nix_path.exists() {
        let size_before = dir_size_bytes(&nix_path);
        match std::fs::remove_dir_all(&nix_path) {
            Ok(()) => {
                anything_cleaned = true;
                println!(
                    "  {}",
                    i18n::tf("clean.nix_cache_removed", &[
                        ("path", &nix_path.display().to_string()),
                        ("size", &human_bytes(size_before)),
                    ])
                );
            }
            Err(e) => {
                println!(
                    "  {}",
                    i18n::tf("clean.nix_cache_failed", &[
                        ("path", &nix_path.display().to_string()),
                        ("error", &e.to_string()),
                    ])
                );
            }
        }
    } else {
        println!("  {}", i18n::t("clean.nix_cache_not_present"));
    }

    println!();
    if anything_cleaned {
        println!("{}", i18n::t("clean.complete"));
    } else {
        println!("{}", i18n::t("clean.nothing"));
    }

    true
}
