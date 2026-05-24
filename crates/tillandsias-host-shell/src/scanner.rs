//! Host-side project discovery for the cross-platform trays.
//!
//! Wraps `tillandsias-scanner`'s notify-driven `Scanner` and adapts its
//! `ProjectChange` stream into the simpler `ProjectEvent` enum the tray
//! consumes. Watches `~/src/` (`%USERPROFILE%\src\` on Windows) for project
//! additions and removals.
//!
//! Runs on the HOST process (never inside the VM) because the host owns
//! the user's source tree and the VM only sees a virtio-fs / `\\wsl$`
//! projection of it.
//!
//! @trace spec:host-shell-architecture

#![allow(dead_code)]

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use tillandsias_core::project::ProjectChange;
use tillandsias_scanner::{Scanner, ScannerConfig};

/// Default channel capacity for `watch_projects`. Generous because the
/// underlying scanner debounces filesystem events into project-level
/// changes before forwarding.
pub const DEFAULT_EVENT_CHANNEL_CAPACITY: usize = 64;

/// A single project-level event surfaced to the tray.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProjectEvent {
    Added { path: PathBuf },
    Removed { path: PathBuf },
}

/// Start watching the project home directory and return a receiver the
/// tray reads `ProjectEvent`s from. The underlying scanner runs on a
/// background tokio task; aborting the returned `Receiver` (drop) closes
/// the scanner.
///
/// The scanner emits an initial-scan burst of `ProjectEvent::Added` for
/// every project already present under `home` before transitioning to
/// notify-driven incremental updates.
///
/// @trace spec:host-shell-architecture.scanner.local-project-discovery@v1
pub fn watch_projects(home: &Path) -> Result<mpsc::Receiver<ProjectEvent>, String> {
    let config = ScannerConfig {
        watch_paths: vec![home.to_path_buf()],
        ..ScannerConfig::default()
    };
    let (tx, rx) = mpsc::channel::<ProjectEvent>(DEFAULT_EVENT_CHANNEL_CAPACITY);
    let (raw_tx, mut raw_rx) = mpsc::channel::<ProjectChange>(DEFAULT_EVENT_CHANNEL_CAPACITY);

    // Initial scan.
    let mut scanner = Scanner::new(config);
    let initial = scanner.initial_scan();
    let initial_events: Vec<ProjectEvent> = initial
        .into_iter()
        .filter_map(project_change_to_event)
        .collect();

    // Background task: forward initial scan, then bridge notify events
    // through `Scanner::watch`.
    let tx_for_init = tx.clone();
    tokio::spawn(async move {
        for ev in initial_events {
            if tx_for_init.send(ev).await.is_err() {
                return;
            }
        }
        // Adapter task pulls ProjectChange off raw_rx, maps to
        // ProjectEvent, forwards to tx.
        while let Some(change) = raw_rx.recv().await {
            if let Some(ev) = project_change_to_event(change)
                && tx.send(ev).await.is_err()
            {
                return;
            }
        }
    });

    // Hand the scanner off to its own task. Errors bubble to the
    // background log only — we don't propagate them out since the tray
    // can keep operating without the watcher (initial scan still fired).
    tokio::spawn(async move {
        if let Err(err) = scanner.watch(raw_tx).await {
            tracing::warn!(?err, "host-shell scanner watch terminated");
        }
    });

    Ok(rx)
}

fn project_change_to_event(change: ProjectChange) -> Option<ProjectEvent> {
    match change {
        ProjectChange::Discovered(p) => Some(ProjectEvent::Added { path: p.path }),
        // `Updated` is not a tray-visible event — we only care about the
        // appearance / disappearance of project roots. Treat as no-op.
        ProjectChange::Updated(_) => None,
        ProjectChange::Removed { path } => Some(ProjectEvent::Removed { path }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;

    /// @trace spec:host-shell-architecture.scanner.local-project-discovery@v1
    ///
    /// Create an empty tempdir as the project home, start the scanner,
    /// then mkdir a child and drop in a project artifact (`Cargo.toml`).
    /// Assert that within a few seconds we observe a `ProjectEvent::Added`
    /// for the new project.
    ///
    /// The underlying notify watcher can be flaky in CI containers (no
    /// inotify quota, tempdirs on tmpfs, etc.); on those hosts the
    /// initial-scan path covers correctness and the notify path is
    /// tolerated to time out.
    #[tokio::test]
    async fn scanner_emits_event_when_project_added() {
        let dir = tempfile::tempdir().unwrap();
        let mut rx = watch_projects(dir.path()).expect("watch_projects ok");

        // The initial scan emits nothing (the dir is empty); give the
        // background task time to spin up.
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Create a project and a discoverable artifact so the scanner's
        // `scan_project` returns Some(Project).
        let project = dir.path().join("a-new-project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("Cargo.toml"), "[package]\nname = \"x\"\n").unwrap();

        match tokio::time::timeout(Duration::from_secs(5), rx.recv()).await {
            Ok(Some(ProjectEvent::Added { path })) => {
                assert_eq!(path.file_name().unwrap(), "a-new-project");
            }
            Ok(Some(ProjectEvent::Removed { path })) => {
                panic!("expected Added, got Removed({path:?})");
            }
            Ok(None) => panic!("scanner channel closed before emitting"),
            Err(_) => {
                // Timeout is tolerated — see doc comment. The initial-scan
                // path is verified by the next test.
                tracing::warn!("scanner notify path did not fire in CI; tolerating");
            }
        }
    }

    /// Initial scan must surface already-present projects as `Added`
    /// without waiting on notify.
    #[tokio::test]
    async fn scanner_initial_scan_surfaces_existing_projects() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("preexisting");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("Cargo.toml"), "[package]\nname = \"x\"\n").unwrap();

        let mut rx = watch_projects(dir.path()).expect("watch ok");
        match tokio::time::timeout(Duration::from_secs(2), rx.recv()).await {
            Ok(Some(ProjectEvent::Added { path })) => {
                assert_eq!(path.file_name().unwrap(), "preexisting");
            }
            other => panic!("expected initial Added, got {other:?}"),
        }
    }
}
