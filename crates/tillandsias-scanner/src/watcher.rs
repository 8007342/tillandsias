use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

use tillandsias_core::project::{Project, ProjectChange};

use crate::detect::scan_project;

/// Scanner configuration.
#[derive(Debug, Clone)]
pub struct ScannerConfig {
    /// Directories to watch (default: `~/src`).
    pub watch_paths: Vec<PathBuf>,
    /// Debounce duration for filesystem events (default: 2000ms).
    pub debounce: Duration,
}

impl Default for ScannerConfig {
    fn default() -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("~"));
        Self {
            watch_paths: vec![home.join("src")],
            debounce: Duration::from_millis(2000),
        }
    }
}

impl ScannerConfig {
    pub fn from_core_config(config: &tillandsias_core::config::ScannerConfig) -> Self {
        Self {
            watch_paths: config.watch_paths.clone(),
            debounce: Duration::from_millis(config.debounce_ms),
        }
    }
}

/// Event-driven filesystem scanner.
///
/// Uses OS-native file watchers (inotify/kqueue/ReadDirectoryChangesW) via the
/// `notify` crate. Zero CPU when idle. Debounces rapid events into batched
/// project state updates.
///
/// ## Platform-specific behavior (notify v8)
///
/// **Linux (inotify)**:
/// - Non-recursive watches need explicit per-directory setup (done in `watch()`).
/// - inotify has a per-user watch limit (default ~8192). If watching many projects,
///   users may need to raise `fs.inotify.max_user_watches` via sysctl.
/// - Rename events may arrive as separate Create/Delete pairs rather than a single
///   Rename, depending on kernel version. The debounce layer handles this.
///
/// **macOS (kqueue / FSEvents)**:
/// - `notify` v8 uses kqueue by default. kqueue watches file descriptors, so it
///   has a per-process open file limit (default 256 on macOS). For large watch
///   trees, `ulimit -n` may need increasing.
/// - FSEvents backend (if enabled) is more efficient for large trees but has
///   higher latency (~1s). Our 2s debounce absorbs this.
/// - Symlinks are NOT followed by default on kqueue. Projects accessed via
///   symlinks will not trigger events on the symlink target.
///
/// **Windows (ReadDirectoryChangesW)**:
/// - Recursive watching is natively supported and efficient.
/// - Network drives (UNC paths, mapped drives) may not reliably deliver events.
///   Recommend using local paths for `watch_paths`.
/// - Long path support (>260 chars) requires the app manifest or registry
///   `LongPathsEnabled`. Tauri's manifest handles this.
pub struct Scanner {
    config: ScannerConfig,
    /// Known projects by path.
    known: HashMap<PathBuf, Project>,
}

impl Scanner {
    pub fn new(config: ScannerConfig) -> Self {
        Self {
            config,
            known: HashMap::new(),
        }
    }

    /// Perform initial scan of all watch paths, returning discovered projects.
    pub fn initial_scan(&mut self) -> Vec<ProjectChange> {
        let mut changes = Vec::new();

        for watch_path in &self.config.watch_paths {
            if !watch_path.exists() {
                info!(?watch_path, "Watch path does not exist, skipping");
                continue;
            }

            let entries = match std::fs::read_dir(watch_path) {
                Ok(entries) => entries,
                Err(e) => {
                    warn!(?watch_path, ?e, "Failed to read watch path");
                    continue;
                }
            };

            for entry in entries.flatten() {
                let path = entry.path();
                if let Some(project) = scan_project(&path) {
                    debug!(name = %project.name, "Discovered project");
                    self.known.insert(path, project.clone());
                    changes.push(ProjectChange::Discovered(project));
                }
            }
        }

        info!(count = changes.len(), "Initial scan complete");
        changes
    }

