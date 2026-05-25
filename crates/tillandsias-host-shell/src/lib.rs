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
pub mod scanner;
pub mod vsock_client;

/// Host shell crate version. Used by the WSL/VZ provisioning paths to
/// fetch the matching `tillandsias-linux-x86_64` artifact from the
/// `8007342/tillandsias` GitHub release.
///
/// @trace spec:vm-provisioning-lifecycle
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
