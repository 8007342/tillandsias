//! browser.read_url(window_id) tool implementation.
//!
//! Returns the current URL of a window via CDP Page.getNavigationHistory.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.read_url tool call.
pub async fn handle_read_url(
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

    // Look up window
    let window = registry
        .get(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // TODO: Call CDP Page.getNavigationHistory to get live URL
    // For now, return the opened URL from the registry

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        "Read URL requested"
    );

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "url": window.opened_url,
            "cdp_port": window.cdp_port
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
}
