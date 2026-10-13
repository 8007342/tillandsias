//! Core MCP server implementation with JSON-RPC method dispatch.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
//! @cheatsheet web/mcp.md, web/cdp.md

use crate::allowlist::{self, BrowserAllowlist};
use crate::cdp_client::{CdpError, CdpSession};
use crate::framing::{RpcRequest, RpcResponse};
use crate::launcher::{self, BrowserContainers, LaunchError, LaunchMode};
use crate::window_registry::{DebounceTable, WindowRegistry, close_window};
use base64::Engine;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
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
        let windows = self.windows.list_for_project(&self.project_label);
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
                "description": "Open a browser window for a project-local URL",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "url": {
                            "type": "string",
                            "description": "The URL to open (must match allowlist: <service>.<project>.localhost:8080, or https on the local-preview port, e.g. https://www.<project>.localhost:18443)"
                        }
                    },
                    "required": ["url"]
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
                "description": "DISABLED: JavaScript evaluation is not available in v1",
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

        match tool_name {
            "browser.open" => self.handle_browser_open(id, args),
            "browser.list_windows" => self.handle_browser_list_windows(id),
            "browser.read_url" => self.handle_browser_read_url(id, args),
            "browser.screenshot" => self.handle_browser_screenshot(id, args).await,
            "browser.click" => self.handle_browser_click(id, args).await,
            "browser.type" => self.handle_browser_type(id, args).await,
            "browser.eval" => Self::tool_error(
                id,
                "EVAL_DISABLED: browser.eval is disabled in v1; see follow-up change",
            ),
            "browser.close" => self.handle_browser_close(id, args),
            other => Self::tool_error(id, format!("TOOL_NOT_FOUND: {other}")),
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

        if let Some((elapsed, existing_window_id)) =
            self.debounce.get(&self.project_label, &allowed.host)
            && elapsed.elapsed() < Duration::from_millis(1000)
            && self.windows.contains(&existing_window_id)
        {
            return RpcResponse::Success {
                id,
                result: json!({
                "window_id": existing_window_id,
                    "debounced": true
                }),
            };
        }

        let entry = match launcher::launch(&allowed.url, &self.project_label, &self.launch_mode) {
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

        let window_id = entry.window_id.clone();
        self.windows.insert(entry);
        self.debounce
            .record(&self.project_label, &allowed.host, window_id.clone());

        RpcResponse::Success {
            id,
            result: json!({
                "window_id": window_id
            }),
        }
    }

    fn handle_browser_list_windows(&self, id: u64) -> RpcResponse {
        let windows = self
            .windows
            .list_for_project(&self.project_label)
            .into_iter()
            .map(|window| {
                json!({
                    "window_id": window.window_id,
                    "url": window.url,
                    "title": window.title
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

        match self.windows.get(window_id) {
            Some(window) => RpcResponse::Success {
                id,
                result: json!({
                    "url": window.url,
                    "title": window.title
                }),
            },
            None => Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}")),
        }
    }

    fn handle_browser_close(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(window_id) = args.get("window_id").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.close requires arguments.window_id");
        };

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

        let (cdp_port, target_id) = match self.windows.get_entry(window_id) {
            Some((port, tid)) => (port, tid),
            None => {
                return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
            }
        };

        match CdpSession::connect(cdp_port, &target_id) {
            Ok(mut session) => match session.screenshot(full_page) {
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
            },
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

        let (cdp_port, target_id) = match self.windows.get_entry(window_id) {
            Some((port, tid)) => (port, tid),
            None => {
                return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
            }
        };

        match CdpSession::connect(cdp_port, &target_id) {
            Ok(mut session) => match session.click(selector) {
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
            },
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

        let (cdp_port, target_id) = match self.windows.get_entry(window_id) {
            Some((port, tid)) => (port, tid),
            None => {
                return Self::tool_error(id, format!("WINDOW_NOT_FOUND: {window_id}"));
            }
        };

        match CdpSession::connect(cdp_port, &target_id) {
            Ok(mut session) => match session.type_text(selector, text) {
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
            },
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

    fn test_server_fake_launch(containers: Option<Arc<dyn BrowserContainers>>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label_and_mode(
            McpServerConfig::default(),
            "acme",
            containers,
            true,
        )
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
    async fn tools_list_returns_eight_tools() {
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
                assert_eq!(tools.unwrap().len(), 8, "Expected 8 tools in v1");
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
    async fn browser_eval_is_disabled_in_v1() {
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
                    Some("EVAL_DISABLED: browser.eval is disabled in v1; see follow-up change")
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
                let windows = result["windows"].as_array().unwrap();
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
                assert_eq!(result["window_id"], first_window_id);
                assert_eq!(result["debounced"], true);
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
                assert_eq!(result["ok"], true);
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
                assert!(result["windows"].as_array().unwrap().is_empty());
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
            RpcResponse::Success { result, .. } => {
                result["window_id"].as_str().unwrap().to_string()
            }
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
                assert_eq!(result["url"], "http://web.acme.localhost:8080/path");
                assert_eq!(result["title"], "web.acme.localhost");
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
                let window_id = result["window_id"].as_str();
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
    }

    impl BrowserContainers for RecordingContainers {
        fn preview_tls_port(&self) -> Option<u16> {
            self.preview_tls_port
        }
        fn start(
            &self,
            request: &launcher::ContainerLaunchRequest<'_>,
        ) -> Result<launcher::ContainerHandle, LaunchError> {
            self.starts
                .lock()
                .push((request.url.to_string(), request.project_label.to_string()));
            Ok(launcher::ContainerHandle {
                container_name: format!("tillandsias-browser-{}-1", request.project_label),
                network_name: "tillandsias-browser-net-1".to_string(),
                profile_dir: std::path::PathBuf::new(),
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
        Ok(result["window_id"].as_str().unwrap_or("").to_string())
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
}
