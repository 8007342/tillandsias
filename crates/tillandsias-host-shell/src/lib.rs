//! Portable host-side logic shared by the Windows and macOS native trays.
//!
//! The Linux tray (zbus/SNI/DBusMenu) keeps its dedicated implementation in
//! `tillandsias-headless`. The Windows (Win32 NotifyIcon) and macOS (AppKit
//! NSStatusItem) trays consume the modules here so the OS-specific bins
//! stay thin: each is a UI shell that delegates project discovery, VM
//! lifecycle, menu modelling, and control-wire communication to this crate.
//!
//! Phase-4 status: the portable modules below are implemented and unit-tested
//! against Linux (the dev box). The OS-specific tray bins wire them up under
//! `#[cfg(target_os = "windows")]` / `#[cfg(target_os = "macos")]` blocks.
//!
//! @trace spec:host-shell-architecture

#![allow(dead_code)]

pub mod lifecycle;
pub mod menu_action;
pub mod menu_state;
pub mod provisioning;
/// Host-side PTY-over-vsock session multiplexing (control-wire-pty-attach §3),
/// cross-platform core. OS backends (ConPTY / openpty) layer on top.
pub mod pty;
pub mod scanner;
pub mod subscription_health;
pub mod vsock_client;

/// Host shell crate version — returns the workspace release version
/// (e.g. `0.2.260528.1`) baked at build time from the repo-root
/// `VERSION` file by `build.rs`.
///
/// Pre-fix this returned `CARGO_PKG_VERSION` which resolves to
/// `tillandsias-host-shell/Cargo.toml`'s `version = "0.1.0"` —
/// crate versions don't get bumped per release, so callers were
/// silently getting a string that:
///   * mismatched what the user actually installed (`v0.2.260528.1`),
///   * made the WSL/VZ provisioning paths fetch a non-existent
///     `v0.1.0` release artifact, and
///   * made downstream UI surfaces (notably [`crate::menu_state::
///     MenuState`] `version` field) render `v0.1.0 — By Tlatoāni`
///     instead of the workspace version in all three trays.
///
/// Fix from windows-host's `tray-convergence-coordination.md`
/// 2026-05-30T11:00Z ASK block: a `build.rs` reads `../../VERSION`
/// and exposes the value as the `WORKSPACE_VERSION` env var. Callers
/// keep using `version()`; the change is transparent.
///
/// @trace spec:vm-provisioning-lifecycle, spec:tray-app
pub fn version() -> &'static str {
    env!("WORKSPACE_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    // @trace spec:vm-provisioning-lifecycle (regression guard for the
    //   CARGO_PKG_VERSION anti-pattern flagged in tray-convergence-
    //   coordination.md 2026-05-30T11:00Z ASK)
    #[test]
    fn version_reports_workspace_release_not_crate_static_zero_dot_one() {
        let v = version();
        assert_ne!(
            v, "0.1.0",
            "host-shell::version() returned the crate-static \"0.1.0\" — \
             build.rs's WORKSPACE_VERSION injection regressed; fix it before \
             provisioning fetches a non-existent v0.1.0 artifact and the tray \
             menu renders the wrong version footer."
        );
        // Workspace VERSION follows the 0.MAJOR.YYMMDD.SEQ shape (e.g.
        // `0.2.260528.1`). A 2-segment "X.Y" string is the unmistakable
        // signature of a crate-static fallback regression.
        assert!(
            v.matches('.').count() >= 2,
            "host-shell::version() = {v:?} doesn't look like a workspace VERSION \
             (expected at least 3 dot-segments e.g. 0.2.260528.1)"
        );
    }
}
