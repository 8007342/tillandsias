//! Browser automation tool handlers.
//!
//! Each module implements one MCP tool via CDP.
//!
//! @trace spec:host-browser-mcp

pub mod click;
pub mod close;
pub mod eval;
pub mod list_windows;
pub mod open;
pub mod read_url;
pub mod screenshot;
pub mod type_;

use serde_json::{json, Value};
use tracing::error;

use crate::browser_mcp::{debounce::DebounceTable, window_registry::WindowRegistry};

/// Dispatch a tool call to the appropriate handler.
///
/// Returns the MCP tool response or an error response.
pub async fn dispatch_tool(
    tool_name: &str,
    request: &Value,
    registry: &WindowRegistry,
    debounce: &DebounceTable,
    project: &str,
) -> Value {
    let result = match tool_name {
        "browser.open" => open::handle_open(request, registry, debounce, project).await,
        "browser.list_windows" => list_windows::handle_list_windows(request, registry, project).await,
        "browser.read_url" => read_url::handle_read_url(request, registry, project).await,
        "browser.screenshot" => screenshot::handle_screenshot(request, registry, project).await,
        "browser.click" => click::handle_click(request, registry, project).await,
        "browser.type" => type_::handle_type(request, registry, project).await,
        "browser.eval" => eval::handle_eval(request, registry, project).await,
        "browser.close" => close::handle_close(request, registry, project).await,
        _ => {
            error!(
                category = "browser-mcp",
                spec = "host-browser-mcp",
                tool_name = %tool_name,
                "Unknown tool name"
            );
            return json!({
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {
                    "code": -32601,
                    "message": format!("Unknown tool: {}", tool_name)
                }
            });
        }
    };

    match result {
        Ok(response) => response,
        Err(error_msg) => json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "error": {
                "code": -32000,
                "message": error_msg
            }
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
}