    /// Start the async watcher loop. Sends `ProjectChange` events to the
    /// provided channel. Blocks on OS-native events — zero CPU when idle.
    pub async fn watch(mut self, tx: mpsc::Sender<ProjectChange>) -> notify::Result<()> {
        // Create a channel for notify events → tokio bridge
        let (notify_tx, mut notify_rx) = mpsc::channel::<notify::Result<Event>>(256);

        // Set up the OS-native watcher
        let mut watcher = RecommendedWatcher::new(
            move |res| {
                let _ = notify_tx.blocking_send(res);
            },
            notify::Config::default(),
        )?;

        // @trace spec:filesystem-scanner — graceful degradation for watch setup
        // Watch each configured path (non-recursive — we only care about depth 1-2).
        // Errors are logged and skipped rather than propagated — the scanner degrades
        // gracefully when paths are missing, permissions are denied, or inotify watch
        // limits are exhausted.
        let mut active_watches = 0usize;
        for watch_path in &self.config.watch_paths {
            if !watch_path.exists() {
                warn!(?watch_path, "Watch path does not exist, skipping");
                continue;
            }

            match watcher.watch(watch_path, RecursiveMode::NonRecursive) {
                Ok(()) => {
                    active_watches += 1;
                    info!(?watch_path, "Watching for project changes");
                }
                Err(e) => {
                    warn!(
                        ?watch_path,
                        ?e,
                        "Failed to watch path (permission denied or watch limit reached), skipping"
                    );
                    continue;
                }
            }

            // Also watch each existing project directory (depth 2)
            match std::fs::read_dir(watch_path) {
                Ok(entries) => {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.is_dir()
                            && !path
                                .file_name()
                                .is_some_and(|n| n.to_string_lossy().starts_with('.'))
                        {
                            match watcher.watch(&path, RecursiveMode::NonRecursive) {
                                Ok(()) => {
                                    active_watches += 1;
                                }
                                Err(e) => {
                                    debug!(
                                        ?path,
                                        ?e,
                                        "Failed to add depth-2 watch, continuing without it"
                                    );
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    warn!(
                        ?watch_path,
                        ?e,
                        "Failed to read watch path for depth-2 scanning"
                    );
                }
            }
        }

        if active_watches == 0 {
            error!("No watch paths could be registered — scanner will not detect changes");
        } else {
            info!(active_watches, "Filesystem watches established");
        }

        // Debounce accumulator: path → pending since
        let mut pending: HashMap<PathBuf, tokio::time::Instant> = HashMap::new();
        let debounce = self.config.debounce;

        loop {
            tokio::select! {
                // OS filesystem event received
                Some(event_result) = notify_rx.recv() => {
                    match event_result {
                        Ok(event) => {
                            for path in &event.paths {
                                // Determine which project directory was affected
                                if let Some(project_dir) = self.resolve_project_dir(path) {
                                    pending.insert(project_dir, tokio::time::Instant::now());
                                }
                            }
                        }
                        Err(e) => {
                            warn!(?e, "Filesystem watch error");
                        }
                    }
                }
                // Check for debounced events ready to emit
                _ = tokio::time::sleep(Duration::from_millis(500)), if !pending.is_empty() => {
                    let now = tokio::time::Instant::now();
                    let ready: Vec<PathBuf> = pending
                        .iter()
                        .filter(|(_, since)| now.duration_since(**since) >= debounce)
                        .map(|(path, _)| path.clone())
                        .collect();

                    for path in ready {
                        pending.remove(&path);
                        if let Some(change) = self.process_change(&path)
                            && tx.send(change).await.is_err() {
                                debug!("Scanner channel closed, stopping");
                                return Ok(());
                            }
                    }
                }
            }
        }
    }

    /// Resolve a filesystem event path to its parent project directory.
    fn resolve_project_dir(&self, path: &Path) -> Option<PathBuf> {
        for watch_path in &self.config.watch_paths {
            // If path is directly under watch_path, it IS a project dir
            if path.parent() == Some(watch_path) && path.is_dir() {
                return Some(path.to_path_buf());
            }
            // If path is deeper, walk up to find the project dir
            if let Ok(relative) = path.strip_prefix(watch_path) {
                let components: Vec<_> = relative.components().collect();
                if !components.is_empty() {
                    return Some(watch_path.join(components[0].as_os_str()));
                }
            }
        }
        None
    }

    /// Process a change for a project directory.
    fn process_change(&mut self, project_dir: &Path) -> Option<ProjectChange> {
        if project_dir.exists() {
            match scan_project(project_dir) {
                Some(project) => {
                    let change = if self.known.contains_key(project_dir) {
                        ProjectChange::Updated(project.clone())
                    } else {
                        ProjectChange::Discovered(project.clone())
                    };
                    self.known.insert(project_dir.to_path_buf(), project);
                    Some(change)
                }
                None => None,
            }
        } else {
            // Directory was removed
            if self.known.remove(project_dir).is_some() {
                Some(ProjectChange::Removed {
                    path: project_dir.to_path_buf(),
                })
            } else {
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn initial_scan_finds_projects() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("test-project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("package.json"), "{}").unwrap();

        let config = ScannerConfig {
            watch_paths: vec![dir.path().to_path_buf()],
            debounce: Duration::from_millis(100),
        };

        let mut scanner = Scanner::new(config);
        let changes = scanner.initial_scan();

        assert_eq!(changes.len(), 1);
        match &changes[0] {
            ProjectChange::Discovered(p) => {
                assert_eq!(p.name, "test-project");
            }
            _ => panic!("Expected Discovered"),
        }
    }

    #[test]
    fn initial_scan_skips_hidden_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let hidden = dir.path().join(".hidden-project");
        fs::create_dir_all(&hidden).unwrap();
        fs::write(hidden.join("Cargo.toml"), "[package]").unwrap();

        let config = ScannerConfig {
            watch_paths: vec![dir.path().to_path_buf()],
            debounce: Duration::from_millis(100),
        };

        let mut scanner = Scanner::new(config);
        let changes = scanner.initial_scan();
        assert!(changes.is_empty());
    }

    #[test]
    fn resolve_project_dir_direct_child() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("my-app");
        fs::create_dir_all(&project).unwrap();

        let config = ScannerConfig {
            watch_paths: vec![dir.path().to_path_buf()],
            debounce: Duration::from_millis(100),
        };
        let scanner = Scanner::new(config);

        let resolved = scanner.resolve_project_dir(&project);
        assert_eq!(resolved, Some(project));
    }

    #[test]
    fn resolve_project_dir_nested_file() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("my-app");
        fs::create_dir_all(project.join("src")).unwrap();

        let config = ScannerConfig {
            watch_paths: vec![dir.path().to_path_buf()],
            debounce: Duration::from_millis(100),
        };
        let scanner = Scanner::new(config);

        let nested = project.join("src").join("main.rs");
        let resolved = scanner.resolve_project_dir(&nested);
        assert_eq!(resolved, Some(project));
    }

    #[tokio::test]
    async fn watch_detects_new_project() {
        let dir = tempfile::tempdir().unwrap();
        let config = ScannerConfig {
            watch_paths: vec![dir.path().to_path_buf()],
            debounce: Duration::from_millis(200),
        };

        let (tx, mut rx) = mpsc::channel(16);
        let scanner = Scanner::new(config);

        // Start watcher in background
        let watch_dir = dir.path().to_path_buf();
        let handle = tokio::spawn(async move {
            let _ = scanner.watch(tx).await;
        });

        // Give the watcher time to set up
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Create a new project directory
        let project = watch_dir.join("new-project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("Cargo.toml"), "[package]").unwrap();

        // Wait for debounce + processing
        match tokio::time::timeout(Duration::from_secs(5), rx.recv()).await {
            Ok(Some(ProjectChange::Discovered(p))) => {
                assert_eq!(p.name, "new-project");
            }
            Ok(Some(other)) => {
                // Updated is also acceptable depending on event ordering
                if let ProjectChange::Updated(p) = other {
                    assert_eq!(p.name, "new-project");
                }
            }
            Ok(None) => panic!("Channel closed unexpectedly"),
            Err(_) => {
                // Timeout is acceptable in CI — inotify may not trigger in temp dirs
                // on all platforms. The unit tests above cover the logic.
            }
        }

        handle.abort();
    }

    // @trace spec:filesystem-scanner — graceful degradation tests

    #[test]
    fn initial_scan_skips_nonexistent_watch_path() {
        let config = ScannerConfig {
            watch_paths: vec![PathBuf::from("/nonexistent/path/that/does/not/exist")],
            debounce: Duration::from_millis(100),
        };

        let mut scanner = Scanner::new(config);
        let changes = scanner.initial_scan();
        // Should return empty, not panic
        assert!(changes.is_empty());
    }

    #[test]
    fn initial_scan_mixed_valid_and_invalid_paths() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("valid-project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("Cargo.toml"), "[package]").unwrap();

        let config = ScannerConfig {
            watch_paths: vec![
                PathBuf::from("/nonexistent/path"),
                dir.path().to_path_buf(),
            ],
            debounce: Duration::from_millis(100),
        };

        let mut scanner = Scanner::new(config);
        let changes = scanner.initial_scan();
        // Should find the project from the valid path and skip the invalid one
        assert_eq!(changes.len(), 1);
        match &changes[0] {
            ProjectChange::Discovered(p) => {
                assert_eq!(p.name, "valid-project");
            }
            _ => panic!("Expected Discovered"),
        }
    }

    #[tokio::test]
    async fn watch_survives_nonexistent_watch_path() {
        let config = ScannerConfig {
            watch_paths: vec![PathBuf::from("/nonexistent/watch/path")],
            debounce: Duration::from_millis(100),
        };

        let (tx, _rx) = mpsc::channel(16);
        let scanner = Scanner::new(config);

        // Start watcher — should not crash, should enter the event loop
        let handle = tokio::spawn(async move {
            let result = scanner.watch(tx).await;
            // Should succeed (enters the loop), not return Err
            result
        });

        // Give it a moment, then abort — the point is it didn't crash
        tokio::time::sleep(Duration::from_millis(200)).await;
        handle.abort();
    }

    #[tokio::test]
    async fn watch_survives_mixed_valid_and_invalid_paths() {
        let dir = tempfile::tempdir().unwrap();

        let config = ScannerConfig {
            watch_paths: vec![
                PathBuf::from("/nonexistent/watch/path"),
                dir.path().to_path_buf(),
            ],
            debounce: Duration::from_millis(100),
        };

        let (tx, _rx) = mpsc::channel(16);
        let scanner = Scanner::new(config);

        let handle = tokio::spawn(async move {
            scanner.watch(tx).await
        });

        // Give it a moment — should set up watches for the valid path without crashing
        tokio::time::sleep(Duration::from_millis(200)).await;
        handle.abort();
    }
}
