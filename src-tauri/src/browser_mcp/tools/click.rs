//! browser.click(window_id, selector) tool implementation.
//!
//! Clicks a DOM element matching the selector via CDP Runtime.evaluate.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

// @trace spec:host-browser-mcp
use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.click tool call.
pub async fn handle_click(
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

    let selector = params
        .get("selector")
        .and_then(|v| v.as_str())
        .ok_or("Missing or invalid 'selector' parameter")?;

    // Look up window
    let window = registry
        .get(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // Call CDP Runtime.evaluate with click expression
    let expr = format!("document.querySelector({:?}).click()", selector);
    crate::cdp::runtime_evaluate(window.cdp_port, &window.target_id, &expr)
        .await?;

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        selector = %selector,
        "Click executed successfully"
    );

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "ok": true
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
}
