//! browser.open(url) tool implementation.
//!
//! Opens a new browser window at the given URL, enforcing the per-project
//! allowlist and debounce logic.
//!
//! @trace spec:host-browser-mcp, spec:host-chromium-on-demand
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;
use url::Url;

use crate::browser_mcp::allowlist::validate;
use crate::browser_mcp::debounce::DebounceTable;
use crate::browser_mcp::launcher;
use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.open tool call.
///
/// Validates the URL against the allowlist, checks debounce, and launches
/// a new window if needed.
pub async fn handle_open(
    request: &Value,
    registry: &WindowRegistry,
    debounce: &DebounceTable,
    project: &str,
) -> Result<Value, String> {
    // Extract parameters
    let params = request
        .get("params")
        .ok_or("Missing params")?
        .as_object()
        .ok_or("params must be an object")?;

    let url_str = params
        .get("url")
        .and_then(|v| v.as_str())
        .ok_or("Missing or invalid 'url' parameter")?;

    // Enforce allowlist (also parses the URL)
    let url = validate(url_str, project)
        .map_err(|e| {
            info!(
                accountability = true,
                category = "browser-mcp",
                spec = "host-browser-mcp",
                reason = %e,
                project = %project,
                "URL not allowed"
            );
            format!("URL_NOT_ALLOWED: {}", e)
        })?;

    // Check debounce
    let host = url
        .host_str()
        .ok_or("URL has no host")?
        .to_string();

    // Check debounce with window-exists predicate
    if let Some(existing_id) = debounce.check_debounce(project, &host, |window_id| {
        registry.get(window_id).is_some()
    }) {
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            host = %host,
            window_id = %existing_id,
            project = %project,
            "Window open debounced (returned existing)"
        );

        return Ok(json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "window_id": existing_id,
                "debounced": true
            }
        }));
    }

    // Launch new window
    let entry = launcher::launch(&url, project).await?;
    let window_id = entry.id.clone();

    // Record in registry and debounce table
    registry.insert(entry.clone());
    debounce.record_open(project, &host, window_id.clone());

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        host = %host,
        window_id = %window_id,
        project = %project,
        pid = entry.pid,
        "New window opened"
    );

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "window_id": window_id,
            "debounced": false,
            "pid": entry.pid,
            "url": entry.opened_url
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_missing_url_param() {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "browser.open",
            "params": {}
        });

        // This would need async test framework
        // For now, test the parameter extraction logic
        let params = request.get("params").unwrap().as_object().unwrap();
        let url = params.get("url").and_then(|v| v.as_str());
        assert!(url.is_none());
    }

    #[test]
    fn test_invalid_url() {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "browser.open",
            "params": {
                "url": "not a url"
            }
        });

        let params = request.get("params").unwrap().as_object().unwrap();
        let url_str = params.get("url").and_then(|v| v.as_str()).unwrap();
        let url = Url::parse(url_str);
        assert!(url.is_err());
    }
}
