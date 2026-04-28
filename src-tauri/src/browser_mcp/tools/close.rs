//! browser.close(window_id) tool implementation.
//!
//! Closes a browser window, terminating its process and cleaning up resources.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.close tool call.
pub async fn handle_close(
    request: &Value,
    registry: &WindowRegistry,
    _project: &str,
) -> Result<Value, String> {
    // Extract parameters
    let params = request
        .get("params")
        .ok_or("Missing params")?
        .as_object()
        .ok_or("params must be an object")?;

    let window_id = params
        .get("window_id")
        .and_then(|v| v.as_str())
        .ok_or("Missing or invalid 'window_id' parameter")?;

    // Look up and remove window from registry
    let window = registry
        .remove(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // TODO: Terminate the chromium process
    // SIGTERM with 5s grace period, then SIGKILL
    // Recursively delete user_data_dir

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        pid = window.pid,
        "Window close requested (process termination pending)"
    );

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "ok": true,
            "window_id": window_id
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
}
