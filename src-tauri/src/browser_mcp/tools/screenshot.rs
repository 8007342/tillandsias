//! browser.screenshot(window_id) tool implementation.
//!
//! Captures a screenshot of the given window via CDP Page.captureScreenshot.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

use crate::{browser_mcp::window_registry::WindowRegistry, cdp};

/// Handle browser.screenshot tool call.
pub async fn handle_screenshot(
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

    let full_page = params
        .get("full_page")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    // Look up window
    let window = registry
        .get(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // Call CDP Page.captureScreenshot
    let (data, width, height) = cdp::page_capture_screenshot(window.cdp_port, &window.target_id, full_page)
        .await?;

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        full_page = full_page,
        width = width,
        height = height,
        "Screenshot captured successfully"
    );

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "data": data,
            "width": width,
            "height": height,
            "format": "png"
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
}
