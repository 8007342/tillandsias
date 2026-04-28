//! PID → ProjectLabel mapping for browser MCP peer authentication.
//!
//! The tray maintains a synchronized table of forge process PIDs to their
//! project labels. When a forge connects to the host control socket, the
//! tray can look up the connecting peer's PID via SO_PEERCRED and verify
//! that it corresponds to a running forge before allowing MCP frames.
//!
//! @trace spec:host-browser-mcp, spec:tray-app, spec:podman-orchestration

use parking_lot::Mutex;
use std::collections::HashMap;

/// A project identifier for MCP authorization.
pub type ProjectLabel = String;

/// Per-peer registry: maps PID → ProjectLabel for active forge containers.
pub struct PeerTable {
    inner: Mutex<HashMap<u32, ProjectLabel>>,
}

impl PeerTable {
    /// Create a new empty peer table.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// Register a process PID with its project label.
    /// Called synchronously when a forge container is spawned, before stdio is exposed.
    pub fn insert(&self, pid: u32, label: ProjectLabel) {
        self.inner.lock().insert(pid, label);
    }

    /// Unregister a PID from the table.
    /// Called when the forge process exits.
    pub fn remove(&self, pid: u32) {
        self.inner.lock().remove(&pid);
    }

    /// Look up the project label for a given PID.
    pub fn lookup(&self, pid: u32) -> Option<ProjectLabel> {
        self.inner.lock().get(&pid).cloned()
    }

    /// Clear all entries. Called at tray shutdown.
    pub fn clear(&self) {
        self.inner.lock().clear();
    }

    /// Return a snapshot of all entries (for debugging / testing).
    pub fn snapshot(&self) -> Vec<(u32, ProjectLabel)> {
        self.inner
            .lock()
            .iter()
            .map(|(pid, label)| (*pid, label.clone()))
            .collect()
    }
}

impl Default for PeerTable {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_lookup() {
        let table = PeerTable::new();
        table.insert(1234, "my-project".to_string());
        assert_eq!(table.lookup(1234), Some("my-project".to_string()));
    }

    #[test]
    fn lookup_missing_pid() {
        let table = PeerTable::new();
        assert_eq!(table.lookup(9999), None);
    }

    #[test]
    fn remove_clears_entry() {
        let table = PeerTable::new();
        table.insert(1234, "my-project".to_string());
        table.remove(1234);
        assert_eq!(table.lookup(1234), None);
    }

    #[test]
    fn clear_empties_table() {
        let table = PeerTable::new();
        table.insert(1234, "proj1".to_string());
        table.insert(5678, "proj2".to_string());
        table.clear();
        assert_eq!(table.lookup(1234), None);
        assert_eq!(table.lookup(5678), None);
    }

    #[test]
    fn concurrent_insert_remove() {
        let table = std::sync::Arc::new(PeerTable::new());

        let mut handles = vec![];
        for i in 0..10 {
            let t = table.clone();
            let handle = std::thread::spawn(move || {
                t.insert(i, format!("proj-{}", i));
                assert_eq!(t.lookup(i), Some(format!("proj-{}", i)));
                t.remove(i);
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.join().unwrap();
        }

        assert_eq!(table.snapshot().len(), 0);
    }
}
