//! Portable menu state model shared by the Windows and macOS trays.
//!
//! Mirrors the Linux tray's `TrayUiState` but emits a backend-agnostic
//! `MenuStructure`. The Windows tray turns this into Win32 `MENUITEMINFO`
//! entries; the macOS tray turns it into `NSMenuItem` instances.
//!
//! @trace spec:host-shell-architecture, spec:windows-native-tray, spec:macos-native-tray

#![allow(dead_code)]
#![allow(unused)]

use serde::{Deserialize, Serialize};

/// A single menu node.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
    pub enabled: bool,
    pub children: Vec<MenuItem>,
}

/// Coarse menu shape the tray paints.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MenuStructure {
    /// Minimal early menu shown while the VM provisions / starts.
    /// Carries the single condensed status line.
    Provisioning { status: String },
    /// Standard tray menu — projects, agents, settings, quit.
    Ready { items: Vec<MenuItem> },
    /// Terminal failure state. Carries the reason + a retry handle.
    Failed { reason: String },
}

impl MenuStructure {
    /// Construct an initial provisioning menu with a default status line.
    pub fn initial() -> Self {
        MenuStructure::Provisioning {
            status: "Setting up Fedora Linux…".to_string(),
        }
    }
}
