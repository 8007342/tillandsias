//! In-memory browser window registry and debounce tracking.
//!
//! @trace spec:host-browser-mcp, spec:browser-window-lifecycle
//! @cheatsheet web/cdp.md

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;

use std::sync::Arc;

use crate::launcher::RunningContainer;
use crate::window_cdp::WindowCdp;
use tracing::{debug, info};

/// Stable browser window identifier.
pub type WindowId = String;

/// Metadata for a launched browser window.
#[derive(Debug)]
pub struct WindowEntry {
    pub window_id: WindowId,
    pub pid: u32,
    pub project_label: String,
    pub user_data_dir: PathBuf,
    pub opened_url: String,
    pub title: String,
    /// The lane that opened the window, `<project>/<instance>` (order
    /// 1656-iktu). Every lookup that acts on the window checks it.
    pub owning_lane: String,
    /// Development mode: the owning lane gets full CDP (order 1656-iktu).
    pub dev: bool,
    /// The engine the window runs (order 1656-tjv4).
    pub engine: crate::launcher::Engine,
    /// Headless: no human can see the window; agents drive it over CDP
    /// (order 1712-3fsw).
    pub headless: bool,
    /// What the user should be told about this open (order 1656-tjv4).
    pub notice: Option<String>,
    /// The window's ONE CDP session (order 1655-urz9). Dropped before the
    /// container, so the relay ends Chromium as the session closes.
    pub cdp: Option<Arc<WindowCdp>>,
    /// The window's container; dropping it stops the container (1649-xqet).
    pub container: Option<RunningContainer>,
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
    /// The engine's user-facing name (order 1656-tjv4).
    pub engine: &'static str,
    /// Whether no human can see the window (order 1712-3fsw).
    pub headless: bool,
}

/// ORDER 2142-3kt8. How long a window may go with no CDP command and no user
/// input before the idle reaper stops it (and its forwarder). Measured on
/// macuahuitl 2026-11-20: five headless `browser.open` windows outlived their
/// work by 13-17 hours, each GPU process at 250-300% CPU, and drove 30 GB of
/// swap. The old 24 h constant was never even checked (no caller). Default 15
/// minutes; `TILLANDSIAS_BROWSER_IDLE_MINUTES=0` disables the idle limit.
/// `TILLANDSIAS_BROWSER_IDLE_SECS` overrides it in seconds (fixtures).
pub const DEFAULT_IDLE_MINUTES: u64 = 15;

pub fn idle_timeout() -> Option<Duration> {
    if let Some(secs) = std::env::var("TILLANDSIAS_BROWSER_IDLE_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
    {
        return (secs > 0).then(|| Duration::from_secs(secs));
    }
    let minutes = std::env::var("TILLANDSIAS_BROWSER_IDLE_MINUTES")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_IDLE_MINUTES);
    (minutes > 0).then(|| Duration::from_secs(minutes * 60))
}

