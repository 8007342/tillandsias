//! Core MCP server implementation with JSON-RPC method dispatch.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
//! @cheatsheet web/mcp.md, web/cdp.md

use crate::allowlist::{self, BrowserAllowlist};
use crate::cdp_client::CdpError;
use crate::framing::{RpcRequest, RpcResponse};
use crate::launcher::{self, BrowserContainers, Engine, LaunchError, LaunchMode};
use crate::window_cdp::{DeviceEmulation, WindowCdp};
use crate::window_registry::{DebounceTable, WindowRegistry, close_window};
use base64::Engine as _;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

/// Order 1725-5uue: how long browser.open waits, once the page has loaded,
/// for a KEPT service worker to register before naming none.
const SERVICE_WORKER_WAIT: Duration = Duration::from_secs(2);
use url;

/// Configuration for the MCP server.
///
/// Order 779-dqsv removed `max_concurrent_calls_per_session`. See
/// [`BrowserMcpServer`] for why a concurrency limit here was unreachable.
#[derive(Default)]
pub struct McpServerConfig {}

/// Per-session state: tracks session metadata.
pub struct SessionState {
    pub session_id: u64,
    pub project_label: String,
}

/// ORDER 1767-5q4b. The CDP domains `browser.cdp` forwards: the window's own
/// page, and nothing that reaches past it. Browser.*, Target.*, SystemInfo.*,
/// Storage.*, Tracing.* and every other domain are refused, because from a
/// page session they act on the whole browser: Browser.grantPermissions lifts
/// the microphone prompt, Target.* opens or attaches to other contexts,
/// Storage.* reads other origins. A domain is added here by name, with why.
const CDP_PAGE_DOMAINS: &[&str] = &[
    "Accessibility",
    "Animation",
    "CSS",
    "Console",
    "DOM",
    "DOMDebugger",
    "DOMSnapshot",
    "Debugger",
    "Emulation",
    "Fetch",
    "HeapProfiler",
    "Input",
    "LayerTree",
    "Log",
    "Network",
    "Overlay",
    "Page",
    "Performance",
    "Profiler",
    "Runtime",
];

/// Methods inside an allowed domain that still reach past the window.
const CDP_REFUSED_METHODS: &[(&str, &str)] = &[
    (
        "Page.setDownloadBehavior",
        "it lets the page write downloads to the container",
    ),
    (
        "Network.getAllCookies",
        "it returns every origin's cookies, not this window's",
    ),
    (
        "Network.clearBrowserCookies",
        "it clears every origin's cookies",
    ),
];

/// Whether a raw CDP call stays on the window's page. `Err` carries why.
fn cdp_method_allowed(
    method: &str,
    browser_level: bool,
    session: Option<&str>,
    page: &str,
) -> Result<(), String> {
    if browser_level {
        return Err(
            "browser-level CDP is not available; raw CDP runs on the window's page session".into(),
        );
    }
    if session.is_some_and(|s| s != page) {
        return Err("only the window's own page session is reachable".into());
    }
    if let Some((_, why)) = CDP_REFUSED_METHODS.iter().find(|(m, _)| *m == method) {
        return Err((*why).into());
    }
    let domain = method.split('.').next().unwrap_or("");
    if !CDP_PAGE_DOMAINS.contains(&domain) {
        return Err(format!(
            "the {domain} domain acts beyond the window's page; allowed domains: {}",
            CDP_PAGE_DOMAINS.join(", ")
        ));
    }
    Ok(())
}

/// The MCP server instance.
///
/// **No concurrent-call limit (order 779-dqsv).** This server used to hold a
/// 16-permit semaphore acquired with `try_acquire_owned`, returning
/// `ConcurrentCallLimit` when exhausted. It could never fire: its only
/// transport is the per-lane NDJSON socket, whose loop reads one line,
/// handles it to completion, and only then reads the next — so at most ONE
/// permit was ever held, and 16 in-flight calls could not exist. A limit
/// that cannot bind is not protection; it reads as protection, which is
/// worse. Removed rather than left as an untaken branch (the same rule that
/// retired the proxy CA-key bind-mount fallback in 755-qcxh).
///
/// What the transport DOES enforce is one in-flight `tools/call` per lane
/// connection, pinned by
/// `tray::tests::mcp_lane_transport_serializes_one_call_at_a_time`. If a
/// future transport pipelines requests, reintroduce a limit THERE, where it
/// can actually bind, and give it a test that observes a rejection.
///
/// @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
pub struct BrowserMcpServer {
    project_label: String,
    /// Order 1649-xqet: a window is the chromium-framework container started
    /// by the host, never host Chromium.
    launch_mode: LaunchMode,
    /// Tests: a fixed local-preview TLS port instead of the host's.
    preview_tls_port_override: Option<u16>,
    /// Order 1655-urz9: the device a window emulates when `browser.open`
    /// names none: the project's `.tillandsias/config.toml` `[browser]
    /// device`, else `desktop`.
    default_device: String,
    /// The lane instance this server serves (order 1656-iktu). A window's
    /// owner is `<project>/<instance>`; every lookup checks it.
    lane: String,
    windows: Arc<WindowRegistry>,
    debounce: Arc<DebounceTable>,
}

impl BrowserMcpServer {
    /// Create a new MCP server with the given config.
    /// @trace spec:host-browser-mcp
    pub fn new(config: McpServerConfig) -> Self {
        let project_label =
            std::env::var("TILLANDSIAS_PROJECT").unwrap_or_else(|_| "unknown".to_string());
        Self::with_project_label(config, project_label, None)
    }

    /// Pin a project label and the host's browser container launcher. With
    /// no launcher, `browser.open` answers `BROWSER_UNAVAILABLE`.
    pub fn with_project_label(
        config: McpServerConfig,
        project_label: impl Into<String>,
        containers: Option<Arc<dyn BrowserContainers>>,
    ) -> Self {
        Self::with_project_label_and_mode(config, project_label, containers, false)
    }

    /// Test helper: pin a project label, launcher, and launch mode.
    /// `fake_launch` registers windows without starting anything.
    pub fn with_project_label_and_mode(
        _config: McpServerConfig,
        project_label: impl Into<String>,
        containers: Option<Arc<dyn BrowserContainers>>,
        fake_launch: bool,
    ) -> Self {
        let launch_mode = match (fake_launch, containers) {
            (true, _) => LaunchMode::Fake,
            (false, Some(host)) => LaunchMode::Container(host),
            (false, None) => LaunchMode::Unavailable,
        };
        Self {
            project_label: project_label.into(),
            launch_mode,
            preview_tls_port_override: None,
            default_device: "desktop".to_string(),
            lane: "default".to_string(),
            windows: Arc::new(WindowRegistry::default()),
            debounce: Arc::new(DebounceTable::default()),
        }
    }

    /// Dispatch an RPC request to the appropriate handler.
    pub async fn handle_request(&self, request: RpcRequest) -> RpcResponse {
        match request.method.as_str() {
            "initialize" => self.handle_initialize(&request),
            "tools/list" => self.handle_tools_list(&request),
            "tools/call" => self.handle_tools_call(&request).await,
            "prompts/list" => self.handle_prompts_list(&request),
            "resources/list" => self.handle_resources_list(&request),
            "resources/templates/list" => self.handle_resources_templates_list(&request),
            "notifications/initialized" => RpcResponse::Notification,
            _ => {
                if let Some(id) = request.id {
                    RpcResponse::Error {
                        id,
                        code: -32601,
                        message: format!("Method not found: {}", request.method),
                    }
                } else {
                    RpcResponse::Notification
                }
            }
        }
    }

    fn tool_error(id: u64, text: impl Into<String>) -> RpcResponse {
        RpcResponse::Success {
            id,
            result: json!({
                "content": [{
                    "type": "text",
                    "text": text.into(),
                }],
                "isError": true
            }),
        }
    }

    fn json_rpc_error(id: u64, code: i32, message: impl Into<String>) -> RpcResponse {
        RpcResponse::Error {
            id,
            code,
            message: message.into(),
        }
    }

    fn requested_tool_name(request: &RpcRequest) -> Option<&str> {
        request.params.get("name").and_then(|value| value.as_str())
    }

    fn requested_arguments(request: &RpcRequest) -> &serde_json::Value {
        request.params.get("arguments").unwrap_or(&request.params)
    }

    /// The device windows emulate when `browser.open` names none (the
    /// project config's `[browser] device`). Order 1655-urz9.
    pub fn with_default_device(mut self, device: impl Into<String>) -> Self {
        self.default_device = device.into();
        self
    }

    /// Pin the lane instance this server serves (the tray passes the
    /// listener's LaneIdentity instance). Order 1656-iktu.
    pub fn with_lane(mut self, instance: impl Into<String>) -> Self {
        self.lane = instance.into();
        self
    }

    /// Order 1754-bu07: share the window registry (and its debounce table)
    /// that outlives this server. The tray keeps one per lane, so a window
    /// stays open after the MCP connection that opened it ends, as the
    /// host-browser-mcp spec requires ("Window survives MCP connection
    /// drop"): until browser.close, the user closing it, or tray Quit. A
    /// per-server registry dropped the window, and SIGKILLed its container,
    /// when a one-shot `opencode run` exited.
    pub fn with_windows(
        mut self,
        windows: Arc<WindowRegistry>,
        debounce: Arc<DebounceTable>,
    ) -> Self {
        self.windows = windows;
        self.debounce = debounce;
        self
    }

    /// The owner a window opened here records: `<project>/<instance>`.
    fn owner(&self) -> String {
        format!("{}/{}", self.project_label, self.lane)
    }

    /// Resolve a device query against the 1643-q3at catalogue.
    fn resolve_device(query: &str) -> Result<DeviceEmulation, String> {
        tillandsias_core::devices::resolve(query)
            .map(|r| DeviceEmulation::from_resolution(&r))
            .ok_or_else(|| {
                format!(
                    "DEVICE_UNKNOWN: no catalogue device matches {query:?} \
                     (see `tillandsias devices resolve <query>`)"
                )
            })
    }

    /// A window's CDP session, its first page and its dev flag, or the tool
    /// error. Another lane's window is WINDOW_NOT_FOUND, exactly like a
    /// window that does not exist (order 1656-iktu).
    fn window_page(
        &self,
        id: u64,
        window_id: &str,
    ) -> Result<(Arc<WindowCdp>, String, bool), RpcResponse> {
        match self.windows.cdp_for(window_id, &self.owner()) {
            None => Err(Self::tool_error(
                id,
                format!("WINDOW_NOT_FOUND: {window_id}"),
            )),
            Some((None, _, Engine::WebKit)) => Err(Self::tool_error(
                id,
                format!(
                    "ENGINE_UNSUPPORTED: this tool needs CDP, and a {} window speaks the Playwright protocol; engine-neutral tools are order 1656-twhk",
                    Engine::WebKit.label()
                ),
            )),
            Some((None, _, Engine::Chromium)) => Err(Self::tool_error(
                id,
                "WINDOW_NOT_RUNNING: the window has no CDP session (fake launch mode)",
            )),
            Some((Some(cdp), dev, _)) => match cdp.main_session() {
                Some(page) => Ok((cdp, page, dev)),
                None => Err(Self::tool_error(
                    id,
                    "WINDOW_NOT_RUNNING: the window has no page",
                )),
            },
        }
    }

