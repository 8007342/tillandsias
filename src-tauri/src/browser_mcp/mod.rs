//! In-process MCP server for browser automation.
//!
//! Accepts JSON-RPC frames from the forge via the host control socket,
//! dispatches them through the MCP server, and sends responses back.
//!
//! @trace spec:host-browser-mcp, spec:tray-app
//! @cheatsheet web/mcp.md

pub mod allowlist;
pub mod debounce;
pub mod launcher;
pub mod tools;
pub mod window_registry;

use std::sync::Arc;
use serde_json::{json, Value};
use tokio::sync::Semaphore;
use tillandsias_control_wire::MAX_MCP_FRAME_BYTES;
use tracing::{error, info};

use debounce::DebounceTable;
use window_registry::WindowRegistry;

/// Handle to the browser MCP system.
pub struct BrowserMcpHandle {
    /// Per-session semaphore limiting concurrent tool calls (16 max).
    call_semaphore: Arc<Semaphore>,
    /// Window registry (shared across sessions for the same project).
    window_registry: Arc<WindowRegistry>,
    /// Debounce table for rapid repeated opens.
    debounce: Arc<DebounceTable>,
}

impl BrowserMcpHandle {
    /// Create a new MCP handle.
    pub fn new(max_concurrent_calls: usize) -> Self {
        Self {
            call_semaphore: Arc::new(Semaphore::new(max_concurrent_calls)),
            window_registry: Arc::new(WindowRegistry::new()),
            debounce: Arc::new(DebounceTable::new()),
        }
    }

    /// Process an incoming McpFrame from the control socket.
    ///
    /// This is called from the host control socket handler when a
    /// `ControlMessage::McpFrame` is received. The payload is a single-line
    /// JSON-RPC request. The handler:
    ///
    /// 1. Parses the JSON-RPC request
    /// 2. Dispatches to initialize / tools/list / tools/call / etc.
    /// 3. Returns a JSON-RPC response (or error)
    ///
    /// Responses are sent back through the control socket as another McpFrame.
    ///
    /// @trace spec:host-browser-mcp
    pub async fn handle_mcp_frame(
        &self,
        session_id: u64,
        payload: Vec<u8>,
        project: &str,
    ) -> Result<Vec<u8>, String> {
        // Validate payload size
        if payload.len() > MAX_MCP_FRAME_BYTES {
            error!(
                accountability = true,
                category = "browser-mcp",
                spec = "host-browser-mcp",
                "McpFrame payload exceeds max size: {} bytes",
                payload.len()
            );
            return Err(format!(
                "Payload exceeds max size: {} bytes",
                MAX_MCP_FRAME_BYTES
            ));
        }

        // Parse JSON-RPC frame (single-line UTF-8 JSON)
        let line = String::from_utf8(payload).map_err(|e| format!("Invalid UTF-8: {}", e))?;
        let request: Value = serde_json::from_str(line.trim())
            .map_err(|e| format!("Invalid JSON-RPC: {}", e))?;

        // Dispatch by method
        let response = self.dispatch_rpc(&request, session_id, project).await;
        Ok(serde_json::to_vec(&response).unwrap_or_default())
    }

