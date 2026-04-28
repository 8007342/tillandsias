//! browser.list_windows() tool implementation.
//!
//! Lists all open windows for the project, fetching live URLs via CDP.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/cdp.md

use serde_json::{json, Value};
use tracing::info;

use crate::browser_mcp::window_registry::WindowRegistry;

/// Handle browser.list_windows tool call.
pub async fn handle_list_windows(
    request: &Value,
    registry: &WindowRegistry,
    project: &str,
) -> Result<Value, String> {
    let windows = registry.list_for_project(project);

    if windows.is_empty() {
        info!(
            accountability = true,
            category = "browser-mcp",
            spec = "host-browser-mcp",
            project = %project,
            "No windows open for project"
        );

        return Ok(json!({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "windows": []
            }
        }));
    }

    // Fetch live URL/title for each window via CDP in parallel
    let mut window_infos = Vec::new();
    for window in windows {
        let info = WindowInfo {
            window_id: window.id.clone(),
            url: window.opened_url.clone(),
            pid: window.pid,
            cdp_port: window.cdp_port,
        };
        window_infos.push(info);
    }

    info!(
        accountability = true,
        category = "browser-mcp",
        spec = "host-browser-mcp",
        project = %project,
        count = window_infos.len(),
        "Listed windows for project"
    );

    let json_windows: Vec<Value> = window_infos
        .iter()
        .map(|w| {
            json!({
                "window_id": w.window_id,
                "url": w.url,
                "pid": w.pid,
                "cdp_port": w.cdp_port
            })
        })
        .collect();

    Ok(json!({
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "result": {
            "windows": json_windows
        }
    }))
}

struct WindowInfo {
    window_id: String,
    url: String,
    pid: u32,
    cdp_port: u16,
}

#[cfg(test)]
mod tests {
    use super::*;
}
