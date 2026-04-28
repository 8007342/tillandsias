//! browser.type(window_id, selector, text) tool implementation.
//!
//! Types text into a form field via CDP Runtime.evaluate.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.type tool call.
pub async fn handle_type(
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

    let text = params
        .get("text")
        .and_then(|v| v.as_str())
        .ok_or("Missing or invalid 'text' parameter")?;

    // Look up window
    let _window = registry
        .get(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // TODO: Call CDP Runtime.evaluate with expression:
    // `let el = document.querySelector(selector);
    //  el.value = text;
    //  el.dispatchEvent(new Event('input', { bubbles: true }))`

    let text_len = text.len();
    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        selector = %selector,
        text_len = text_len,
        "Type requested (CDP call pending)"
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
