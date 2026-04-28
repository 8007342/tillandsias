//! Browser window registry and lifecycle management.
//!
//! Tracks all open browser windows, their CDP targets, and associated metadata.
//! Windows are identified by stable window_id (UUID) and bound to (project, target_id).
//!
//! @trace spec:host-browser-mcp, spec:host-chromium-on-demand

use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::PathBuf;
use uuid::Uuid;

/// Stable window identifier (UUID).
pub type WindowId = String;

/// Entry in the window registry.
#[derive(Debug, Clone)]
pub struct WindowEntry {
    pub id: WindowId,
    pub pid: u32,
    pub cdp_port: u16,
    pub target_id: String,
    pub project: String,
    pub user_data_dir: PathBuf,
    pub opened_url: String,
}

/// Registry of all active browser windows.
pub struct WindowRegistry {
    windows: Mutex<HashMap<WindowId, WindowEntry>>,
}

impl WindowRegistry {
    /// Create a new window registry.
    pub fn new() -> Self {
        Self {
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Add a window to the registry.
    pub fn insert(&self, window: WindowEntry) {
        self.windows.lock().insert(window.id.clone(), window);
    }

    /// Retrieve a window by ID.
    pub fn get(&self, id: &str) -> Option<WindowEntry> {
        self.windows.lock().get(id).cloned()
    }

    /// Remove a window from the registry.
    pub fn remove(&self, id: &str) -> Option<WindowEntry> {
        self.windows.lock().remove(id)
    }

    /// List all windows for a given project.
    pub fn list_for_project(&self, project: &str) -> Vec<WindowEntry> {
        self.windows
            .lock()
            .values()
            .filter(|w| w.project == project)
            .cloned()
            .collect()
    }

    /// Drain all windows (for shutdown).
    pub fn drain_all(&self) -> Vec<WindowEntry> {
        self.windows.lock().drain().map(|(_, v)| v).collect()
    }

    /// Return a snapshot of all windows.
    pub fn snapshot(&self) -> Vec<WindowEntry> {
        self.windows.lock().values().cloned().collect()
    }
}

impl Default for WindowRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_window(id: &str, project: &str) -> WindowEntry {
        WindowEntry {
            id: id.to_string(),
            pid: 1234,
            cdp_port: 9222,
            target_id: "target-1".to_string(),
            project: project.to_string(),
            user_data_dir: PathBuf::from("/tmp/user-data"),
            opened_url: "http://web.example.localhost:8080".to_string(),
        }
    }

    #[test]
    fn insert_and_get() {
        let reg = WindowRegistry::new();
        let w = sample_window("win-1", "my-project");
        reg.insert(w.clone());
        assert_eq!(reg.get("win-1").unwrap().id, "win-1");
    }

    #[test]
    fn list_for_project() {
        let reg = WindowRegistry::new();
        reg.insert(sample_window("win-1", "proj-a"));
        reg.insert(sample_window("win-2", "proj-a"));
        reg.insert(sample_window("win-3", "proj-b"));
        assert_eq!(reg.list_for_project("proj-a").len(), 2);
        assert_eq!(reg.list_for_project("proj-b").len(), 1);
    }

    #[test]
    fn remove() {
        let reg = WindowRegistry::new();
        reg.insert(sample_window("win-1", "proj"));
        assert!(reg.get("win-1").is_some());
        reg.remove("win-1");
        assert!(reg.get("win-1").is_none());
    }

    #[test]
    fn drain_all() {
        let reg = WindowRegistry::new();
        reg.insert(sample_window("win-1", "proj"));
        reg.insert(sample_window("win-2", "proj"));
        let drained = reg.drain_all();
        assert_eq!(drained.len(), 2);
        assert_eq!(reg.snapshot().len(), 0);
    }
}
