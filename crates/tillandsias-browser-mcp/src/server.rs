//! Core MCP server implementation with JSON-RPC method dispatch.
//!
//! @trace spec:host-browser-mcp, spec:browser-daemon-tracking, spec:browser-tray-notifications
//! @cheatsheet web/mcp.md

use crate::framing::{RpcRequest, RpcResponse};
use serde_json::json;
use std::sync::Arc;
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
    /// @trace spec:browser-window-rate-limiting, spec:browser-debounce
    pub call_semaphore: Arc<Semaphore>,
}

/// The MCP server instance.
/// @trace spec:browser-daemon-tracking, spec:browser-tray-notifications
#[allow(dead_code)]
pub struct BrowserMcpServer {
    config: McpServerConfig,
}

impl BrowserMcpServer {
    /// Create a new MCP server with the given config.
    /// @trace spec:browser-daemon-tracking
    pub fn new(config: McpServerConfig) -> Self {
        Self { config }
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
            _ => {
                // Method not found
                if let Some(id) = request.id {
                    RpcResponse::Error {
                        id,
                        code: -32601,
                        message: "Method not found".to_string(),
                    }
                } else {
                    RpcResponse::Notification
                }
            }
        }
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
                "version": "0.1.170"
            }
        });

        RpcResponse::Success { id, result }
    }

    /// Handle `tools/list` request (return all available tools).
    /// @trace spec:browser-daemon-tracking, spec:browser-tray-notifications
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

    /// Handle `tools/call` request (invoke a specific tool).
    async fn handle_tools_call(&self, request: &RpcRequest) -> RpcResponse {
        // @trace spec:host-browser-mcp
        let id = match request.id {
            Some(id) => id,
            None => {
                return RpcResponse::Error {
                    id: 0,
                    code: -32600,
                    message: "tools/call requires an id".to_string(),
                };
            }
        };

        // For now, all tools return a placeholder error (Wave 2 will implement actual logic).
        RpcResponse::Success {
            id,
            result: json!({
                "content": [
                    {
                        "type": "text",
                        "text": "Tool handler not yet implemented"
                    }
                ],
                "isError": true
            }),
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

    #[tokio::test]
    async fn initialize_request() {
        let server = BrowserMcpServer::new(McpServerConfig::default());
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
        let server = BrowserMcpServer::new(McpServerConfig::default());
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
        let server = BrowserMcpServer::new(McpServerConfig::default());
        let request = RpcRequest {
            id: Some(3),
            method: "unknown/method".to_string(),
            params: json!({}),
        };

        let response = server.handle_request(request).await;
        match response {
            RpcResponse::Error { id, code, .. } => {
                assert_eq!(id, 3);
                assert_eq!(code, -32601); // Method not found
            }
            _ => panic!("Expected error response"),
        }
    }

    #[tokio::test]
    async fn prompts_list_returns_empty() {
        let server = BrowserMcpServer::new(McpServerConfig::default());
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
}
