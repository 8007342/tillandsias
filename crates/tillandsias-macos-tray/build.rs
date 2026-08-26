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
    if s.is_empty() { None } else { Some(s) }
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

    // 635-bhkb: the repo-root VERSION file is the single source of truth for
    // the release version. Crate versions are never bumped per release, so
    // `CARGO_PKG_VERSION` here is the literal "0.1.0" forever — which made
    // `--version` untruthful, put "0.1.0" in the diagnose JSON that support
    // tooling reads, and (the part that was not cosmetic) made the control
    // wire's build-version skew check compare a real guest version against
    // "0.1.0", so the warning fired on EVERY connection to a healthy guest.
    // A warning that is always true is one an operator learns to scroll past.
    //
    // Mirrors tillandsias-windows-tray/build.rs rather than inventing a second
    // mechanism: same env name, same fallback, same rerun-if-changed. Set
    // UNCONDITIONALLY (not behind a macOS-target gate) so cross-checks from
    // Linux and Windows have the var available — the crate compiles to a
    // cfg-gated stub off Darwin and its tests still need to resolve it.
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");

    println!("cargo:rustc-env=TILLANDSIAS_GIT_SHA={sha_full}");
    println!("cargo:rustc-env=TILLANDSIAS_BUILD_TIME={build_time}");

    // Re-run when HEAD moves so the embedded SHA stays accurate across
    // commits/branch switches. 765-uti9 quick win (velocity audit F6.1):
    // .git/index is deliberately NOT tracked — its mtime moves on every
    // `git add`/`status` refresh, and since this crate compiles (as a
    // cfg-gated stub) on every host, index churn was forcing a rebuild into
    // every gate run fleet-wide. Cost: the -dirty suffix can lag until the
    // next HEAD move — provenance for any COMMITTED state is unchanged, and
    // the full fingerprint redesign (BUILD_TIME fallback included) belongs to
    // the tray-fingerprint packet, 765-evbt.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
}
