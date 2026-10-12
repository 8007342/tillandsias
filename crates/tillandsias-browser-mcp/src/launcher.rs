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
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::window_registry::WindowEntry;

#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    #[error("no browser container launcher is configured for this lane")]
    BrowserUnavailable,
    #[error("failed to start the browser container: {0}")]
    Spawn(String),
    #[error("browser metadata probe failed: {0}")]
    Probe(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// What the host needs to start one browser window.
#[derive(Debug, Clone)]
pub struct ContainerLaunchRequest<'a> {
    pub url: &'a Url,
    pub project_label: &'a str,
    pub window_id: &'a str,
    /// Host loopback port the container's CDP relay is published on.
    pub cdp_host_port: u16,
}

/// A started browser window, as the host names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerHandle {
    pub container_name: String,
    pub network_name: String,
    pub profile_dir: PathBuf,
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
    /// How long to wait for the container's CDP relay to list a target.
    fn cdp_probe_budget(&self) -> Duration {
        CDP_PROBE_BUDGET
    }
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

fn reserve_port() -> Result<u16, std::io::Error> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// A container start (image already present) takes seconds, not the
/// 1.5 s the host binary needed.
const CDP_PROBE_BUDGET: Duration = Duration::from_secs(20);

fn cdp_http_list(port: u16, budget: Duration) -> Result<Option<(String, String)>, LaunchError> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        let attempt =
            TcpStream::connect_timeout(&addr, Duration::from_millis(150)).and_then(|mut stream| {
                stream.set_read_timeout(Some(Duration::from_millis(500)))?;
                stream.set_write_timeout(Some(Duration::from_millis(500)))?;
                stream.write_all(
                    b"GET /json/list HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
                )?;
                let mut response = String::new();
                stream.read_to_string(&mut response)?;
                Ok(response)
            });
        // The relay accepts before Chromium listens, and then closes the
        // connection with nothing written: retry until a target appears.
        if let Ok(response) = attempt {
            let body = response
                .split_once("\r\n\r\n")
                .map(|(_, body)| body)
                .unwrap_or("");
            if let Ok(parsed) = serde_json::from_str::<Value>(body)
                && let Some(first) = parsed.as_array().and_then(|items| items.first())
            {
                let target_id = first
                    .get("id")
                    .and_then(|value| value.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let title = first
                    .get("title")
                    .and_then(|value| value.as_str())
                    .unwrap_or("browser")
                    .to_string();
                return Ok(Some((target_id, title)));
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }

    Ok(None)
}

fn default_title(url: &Url) -> String {
    url.host_str().unwrap_or("browser").to_string()
}

/// Launch a browser window and return its registry entry.
pub fn launch(
    url: &Url,
    project_label: &str,
    mode: &LaunchMode,
) -> Result<WindowEntry, LaunchError> {
    let window_id = format!("win-{}", Uuid::new_v4());
    let (container, cdp_port, target_id, title, user_data_dir) = match mode {
        LaunchMode::Unavailable => return Err(LaunchError::BrowserUnavailable),
        LaunchMode::Fake => (
            None,
            0,
            format!("{window_id}-target"),
            default_title(url),
            PathBuf::new(),
        ),
        LaunchMode::Container(host) => {
            let cdp_port = reserve_port()?;
            let handle = host.start(&ContainerLaunchRequest {
                url,
                project_label,
                window_id: &window_id,
                cdp_host_port: cdp_port,
            })?;
            let profile_dir = handle.profile_dir.clone();
            let running = RunningContainer {
                handle,
                host: Arc::clone(host),
            };
            let probe = cdp_http_list(cdp_port, host.cdp_probe_budget()).unwrap_or(None);
            let (target_id, title) =
                probe.unwrap_or_else(|| (format!("{window_id}-target"), default_title(url)));
            (Some(running), cdp_port, target_id, title, profile_dir)
        }
    };

    // @trace spec:browser-window-timeout
    let now = std::time::Instant::now();
    Ok(WindowEntry {
        window_id,
        pid: 0,
        cdp_port,
        target_id,
        project_label: project_label.to_string(),
        user_data_dir,
        opened_url: url.as_str().to_string(),
        title,
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
