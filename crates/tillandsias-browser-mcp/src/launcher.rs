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
    /// Order 1776-pr0g: the window's engine image is being built on first
    /// use, in the background. Nothing was started; call browser.open again.
    /// `step` is `(n, m)` while the build reports one. `retry_after_s` is
    /// when to ask again: [`crate::server::PREPARING_RETRY_AFTER_S`] while it
    /// builds, longer while a failed build waits for its automatic retry
    /// (1776-brk3: "busy, try again in N").
    #[error("{notice}")]
    Preparing {
        engine: Engine,
        notice: String,
        step: Option<(u64, u64)>,
        retry_after_s: u64,
    },
}

/// The engine a window runs (order 1656-tjv4). Its user-facing name is
/// `label()`, everywhere: WebKit is never called Safari alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    Chromium,
    WebKit,
}

impl Engine {
    /// The name a user sees.
    pub fn label(self) -> &'static str {
        match self {
            Engine::Chromium => "Chromium",
            Engine::WebKit => "WebKit (approximates Safari)",
        }
    }

    /// The engine a catalogue device asks for: Apple presets are webkit.
    /// Gecko presets run in Chromium until a Gecko engine exists.
    pub fn for_device(catalogue_engine: &str) -> Self {
        if catalogue_engine == "webkit" {
            Engine::WebKit
        } else {
            Engine::Chromium
        }
    }

    /// `browser.open{engine}`: an explicit choice overrides the device's.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "chromium" | "blink" => Some(Engine::Chromium),
            "webkit" => Some(Engine::WebKit),
            _ => None,
        }
    }
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
    /// The engine to start (order 1656-tjv4).
    pub engine: Engine,
    /// The device, as Playwright context options: what a WebKit window
    /// emulates (a Chromium window gets it over CDP instead).
    pub playwright_context: serde_json::Value,
    /// Start the window with no display (order 1712-3fsw): Chromium
    /// `--headless=new`, no compositor socket. Decided by `browser.open`
    /// before the launch, from the request or [`BrowserContainers::has_display`].
    pub headless: bool,
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
    /// Something the user should be told about this open, e.g. that the
    /// WebKit engine was prepared on first use (order 1656-tjv4).
    pub notice: Option<String>,
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
    /// The `<host>:<port>` pairs the tray has ROUTED for a browser (the
    /// router's route table: a published www preview, a toolchain dev server
    /// such as `flutter run -d web-server`). browser.open admits these beside
    /// the hosts of windows already open (1788-qlwq slice 10): before, opening
    /// one window locked every other routed service of the project out.
    /// Defaults to none: a launcher that cannot tell keeps the old behaviour.
    fn routed_hosts(&self) -> Vec<String> {
        Vec::new()
    }
    /// Whether this host can show a window (order 1712-3fsw). Without one,
    /// `browser.open` starts headless unless the caller insists otherwise.
    /// Defaults to true: a launcher that cannot tell keeps the old behaviour.
    fn has_display(&self) -> bool {
        true
    }
    fn start(&self, request: &ContainerLaunchRequest<'_>) -> Result<ContainerHandle, LaunchError>;
    fn stop(&self, handle: &ContainerHandle);
}

/// A running window's container. Dropping it stops the container, so a
/// window cannot outlive the registry that holds it: a leaked one would also
/// leave its network attached to the router. The tray keeps one registry per
/// lane for the life of the process (order 1754-bu07), so a window outlives
/// the MCP connection that opened it and ends at browser.close or tray Quit.
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

impl LaunchMode {
    /// Whether a window opened this way can be seen (order 1712-3fsw).
    /// `Fake` and `Unavailable` report a display, as before.
    pub fn has_display(&self) -> bool {
        match self {
            LaunchMode::Container(host) => host.has_display(),
            LaunchMode::Fake | LaunchMode::Unavailable => true,
        }
    }
}

fn default_title(url: &Url) -> String {
    url.host_str().unwrap_or("browser").to_string()
}

/// How long `launch` waits for the window container's CDP relay socket.
const CDP_CONNECT_BUDGET: std::time::Duration = std::time::Duration::from_secs(30);

/// Development mode for a window (order 1656-iktu), and whether its pages
/// keep their service workers (order 1725-5uue; dev windows bypass them).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DevMode {
    pub dev: bool,
    pub keep_service_worker: bool,
}

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
    dev: DevMode,
    engine: Engine,
    headless: bool,
) -> Result<WindowEntry, LaunchError> {
    let window_id = format!("win-{}", Uuid::new_v4());
    let (container, cdp, title, user_data_dir, notice) = match mode {
        LaunchMode::Unavailable => return Err(LaunchError::BrowserUnavailable),
        LaunchMode::Fake => (None, None, default_title(url), PathBuf::new(), None),
        // No DevTools port: a host TCP listener would hand full control of
        // the window, cookies included, to every local process. CDP is the
        // container's --remote-debugging-pipe, relayed to a Unix socket.
        LaunchMode::Container(host) => {
            let handle = host.start(&ContainerLaunchRequest {
                url,
                project_label,
                window_id: &window_id,
                window_size: device.window_size(),
                engine,
                playwright_context: device.playwright_context(),
                headless,
            })?;
            let profile_dir = handle.profile_dir.clone();
            let socket = handle.cdp_socket.clone();
            let mut notice = handle.notice.clone();
            let running = RunningContainer {
                handle,
                host: Arc::clone(host),
            };
            // A WebKit window speaks the Playwright protocol, never CDP
            // (1656-tjv4); whatever the host returned, no CDP session.
            let socket = if engine == Engine::WebKit {
                None
            } else {
                socket
            };
            let cdp = match socket {
                Some(socket) => {
                    let cdp = WindowCdp::attach(
                        &socket,
                        device.clone(),
                        dev.dev,
                        dev.keep_service_worker,
                        CDP_CONNECT_BUDGET,
                    )
                    .and_then(|cdp| cdp.navigate(url.as_str()).map(|()| cdp))
                    .map_err(|e| LaunchError::Cdp(e.to_string()))?;
                    // Order 1725-cgh2: say so when the first load had to
                    // start over, so a slower open is explained.
                    let recovered = cdp.network_recoveries();
                    if recovered > 0 {
                        let line = format!(
                            "The page was loaded again {recovered} time(s): a network change at window start (net::ERR_NETWORK_CHANGED) interrupted its first load."
                        );
                        notice = Some(match notice.take() {
                            Some(n) => format!("{n} {line}"),
                            None => line,
                        });
                    }
                    Some(Arc::new(cdp))
                }
                None => None,
            };
            (Some(running), cdp, default_title(url), profile_dir, notice)
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
        owning_lane: String::new(),
        dev: dev.dev,
        engine,
        headless,
        notice,
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
