//! browser.eval(window_id, expression) tool implementation.
//!
//! Evaluates JavaScript in a window. Gated: returns EVAL_DISABLED in v1.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tracing::info;

use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.eval tool call.
pub async fn handle_eval(
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

    let expression = params
        .get("expression")
        .and_then(|v| v.as_str())
        .ok_or("Missing or invalid 'expression' parameter")?;

    // Look up window
    let _window = registry
        .get(window_id)
        .ok_or_else(|| format!("Window {} not found", window_id))?;

    // Compute SHA256 of expression for logging (never log the expression itself)
    let mut hasher = Sha256::new();
    hasher.update(expression.as_bytes());
    let expression_sha256 = format!("{:x}", hasher.finalize());

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        cheatsheet = "web/cdp.md",
        window_id = %window_id,
        expression_sha256 = %expression_sha256,
        "Eval requested (DISABLED in v1)"
    );

    // v1: always disabled
    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "error": {
            "code": -32000,
            "message": "EVAL_DISABLED: JavaScript evaluation is disabled in v1"
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
}
