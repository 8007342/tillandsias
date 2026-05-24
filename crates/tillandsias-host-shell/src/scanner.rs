//! Host-side project discovery for the cross-platform trays.
//!
//! Watches `~/src/` (`%USERPROFILE%\src\` on Windows) for project additions
//! and removals, and emits `ProjectEvent`s the tray consumes to refresh
//! its menu. Mirrors the existing `tillandsias-scanner` discipline but
//! lives on the host (not in the VM).
//!
//! @trace spec:host-shell-architecture

#![allow(dead_code)]
#![allow(unused)]

use std::path::Path;

use serde::{Deserialize, Serialize};

/// A single project-level event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProjectEvent {
    Added { path: std::path::PathBuf },
    Removed { path: std::path::PathBuf },
    Renamed {
        from: std::path::PathBuf,
        to: std::path::PathBuf,
    },
}

/// Start watching the project home directory. Returns a long-lived handle
/// the tray reads events from. The actual stream type is intentionally
/// abstract — concrete returns land with the implementation wave.
pub fn watch_projects(_home: &Path) -> Result<ProjectWatcher, String> {
    todo!("@spec host-shell-architecture: notify-based recursive watcher on ~/src/")
}

/// Handle exposed by `watch_projects`. Holds the underlying notify watcher
/// so its lifetime is tied to the tray process.
pub struct ProjectWatcher;

impl ProjectWatcher {
    /// Block until the next event arrives. Returns `None` if the watcher
    /// has been closed.
    pub async fn next(&mut self) -> Option<ProjectEvent> {
        todo!("@spec host-shell-architecture: bridge notify events to async channel")
    }
}