    /// Dispatch a JSON-RPC 2.0 request to the appropriate handler.
    async fn dispatch_rpc(
        &self,
        request: &Value,
        _session_id: u64,
        project: &str,
    ) -> Value {
        let method = match request.get("method").and_then(|v| v.as_str()) {
            Some(m) => m,
            None => {
                return json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {
                        "code": -32600,
                        "message": "Missing method field"
                    }
                })
            }
        };

        let id = request.get("id");

        match method {
            "initialize" => self.handle_initialize(request),
            "tools/list" => self.handle_tools_list(request),
            "tools/call" => self.handle_tools_call(request, project).await,
            "prompts/list" => self.handle_prompts_list(request),
            "resources/list" => self.handle_resources_list(request),
            "resources/templates/list" => self.handle_resources_templates_list(request),
            "notifications/initialized" => self.handle_notifications_initialized(request),
            _ => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {
                    "code": -32601,
                    "message": format!("Unknown method: {}", method)
                }
            }),
        }
    }

    /// Handle initialize request.
    fn handle_initialize(&self, request: &Value) -> Value {
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            "MCP initialize"
        );

        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "tillandsias-browser-mcp",
                    "version": "0.1.0"
                }
            }
        })
    }

    /// Handle tools/list request.
    fn handle_tools_list(&self, request: &Value) -> Value {
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            "Tool list requested"
        );

        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "tools": [
                    {
                        "name": "browser.open",
                        "description": "Open a new browser window at the given URL",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "url": {
                                    "type": "string",
                                    "description": "URL to open (must match allowlist)"
                                }
                            },
                            "required": ["url"]
                        }
                    },
                    {
                        "name": "browser.list_windows",
                        "description": "List all open windows for the project",
                        "inputSchema": {
                            "type": "object",
                            "properties": {}
                        }
                    },
                    {
                        "name": "browser.read_url",
                        "description": "Get the current URL of a window",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "window_id": {
                                    "type": "string",
                                    "description": "Window ID"
                                }
                            },
                            "required": ["window_id"]
                        }
                    },
                    {
                        "name": "browser.screenshot",
                        "description": "Take a screenshot of a window",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "window_id": {
                                    "type": "string",
                                    "description": "Window ID"
                                },
                                "full_page": {
                                    "type": "boolean",
                                    "description": "Capture full page or viewport"
                                }
                            },
                            "required": ["window_id"]
                        }
                    },
                    {
                        "name": "browser.click",
                        "description": "Click an element in a window",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "window_id": {
                                    "type": "string",
                                    "description": "Window ID"
                                },
                                "selector": {
                                    "type": "string",
                                    "description": "CSS selector"
                                }
                            },
                            "required": ["window_id", "selector"]
                        }
                    },
                    {
                        "name": "browser.type",
                        "description": "Type text into a form field",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "window_id": {
                                    "type": "string",
                                    "description": "Window ID"
                                },
                                "selector": {
                                    "type": "string",
                                    "description": "CSS selector"
                                },
                                "text": {
                                    "type": "string",
                                    "description": "Text to type"
                                }
                            },
                            "required": ["window_id", "selector", "text"]
                        }
                    },
                    {
                        "name": "browser.eval",
                        "description": "Evaluate JavaScript (DISABLED in v1)",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "window_id": {
                                    "type": "string",
                                    "description": "Window ID"
                                },
                                "expression": {
                                    "type": "string",
                                    "description": "JavaScript expression"
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
                                    "type": "string",
                                    "description": "Window ID"
                                }
                            },
                            "required": ["window_id"]
                        }
                    }
                ]
            }
        })
    }

    /// Handle tools/call request.
    async fn handle_tools_call(
        &self,
        request: &Value,
        project: &str,
    ) -> Value {
        // Acquire semaphore permit (enforces 16-concurrent-call limit)
        let permit = self.call_semaphore.acquire().await.ok();
        if permit.is_none() {
            return json!({
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {
                    "code": -32000,
                    "message": "ConcurrentCallLimit: too many in-flight calls"
                }
            });
        }

        // Extract tool name
        let tool_name = match request.get("params")
            .and_then(|p| p.get("name"))
            .and_then(|n| n.as_str())
        {
            Some(name) => name,
            None => {
                return json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {
                        "code": -32602,
                        "message": "Missing tool name in params"
                    }
                })
            }
        };

        // Dispatch to tool handler
        tools::dispatch_tool(
            tool_name,
            request,
            &self.window_registry,
            &self.debounce,
            project,
        )
        .await
    }

    /// Handle prompts/list request (required, returns empty per spec).
    fn handle_prompts_list(&self, request: &Value) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "prompts": []
            }
        })
    }

    /// Handle resources/list request (required, returns empty per spec).
    fn handle_resources_list(&self, request: &Value) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "resources": []
            }
        })
    }

    /// Handle resources/templates/list request (required, returns empty per spec).
    fn handle_resources_templates_list(&self, request: &Value) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "resourceTemplates": []
            }
        })
    }

    /// Handle notifications/initialized request.
    fn handle_notifications_initialized(&self, request: &Value) -> Value {
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            "MCP initialized notification received"
        );

        json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {}
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn handle_mcp_frame_oversized() {
        let handle = BrowserMcpHandle::new(16);
        let huge_payload = vec![0u8; MAX_MCP_FRAME_BYTES + 1];
        let result = handle.handle_mcp_frame(1, huge_payload).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn handle_mcp_frame_invalid_utf8() {
        let handle = BrowserMcpHandle::new(16);
        let invalid_utf8 = vec![0xFF, 0xFE, 0xFD]; // Not valid UTF-8
        let result = handle.handle_mcp_frame(1, invalid_utf8).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn handle_mcp_frame_valid() {
        let handle = BrowserMcpHandle::new(16);
        let payload = br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.to_vec();
        let result = handle.handle_mcp_frame(1, payload).await;
        assert!(result.is_ok());
    }
}
