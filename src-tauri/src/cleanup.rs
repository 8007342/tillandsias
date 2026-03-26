//! `tillandsias --stats` and `tillandsias --clean` implementation.
//!
//! These commands print to stdout and exit — they never enter the Tauri event loop.

use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Return the size of a directory tree (in bytes), or 0 if it doesn't exist.
fn dir_size_bytes(path: &Path) -> u64 {
    if !path.exists() {
        return 0;
    }
    // Use `du -sb` for a reliable recursive byte count.
    let path_str = path.to_string_lossy().into_owned();
    let output = std::process::Command::new("du")
        .args(["-sb", &path_str])
        .output();
    match output {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            s.split_whitespace()
                .next()
                .and_then(|n| n.parse::<u64>().ok())
                .unwrap_or(0)
        }
        _ => 0,
    }
}

/// Return the size of a single file in bytes, or 0 if it doesn't exist.
fn file_size_bytes(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// Human-readable byte count: "1.2 GB", "345 MB", "12 KB".
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

/// Home directory path.
fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".to_string()))
}

/// Run a podman command synchronously, returning (stdout, success).
fn podman_run(args: &[&str]) -> (String, bool) {
    let output = tillandsias_podman::podman_cmd_sync()
        .args(args)
        .output();
    match output {
        Ok(o) => (String::from_utf8_lossy(&o.stdout).to_string(), o.status.success()),
        Err(_) => (String::new(), false),
    }
}

// ---------------------------------------------------------------------------
// --stats
// ---------------------------------------------------------------------------

pub fn run_stats() -> bool {
    println!("Tillandsias — disk usage report");
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
            println!("  Images:     (none)");
        } else {
            println!("  Images:");
            for line in &relevant {
                println!("    {line}");
            }
        }
    } else {
        println!("  Images:     (podman not available)");
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
            println!("  Containers: (none)");
        } else {
            println!("  Containers:");
            for line in &containers {
                println!("    {line}");
            }
        }
    } else {
        println!("  Containers: (podman not available)");
    }
    println!();

    // --- Nix cache ---
    let nix_path = home().join(".cache/tillandsias/nix");
    let nix_bytes = dir_size_bytes(&nix_path);
    total_bytes += nix_bytes;
    if nix_bytes > 0 {
        println!("  Nix cache:       {} ({})", nix_path.display(), human_bytes(nix_bytes));
    } else {
        println!("  Nix cache:       (not present)");
    }

    // --- Cargo registry cache ---
    let cargo_path = home().join(".cache/tillandsias/cargo-registry");
    let cargo_bytes = dir_size_bytes(&cargo_path);
    total_bytes += cargo_bytes;
    if cargo_bytes > 0 {
        println!("  Cargo cache:     {} ({})", cargo_path.display(), human_bytes(cargo_bytes));
    } else {
        println!("  Cargo cache:     (not present)");
    }

    // --- Installed binary ---
    let bin_path = home().join(".local/bin/.tillandsias-bin");
    let bin_bytes = file_size_bytes(&bin_path);
    total_bytes += bin_bytes;
    if bin_bytes > 0 {
        println!("  Installed binary:{} ({})", bin_path.display(), human_bytes(bin_bytes));
    } else {
        println!("  Installed binary: (not installed at {})", bin_path.display());
    }

    println!();
    println!("  Total (caches + binary): {}", human_bytes(total_bytes));
    println!("  (Podman image storage is managed by podman — see 'podman system df')");

    true
}

// ---------------------------------------------------------------------------
// --clean
// ---------------------------------------------------------------------------

pub fn run_clean() -> bool {
    println!("Tillandsias — artifact cleanup");
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
    let nix_path = home().join(".cache/tillandsias/nix");
    if nix_path.exists() {
        let size_before = dir_size_bytes(&nix_path);
        match std::fs::remove_dir_all(&nix_path) {
            Ok(()) => {
                anything_cleaned = true;
                println!("  Nix cache:  removed {} ({})", nix_path.display(), human_bytes(size_before));
            }
            Err(e) => {
                println!("  Nix cache:  failed to remove {}: {e}", nix_path.display());
            }
        }
    } else {
        println!("  Nix cache:  (not present)");
    }

    println!();
    if anything_cleaned {
        println!("Cleanup complete.");
    } else {
        println!("Nothing to clean.");
    }

    true
}
