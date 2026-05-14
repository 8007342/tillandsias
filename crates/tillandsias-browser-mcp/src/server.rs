//! Core MCP server implementation with JSON-RPC method dispatch.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
//! @cheatsheet web/mcp.md, web/cdp.md

use base64::Engine;
use crate::allowlist;
use crate::cdp_client::{CdpError, CdpSession};
use crate::framing::{RpcRequest, RpcResponse};
use crate::launcher::{self, LaunchError};
use crate::window_registry::{close_window, DebounceTable, WindowRegistry};
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;

/// Configuration for the MCP server.
pub struct McpServerConfig {
    pub max_concurrent_calls_per_session: usize,
}

impl Default for McpServerConfig {
    fn default() -> Self {
        Self {
            max_concurrent_calls_per_session: crate::DEFAULT_CONCURRENT_CALLS,
        }
    }
}

/// Per-session state: tracks concurrent tool calls and session metadata.
pub struct SessionState {
    pub session_id: u64,
    pub project_label: String,
    /// Semaphore limiting concurrent `tools/call` invocations.
    /// @trace spec:host-browser-mcp
    pub call_semaphore: Arc<Semaphore>,
}

/// The MCP server instance.
/// @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
pub struct BrowserMcpServer {
    project_label: String,
    browser_binary_override: Option<PathBuf>,
    fake_launch: bool,
    windows: Arc<WindowRegistry>,
    debounce: Arc<DebounceTable>,
    call_semaphore: Arc<Semaphore>,
}

impl BrowserMcpServer {
    /// Create a new MCP server with the given config.
    /// @trace spec:host-browser-mcp
    pub fn new(config: McpServerConfig) -> Self {
        let project_label = std::env::var("TILLANDSIAS_PROJECT").unwrap_or_else(|_| "unknown".to_string());
        Self::with_project_label(config, project_label, None)
    }

    /// Test helper: pin a project label and a browser binary override.
    pub fn with_project_label(
        config: McpServerConfig,
        project_label: impl Into<String>,
        browser_binary_override: Option<PathBuf>,
    ) -> Self {
        Self::with_project_label_and_mode(config, project_label, browser_binary_override, false)
    }

    /// Test helper: pin a project label, binary override, and launch mode.
    pub fn with_project_label_and_mode(
        config: McpServerConfig,
        project_label: impl Into<String>,
        browser_binary_override: Option<PathBuf>,
        fake_launch: bool,
    ) -> Self {
        Self {
            project_label: project_label.into(),
            browser_binary_override,
            fake_launch,
            windows: Arc::new(WindowRegistry::default()),
            debounce: Arc::new(DebounceTable::default()),
            call_semaphore: Arc::new(Semaphore::new(config.max_concurrent_calls_per_session)),
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
        request.params
            .get("arguments")
            .unwrap_or(&request.params)
    }

    fn browser_binary(&self) -> Option<PathBuf> {
        self.browser_binary_override.clone()
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

        let result = json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "tillandsias-browser-mcp",
                "version": env!("CARGO_PKG_VERSION")
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
                            "description": "The URL to open (must match allowlist: <service>.<project>.localhost:8080)"
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

        let permit = match Arc::clone(&self.call_semaphore).try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => return Self::json_rpc_error(id, -32000, "ConcurrentCallLimit"),
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
            "browser.eval" => Self::tool_error(id, "EVAL_DISABLED: browser.eval is disabled in v1; see follow-up change"),
            "browser.close" => self.handle_browser_close(id, args),
            other => Self::tool_error(id, format!("TOOL_NOT_FOUND: {other}")),
        };

        drop(permit);
        response
    }

    fn handle_browser_open(&self, id: u64, args: &serde_json::Value) -> RpcResponse {
        let Some(url) = args.get("url").and_then(|value| value.as_str()) else {
            return Self::json_rpc_error(id, -32602, "browser.open requires arguments.url");
        };

        let allowed = match allowlist::validate(url, &self.project_label) {
            Ok(allowed) => allowed,
            Err(reason) => {
                return Self::tool_error(id, format!("URL_NOT_ALLOWED: {reason}"));
            }
        };

        if let Some((elapsed, existing_window_id)) = self
            .debounce
            .get(&self.project_label, &allowed.host)
        {
            if elapsed.elapsed() < Duration::from_millis(1000) && self.windows.contains(&existing_window_id)
            {
                return RpcResponse::Success {
                    id,
                    result: json!({
                        "window_id": existing_window_id,
                        "debounced": true
                    }),
                };
            }
        }

        let entry = match launcher::launch(
            &allowed.url,
            &self.project_label,
            self.browser_binary().as_deref(),
            self.fake_launch,
        ) {
            Ok(entry) => entry,
            Err(LaunchError::BrowserUnavailable) => {
                return Self::tool_error(
                    id,
                    "BROWSER_UNAVAILABLE: bundled chromium not yet downloaded",
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
            return Self::json_rpc_error(id, -32602, "browser.read_url requires arguments.window_id");
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
            return Self::json_rpc_error(id, -32602, "browser.screenshot requires arguments.window_id");
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
    fn test_server(browser_bin: Option<PathBuf>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label(
            McpServerConfig::default(),
            "acme",
            browser_bin,
        )
    }

    fn test_server_fake_launch(browser_bin: Option<PathBuf>) -> BrowserMcpServer {
        BrowserMcpServer::with_project_label_and_mode(
            McpServerConfig::default(),
            "acme",
            browser_bin,
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
        assert!(server.fake_launch);
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
        assert!(server.fake_launch);
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
            RpcResponse::Success { result, .. } => result["window_id"].as_str().unwrap().to_string(),
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
        assert!(server.fake_launch);
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
            RpcResponse::Success { result, .. } => result["window_id"].as_str().unwrap().to_string(),
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
            RpcResponse::Success { result, .. } => result["window_id"].as_str().unwrap().to_string(),
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
}
