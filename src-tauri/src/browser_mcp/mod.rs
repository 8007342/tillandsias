//! In-process MCP server for browser automation.
//!
//! Accepts JSON-RPC frames from the forge via the host control socket,
//! dispatches them through the MCP server, and sends responses back.
//!
//! @trace spec:host-browser-mcp, spec:tray-app

pub mod allowlist;
pub mod debounce;
pub mod window_registry;

use std::sync::Arc;
use tokio::sync::Semaphore;
use tillandsias_control_wire::MAX_MCP_FRAME_BYTES;
use tracing::{error, info};

/// Handle to the browser MCP system.
pub struct BrowserMcpHandle {
    /// Per-session semaphore limiting concurrent tool calls.
    call_semaphore: Arc<Semaphore>,
}

impl BrowserMcpHandle {
    /// Create a new MCP handle.
    pub fn new(max_concurrent_calls: usize) -> Self {
        Self {
            call_semaphore: Arc::new(Semaphore::new(max_concurrent_calls)),
        }
    }

    /// Process an incoming McpFrame from the control socket.
    ///
    /// This is called from the host control socket handler when a
    /// `ControlMessage::McpFrame` is received. The payload is a single-line
    /// JSON-RPC request. The handler:
    ///
    /// 1. Parses the JSON-RPC request
    /// 2. Dispatches to the appropriate tool handler
    /// 3. Returns a JSON-RPC response (or error)
    ///
    /// Responses are sent back through the control socket as another McpFrame.
    ///
    /// @trace spec:host-browser-mcp
    pub async fn handle_mcp_frame(
        &self,
        session_id: u64,
        payload: Vec<u8>,
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
        let _line = line.trim();

        // Parse and respond (placeholder for Wave 2)
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            session_id = session_id,
            "MCP frame received (Wave 2: handler pending)"
        );

        // For now, return a placeholder response
        let response = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": "Tool handlers not yet implemented (Wave 2)"
                    }
                ],
                "isError": true
            }
        });

        Ok(serde_json::to_vec(&response).unwrap_or_default())
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
