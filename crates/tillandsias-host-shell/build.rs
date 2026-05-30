//! Build script for the shared host-shell crate.
//!
//! Reads the workspace VERSION file and exposes it as `WORKSPACE_VERSION`
//! so [`crate::version()`] returns the release version (`0.2.260528.1`)
//! rather than the crate's static `Cargo.toml` `version = "0.1.0"`. The
//! crate versions don't get bumped per release; the repo-root VERSION
//! file is the single source of truth (the install/build scripts already
//! quote it).
//!
//! This is the shared structural fix windows-host asked for in
//! `plan/issues/tray-convergence-coordination.md` (2026-05-30T11:00Z ASK
//! block). With this in place, all three tray runtimes — Linux (via the
//! provisioning fetch path that consumes [`crate::version()`]), macOS,
//! and Windows — see the workspace VERSION. The windows-tray's contained
//! `fresh_menu_state()` override (commit 6eb026e0) becomes structurally
//! redundant; it can stay as defence-in-depth but is no longer required
//! for correct behaviour.
//!
//! Fallback: if `../../VERSION` is unreadable (source-tarball builds, CI
//! cross-checks without a checkout) the script falls back to
//! `CARGO_PKG_VERSION` so `env!("WORKSPACE_VERSION")` always resolves.
//!
//! @trace spec:vm-provisioning-lifecycle, spec:tray-app

fn main() {
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");
}