    /// `window_page` for the dev-mode tools: a normal window is refused.
    fn dev_window(
        &self,
        id: u64,
        window_id: &str,
        tool: &str,
    ) -> Result<(Arc<WindowCdp>, String), RpcResponse> {
        let (cdp, page, dev) = self.window_page(id, window_id)?;
        if !dev {
            return Err(Self::tool_error(
                id,
                format!(
                    "DEV_MODE_REQUIRED: {tool} needs a development-mode window; open it with browser.open{{url, dev: true}}"
                ),
            ));
        }
        Ok((cdp, page))
    }

    /// Test helper: admit a fixed local-preview TLS port.
    pub fn with_preview_tls_port(mut self, port: u16) -> Self {
        self.preview_tls_port_override = Some(port);
        self
    }

    /// The router's local-preview TLS port, read from the host on every
    /// open: the listener may come up after this lane connected.
    fn preview_tls_port(&self) -> Option<u16> {
        self.preview_tls_port_override.or(match &self.launch_mode {
            LaunchMode::Container(host) => host.preview_tls_port(),
            LaunchMode::Fake | LaunchMode::Unavailable => None,
        })
    }

    /// Build the active routes allowlist from the current window registry.
    /// @trace spec:host-browser-mcp
    fn build_active_routes_allowlist(&self) -> BrowserAllowlist {
        let windows = self.windows.list_for_lane(&self.owner());
        let active_hosts: Vec<String> = windows
            .iter()
            .filter_map(|window| {
                // Parse the URL to extract host and port
                if let Ok(parsed) = url::Url::parse(&window.url)
                    && let Some(host) = parsed.host_str()
                {
                    let port = parsed.port().unwrap_or(8080);
                    return Some(format!("{}:{}", host, port));
                }
                None
            })
            .collect();

        BrowserAllowlist::new(&active_hosts).with_preview_tls_port(self.preview_tls_port())
    }

