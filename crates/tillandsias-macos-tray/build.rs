//! Embed build provenance (git SHA, dirty flag, build time) so the running
//! binary can self-report whether it was built from current HEAD. Without this
//! the only version surfaces are the frozen crate version and the un-bumped
//! VERSION file, so a stale build is indistinguishable from a fresh one — which
//! is exactly how an old artifact can be tested by mistake.
//!
//! Surfaced via `--version` and `--diagnose --json` (build_sha/build_time).

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn main() {
    let sha = git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".into());
    // Dirty if there are staged/unstaged tracked changes (untracked ignored).
    let dirty = Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=no"])
        .output()
        .ok()
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false);
    let sha_full = if dirty { format!("{sha}-dirty") } else { sha };

    // Build time: prefer SOURCE_DATE_EPOCH (reproducible builds) else `date -u`.
    let build_time = std::env::var("SOURCE_DATE_EPOCH")
        .ok()
        .and_then(|epoch| {
            Command::new("date")
                .args(["-u", "-r", &epoch, "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
                .ok()
        })
        .or_else(|| {
            Command::new("date")
                .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
                .ok()
        })
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".into());

    println!("cargo:rustc-env=TILLANDSIAS_GIT_SHA={sha_full}");
    println!("cargo:rustc-env=TILLANDSIAS_BUILD_TIME={build_time}");

    // Re-run when HEAD moves or the index changes so the SHA/dirty flag stay
    // accurate across commits/staging without a manual clean.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/index");
}
