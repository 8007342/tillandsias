//! In-memory browser window registry and debounce tracking.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Child;
use std::time::Instant;

use parking_lot::Mutex;

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
}

#[derive(Debug, Clone)]
pub struct WindowSummary {
    pub window_id: WindowId,
    pub url: String,
    pub title: String,
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
        self.windows.lock().insert(entry.window_id.clone(), entry);
    }

    pub fn get(&self, window_id: &str) -> Option<WindowSummary> {
        self.windows.lock().get(window_id).map(|entry| WindowSummary {
            window_id: entry.window_id.clone(),
            url: entry.opened_url.clone(),
            title: entry.title.clone(),
        })
    }

    pub fn get_entry(&self, window_id: &str) -> Option<(u16, String)> {
        self.windows.lock().get(window_id).map(|entry| (entry.cdp_port, entry.target_id.clone()))
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
        self.windows.lock().drain().map(|(_, entry)| entry).collect()
    }

    pub fn contains(&self, window_id: &str) -> bool {
        self.windows.lock().contains_key(window_id)
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
    if let Some(mut child) = entry.child.take() {
        kill_child(&mut child);
    }
    debounce.remove_window(window_id);
    Some(entry)
}

pub fn close_all(registry: &WindowRegistry, debounce: &DebounceTable) -> Vec<WindowEntry> {
    let mut entries = registry.drain_all();
    for entry in &mut entries {
        if let Some(mut child) = entry.child.take() {
            kill_child(&mut child);
        }
        debounce.remove_window(&entry.window_id);
    }
    entries
}

