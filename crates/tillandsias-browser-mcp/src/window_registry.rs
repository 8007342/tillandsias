//! In-memory browser window registry and debounce tracking.
//!
//! @trace spec:host-browser-mcp, spec:browser-window-lifecycle
//! @cheatsheet web/cdp.md

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Child;
use std::time::Instant;

use parking_lot::Mutex;
use tracing::{debug, info};

/// Stable browser window identifier.
pub type WindowId = String;

/// Metadata for a launched browser window.
#[derive(Debug)]
pub struct WindowEntry {
    pub window_id: WindowId,
    pub pid: u32,
    pub cdp_port: u16,
    pub target_id: String,
    pub project_label: String,
    pub user_data_dir: PathBuf,
    pub opened_url: String,
    pub title: String,
    pub child: Option<Child>,
    /// @trace spec:browser-window-timeout
    /// When the window was created.
    pub created_at: Instant,
    /// @trace spec:browser-window-timeout
    /// When the window was last accessed.
    pub last_activity: Instant,
}

#[derive(Debug, Clone)]
pub struct WindowSummary {
    pub window_id: WindowId,
    pub url: String,
    pub title: String,
}

impl WindowEntry {
    /// @trace spec:browser-window-timeout
    /// Check if window has exceeded idle timeout (24 hours).
    pub fn is_idle_timeout(&self) -> bool {
        const IDLE_TIMEOUT_SECS: u64 = 24 * 60 * 60; // 24 hours
        self.last_activity.elapsed().as_secs() > IDLE_TIMEOUT_SECS
    }

    /// @trace spec:browser-window-timeout
    /// Check if window has exceeded absolute lifetime (48 hours).
    pub fn is_lifetime_exceeded(&self) -> bool {
        const MAX_LIFETIME_SECS: u64 = 48 * 60 * 60; // 48 hours
        self.created_at.elapsed().as_secs() > MAX_LIFETIME_SECS
    }

    /// @trace spec:browser-window-timeout
    /// Mark window as having recent activity (reset idle timer).
    pub fn touch_activity(&mut self) {
        self.last_activity = Instant::now();
    }

    /// @trace spec:browser-window-timeout
    /// Get time until idle timeout in seconds. Returns 0 if already timed out.
    pub fn seconds_until_idle_timeout(&self) -> u64 {
        const IDLE_TIMEOUT_SECS: u64 = 24 * 60 * 60;
        let elapsed = self.last_activity.elapsed().as_secs();
        IDLE_TIMEOUT_SECS.saturating_sub(elapsed)
    }
}

#[derive(Debug, Default)]
pub struct WindowRegistry {
    windows: Mutex<HashMap<WindowId, WindowEntry>>,
}

#[derive(Debug, Default)]
pub struct DebounceTable {
    entries: Mutex<HashMap<(String, String), (Instant, WindowId)>>,
}

impl WindowRegistry {
    pub fn insert(&self, entry: WindowEntry) {
        // @trace spec:browser-window-lifecycle
        info!(
            window_id = %entry.window_id,
            project = %entry.project_label,
            url = %entry.opened_url,
            pid = entry.pid,
            "window_created"
        );
        self.windows.lock().insert(entry.window_id.clone(), entry);
    }

    pub fn get(&self, window_id: &str) -> Option<WindowSummary> {
        self.windows
            .lock()
            .get(window_id)
            .map(|entry| WindowSummary {
                window_id: entry.window_id.clone(),
                url: entry.opened_url.clone(),
                title: entry.title.clone(),
            })
    }

    pub fn get_entry(&self, window_id: &str) -> Option<(u16, String)> {
        self.windows
            .lock()
            .get(window_id)
            .map(|entry| (entry.cdp_port, entry.target_id.clone()))
    }

    pub fn get_entry_mut(&self, window_id: &str) -> Option<WindowEntry> {
        self.windows.lock().remove(window_id)
    }

    pub fn list_for_project(&self, project_label: &str) -> Vec<WindowSummary> {
        self.windows
            .lock()
            .values()
            .filter(|entry| entry.project_label == project_label)
            .map(|entry| WindowSummary {
                window_id: entry.window_id.clone(),
                url: entry.opened_url.clone(),
                title: entry.title.clone(),
            })
            .collect()
    }

    pub fn drain_all(&self) -> Vec<WindowEntry> {
        self.windows
            .lock()
            .drain()
            .map(|(_, entry)| entry)
            .collect()
    }

    pub fn contains(&self, window_id: &str) -> bool {
        self.windows.lock().contains_key(window_id)
    }

    /// @trace spec:browser-window-timeout
    /// Check for and return list of windows that have timed out (idle or lifetime exceeded).
    /// Does NOT remove them from the registry.
    pub fn find_timed_out_windows(&self) -> Vec<(WindowId, String)> {
        self.windows
            .lock()
            .iter()
            .filter_map(|(window_id, entry)| {
                if entry.is_idle_timeout() || entry.is_lifetime_exceeded() {
                    Some((window_id.clone(), entry.project_label.clone()))
                } else {
                    None
                }
            })
            .collect()
    }

    /// @trace spec:browser-window-timeout
    /// Mark a window as having recent activity (reset idle timer).
    pub fn touch_window_activity(&self, window_id: &str) -> bool {
        if let Some(entry) = self.windows.lock().get_mut(window_id) {
            entry.touch_activity();
            debug!(window_id = %window_id, "window_activity_touched");
            true
        } else {
            false
        }
    }
}

impl DebounceTable {
    pub fn get(&self, project_label: &str, host: &str) -> Option<(Instant, WindowId)> {
        self.entries
            .lock()
            .get(&(project_label.to_string(), host.to_string()))
            .cloned()
    }

    pub fn record(&self, project_label: &str, host: &str, window_id: WindowId) {
        self.entries.lock().insert(
            (project_label.to_string(), host.to_string()),
            (Instant::now(), window_id),
        );
    }

    pub fn remove_window(&self, window_id: &str) {
        self.entries
            .lock()
            .retain(|_, (_, candidate)| candidate != window_id);
    }
}

fn kill_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

pub fn close_window(
    registry: &WindowRegistry,
    debounce: &DebounceTable,
    window_id: &str,
) -> Option<WindowEntry> {
    let mut entry = registry.get_entry_mut(window_id)?;
    // @trace spec:browser-window-lifecycle
    debug!(
        window_id = %entry.window_id,
        project = %entry.project_label,
        url = %entry.opened_url,
        pid = entry.pid,
        "window_closed"
    );
    if let Some(mut child) = entry.child.take() {
        kill_child(&mut child);
    }
    debounce.remove_window(window_id);
    Some(entry)
}

pub fn close_all(registry: &WindowRegistry, debounce: &DebounceTable) -> Vec<WindowEntry> {
    let mut entries = registry.drain_all();
    // @trace spec:browser-window-lifecycle
    info!(window_count = entries.len(), "closing_all_windows");
    for entry in &mut entries {
        debug!(
            window_id = %entry.window_id,
            project = %entry.project_label,
            "window_closed"
        );
        if let Some(mut child) = entry.child.take() {
            kill_child(&mut child);
        }
        debounce.remove_window(&entry.window_id);
    }
    entries
}
