//! Portable host-side logic shared by the Windows and macOS native trays.
//!
//! The Linux tray (zbus/SNI/DBusMenu) keeps its dedicated implementation in
//! `tillandsias-headless`. The Windows (Win32 NotifyIcon) and macOS (AppKit
//! NSStatusItem) trays consume the modules here so the OS-specific bins
//! stay thin: each is a UI shell that delegates project discovery, VM
//! lifecycle, menu modelling, and control-wire communication to this crate.
//!
//! This crate is a SCAFFOLD ONLY — every public function returns `todo!()`
//! pending the implementation wave. See
//! `openspec/specs/host-shell-architecture/spec.md`.
//!
//! @trace spec:host-shell-architecture

#![allow(dead_code)]
#![allow(unused)]

pub mod lifecycle;
pub mod menu_state;
pub mod provisioning;
pub mod scanner;
pub mod vsock_client;