/// How often the reaper looks (`TILLANDSIAS_BROWSER_REAP_SECS`, default 30).
fn reap_interval() -> Duration {
    let secs = std::env::var("TILLANDSIAS_BROWSER_REAP_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|s| *s > 0)
        .unwrap_or(30);
    Duration::from_secs(secs)
}

/// The page script that records the last user input, so a headed window a
/// person is using is not reaped while the agent is quiet. Installed on every
/// new document of the window (and once on the current one) at open.
pub const INPUT_LISTENER_SCRIPT: &str = "(() => { if (window.__tillandsiasInput) return; \
window.__tillandsiasInput = true; window.__tillandsiasLastInput = Date.now(); \
for (const t of ['pointerdown','keydown','wheel','touchstart']) \
addEventListener(t, () => { window.__tillandsiasLastInput = Date.now(); }, {capture: true, passive: true}); })()";

impl WindowEntry {
    pub fn is_idle_timeout(&self) -> bool {
        idle_timeout().is_some_and(|limit| self.last_activity.elapsed() > limit)
    }

    pub fn is_lifetime_exceeded(&self) -> bool {
        const MAX_LIFETIME_SECS: u64 = 48 * 60 * 60; // 48 hours
        self.created_at.elapsed().as_secs() > MAX_LIFETIME_SECS
    }

    pub fn touch_activity(&mut self) {
        self.last_activity = Instant::now();
    }

    pub fn seconds_until_idle_timeout(&self) -> u64 {
        match idle_timeout() {
            Some(limit) => limit
                .as_secs()
                .saturating_sub(self.last_activity.elapsed().as_secs()),
            None => u64::MAX,
        }
    }

    /// Which windows the idle limit applies to: headless ones (no person can
    /// see them; the macuahuitl case) and dev windows (which carry the input
    /// listener). A headed non-dev window runs no page script, so input in it
    /// cannot be seen; a person can see and close it, and only the 48 h
    /// lifetime bounds it.
    pub fn idle_reapable(&self) -> bool {
        self.headless || self.dev
    }

    /// Did a person use this window inside the idle limit? Only a headed
    /// window can have one; the page listener answers (absent -> no).
    fn user_input_recent(&self) -> bool {
        if self.headless {
            return false;
        }
        let (Some(cdp), Some(limit)) = (self.cdp.as_ref(), idle_timeout()) else {
            return false;
        };
        let Ok(value) = cdp.evaluate("window.__tillandsiasLastInput || 0") else {
            return false;
        };
        let last_ms = value.as_f64().unwrap_or(0.0) as u128;
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        last_ms > 0 && now_ms.saturating_sub(last_ms) < limit.as_millis()
    }
}

#[derive(Debug, Default)]
pub struct WindowRegistry {
    windows: Mutex<HashMap<WindowId, WindowEntry>>,
    /// ORDER 2142-3kt8: windows the reaper closed, by id -> (owning lane,
    /// reason), so the agent's next call on one answers `browser.closed:<reason>`.
    reaped: Mutex<HashMap<WindowId, (String, &'static str)>>,
    reaper_started: AtomicBool,
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
                engine: entry.engine.label(),
                headless: entry.headless,
            })
    }

    /// The window's CDP session and dev flag, for its owning lane only:
    /// `None` when there is no such window OR another lane opened it (the
    /// two are indistinguishable to the caller, order 1656-iktu); an inner
    /// `None` when the window has no CDP (fake launch mode).
    pub fn cdp_for(
        &self,
        window_id: &str,
        lane: &str,
    ) -> Option<(Option<Arc<WindowCdp>>, bool, crate::launcher::Engine)> {
        self.windows
            .lock()
            .get(window_id)
            .filter(|entry| entry.owning_lane == lane)
            .map(|entry| (entry.cdp.clone(), entry.dev, entry.engine))
    }

    /// Whether `lane` opened `window_id`.
    pub fn owned_by(&self, window_id: &str, lane: &str) -> bool {
        self.windows
            .lock()
            .get(window_id)
            .is_some_and(|entry| entry.owning_lane == lane)
    }

    pub fn get_entry_mut(&self, window_id: &str) -> Option<WindowEntry> {
        self.windows.lock().remove(window_id)
    }

    pub fn list_for_lane(&self, lane: &str) -> Vec<WindowSummary> {
        self.windows
            .lock()
            .values()
            .filter(|entry| entry.owning_lane == lane)
            .map(|entry| WindowSummary {
                window_id: entry.window_id.clone(),
                url: entry.opened_url.clone(),
                title: entry.title.clone(),
                engine: entry.engine.label(),
                headless: entry.headless,
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

impl WindowRegistry {
    /// ORDER 2142-3kt8. Close every window idle past the limit (or past its
    /// 48 h lifetime): CDP dropped, container and forwarder stopped, profile
    /// removed. A headed window a person used inside the limit is kept and its
    /// clock reset. Returns the closed ids with their reason.
    pub fn reap(&self, debounce: &DebounceTable) -> Vec<(WindowId, &'static str)> {
        let candidates: Vec<(WindowId, &'static str)> = self
            .windows
            .lock()
            .values()
            .filter_map(|e| {
                if e.is_lifetime_exceeded() {
                    Some((e.window_id.clone(), "lifetime"))
                } else if e.idle_reapable() && e.is_idle_timeout() {
                    Some((e.window_id.clone(), "idle"))
                } else {
                    None
                }
            })
            .collect();
        let mut closed = Vec::new();
        for (window_id, reason) in candidates {
            if reason == "idle" {
                let used = self
                    .windows
                    .lock()
                    .get(&window_id)
                    .map(|e| e.user_input_recent())
                    .unwrap_or(false);
                if used {
                    self.touch_window_activity(&window_id);
                    continue;
                }
            }
            if let Some(entry) = close_window(self, debounce, &window_id) {
                crate::launcher::remove_profile_dir(&entry.user_data_dir);
                info!(window_id = %window_id, reason, "browser.closed");
                self.reaped
                    .lock()
                    .insert(window_id.clone(), (entry.owning_lane.clone(), reason));
                closed.push((window_id, reason));
            }
        }
        closed
    }

    /// Tests: pretend `window_id` has been quiet for `secs`.
    #[cfg(test)]
    pub fn age_for_test(&self, window_id: &str, secs: u64) {
        if let Some(e) = self.windows.lock().get_mut(window_id) {
            e.last_activity = Instant::now()
                .checked_sub(Duration::from_secs(secs))
                .unwrap_or(e.last_activity);
        }
    }

    /// The reason the reaper closed `window_id`, if it did and `lane` owned
    /// it. Read once: the record is consumed.
    pub fn take_reaped(&self, window_id: &str, lane: &str) -> Option<&'static str> {
        let mut reaped = self.reaped.lock();
        match reaped.get(window_id) {
            Some((owner, reason)) if owner == lane => {
                let reason = *reason;
                reaped.remove(window_id);
                Some(reason)
            }
            _ => None,
        }
    }

    /// Start the idle reaper for this registry, once. It holds only a weak
    /// reference, so it ends with the registry.
    pub fn start_idle_reaper(self: &Arc<Self>, debounce: Arc<DebounceTable>) {
        if self.reaper_started.swap(true, Ordering::SeqCst) {
            return;
        }
        let weak = Arc::downgrade(self);
        let every = reap_interval();
        let _ = std::thread::Builder::new()
            .name("browser-idle-reaper".into())
            .spawn(move || {
                loop {
                    std::thread::sleep(every);
                    let Some(registry) = weak.upgrade() else {
                        break;
                    };
                    registry.reap(&debounce);
                }
            });
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
    drop(entry.cdp.take());
    drop(entry.container.take());
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
        drop(entry.cdp.take());
        drop(entry.container.take());
        debounce.remove_window(&entry.window_id);
    }
    entries
}
