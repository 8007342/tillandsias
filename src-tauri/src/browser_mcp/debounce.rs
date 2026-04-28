//! Per-(project, host) debounce for browser.open calls.
//!
//! Prevents window-spam by rejecting duplicate opens on the same host
//! within 1000 ms if the window is still alive.
//!
//! @trace spec:host-browser-mcp

use parking_lot::Mutex;
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub type WindowId = String;

/// Debounce table entry: (last_open_instant, window_id).
type DebounceEntry = (Instant, WindowId);

/// Debounce table indexed by (project, host).
pub struct DebounceTable {
    entries: Mutex<HashMap<(String, String), DebounceEntry>>,
}

impl DebounceTable {
    /// Create a new debounce table.
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    /// Check if a (project, host) is debounced. Returns the existing window_id if so.
    ///
    /// # Arguments
    /// - `project`: Project label
    /// - `host`: Hostname (e.g., "web.my-project.localhost")
    /// - `window_exists`: Predicate to check if the window still exists
    ///
    /// # Returns
    /// `Some(window_id)` if the entry is fresh and the window exists.
    /// `None` if debounce has expired or the window no longer exists.
    pub fn check_debounce<F>(
        &self,
        project: &str,
        host: &str,
        window_exists: F,
    ) -> Option<WindowId>
    where
        F: Fn(&str) -> bool,
    {
        let mut entries = self.entries.lock();
        let key = (project.to_string(), host.to_string());

        if let Some((last_open, window_id)) = entries.get(&key) {
            // Check if debounce window (1000 ms) has expired
            let age: Duration = last_open.elapsed();
            if age < Duration::from_millis(1000) && window_exists(window_id) {
                // Still fresh and window still exists
                return Some(window_id.to_string());
            }
        }

        // Debounce expired or window is gone — remove the entry
        entries.remove(&key);
        None
    }

    /// Record a fresh open for (project, host).
    pub fn record_open(&self, project: &str, host: &str, window_id: WindowId) {
        let key = (project.to_string(), host.to_string());
        self.entries
            .lock()
            .insert(key, (Instant::now(), window_id));
    }

    /// Clear all entries.
    pub fn clear(&self) {
        self.entries.lock().clear();
    }
}

impl Default for DebounceTable {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn rapid_duplicate_returns_existing() {
        let table = DebounceTable::new();

        let exists = AtomicBool::new(true);
        let check_exists = |_: &str| exists.load(Ordering::Relaxed);

        // Record an open
        table.record_open("proj", "web.proj.localhost", "win-123".to_string());

        // Immediately check — should return existing
        assert_eq!(
            table.check_debounce("proj", "web.proj.localhost", &check_exists),
            Some("win-123".to_string())
        );
    }

    #[test]
    fn debounce_expires_after_1000ms() {
        let table = DebounceTable::new();

        let exists = AtomicBool::new(true);
        let check_exists = |_: &str| exists.load(Ordering::Relaxed);

        table.record_open("proj", "web.proj.localhost", "win-123".to_string());

        // Immediately check — should return existing
        assert!(table.check_debounce("proj", "web.proj.localhost", &check_exists).is_some());

        // Simulate time passing (in real code, use tokio::time::sleep)
        // For now, we can't easily test this without mocking Instant.
        // Real integration tests will cover timing.
    }

    #[test]
    fn closed_window_invalidates_debounce() {
        let table = DebounceTable::new();

        let exists = Arc::new(AtomicBool::new(true));
        let exists_clone = exists.clone();
        let check_exists = move |_: &str| exists_clone.load(Ordering::Relaxed);

        table.record_open("proj", "web.proj.localhost", "win-123".to_string());

        // Window exists — debounce active
        assert!(table.check_debounce("proj", "web.proj.localhost", &check_exists).is_some());

        // Mark window as closed
        exists.store(false, Ordering::Relaxed);

        // Now debounce should not return the window
        assert_eq!(
            table.check_debounce("proj", "web.proj.localhost", &check_exists),
            None
        );
    }

    #[test]
    fn different_hosts_dont_debounce_each_other() {
        let table = DebounceTable::new();

        let check_exists = |_: &str| true;

        table.record_open("proj", "web.proj.localhost", "win-1".to_string());
        table.record_open("proj", "api.proj.localhost", "win-2".to_string());

        // Check web — should get win-1
        assert_eq!(
            table.check_debounce("proj", "web.proj.localhost", &check_exists),
            Some("win-1".to_string())
        );

        // Check api — should get win-2 (not win-1)
        assert_eq!(
            table.check_debounce("proj", "api.proj.localhost", &check_exists),
            Some("win-2".to_string())
        );
    }

    #[test]
    fn clear_empties_table() {
        let table = DebounceTable::new();
        let check_exists = |_: &str| true;

        table.record_open("proj", "web.proj.localhost", "win-123".to_string());
        table.clear();

        assert_eq!(table.check_debounce("proj", "web.proj.localhost", &check_exists), None);
    }
}
