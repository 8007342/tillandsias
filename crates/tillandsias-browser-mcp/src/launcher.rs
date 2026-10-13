//! Browser window launcher for `browser.open`.
//!
//! Order 1649-xqet: a window is ALWAYS the chromium-framework container,
//! started by the host through [`BrowserContainers`]. There is no host
//! Chromium path: the old one looked for a binary under
//! `~/.cache/tillandsias/chromium` that nothing downloads, so `browser.open`
//! answered `BROWSER_UNAVAILABLE` on every host, and when a binary WAS there
//! it ran unconfined with the operator's whole network.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
//! @cheatsheet web/cdp.md

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use url::Url;
use uuid::Uuid;

use crate::window_cdp::{DeviceEmulation, WindowCdp};
use crate::window_registry::WindowEntry;

#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    #[error("no browser container launcher is configured for this lane")]
    BrowserUnavailable,
    #[error("failed to start the browser container: {0}")]
    Spawn(String),
    #[error("browser metadata probe failed: {0}")]
    Probe(String),
    #[error("the window's CDP session failed: {0}")]
    Cdp(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// What the host needs to start one browser window.
#[derive(Debug, Clone)]
pub struct ContainerLaunchRequest<'a> {
    pub url: &'a Url,
    pub project_label: &'a str,
    pub window_id: &'a str,
    /// The window's size at launch: the device's CSS viewport, in host DIPs
    /// (order 1655-urz9).
    pub window_size: (u32, u32),
}

/// A started browser window, as the host names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerHandle {
    pub container_name: String,
    pub network_name: String,
    pub profile_dir: PathBuf,
    /// The window's CDP relay socket, in a per-window host directory only
    /// the tray mounts (order 1655-urz9). `None`: the window has no CDP.
    pub cdp_socket: Option<PathBuf>,
}

/// The host side of `browser.open`: start and stop the browser container.
///
/// The tray implements this with `build_project_browser_spec` (Wayland-only,
/// socket-file mount), a per-launch `--internal` network joined only by the
/// router, and Chromium host-resolver rules that send the project's hosts to
/// the router and nothing else anywhere.
pub trait BrowserContainers: Send + Sync {
    /// The router's local-preview TLS port (`preview-tls-port`), when the
    /// preview listener exists. `browser.open` admits this port for https.
    fn preview_tls_port(&self) -> Option<u16>;
    fn start(&self, request: &ContainerLaunchRequest<'_>) -> Result<ContainerHandle, LaunchError>;
    fn stop(&self, handle: &ContainerHandle);
}

/// A running window's container. Dropping it stops the container, so a
/// window cannot outlive the server (and the lane connection) that opened
/// it: a leaked one would also leave its network attached to the router.
pub struct RunningContainer {
    handle: ContainerHandle,
    host: Arc<dyn BrowserContainers>,
}

impl RunningContainer {
    pub fn handle(&self) -> &ContainerHandle {
        &self.handle
    }
}

impl std::fmt::Debug for RunningContainer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RunningContainer")
            .field("handle", &self.handle)
            .finish_non_exhaustive()
    }
}

impl Drop for RunningContainer {
    fn drop(&mut self) {
        self.host.stop(&self.handle);
    }
}

/// How `browser.open` starts a window.
#[derive(Clone)]
pub enum LaunchMode {
    /// Tests: register a window, start nothing.
    Fake,
    /// The chromium-framework container, through the host.
    Container(Arc<dyn BrowserContainers>),
    /// No host launcher wired: every open answers `BROWSER_UNAVAILABLE`.
    Unavailable,
}

fn default_title(url: &Url) -> String {
    url.host_str().unwrap_or("browser").to_string()
}

/// How long `launch` waits for the window container's CDP relay socket.
const CDP_CONNECT_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

/// Launch a browser window emulating `device` and return its registry entry.
///
/// Order 1655-urz9: a container window starts on about:blank. The tray
/// attaches the window's ONE CDP session through its relay socket, emulates
/// the device on the page, and only then navigates to `url`, so the first
/// request already carries the device's UA and the first layout its
/// viewport. Any failure stops the container.
pub fn launch(
    url: &Url,
    project_label: &str,
    mode: &LaunchMode,
    device: &DeviceEmulation,
) -> Result<WindowEntry, LaunchError> {
    let window_id = format!("win-{}", Uuid::new_v4());
    let (container, cdp, title, user_data_dir) = match mode {
        LaunchMode::Unavailable => return Err(LaunchError::BrowserUnavailable),
        LaunchMode::Fake => (None, None, default_title(url), PathBuf::new()),
        // No DevTools port: a host TCP listener would hand full control of
        // the window, cookies included, to every local process. CDP is the
        // container's --remote-debugging-pipe, relayed to a Unix socket.
        LaunchMode::Container(host) => {
            let handle = host.start(&ContainerLaunchRequest {
                url,
                project_label,
                window_id: &window_id,
                window_size: device.window_size(),
            })?;
            let profile_dir = handle.profile_dir.clone();
            let socket = handle.cdp_socket.clone();
            let running = RunningContainer {
                handle,
                host: Arc::clone(host),
            };
            let cdp = match socket {
                Some(socket) => {
                    let cdp = WindowCdp::attach(&socket, device.clone(), CDP_CONNECT_BUDGET)
                        .and_then(|cdp| cdp.navigate(url.as_str()).map(|()| cdp))
                        .map_err(|e| LaunchError::Cdp(e.to_string()))?;
                    Some(Arc::new(cdp))
                }
                None => None,
            };
            (Some(running), cdp, default_title(url), profile_dir)
        }
    };

    // @trace spec:browser-window-timeout
    let now = std::time::Instant::now();
    Ok(WindowEntry {
        window_id,
        pid: 0,
        project_label: project_label.to_string(),
        user_data_dir,
        opened_url: url.as_str().to_string(),
        title,
        cdp,
        container,
        created_at: now,
        last_activity: now,
    })
}

/// Remove a browser profile directory after close.
pub fn remove_profile_dir(path: &Path) {
    if !path.as_os_str().is_empty() {
        let _ = fs::remove_dir_all(path);
    }
}