    /// Handle `initialize` request (first call after connection).
    fn handle_initialize(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "initialize requires an id".to_string(),
                };
            }
        };

        // Server version reports the workspace release VERSION (e.g.
        // `0.2.260528.1`), NOT the crate-static `Cargo.toml` version
        // (`0.1.170`). The MCP `serverInfo.version` field is what the
        // AI agent sees; reporting the workspace release lets an
        // operator pasting the agent's serverInfo into a bug report
        // correlate the response to a specific release. `WORKSPACE_
        // VERSION` is baked at build time by `build.rs` reading the
        // repo-root `VERSION` file.
        //
        // @trace spec:host-browser-mcp (follow-on of host-shell fix
        //   76f93287 / tray-convergence-coordination.md 2026-05-30T11:00Z)
        let result = json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "tillandsias-browser-mcp",
                "version": env!("WORKSPACE_VERSION")
            }
        });

        RpcResponse::Success { id, result }
    }

    /// Handle `tools/list` request (return all available tools).
    /// @trace spec:host-browser-mcp
    fn handle_tools_list(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "tools/list requires an id".to_string(),
                };
            }
        };

        let tools = json!([
            {
                "name": "browser.open",
                "description": "Open a browser window for a project-local URL. The reply's headless field says whether a human can see it: headless: true means NO human can see the window, and only agents drive it (over CDP in dev mode). The window stays open after this session ends, until browser.close or the user closes it.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "url": {
                            "type": "string",
                            "description": "The URL to open (must match allowlist: <service>.<project>.localhost:8080, or https on the local-preview port, e.g. https://www.<project>.localhost:18443)"
                        },
                        "engine": {
                            "type": "string",
                            "enum": ["chromium", "webkit"],
                            "description": "The engine: default is the device's (Apple presets open in \"WebKit (approximates Safari)\", everything else in Chromium). \"chromium\" emulates any preset in Chromium."
                        },
                        "dev": {
                            "type": "boolean",
                            "description": "Development mode: the lane that opens the window gets full browser control (browser.cdp, browser.eval, browser.navigate, console and network tails). The window's network is unchanged: it still reaches only this project."
                        },
                        "keep_service_worker": {
                            "type": "boolean",
                            "description": "Development mode only. Default false: every page BYPASSES service workers, so a reload always reaches the preview and a stopped preview shows as down, never as a cached build. true keeps them (for testing offline and update flows), and the reply names the registered worker scripts. The reply's service_workers field says which applied."
                        },
                        "device": {
                            "type": "string",
                            "description": "The device to emulate, e.g. \"iphone 12 pro max\", \"galaxy s24\", \"desktop\" (default: the project's .tillandsias/config.toml [browser] device, else desktop). The window opens at the device's CSS viewport with its dpr, UA and touch."
                        },
                        "headless": {
                            "type": "boolean",
                            "description": "true: a headless window that no human can see, for agents driving it themselves (faster). false: a visible window a human can watch and use. Default: visible when this host has a display, else headless. A headless window is Chromium; a device that defaults to WebKit is emulated in Chromium, and the reply's notice says so."
                        }
                    },
                    "required": ["url"]
                }
            },
            {
                "name": "browser.cdp",
                "description": "Development-mode windows only (browser.open{dev:true}): send a Chrome DevTools Protocol command to the window's page session and return CDP's result. Page-level domains only (Page, Runtime, DOM, CSS, Input, Network, Emulation, Debugger, Log, Console, Overlay and the like); browser-level CDP, other sessions, and domains that act beyond the page (Browser, Target, Storage, SystemInfo, ...) are refused with CDP_METHOD_REFUSED, so a lane cannot grant itself permissions such as the microphone. Page CDP exposes the window's own session cookies (Network.getCookies) to the owning lane, the lane that opened the window, and to no other lane. It does not widen the window's network: the window still reaches only this project's routes.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": { "type": "string" },
                        "method": { "type": "string", "description": "A CDP method, e.g. Runtime.evaluate" },
                        "params": { "type": "object" },
                        "sessionId": { "type": "string" },
                        "browser_level": { "type": "boolean" }
                    },
                    "required": ["window_id", "method"]
                }
            },
            {
                "name": "browser.navigate",
                "description": "Development-mode windows only: load a project URL in the window (the same allowlist as browser.open)",
                "inputSchema": {
                    "type": "object",
                    "properties": { "window_id": { "type": "string" }, "url": { "type": "string" } },
                    "required": ["window_id", "url"]
                }
            },
            {
                "name": "browser.console_tail",
                "description": "Development-mode windows only: the window's last console messages and exceptions (newest last)",
                "inputSchema": {
                    "type": "object",
                    "properties": { "window_id": { "type": "string" }, "limit": { "type": "integer" } },
                    "required": ["window_id"]
                }
            },
            {
                "name": "browser.network_tail",
                "description": "Development-mode windows only: the window's last network requests, responses and failures (newest last)",
                "inputSchema": {
                    "type": "object",
                    "properties": { "window_id": { "type": "string" }, "limit": { "type": "integer" } },
                    "required": ["window_id"]
                }
            },
            {
                "name": "browser.set_device",
                "description": "Switch an open window to another emulated device, live",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": { "type": "string" },
                        "device": { "type": "string", "description": "A device query, as for browser.open" }
                    },
                    "required": ["window_id", "device"]
                }
            },
            {
                "name": "browser.list_windows",
                "description": "List all open browser windows for this project",
                "inputSchema": {
                    "type": "object",
                    "properties": {}
                }
            },
            {
                "name": "browser.read_url",
                "description": "Read the current URL and title from an open window",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string",
                            "description": "The window ID from browser.open"
                        }
                    },
                    "required": ["window_id"]
                }
            },
            {
                "name": "browser.screenshot",
                "description": "Capture a screenshot of the window",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string",
                            "description": "The window ID"
                        },
                        "full_page": {
                            "type": "boolean",
                            "description": "Capture full page (true) or viewport (false, default)"
                        }
                    },
                    "required": ["window_id"]
                }
            },
            {
                "name": "browser.click",
                "description": "Click an element matching a CSS selector",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string"
                        },
                        "selector": {
                            "type": "string",
                            "description": "CSS selector for the element"
                        }
                    },
                    "required": ["window_id", "selector"]
                }
            },
            {
                "name": "browser.type",
                "description": "Type text into an element",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string"
                        },
                        "selector": {
                            "type": "string"
                        },
                        "text": {
                            "type": "string"
                        }
                    },
                    "required": ["window_id", "selector", "text"]
                }
            },
            {
                "name": "browser.eval",
                "description": "Development-mode windows only (browser.open{dev:true}): evaluate a JavaScript expression in the page and return its value (promises awaited)",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string"
                        },
                        "expression": {
                            "type": "string"
                        }
                    },
                    "required": ["window_id", "expression"]
                }
            },
            {
                "name": "browser.close",
                "description": "Close a browser window",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "window_id": {
                            "type": "string"
                        }
                    },
                    "required": ["window_id"]
                }
            }
        ]);

        RpcResponse::Success {
            id,
            result: json!({
                "tools": tools
            }),
        }
    }

    async fn handle_tools_call(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => return Self::json_rpc_error(0, -32600, "tools/call requires an id"),
        };

        let tool_name = match Self::requested_tool_name(request) {
            Some(name) => name,
            None => return Self::json_rpc_error(id, -32602, "tools/call requires name"),
        };
        let args = Self::requested_arguments(request);

        let response = match tool_name {
            "browser.open" => self.handle_browser_open(id, args),
            "browser.list_windows" => self.handle_browser_list_windows(id),
            "browser.read_url" => self.handle_browser_read_url(id, args),
            "browser.screenshot" => self.handle_browser_screenshot(id, args).await,
            "browser.click" => self.handle_browser_click(id, args).await,
            "browser.type" => self.handle_browser_type(id, args).await,
            "browser.eval" => self.handle_browser_eval(id, args),
            "browser.cdp" => self.handle_browser_cdp(id, args),
            "browser.navigate" => self.handle_browser_navigate(id, args),
            "browser.console_tail" => self.handle_browser_tail(id, args, "browser.console_tail"),
            "browser.network_tail" => self.handle_browser_tail(id, args, "browser.network_tail"),
            "browser.close" => self.handle_browser_close(id, args),
            "browser.set_device" => self.handle_browser_set_device(id, args),
            other => Self::tool_error(id, format!("TOOL_NOT_FOUND: {other}")),
        };
        // Order 1696-gz2y: every success reaches the client as MCP content.
        match response {
            RpcResponse::Success { id, result } => RpcResponse::Success {
                id,
                result: crate::framing::tool_result_content(result),
            },
            other => other,
        }
    }

    fn handle_browser_open(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(url) = args.get("url").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.open requires arguments.url");
        };

        // Layer 1: Basic format validation
        // @trace spec:host-browser-mcp
        let allowed = match allowlist::validate_with_preview(
            url,
            &self.project_label,
            self.preview_tls_port(),
        ) {
            Ok(allowed) => allowed,
            Err(reason) => {
                return Self::tool_error(id, format!("URL_NOT_ALLOWED: {reason}"));
            }
        };

        // Order 1651-5t7n: a container window reaches its project only over
        // TLS (its forwarder admits nothing else, because a plaintext Host
        // cannot be bound to a project). Admitting an http URL would open a
        // window that cannot load, so the allowlist refuses it here.
        if matches!(self.launch_mode, LaunchMode::Container(_)) && allowed.url.scheme() != "https" {
            return Self::tool_error(
                id,
                format!(
                    "URL_NOT_ALLOWED: browser windows load the project over https only; \
                     open https://www.{}.localhost:<preview port> instead",
                    self.project_label
                ),
            );
        }

        // Layer 2: Defense-in-depth allowlist enforcement against active routes
        // @trace spec:host-browser-mcp
        let route_allowlist = self.build_active_routes_allowlist();
        if !route_allowlist.is_allowed(url) {
            return Self::tool_error(
                id,
                format!(
                    "URL_NOT_ALLOWED: not in active routes for project '{}'",
                    self.project_label
                ),
            );
        }

        // Order 1656-iktu: development mode gives the owning lane full CDP.
        let dev = args
            .get("dev")
            .and_then(|value| value.as_bool())
            .unwrap_or(false);

        // Order 1725-5uue: dev windows bypass service workers unless kept.
        let keep_service_worker = args
            .get("keep_service_worker")
            .and_then(|value| value.as_bool())
            .unwrap_or(false);

        // Order 1655-urz9: resolve the device before anything starts.
        // Order 1656-tjv4: and the engine, from the device or `engine`.
        let device_query = args
            .get("device")
            .and_then(|value| value.as_str())
            .unwrap_or(&self.default_device);
        let device = match Self::resolve_device(device_query) {
            Ok(device) => device,
            Err(err) => return Self::tool_error(id, err),
        };
        let engine_named = args.get("engine").and_then(|value| value.as_str());
        let mut engine = match engine_named {
            None => Engine::for_device(&device.engine),
            Some(name) => match Engine::parse(name) {
                Some(engine) => engine,
                None => {
                    return Self::tool_error(
                        id,
                        format!("ENGINE_UNKNOWN: {name:?}; use \"chromium\" or \"webkit\""),
                    );
                }
            },
        };

        // Order 1712-3fsw: headless when asked, or by default when this host
        // cannot show a window (macOS today, Linux without Wayland).
        let has_display = self.launch_mode.has_display();
        let headless = match args.get("headless") {
            None | Some(serde_json::Value::Null) => !has_display,
            Some(serde_json::Value::Bool(headless)) => *headless,
            Some(_) => {
                return Self::tool_error(id, "INVALID_HEADLESS: headless must be true or false");
            }
        };
        if !headless && !has_display {
            return Self::tool_error(
                id,
                "DISPLAY_UNAVAILABLE: this host has no display to show a window on; \
                 omit headless (or pass headless: true) for a headless window an agent drives over CDP",
            );
        }
        // A headless window is Chromium: the WebKit engine needs a compositor.
        // A device that only DEFAULTS to WebKit is emulated in Chromium and
        // the reply says so; an explicit engine: "webkit" is refused.
        let mut engine_notice = None;
        if headless && engine == Engine::WebKit {
            if engine_named.is_some() {
                return Self::tool_error(
                    id,
                    format!(
                        "ENGINE_UNSUPPORTED: a headless window is Chromium, and {} needs a display; \
                         omit engine to emulate the device in Chromium",
                        Engine::WebKit.label()
                    ),
                );
            }
            engine = Engine::Chromium;
            engine_notice = Some(format!(
                "Emulated in Chromium: {} needs a display, and this window is headless.",
                Engine::WebKit.label()
            ));
        }
        if dev && engine == Engine::WebKit {
            return Self::tool_error(
                id,
                format!(
                    "ENGINE_UNSUPPORTED: development mode is CDP, and a {} window speaks the Playwright protocol (order 1656-twhk); open it with engine: \"chromium\" for dev mode",
                    Engine::WebKit.label()
                ),
            );
        }

        if let Some((elapsed, existing_window_id)) =
            self.debounce.get(&self.project_label, &allowed.host)
            && elapsed.elapsed() < Duration::from_millis(1000)
            && self.windows.owned_by(&existing_window_id, &self.owner())
        {
            return RpcResponse::Success {
                id,
                result: json!({
                "window_id": existing_window_id,
                    "debounced": true
                }),
            };
        }

        let entry = match launcher::launch(
            &allowed.url,
            &self.project_label,
            &self.launch_mode,
            &device,
            launcher::DevMode {
                dev,
                keep_service_worker,
            },
            engine,
            headless,
        ) {
            Ok(entry) => entry,
            Err(LaunchError::BrowserUnavailable) => {
                return Self::tool_error(
                    id,
                    "BROWSER_UNAVAILABLE: no browser container launcher is configured for this lane",
                );
            }
            Err(err) => {
                return Self::tool_error(id, format!("BROWSER_LAUNCH_FAILED: {err}"));
            }
        };

        let mut entry = entry;
        entry.owning_lane = self.owner();
        entry.notice = match (engine_notice, entry.notice.take()) {
            (Some(a), Some(b)) => Some(format!("{a} {b}")),
            (a, b) => a.or(b),
        };
        // Order 1725-5uue: say what the window does with service workers;
        // a kept one is named, once the page registers it (bounded wait).
        let service_workers = match (dev, keep_service_worker) {
            (false, _) => json!({ "mode": "active" }),
            (true, false) => json!({ "mode": "bypassed" }),
            (true, true) => json!({
                "mode": "kept",
                "registered": entry
                    .cdp
                    .as_ref()
                    .map(|cdp| cdp.service_workers(SERVICE_WORKER_WAIT))
                    .unwrap_or_default(),
            }),
        };
        let notice = entry.notice.clone();
        let window_id = entry.window_id.clone();
        self.windows.insert(entry);
        self.debounce
            .record(&self.project_label, &allowed.host, window_id.clone());

        RpcResponse::Success {
            id,
            result: json!({
                "window_id": window_id,
                "device": device.summary(),
                "dev": dev,
                "engine": engine.label(),
                // Order 1712-3fsw: whether a human can see this window.
                "headless": headless,
                "service_workers": service_workers,
                "notice": notice,
            }),
        }
    }

    /// `browser.set_device{window_id, device}`: re-emulate a live window.
    /// Order 1655-urz9.
    fn handle_browser_set_device(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(
                id,
                -32602,
                "browser.set_device requires arguments.window_id",
            );
        };
        let Some(query) = args.get("device").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(
                id,
                -32602,
                "browser.set_device requires arguments.device",
            );
        };
        let device = match Self::resolve_device(query) {
            Ok(device) => device,
            Err(err) => return Self::tool_error(id, err),
        };
        let (cdp, _, _) = match self.window_page(id, window_id) {
            Ok(found) => found,
            Err(response) => return response,
        };
        match cdp.set_device(device.clone()) {
            Ok(()) => RpcResponse::Success {
                id,
                result: json!({ "window_id": window_id, "device": device.summary() }),
            },
            Err(e) => Self::tool_error(id, format!("SET_DEVICE_FAILED: {e}")),
        }
    }

    fn window_id_arg<'a>(
        id: u64,
        args: &'a serde_json::Value,
        tool: &str,
    ) -> Result<&'a str, RpcResponse> {
        args.get("window_id")
            .and_then(|value| value.as_str())
            .ok_or_else(|| {
                Self::json_rpc_error(id, -32602, format!("{tool} requires arguments.window_id"))
            })
    }

    /// `browser.eval{window_id, expression}`: dev-mode windows only.
    fn handle_browser_eval(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let window_id = match Self::window_id_arg(id, args, "browser.eval") {
            Ok(w) => w,
            Err(r) => return r,
        };
        let Some(expression) = args.get("expression").and_then(|v| v.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.eval requires arguments.expression");
        };
        let (cdp, _, dev) = match self.window_page(id, window_id) {
            Ok(found) => found,
            Err(r) => return r,
        };
        if !dev {
            return Self::tool_error(
                id,
                "EVAL_DISABLED: browser.eval needs a development-mode window; open it with browser.open{url, dev: true}",
            );
        }
        match cdp.evaluate(expression) {
            Ok(value) => RpcResponse::Success {
                id,
                result: json!({ "value": value }),
            },
            Err(e) => Self::tool_error(id, format!("EVAL_FAILED: {e}")),
        }
    }

    /// `browser.cdp{window_id, method, params?, sessionId?, browser_level?}`:
    /// any CDP command, for the owning lane of a dev-mode window. The page
    /// session by default; `browser_level: true` for the browser target.
    fn handle_browser_cdp(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let window_id = match Self::window_id_arg(id, args, "browser.cdp") {
            Ok(w) => w,
            Err(r) => return r,
        };
        let Some(method) = args.get("method").and_then(|v| v.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.cdp requires arguments.method");
        };
        let params = args.get("params").cloned().unwrap_or_else(|| json!({}));
        if !params.is_object() {
            return Self::json_rpc_error(
                id,
                -32602,
                "browser.cdp arguments.params must be an object",
            );
        }
        let (cdp, page) = match self.dev_window(id, window_id, "browser.cdp") {
            Ok(found) => found,
            Err(r) => return r,
        };
        let browser_level = args
            .get("browser_level")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let explicit = args.get("sessionId").and_then(|v| v.as_str());
        if let Err(why) = cdp_method_allowed(method, browser_level, explicit, &page) {
            return Self::tool_error(id, format!("CDP_METHOD_REFUSED: {method}: {why}"));
        }
        let session = match explicit {
            _ if browser_level => None,
            Some(explicit) => Some(explicit.to_string()),
            None => Some(page),
        };
        match cdp.connection().call(session.as_deref(), method, params) {
            Ok(result) => RpcResponse::Success { id, result },
            Err(e) => Self::tool_error(id, format!("CDP_ERROR: {e}")),
        }
    }

    /// `browser.navigate{window_id, url}`: the same allowlist as browser.open.
    fn handle_browser_navigate(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let window_id = match Self::window_id_arg(id, args, "browser.navigate") {
            Ok(w) => w,
            Err(r) => return r,
        };
        let Some(url) = args.get("url").and_then(|v| v.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.navigate requires arguments.url");
        };
        let (cdp, _) = match self.dev_window(id, window_id, "browser.navigate") {
            Ok(found) => found,
            Err(r) => return r,
        };
        let allowed = match allowlist::validate_with_preview(
            url,
            &self.project_label,
            self.preview_tls_port(),
        ) {
            Ok(allowed) => allowed,
            Err(reason) => return Self::tool_error(id, format!("URL_NOT_ALLOWED: {reason}")),
        };
        if matches!(self.launch_mode, LaunchMode::Container(_)) && allowed.url.scheme() != "https" {
            return Self::tool_error(
                id,
                "URL_NOT_ALLOWED: browser windows load the project over https only",
            );
        }
        match cdp.navigate(allowed.url.as_str()) {
            Ok(()) => RpcResponse::Success {
                id,
                result: json!({ "ok": true, "url": allowed.url.as_str() }),
            },
            Err(e) => Self::tool_error(id, format!("NAVIGATE_FAILED: {e}")),
        }
    }

    /// `browser.console_tail` / `browser.network_tail{window_id, limit?}`.
    fn handle_browser_tail(&self, id: u64, args: &serde_json::Value, tool: &str) -> RpcResponse {
        let window_id = match Self::window_id_arg(id, args, tool) {
            Ok(w) => w,
            Err(r) => return r,
        };
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .unwrap_or(50)
            .min(500) as usize;
        let (cdp, _) = match self.dev_window(id, window_id, tool) {
            Ok(found) => found,
            Err(r) => return r,
        };
        let entries = if tool == "browser.console_tail" {
            cdp.console_tail(limit)
        } else {
            cdp.network_tail(limit)
        };
        RpcResponse::Success {
            id,
            result: json!({ "entries": entries }),
        }
    }

    fn handle_browser_list_windows(&self, id: u64) -> RpcResponse {
        let windows = self
            .windows
            .list_for_lane(&self.owner())
            .into_iter()
            .map(|window| {
                json!({
                    "window_id": window.window_id,
                    "url": window.url,
                    "title": window.title,
                    "engine": window.engine,
                    "headless": window.headless
                })
            })
            .collect::<Vec<_>>();

        RpcResponse::Success {
            id,
            result: json!({
                "windows": windows
            }),
        }
    }

    fn handle_browser_read_url(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(
                id,
                -32602,
                "browser.read_url requires arguments.window_id",
            );
        };

        if !self.windows.owned_by(window_id, &self.owner()) {
            return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
        }
        // The live page when the window has a CDP session (1637-5765): the
        // registry keeps what browser.open saw, and a page that navigated or
        // retitled itself since would otherwise be reported as it was.
        let live = match self.windows.cdp_for(window_id, &self.owner()) {
            Some((Some(cdp), _, _)) => cdp.page_info().ok(),
            _ => None,
        };
        match self.windows.get(window_id) {
            Some(window) => RpcResponse::Success {
                id,
                result: json!({
                    "url": live.as_ref().map_or(window.url.as_str(), |(url, _)| url.as_str()),
                    "title": live.as_ref().map_or(window.title.as_str(), |(_, title)| title.as_str()),
                    "engine": window.engine,
                    "headless": window.headless
                }),
            },
            None => Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}")),
        }
    }

    fn handle_browser_close(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.close requires arguments.window_id");
        };

        if !self.windows.owned_by(window_id, &self.owner()) {
            return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
        }
        let Some(entry) = close_window(&self.windows, &self.debounce, window_id) else {
            return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
        };

        launcher::remove_profile_dir(&entry.user_data_dir);
        RpcResponse::Success {
            id,
            result: json!({
                "ok": true
            }),
        }
    }

    async fn handle_browser_screenshot(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        // @trace spec:host-browser-mcp, spec:browser-isolation-core
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(
                id,
                -32602,
                "browser.screenshot requires arguments.window_id",
            );
        };

        let full_page = args
            .get("full_page")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let (cdp, page, _) = match self.window_page(id, window_id) {
            Ok(found) => found,
            Err(response) => return response,
        };

        match cdp.connection().screenshot(&page, full_page) {
            Ok(png_bytes) => {
                let b64 = base64::engine::general_purpose::STANDARD.encode(&png_bytes);
                RpcResponse::Success {
                    id,
                    result: json!({
                        "data": b64
                    }),
                }
            }
            Err(CdpError::WindowNotRunning(msg)) => {
                Self::tool_error(id, format!("WINDOW_NOT_RUNNING: {msg}"))
            }
            Err(e) => Self::tool_error(id, format!("SCREENSHOT_FAILED: {e}")),
        }
    }

    async fn handle_browser_click(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        // @trace spec:host-browser-mcp, spec:browser-isolation-core
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.click requires arguments.window_id");
        };

        let Some(selector) = args.get("selector").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.click requires arguments.selector");
        };

        let (cdp, page, _) = match self.window_page(id, window_id) {
            Ok(found) => found,
            Err(response) => return response,
        };

        match cdp.connection().click(&page, selector) {
            Ok(_) => RpcResponse::Success {
                id,
                result: json!({
                    "ok": true
                }),
            },
            Err(CdpError::ElementNotFound { selector }) => {
                Self::tool_error(id, format!("ELEMENT_NOT_FOUND: {selector}"))
            }
            Err(CdpError::WindowNotRunning(msg)) => {
                Self::tool_error(id, format!("WINDOW_NOT_RUNNING: {msg}"))
            }
            Err(e) => Self::tool_error(id, format!("CLICK_FAILED: {e}")),
        }
    }

    async fn handle_browser_type(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        // @trace spec:host-browser-mcp, spec:browser-isolation-core
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.type requires arguments.window_id");
        };

        let Some(selector) = args.get("selector").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.type requires arguments.selector");
        };

        let Some(text) = args.get("text").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.type requires arguments.text");
        };

        let (cdp, page, _) = match self.window_page(id, window_id) {
            Ok(found) => found,
            Err(response) => return response,
        };

        match cdp.connection().type_text(&page, selector, text) {
            Ok(_) => RpcResponse::Success {
                id,
                result: json!({
                    "ok": true
                }),
            },
            Err(CdpError::ElementNotFound { selector }) => {
                Self::tool_error(id, format!("ELEMENT_NOT_FOUND: {selector}"))
            }
            Err(CdpError::WindowNotRunning(msg)) => {
                Self::tool_error(id, format!("WINDOW_NOT_RUNNING: {msg}"))
            }
            Err(e) => Self::tool_error(id, format!("TYPE_FAILED: {e}")),
        }
    }

    /// Handle `prompts/list` request (no custom prompts).
    fn handle_prompts_list(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "prompts/list requires an id".to_string(),
                };
            }
        };

        RpcResponse::Success {
            id,
            result: json!({
                "prompts": []
            }),
        }
    }

    /// Handle `resources/list` request (no resources).
    fn handle_resources_list(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "resources/list requires an id".to_string(),
                };
            }
        };

        RpcResponse::Success {
            id,
            result: json!({
                "resources": []
            }),
        }
    }

    /// Handle `resources/templates/list` request (no resource templates).
    fn handle_resources_templates_list(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "resources/templates/list requires an id".to_string(),
                };
            }
        };

        RpcResponse::Success {
            id,
            result: json!({
                "resourceTemplates": []
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn test_server(containers: Option<Arc<dyn BrowserContainers>>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label(McpServerConfig::default(), "acme", containers)
    }

    // Order 1754-bu07: a window opened through one server is still listed
    // through the next one on the same shared registry, after the first is
    // gone (a one-shot agent run that opened it, then exited).
    #[tokio::test]
    async fn a_window_outlives_the_server_that_opened_it_on_a_shared_registry() {
        let windows = Arc::new(WindowRegistry::default());
        let debounce = Arc::new(DebounceTable::default());
        let call = |name: &str, arguments: serde_json::Value| RpcRequest {
            id: Some(1),
            method: "tools/call".to_string(),
            params: json!({ "name": name, "arguments": arguments }),
        };
        {
            let first =
                test_server_fake_launch(None).with_windows(windows.clone(), debounce.clone());
            let opened = first
                .handle_request(call(
                    "browser.open",
                    json!({ "url": "http://web.acme.localhost:8080/" }),
                ))
                .await;
            assert!(matches!(opened, RpcResponse::Success { .. }), "{opened:?}");
        }
        let second = test_server_fake_launch(None).with_windows(windows.clone(), debounce);
        let listed = second
            .handle_request(call("browser.list_windows", json!({})))
            .await;
        let line = listed.to_line().unwrap();
        assert!(
            line.contains("web.acme.localhost"),
            "the window survived its opener: {line}"
        );
        assert_eq!(windows.list_for_lane("acme/default").len(), 1);
    }

    fn test_server_fake_launch(containers: Option<Arc<dyn BrowserContainers>>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label_and_mode(
            McpServerConfig::default(),
            "acme",
            containers,
            true,
        )
    }

    // Order 1696-gz2y: MCP clients render a tools/call result's `content`
    // (and `structuredContent`), never bare fields. Successes used to return
    // the bare payload, so every successful call reached the agent empty
    // while errors (already wrapped) arrived intact.
    #[tokio::test]
    async fn a_successful_tool_call_carries_its_payload_as_mcp_content() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(7),
            method: "tools/call".to_string(),
            params: json!({"name": "browser.list_windows", "arguments": {}}),
        };
        match server.handle_request(request).await {
            RpcResponse::Success { result, .. } => {
                let text = result["content"][0]["text"]
                    .as_str()
                    .unwrap_or_else(|| panic!("no content text: {result}"));
                assert_eq!(result["content"][0]["type"], "text");
                let parsed: serde_json::Value = serde_json::from_str(text).unwrap();
                assert_eq!(parsed, result["structuredContent"]);
                assert!(parsed["windows"].is_array(), "{parsed}");
                assert_ne!(result["isError"], true);
            }
            _ => panic!("Expected success response"),
        }
    }

    #[tokio::test]
    async fn initialize_request() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(1),
            method: "initialize".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Success { id, result } => {
                assert_eq!(id, 1);
                assert!(result.get("protocolVersion").is_some());
                assert!(result.get("serverInfo").is_some());
            }
            _ => panic!("Expected success response"),
        }
    }

    // @trace spec:host-browser-mcp (regression guard for the
    //   CARGO_PKG_VERSION anti-pattern flagged in tray-convergence-
    //   coordination.md 2026-05-30T11:00Z; follow-on of host-shell
    //   fix 76f93287)
    #[tokio::test]
    async fn initialize_serverinfo_version_is_workspace_release_not_crate_static() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(99),
            method: "initialize".to_string(),
            params: json!({}),
        };
        let response = server.handle_request(request).await;
        let result = match response {
            RpcResponse::Success { result, .. } => result,
            _ => panic!("initialize should succeed"),
        };
        let version = result
            .get("serverInfo")
            .and_then(|s| s.get("version"))
            .and_then(|v| v.as_str())
            .expect("serverInfo.version must be a string");

        assert_ne!(
            version, "0.1.170",
            "serverInfo.version returned the crate-static `Cargo.toml` value \
             — build.rs's WORKSPACE_VERSION injection regressed; AI agents \
             pasting the MCP serverInfo into a bug report will no longer be \
             able to correlate the response to a specific release."
        );
        // Workspace VERSION shape: `0.MAJOR.YYMMDD.SEQ` (e.g.
        // `0.2.260528.1`). A 2-segment "X.Y" string is the unmistakable
        // signature of a crate-static fallback regression.
        assert!(
            version.matches('.').count() >= 2,
            "serverInfo.version = {version:?} doesn't look like a workspace \
             VERSION (expected at least 3 dot-segments e.g. 0.2.260528.1)"
        );
    }

    #[tokio::test]
    async fn tools_list_returns_thirteen_tools() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(2),
            method: "tools/list".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Success { id, result } => {
                assert_eq!(id, 2);
                let tools = result.get("tools").and_then(|t| t.as_array());
                assert!(tools.is_some());
                assert_eq!(
                    tools.unwrap().len(),
                    13,
                    "8 v1 tools + set_device (1655-urz9) + cdp, navigate, console_tail, network_tail (1656-iktu)"
                );
            }
            _ => panic!("Expected success response"),
        }
    }

    #[tokio::test]
    async fn unknown_method_returns_error() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(3),
            method: "unknown/method".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Error { id, code, .. } => {
                assert_eq!(id, 3);
                assert_eq!(code, -32601);
            }
            _ => panic!("Expected error response"),
        }
    }

    #[tokio::test]
    async fn unknown_method_error_mentions_method_name() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(6),
            method: "unknown/method".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Error { message, .. } => {
                assert!(message.starts_with("Method not found: unknown/method"));
            }
            _ => panic!("Expected error response"),
        }
    }

    #[tokio::test]
    async fn browser_eval_on_an_unknown_window_is_window_not_found() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(5),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.eval",
                "arguments": {
                    "window_id": "win-A",
                    "expression": "1 + 1"
                }
            }),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Success { id, result } => {
                assert_eq!(id, 5);
                assert_eq!(
                    result.get("isError").and_then(|value| value.as_bool()),
                    Some(true)
                );
                let content = result
                    .get("content")
                    .and_then(|value| value.as_array())
                    .expect("expected tool error content");
                assert_eq!(content.len(), 1);
                assert_eq!(
                    content[0].get("text").and_then(|value| value.as_str()),
                    Some("WINDOW_NOT_FOUND: win-A")
                );
            }
            _ => panic!("Expected success response"),
        }
    }

    #[tokio::test]
    async fn prompts_list_returns_empty() {
        let server = test_server(None);
        let request = RpcRequest {
            id: Some(4),
            method: "prompts/list".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Success { id, result } => {
                assert_eq!(id, 4);
                let prompts = result.get("prompts").and_then(|p| p.as_array());
                assert_eq!(prompts.unwrap().len(), 0);
            }
            _ => panic!("Expected success response"),
        }
    }

    #[tokio::test]
    async fn browser_open_registers_and_lists_window() {
        let server = test_server_fake_launch(None);
        assert!(matches!(server.launch_mode, LaunchMode::Fake));
        let response = server
            .handle_request(RpcRequest {
                id: Some(10),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        let window_id = match response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };
        assert!(window_id.starts_with("win-"));

        let list = server
            .handle_request(RpcRequest {
                id: Some(11),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.list_windows",
                    "arguments": {}
                }),
            })
            .await;
        match list {
            RpcResponse::Success { result, .. } => {
                let windows = result["structuredContent"]["windows"].as_array().unwrap();
                assert_eq!(windows.len(), 1);
                assert_eq!(windows[0]["window_id"], window_id);
                assert_eq!(windows[0]["url"], "http://web.acme.localhost:8080/");
            }
            other => panic!("expected success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_open_debounces_same_host() {
        let server = test_server_fake_launch(None);
        assert!(matches!(server.launch_mode, LaunchMode::Fake));
        let first = server
            .handle_request(RpcRequest {
                id: Some(20),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/foo"
                    }
                }),
            })
            .await;
        let first_window_id = match first {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        let second = server
            .handle_request(RpcRequest {
                id: Some(21),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/bar"
                    }
                }),
            })
            .await;

        match second {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["structuredContent"]["window_id"], first_window_id);
                assert_eq!(result["structuredContent"]["debounced"], true);
            }
            other => panic!("expected success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_open_rejects_non_project_host() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(30),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.beta.localhost:8080/"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.starts_with("URL_NOT_ALLOWED:"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_close_removes_window() {
        let server = test_server_fake_launch(None);
        assert!(matches!(server.launch_mode, LaunchMode::Fake));
        let open = server
            .handle_request(RpcRequest {
                id: Some(40),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;
        let window_id = match open {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        let close = server
            .handle_request(RpcRequest {
                id: Some(41),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.close",
                    "arguments": {
                        "window_id": window_id
                    }
                }),
            })
            .await;

        match close {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["structuredContent"]["ok"], true);
            }
            other => panic!("expected success, got {other:?}"),
        }

        let list = server
            .handle_request(RpcRequest {
                id: Some(42),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.list_windows",
                    "arguments": {}
                }),
            })
            .await;
        match list {
            RpcResponse::Success { result, .. } => {
                assert!(
                    result["structuredContent"]["windows"]
                        .as_array()
                        .unwrap()
                        .is_empty()
                );
            }
            other => panic!("expected success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_screenshot_requires_window_id() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(50),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.screenshot",
                    "arguments": {}
                }),
            })
            .await;

        match response {
            RpcResponse::Error { code, .. } => {
                assert_eq!(code, -32602);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_screenshot_rejects_missing_window() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(51),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.screenshot",
                    "arguments": {
                        "window_id": "nonexistent"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_FOUND"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_click_requires_selector() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(52),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.click",
                    "arguments": {
                        "window_id": "win-test"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Error { code, .. } => {
                assert_eq!(code, -32602);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_type_requires_text() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(53),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.type",
                    "arguments": {
                        "window_id": "win-test",
                        "selector": "#input"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Error { code, .. } => {
                assert_eq!(code, -32602);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_screenshot_fake_launch_mode_errors() {
        let server = test_server_fake_launch(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(54),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        let window_id = match response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        // Fake launch mode has port=0, so CDP connection should fail gracefully
        let screenshot_response = server
            .handle_request(RpcRequest {
                id: Some(55),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.screenshot",
                    "arguments": {
                        "window_id": window_id
                    }
                }),
            })
            .await;

        match screenshot_response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_RUNNING") || text.contains("SCREENSHOT_FAILED"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_click_requires_window_id() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(56),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.click",
                    "arguments": {
                        "selector": "button"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Error { code, .. } => {
                assert_eq!(code, -32602);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_click_rejects_missing_window() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(57),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.click",
                    "arguments": {
                        "window_id": "nonexistent",
                        "selector": "button"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_FOUND"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_click_fake_launch_mode_errors() {
        let server = test_server_fake_launch(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(58),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        let window_id = match response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        // Fake launch mode has port=0, so CDP connection should fail gracefully
        let click_response = server
            .handle_request(RpcRequest {
                id: Some(59),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.click",
                    "arguments": {
                        "window_id": window_id,
                        "selector": "button"
                    }
                }),
            })
            .await;

        match click_response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_RUNNING") || text.contains("CLICK_FAILED"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_type_requires_window_id() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(60),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.type",
                    "arguments": {
                        "selector": "#input",
                        "text": "hello"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Error { code, .. } => {
                assert_eq!(code, -32602);
            }
            other => panic!("expected error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_type_rejects_missing_window() {
        let server = test_server(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(61),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.type",
                    "arguments": {
                        "window_id": "nonexistent",
                        "selector": "#input",
                        "text": "hello"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_FOUND"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_type_fake_launch_mode_errors() {
        let server = test_server_fake_launch(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(62),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        let window_id = match response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        // Fake launch mode has port=0, so CDP connection should fail gracefully
        let type_response = server
            .handle_request(RpcRequest {
                id: Some(63),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.type",
                    "arguments": {
                        "window_id": window_id,
                        "selector": "#input",
                        "text": "test"
                    }
                }),
            })
            .await;

        match type_response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(result["isError"], true);
                let text = result["content"][0]["text"].as_str().unwrap();
                assert!(text.contains("WINDOW_NOT_RUNNING") || text.contains("TYPE_FAILED"));
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_screenshot_with_full_page_true() {
        let server = test_server_fake_launch(None);
        let response = server
            .handle_request(RpcRequest {
                id: Some(64),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        let window_id = match response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        // Test with full_page=true (should pass through to CDP)
        let screenshot_response = server
            .handle_request(RpcRequest {
                id: Some(65),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.screenshot",
                    "arguments": {
                        "window_id": window_id,
                        "full_page": true
                    }
                }),
            })
            .await;

        match screenshot_response {
            RpcResponse::Success { result, .. } => {
                // In fake launch mode, should error
                assert_eq!(result["isError"], true);
            }
            other => panic!("expected tool error success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn browser_read_url_works_with_registered_window() {
        let server = test_server_fake_launch(None);
        let open_response = server
            .handle_request(RpcRequest {
                id: Some(66),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/path"
                    }
                }),
            })
            .await;

        let window_id = match open_response {
            RpcResponse::Success { result, .. } => result["structuredContent"]["window_id"]
                .as_str()
                .unwrap()
                .to_string(),
            other => panic!("expected success, got {other:?}"),
        };

        let read_response = server
            .handle_request(RpcRequest {
                id: Some(67),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.read_url",
                    "arguments": {
                        "window_id": window_id
                    }
                }),
            })
            .await;

        match read_response {
            RpcResponse::Success { result, .. } => {
                assert_eq!(
                    result["structuredContent"]["url"],
                    "http://web.acme.localhost:8080/path"
                );
                assert_eq!(result["structuredContent"]["title"], "web.acme.localhost");
            }
            other => panic!("expected success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn allowlist_allows_properly_formatted_localhost_when_no_active_routes() {
        // @trace spec:host-browser-mcp
        let server = test_server_fake_launch(None);

        // Even with no windows registered (no active routes), properly formatted
        // localhost URLs should be allowed. The network-layer router validates
        // actual requests to ensure routes exist.
        let response = server
            .handle_request(RpcRequest {
                id: Some(70),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": "http://web.acme.localhost:8080/"
                    }
                }),
            })
            .await;

        match response {
            RpcResponse::Success { result, .. } => {
                // Should succeed at the app layer; network layer validates routing
                let window_id = result["structuredContent"]["window_id"].as_str();
                assert!(window_id.is_some(), "expected window_id in result");
            }
            other => panic!("expected success, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn allowlist_allows_localhost_ip_testing() {
        // @trace spec:host-browser-mcp
        let server = test_server_fake_launch(None);

        // 127.0.0.1 should always be allowed for localhost testing
        // (even though format validation will reject it normally)
        // This test verifies the allowlist layer independently
        let allowlist = server.build_active_routes_allowlist();
        assert!(allowlist.is_allowed("http://127.0.0.1:8080/"));
        assert!(allowlist.is_allowed("http://127.0.0.1:80/"));
    }

    #[tokio::test]
    async fn allowlist_blocks_external_domains() {
        // @trace spec:host-browser-mcp
        let server = test_server_fake_launch(None);

        let allowlist = server.build_active_routes_allowlist();
        assert!(!allowlist.is_allowed("http://google.com/"));
        assert!(!allowlist.is_allowed("https://github.com/"));
        assert!(!allowlist.is_allowed("http://example.com:8080/"));
    }

    #[tokio::test]
    async fn allowlist_blocks_opencode_self_reference() {
        // @trace spec:host-browser-mcp
        let server = test_server_fake_launch(None);

        let allowlist = server.build_active_routes_allowlist();
        // Even if opencode.acme.localhost is in routes, it should be blocked
        // to prevent recursive OpenCode Web launches
        assert!(!allowlist.is_allowed("http://opencode.acme.localhost:8080/"));
    }

    // ---- Order 1649-xqet: browser.open runs the container, admits the preview port ----

    /// A host launcher that records what it was asked and starts nothing.
    #[derive(Default)]
    struct RecordingContainers {
        starts: parking_lot::Mutex<Vec<(String, String)>>,
        stops: parking_lot::Mutex<Vec<String>>,
        preview_tls_port: Option<u16>,
        /// Order 1712-3fsw: a host with no display (macOS VM, Linux without
        /// Wayland), and what each start was asked for.
        no_display: bool,
        launches: parking_lot::Mutex<Vec<(bool, Engine)>>,
    }

    impl BrowserContainers for RecordingContainers {
        fn preview_tls_port(&self) -> Option<u16> {
            self.preview_tls_port
        }
        fn has_display(&self) -> bool {
            !self.no_display
        }
        fn start(
            &self,
            request: &launcher::ContainerLaunchRequest<'_>,
        ) -> Result<launcher::ContainerHandle, LaunchError> {
            self.starts
                .lock()
                .push((request.url.to_string(), request.project_label.to_string()));
            self.launches
                .lock()
                .push((request.headless, request.engine));
            Ok(launcher::ContainerHandle {
                container_name: format!("tillandsias-browser-{}-1", request.project_label),
                network_name: "tillandsias-browser-net-1".to_string(),
                profile_dir: std::path::PathBuf::new(),
                cdp_socket: None,
                notice: None,
            })
        }
        fn stop(&self, handle: &launcher::ContainerHandle) {
            self.stops.lock().push(handle.container_name.clone());
        }
    }

    async fn open(server: &BrowserMcpServer, url: &str) -> Result<String, String> {
        let response = server
            .handle_request(RpcRequest {
                id: Some(1),
                method: "tools/call".to_string(),
                params: json!({ "name": "browser.open", "arguments": { "url": url } }),
            })
            .await;
        let RpcResponse::Success { result, .. } = response else {
            return Err(format!("not a success frame: {response:?}"));
        };
        if result["isError"].as_bool() == Some(true) {
            return Err(result["content"][0]["text"]
                .as_str()
                .unwrap_or("")
                .to_string());
        }
        Ok(result["structuredContent"]["window_id"]
            .as_str()
            .unwrap_or("")
            .to_string())
    }

    /// Criterion (a), unit half: with a host launcher wired, browser.open
    /// starts the container through it (never a host binary), and the window
    /// carries the container until close stops it.
    #[tokio::test]
    async fn browser_open_starts_the_container_through_the_host_launcher() {
        let host = Arc::new(RecordingContainers {
            preview_tls_port: Some(18443),
            ..Default::default()
        });
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        let window = open(&server, "https://www.acme.localhost:18443/")
            .await
            .expect("the preview URL opens");
        {
            let starts = host.starts.lock();
            assert_eq!(starts.len(), 1);
            assert_eq!(starts[0].0, "https://www.acme.localhost:18443/");
            assert_eq!(starts[0].1, "acme");
        }
        assert!(host.stops.lock().is_empty());
        let closed = server
            .handle_request(RpcRequest {
                id: Some(2),
                method: "tools/call".to_string(),
                params: json!({ "name": "browser.close", "arguments": { "window_id": window } }),
            })
            .await;
        assert!(matches!(closed, RpcResponse::Success { .. }));
        assert_eq!(*host.stops.lock(), vec!["tillandsias-browser-acme-1"]);
    }

    // ---- Order 1712-3fsw: headless when there is no display, or on request ----

    fn headless_host(no_display: bool) -> (Arc<RecordingContainers>, BrowserMcpServer) {
        let host = Arc::new(RecordingContainers {
            preview_tls_port: Some(18443),
            no_display,
            ..Default::default()
        });
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        (host, server)
    }

    /// What an MCP client sees of a tools/call: the content text, parsed, or
    /// the error text (1696-gz2y: never the bare payload).
    async fn call_seen(
        server: &BrowserMcpServer,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let response = server
            .handle_request(RpcRequest {
                id: Some(7),
                method: "tools/call".to_string(),
                params: json!({ "name": name, "arguments": arguments }),
            })
            .await;
        let RpcResponse::Success { result, .. } = response else {
            return Err(format!("not a success frame: {response:?}"));
        };
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        if result["isError"].as_bool() == Some(true) {
            return Err(text);
        }
        serde_json::from_str(&text).map_err(|e| format!("content text is not JSON ({e}): {text}"))
    }

    const PREVIEW: &str = "https://www.acme.localhost:18443/";

    /// macOS today, and Linux without Wayland: an Apple preset with no flags
    /// opens HEADLESS in Chromium (WebKit needs a display), and the reply an
    /// agent reads says so.
    #[tokio::test]
    async fn with_no_display_browser_open_runs_headless_and_says_so() {
        let (host, server) = headless_host(true);
        let seen = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "device": "iphone 12 pro max" }),
        )
        .await
        .expect("a display-less host opens headless instead of refusing");
        assert_eq!(seen["headless"], true, "{seen}");
        assert_eq!(seen["engine"], "Chromium", "{seen}");
        assert_eq!(seen["device"]["viewport"], json!({ "w": 428, "h": 926 }));
        let notice = seen["notice"].as_str().unwrap_or_default();
        assert!(
            notice.contains("WebKit (approximates Safari) needs a display"),
            "the fallback is announced: {seen}"
        );
        assert_eq!(*host.launches.lock(), vec![(true, Engine::Chromium)]);

        let listed = call_seen(&server, "browser.list_windows", json!({}))
            .await
            .unwrap();
        assert_eq!(listed["windows"][0]["headless"], true, "{listed}");
    }

    /// NEGATIVE CONTROL: a host WITH a display and no flag still opens a
    /// visible window, in the device's own engine. The windowed path is
    /// unchanged.
    #[tokio::test]
    async fn with_a_display_and_no_flag_the_window_is_visible_as_before() {
        let (host, server) = headless_host(false);
        let seen = call_seen(&server, "browser.open", json!({ "url": PREVIEW }))
            .await
            .unwrap();
        assert_eq!(seen["headless"], false, "{seen}");
        assert_eq!(*host.launches.lock(), vec![(false, Engine::Chromium)]);

        let (host, server) = headless_host(false);
        let seen = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "device": "iphone 12 pro max" }),
        )
        .await
        .unwrap();
        assert_eq!(seen["engine"], "WebKit (approximates Safari)", "{seen}");
        assert_eq!(*host.launches.lock(), vec![(false, Engine::WebKit)]);
    }

    /// Order 1725-5uue: the reply says what the window does with service
    /// workers: a dev window bypasses them unless asked to keep them.
    #[tokio::test]
    async fn the_open_reply_says_whether_service_workers_were_bypassed() {
        for (args, want) in [
            (json!({ "url": PREVIEW }), json!({ "mode": "active" })),
            (
                json!({ "url": PREVIEW, "dev": true }),
                json!({ "mode": "bypassed" }),
            ),
            (
                json!({ "url": PREVIEW, "dev": true, "keep_service_worker": true }),
                json!({ "mode": "kept", "registered": [] }),
            ),
        ] {
            let (_host, server) = headless_host(false);
            let seen = call_seen(&server, "browser.open", args.clone())
                .await
                .unwrap();
            assert_eq!(seen["service_workers"], want, "{args} -> {seen}");
        }
    }

    /// headless: true on a display host runs headless: agents that drive
    /// themselves skip the compositor.
    #[tokio::test]
    async fn headless_true_on_a_display_host_runs_headless() {
        let (host, server) = headless_host(false);
        let seen = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "headless": true, "dev": true }),
        )
        .await
        .unwrap();
        assert_eq!(seen["headless"], true, "{seen}");
        assert_eq!(seen["dev"], true, "{seen}");
        assert_eq!(*host.launches.lock(), vec![(true, Engine::Chromium)]);
    }

    /// The refusals name their reason and start nothing.
    #[tokio::test]
    async fn headless_refusals_are_named_and_start_nothing() {
        let (host, server) = headless_host(true);
        let err = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "headless": false }),
        )
        .await
        .unwrap_err();
        assert!(err.starts_with("DISPLAY_UNAVAILABLE:"), "{err}");

        let err = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "engine": "webkit" }),
        )
        .await
        .unwrap_err();
        assert!(err.starts_with("ENGINE_UNSUPPORTED:"), "{err}");
        assert!(err.contains("headless"), "{err}");

        let err = call_seen(
            &server,
            "browser.open",
            json!({ "url": PREVIEW, "headless": "yes" }),
        )
        .await
        .unwrap_err();
        assert!(err.starts_with("INVALID_HEADLESS:"), "{err}");

        assert!(host.launches.lock().is_empty(), "nothing started");
    }

    /// The tool description tells an agent what headless means for a human.
    #[tokio::test]
    async fn browser_open_describes_headless_as_invisible_to_humans() {
        let (_host, server) = headless_host(true);
        let listed = server
            .handle_request(RpcRequest {
                id: Some(1),
                method: "tools/list".to_string(),
                params: json!({}),
            })
            .await;
        let RpcResponse::Success { result, .. } = listed else {
            panic!("tools/list failed: {listed:?}");
        };
        let open = result["tools"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == "browser.open")
            .expect("browser.open is listed");
        assert!(
            open["description"]
                .as_str()
                .unwrap()
                .contains("NO human can see the window"),
            "{open}"
        );
        assert_eq!(
            open["inputSchema"]["properties"]["headless"]["type"],
            "boolean"
        );
    }

    /// A window cannot outlive the server (the lane connection) that opened
    /// it: its network would stay attached to the router.
    #[tokio::test]
    async fn dropping_the_server_stops_its_browser_containers() {
        let host = Arc::new(RecordingContainers {
            preview_tls_port: Some(18443),
            ..Default::default()
        });
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        open(&server, "https://www.acme.localhost:18443/")
            .await
            .expect("opens");
        drop(server);
        assert_eq!(*host.stops.lock(), vec!["tillandsias-browser-acme-1"]);
    }

    /// Order 1651-5t7n: in container mode a plaintext URL is refused before
    /// anything starts, since the window's forwarder serves TLS only. The
    /// same URL is still admitted in fake mode (the allowlist's own rules).
    #[tokio::test]
    async fn container_mode_refuses_plaintext_urls_and_starts_nothing() {
        let host = Arc::new(RecordingContainers {
            preview_tls_port: Some(18443),
            ..Default::default()
        });
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        for plaintext in [
            "http://web.acme.localhost:8080/",
            "http://web.acme.localhost/",
        ] {
            let err = open(&server, plaintext).await.expect_err(plaintext);
            assert!(
                err.starts_with("URL_NOT_ALLOWED:") && err.contains("https only"),
                "{plaintext}: {err}"
            );
        }
        assert!(host.starts.lock().is_empty(), "nothing started");
        open(&server, "https://www.acme.localhost:18443/")
            .await
            .expect("https preview still opens");
        assert_eq!(host.starts.lock().len(), 1);
        open(
            &test_server_fake_launch(None),
            "http://web.acme.localhost:8080/",
        )
        .await
        .expect("fake mode keeps the allowlist's own rules");
    }

    /// No launcher wired: the open is refused as unavailable, nothing starts.
    #[tokio::test]
    async fn browser_open_without_a_launcher_is_unavailable() {
        let server = test_server(None);
        let err = open(&server, "http://web.acme.localhost:8080/")
            .await
            .expect_err("no launcher");
        assert!(err.starts_with("BROWSER_UNAVAILABLE:"), "{err}");
    }

    /// Criterion (c): the preview URL is admitted, other localhost ports and
    /// plain http on the preview port stay refused, and so does another
    /// project on the preview port.
    #[tokio::test]
    async fn browser_open_admits_the_preview_tls_port_and_refuses_other_localhost_ports() {
        let server = test_server_fake_launch(None).with_preview_tls_port(18443);
        open(&server, "https://www.acme.localhost:18443/")
            .await
            .expect("preview URL admitted");
        for refused in [
            "https://www.acme.localhost:18444/",
            "https://www.acme.localhost:8443/",
            "http://www.acme.localhost:18443/",
            "https://www.beta.localhost:18443/",
            "https://127.0.0.1:18443/",
        ] {
            let err = open(&server, refused).await.expect_err(refused);
            assert!(err.starts_with("URL_NOT_ALLOWED:"), "{refused}: {err}");
        }
    }

    /// The control for the admission: with no preview listener, 18443 is
    /// just another localhost port.
    #[tokio::test]
    async fn without_a_preview_listener_the_preview_port_is_refused() {
        let server = test_server_fake_launch(None);
        let err = open(&server, "https://www.acme.localhost:18443/")
            .await
            .expect_err("no preview listener");
        assert!(err.starts_with("URL_NOT_ALLOWED:"), "{err}");
    }

    // ---- Order 1655-urz9: browser.open{device} emulates through the window's CDP session ----

    /// A host launcher whose windows have a CDP relay socket, served by a
    /// fake Chromium: it auto-attaches one page on `Target.setAutoAttach`,
    /// answers everything else with `{}`, and records what it was sent.
    #[cfg(unix)]
    #[derive(Default)]
    struct CdpContainers {
        dir: parking_lot::Mutex<Option<tempfile::TempDir>>,
        sizes: parking_lot::Mutex<Vec<(u32, u32)>>,
        seen: Arc<parking_lot::Mutex<Vec<serde_json::Value>>>,
        closed: Arc<std::sync::atomic::AtomicBool>,
        stops: parking_lot::Mutex<Vec<String>>,
    }

    #[cfg(unix)]
    impl BrowserContainers for CdpContainers {
        fn preview_tls_port(&self) -> Option<u16> {
            Some(18443)
        }
        fn start(
            &self,
            request: &launcher::ContainerLaunchRequest<'_>,
        ) -> Result<launcher::ContainerHandle, LaunchError> {
            use std::io::{BufRead, Write};
            self.sizes.lock().push(request.window_size);
            let dir = tempfile::tempdir()?;
            let socket = dir.path().join("cdp.sock");
            let listener = std::os::unix::net::UnixListener::bind(&socket)?;
            *self.dir.lock() = Some(dir);
            let seen = Arc::clone(&self.seen);
            let closed = Arc::clone(&self.closed);
            std::thread::spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut writer = stream.try_clone().unwrap();
                let mut reader = std::io::BufReader::new(stream);
                let mut frame = Vec::new();
                let mut send = |v: serde_json::Value| {
                    let mut out = serde_json::to_vec(&v).unwrap();
                    out.push(0);
                    writer.write_all(&out).is_ok()
                };
                loop {
                    frame.clear();
                    match reader.read_until(0, &mut frame) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                    frame.pop();
                    let msg: serde_json::Value = serde_json::from_slice(&frame).unwrap();
                    seen.lock().push(msg.clone());
                    let result = match msg["method"].as_str() {
                        Some("Browser.getWindowForTarget") => json!({ "windowId": 1 }),
                        Some("Page.navigate") => json!({ "frameId": "F1" }),
                        Some("Page.getNavigationHistory") => {
                            json!({ "currentIndex": 0, "entries": [
                                { "id": 1, "url": "https://www.acme.localhost:18443/", "title": "RETITLED-LIVE" }
                            ]})
                        }
                        Some("Runtime.evaluate") if msg["params"]["expression"] == "1+1" => {
                            json!({ "result": { "type": "number", "value": 2, "description": "2" } })
                        }
                        _ => json!({}),
                    };
                    if !send(json!({ "id": msg["id"], "result": result })) {
                        break;
                    }
                    if msg["method"] == "Target.setAutoAttach" {
                        send(json!({ "method": "Target.attachedToTarget", "params": {
                            "sessionId": "P1",
                            "targetInfo": { "type": "page", "targetId": "T1" },
                            "waitingForDebugger": false,
                        }}));
                    }
                }
                closed.store(true, std::sync::atomic::Ordering::SeqCst);
            });
            Ok(launcher::ContainerHandle {
                container_name: format!("tillandsias-browser-{}-1", request.project_label),
                network_name: "tillandsias-browser-net-1".to_string(),
                profile_dir: std::path::PathBuf::new(),
                cdp_socket: Some(socket),
                notice: None,
            })
        }
        fn stop(&self, handle: &launcher::ContainerHandle) {
            self.stops.lock().push(handle.container_name.clone());
        }
    }

    #[cfg(unix)]
    impl CdpContainers {
        fn methods_on(&self, session: &str) -> Vec<(String, serde_json::Value)> {
            self.seen
                .lock()
                .iter()
                .filter(|m| m["sessionId"] == session)
                .map(|m| {
                    (
                        m["method"].as_str().unwrap_or("").to_string(),
                        m["params"].clone(),
                    )
                })
                .collect()
        }
    }

    async fn call_tool(
        server: &BrowserMcpServer,
        name: &str,
        arguments: serde_json::Value,
    ) -> serde_json::Value {
        match server
            .handle_request(RpcRequest {
                id: Some(1),
                method: "tools/call".to_string(),
                params: json!({ "name": name, "arguments": arguments }),
            })
            .await
        {
            // Read a success as a client does, through structuredContent
            // (1696-gz2y); an error keeps its content and isError.
            RpcResponse::Success { result, .. } => match result.get("structuredContent") {
                Some(structured) => structured.clone(),
                None => result,
            },
            other => json!({ "frame": format!("{other:?}") }),
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn browser_open_with_a_device_emulates_it_before_navigating_and_set_device_switches_it() {
        let host = Arc::new(CdpContainers::default());
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        let url = "https://www.acme.localhost:18443/";
        let opened = call_tool(
            &server,
            "browser.open",
            json!({ "url": url, "device": "iphone 12 pro max", "engine": "chromium" }),
        )
        .await;
        assert_eq!(
            opened["device"]["id"], "apple-iphone-12-pro-max",
            "{opened}"
        );
        assert_eq!(opened["device"]["viewport"], json!({ "w": 428, "h": 926 }));
        assert_eq!(opened["device"]["dpr"], 3.0);
        assert_eq!(
            *host.sizes.lock(),
            vec![(428, 926)],
            "CSS viewport, host DIPs"
        );

        let p1 = host.methods_on("P1");
        let names: Vec<&str> = p1.iter().map(|(m, _)| m.as_str()).collect();
        let emulation = [
            "Emulation.setTouchEmulationEnabled",
            "Emulation.setEmitTouchEventsForMouse",
            "Emulation.setDeviceMetricsOverride",
            "Emulation.setUserAgentOverride",
        ];
        assert_eq!(names[..4], emulation, "emulated as it attached: {names:?}");
        assert_eq!(names[4..6], ["Page.enable", "Network.enable"]);
        assert_eq!(
            names[6..10],
            emulation,
            "then the checked re-apply: {names:?}"
        );
        assert_eq!(
            names[10], "Page.navigate",
            "and only then navigated: {names:?}"
        );
        assert_eq!(p1[2].1["width"], 428);
        assert_eq!(p1[2].1["deviceScaleFactor"], 3.0);
        assert!(p1[0].1["maxTouchPoints"].as_u64().unwrap() > 0);
        assert_eq!(p1[10].1["url"], url);

        let window = opened["window_id"].as_str().unwrap().to_string();
        let switched = call_tool(
            &server,
            "browser.set_device",
            json!({ "window_id": window, "device": "galaxy s24" }),
        )
        .await;
        assert_eq!(switched["device"]["id"], "samsung-galaxy-s24", "{switched}");
        let metrics: Vec<serde_json::Value> = host
            .methods_on("P1")
            .into_iter()
            .filter(|(m, _)| m == "Emulation.setDeviceMetricsOverride")
            .map(|(_, p)| p)
            .collect();
        assert_eq!(metrics.last().unwrap()["width"], 360);

        let unknown = call_tool(
            &server,
            "browser.set_device",
            json!({ "window_id": window, "device": "blorp 9000" }),
        )
        .await;
        assert!(
            unknown["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("DEVICE_UNKNOWN:")
        );

        call_tool(&server, "browser.close", json!({ "window_id": window })).await;
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while !host.closed.load(std::sync::atomic::Ordering::SeqCst)
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            host.closed.load(std::sync::atomic::Ordering::SeqCst),
            "close ends the CDP session"
        );
        assert_eq!(*host.stops.lock(), vec!["tillandsias-browser-acme-1"]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn an_unknown_device_starts_nothing_and_the_default_comes_from_the_project() {
        let host = Arc::new(CdpContainers::default());
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        );
        let refused = call_tool(
            &server,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "device": "blorp 9000" }),
        )
        .await;
        assert!(
            refused["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("DEVICE_UNKNOWN:"),
            "{refused}"
        );
        assert!(host.sizes.lock().is_empty(), "nothing started");

        let opened = call_tool(
            &server,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/" }),
        )
        .await;
        assert_eq!(
            opened["device"]["id"], "desktop-chrome",
            "no project default: desktop"
        );

        let host = Arc::new(CdpContainers::default());
        let server = BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        )
        .with_default_device("galaxy s24");
        let opened = call_tool(
            &server,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/" }),
        )
        .await;
        assert_eq!(opened["device"]["id"], "samsung-galaxy-s24", "{opened}");
    }

    #[tokio::test]
    async fn cdp_tools_on_a_fake_window_answer_window_not_running() {
        let server = test_server_fake_launch(None);
        let window = open(&server, "http://web.acme.localhost:8080/")
            .await
            .unwrap();
        let shot = call_tool(
            &server,
            "browser.set_device",
            json!({ "window_id": window, "device": "desktop" }),
        )
        .await;
        assert!(
            shot["content"][0]["text"]
                .as_str()
                .unwrap()
                .starts_with("WINDOW_NOT_RUNNING:"),
            "{shot}"
        );
    }

    // ---- Order 1656-iktu: dev mode gives the OWNING lane full CDP ----

    #[cfg(unix)]
    fn tool_text(v: &serde_json::Value) -> String {
        v["content"][0]["text"].as_str().unwrap_or("").to_string()
    }

    #[cfg(unix)]
    fn lane_server(host: &Arc<CdpContainers>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            Some(host.clone() as Arc<dyn BrowserContainers>),
        )
    }

    /// Order 1637-5765: read_url reports the LIVE page, not what browser.open
    /// stored, so an app that retitles itself (a hot reload) is seen — and a
    /// window that is not in dev mode answers it without running page script.
    #[cfg(unix)]
    #[tokio::test]
    async fn read_url_reports_the_live_title_without_page_script() {
        let host = Arc::new(CdpContainers::default());
        let lane = lane_server(&host);
        let opened = call_tool(
            &lane,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/" }),
        )
        .await;
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let read = call_tool(&lane, "browser.read_url", json!({ "window_id": window })).await;
        assert_eq!(read["title"], "RETITLED-LIVE", "{read}");
        assert_eq!(read["url"], "https://www.acme.localhost:18443/", "{read}");
        let page = host.methods_on("P1");
        assert!(
            page.iter().any(|(m, _)| m == "Page.getNavigationHistory"),
            "{page:?}"
        );
        assert!(
            !page.iter().any(|(m, _)| m == "Runtime.evaluate"),
            "read_url must not run page script: {page:?}"
        );
    }

    /// Exit criterion 1: from the owning lane, raw browser.cdp evaluates on
    /// the window's page.
    #[cfg(unix)]
    #[tokio::test]
    async fn dev_window_raw_cdp_evaluates_on_the_page_for_the_owning_lane() {
        let host = Arc::new(CdpContainers::default());
        let lane_a = lane_server(&host);
        let opened = call_tool(
            &lane_a,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "dev": true }),
        )
        .await;
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let got = call_tool(
            &lane_a,
            "browser.cdp",
            json!({
                "window_id": window, "method": "Runtime.evaluate", "params": { "expression": "1+1" }
            }),
        )
        .await;
        assert_eq!(got["result"]["value"], 2, "{got}");
    }

    /// Exit criterion 2: another lane holding the same window_id gets
    /// WINDOW_NOT_FOUND, for raw CDP and for the typed tools alike.
    #[cfg(unix)]
    #[tokio::test]
    async fn another_lane_gets_window_not_found_for_a_dev_window() {
        let host = Arc::new(CdpContainers::default());
        let lane_a = lane_server(&host);
        let lane_b = lane_server(&host);
        let opened = call_tool(
            &lane_a,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "dev": true }),
        )
        .await;
        let window = opened["window_id"].as_str().expect("opened").to_string();
        for (tool, args) in [
            (
                "browser.cdp",
                json!({ "window_id": window, "method": "Runtime.evaluate", "params": { "expression": "1+1" } }),
            ),
            ("browser.screenshot", json!({ "window_id": window })),
            (
                "browser.eval",
                json!({ "window_id": window, "expression": "1+1" }),
            ),
        ] {
            let got = call_tool(&lane_b, tool, args).await;
            assert!(
                tool_text(&got).starts_with("WINDOW_NOT_FOUND:"),
                "{tool} from lane B: {got}"
            );
        }
    }

    /// ORDER 1767-5q4b. Raw CDP is the page's protocol, not the browser's: a
    /// browser-level method, a domain outside the page allowlist, a page-domain
    /// method that reaches past the window, or another session is refused
    /// BEFORE anything is sent. Browser.grantPermissions(audioCapture) would
    /// skip the microphone prompt; that is the arm this order exists for.
    #[cfg(unix)]
    #[tokio::test]
    async fn raw_cdp_refuses_methods_that_reach_past_the_page() {
        let host = Arc::new(CdpContainers::default());
        let lane_a = lane_server(&host);
        let opened = call_tool(
            &lane_a,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "dev": true }),
        )
        .await;
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let sent_before = host.seen.lock().len();
        for (name, args) in [
            (
                "grantPermissions at browser level",
                json!({ "method": "Browser.grantPermissions", "params": { "permissions": ["audioCapture"] }, "browser_level": true }),
            ),
            (
                "grantPermissions on the page session",
                json!({ "method": "Browser.grantPermissions", "params": { "permissions": ["audioCapture"] } }),
            ),
            (
                "setPermission",
                json!({ "method": "Browser.setPermission", "params": { "permission": { "name": "microphone" }, "setting": "granted" } }),
            ),
            (
                "setDownloadBehavior",
                json!({ "method": "Browser.setDownloadBehavior", "params": { "behavior": "allow" } }),
            ),
            (
                "Page.setDownloadBehavior",
                json!({ "method": "Page.setDownloadBehavior", "params": { "behavior": "allow" } }),
            ),
            (
                "createBrowserContext",
                json!({ "method": "Target.createBrowserContext" }),
            ),
            (
                "attachToTarget",
                json!({ "method": "Target.attachToTarget", "params": { "targetId": "x" } }),
            ),
            ("SystemInfo", json!({ "method": "SystemInfo.getInfo" })),
            (
                "Storage of another origin",
                json!({ "method": "Storage.getCookies" }),
            ),
            (
                "every origin's cookies",
                json!({ "method": "Network.getAllCookies" }),
            ),
            (
                "clear every origin's cookies",
                json!({ "method": "Network.clearBrowserCookies" }),
            ),
            (
                "any method at browser level",
                json!({ "method": "Runtime.evaluate", "params": { "expression": "1" }, "browser_level": true }),
            ),
            (
                "another session",
                json!({ "method": "Runtime.evaluate", "params": { "expression": "1" }, "sessionId": "not-the-page" }),
            ),
        ] {
            let mut a = args.clone();
            a["window_id"] = json!(window);
            let got = call_tool(&lane_a, "browser.cdp", a).await;
            assert!(
                tool_text(&got).starts_with("CDP_METHOD_REFUSED:"),
                "{name}: {got}"
            );
        }
        assert_eq!(
            host.seen.lock().len(),
            sent_before,
            "a refused method must not reach Chromium"
        );
        // The page's own protocol is untouched.
        for (method, params) in [
            ("Runtime.evaluate", json!({ "expression": "1+1" })),
            ("Page.reload", json!({})),
            ("DOM.getDocument", json!({})),
            (
                "Input.dispatchMouseEvent",
                json!({ "type": "mousePressed", "x": 1, "y": 1 }),
            ),
            ("Network.getCookies", json!({})),
        ] {
            let got = call_tool(
                &lane_a,
                "browser.cdp",
                json!({ "window_id": window, "method": method, "params": params }),
            )
            .await;
            assert!(
                !tool_text(&got).starts_with("CDP_METHOD_REFUSED:"),
                "{method} must stay allowed: {got}"
            );
        }
    }

    /// A normal (non-dev) window gets no raw CDP: dev mode is opt-in.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_normal_window_refuses_raw_cdp() {
        let host = Arc::new(CdpContainers::default());
        let lane_a = lane_server(&host);
        let opened = call_tool(
            &lane_a,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/" }),
        )
        .await;
        let window = opened["window_id"].as_str().expect("opened").to_string();
        let got = call_tool(&lane_a, "browser.cdp", json!({ "window_id": window, "method": "Runtime.evaluate", "params": { "expression": "1+1" } })).await;
        assert!(tool_text(&got).starts_with("DEV_MODE_REQUIRED:"), "{got}");
    }

    /// Exit criterion 5: the tool says what full CDP hands the lane.
    #[tokio::test]
    async fn browser_cdp_description_states_the_cookie_exposure() {
        let server = test_server(None);
        let RpcResponse::Success { result, .. } = server
            .handle_request(RpcRequest {
                id: Some(1),
                method: "tools/list".into(),
                params: json!({}),
            })
            .await
        else {
            panic!("tools/list");
        };
        let cdp = result["tools"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == "browser.cdp")
            .cloned()
            .unwrap_or_default();
        let text = cdp["description"].as_str().unwrap_or("");
        assert!(
            text.contains("cookies") && text.contains("owning lane"),
            "browser.cdp must state that full CDP exposes the window's session cookies to the owning lane: {cdp}"
        );
    }

    // ---- Order 1656-tjv4: Apple presets open in "WebKit (approximates Safari)" ----

    #[cfg(unix)]
    #[tokio::test]
    async fn an_apple_preset_opens_the_webkit_engine_with_no_cdp_and_says_so() {
        let host = Arc::new(CdpContainers::default());
        let server = lane_server(&host);
        let opened = call_tool(
            &server,
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "device": "iphone 15" }),
        )
        .await;
        assert_eq!(opened["engine"], "WebKit (approximates Safari)", "{opened}");
        assert_eq!(opened["device"]["id"], "apple-iphone-15");
        assert!(opened["notice"].is_null(), "nothing was prepared: {opened}");
        assert!(
            host.seen.lock().is_empty(),
            "no CDP session for a WebKit window"
        );
        let window = opened["window_id"].as_str().unwrap().to_string();
        let listed = call_tool(&server, "browser.list_windows", json!({})).await;
        assert_eq!(
            listed["windows"][0]["engine"],
            "WebKit (approximates Safari)"
        );
        for (tool, args) in [
            ("browser.screenshot", json!({ "window_id": window })),
            (
                "browser.set_device",
                json!({ "window_id": window, "device": "galaxy s24" }),
            ),
        ] {
            let got = call_tool(&server, tool, args).await;
            let text = tool_text(&got);
            assert!(
                text.starts_with("ENGINE_UNSUPPORTED:")
                    && text.contains("WebKit (approximates Safari)"),
                "{tool}: {got}"
            );
        }
        // The same preset can still be emulated in Chromium, over CDP (a
        // fresh lane: the same host would be debounced to the first window).
        let host2 = Arc::new(CdpContainers::default());
        let chromium = call_tool(
            &lane_server(&host2),
            "browser.open",
            json!({ "url": "https://www.acme.localhost:18443/", "device": "iphone 15", "engine": "chromium" }),
        )
        .await;
        assert_eq!(chromium["engine"], "Chromium", "{chromium}");
    }

    #[tokio::test]
    async fn dev_mode_on_webkit_and_unknown_engines_are_refused_before_anything_starts() {
        let server = test_server_fake_launch(None);
        let got = |v: serde_json::Value| v["content"][0]["text"].as_str().unwrap_or("").to_string();
        let dev = call_tool(
            &server,
            "browser.open",
            json!({ "url": "http://web.acme.localhost:8080/", "device": "iphone 15", "dev": true }),
        )
        .await;
        assert!(got(dev.clone()).starts_with("ENGINE_UNSUPPORTED:"), "{dev}");
        let unknown = call_tool(
            &server,
            "browser.open",
            json!({ "url": "http://web.acme.localhost:8080/", "engine": "gecko" }),
        )
        .await;
        assert!(
            got(unknown.clone()).starts_with("ENGINE_UNKNOWN:"),
            "{unknown}"
        );
    }

    /// The engine's name is never "Safari" alone.
    #[test]
    fn the_webkit_label_never_says_safari_alone() {
        use crate::launcher::Engine;
        let label = Engine::WebKit.label();
        assert_eq!(label, "WebKit (approximates Safari)");
        assert!(!label.trim().eq_ignore_ascii_case("safari"));
        assert!(label.contains("WebKit"));
        assert_eq!(Engine::for_device("webkit"), Engine::WebKit);
        assert_eq!(Engine::for_device("blink"), Engine::Chromium);
        assert_eq!(Engine::for_device("gecko"), Engine::Chromium);
    }
}
