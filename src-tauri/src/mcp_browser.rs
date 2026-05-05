//! MCP (Model Context Protocol) server for browser window control.
//!
//! Exposes `open_safe_window` and `open_debug_window` tools to agents.
//! Forwards requests to tray via Unix socket at `/run/tillandsias/tray.sock`.
//!
//! ## Protocol
//!
//! Agents (running in forge containers) call MCP tools:
//! - `open_safe_window(url)` → spawns isolated Chromium window (no DevTools)
//! - `open_debug_window(url)` → spawns Chromium with DevTools on port 9222
//!
//! The MCP server listens on stdin/stdout (standard MCP transport).
//! It connects to the tray's Unix socket to trigger actual browser spawning.
//!
//! @trace spec:browser-mcp-server
//! @trace spec:browser-isolation-core

#![cfg_attr(unix, allow(dead_code))] // Unix sockets only on Unix

use std::io::{BufRead, Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tracing::{debug, info, warn};

/// Entry point for the MCP browser server binary (Unix only).
/// Expects `TILLANDSIAS_PROJECT` environment variable to be set.
#[cfg(unix)]
fn main() {
    let project = std::env::var("TILLANDSIAS_PROJECT").unwrap_or_else(|_| "unknown".to_string());

    // Initialize logging
    let _ = tracing_subscriber::fmt().with_env_filter("info").try_init();

    if let Err(e) = run_mcp_server(&project) {
        eprintln!("MCP server error: {}", e);
        std::process::exit(1);
    }
}

/// Unix socket path for communicating with the Tillandsias tray app.
const TRAY_SOCKET: &str = "/run/tillandsias/tray.sock";

/// MCP protocol version we support.
const MCP_VERSION: &str = "2024-11-05";

/// Tool definitions for browser control.
#[derive(Debug, Serialize)]
struct McpTool {
    name: &'static str,
    description: &'static str,
    input_schema: Value,
}

/// Build the tool list (not const to avoid json!() in const context).
#[cfg(unix)]
fn get_tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "open_safe_window",
            description: "Open a URL in an isolated safe browser window with dark theme, hidden address bar, and no developer tools. \
                 Safe windows enforce read-only isolation. Available for URLs matching <service>.<project>.localhost or dashboard.localhost.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Target URL in format <service>.<project>.localhost or dashboard.localhost (e.g., 'opencode.my-project.localhost', 'dashboard.localhost')"
                    }
                },
                "required": ["url"]
            }),
        },
        McpTool {
            name: "open_debug_window",
            description: "Open a URL in an isolated debug browser window with Chrome DevTools enabled and visible address bar. \
                 Debug windows expose the full inspector on localhost:9222 for troubleshooting. \
                 Agents can only open debug windows for their own project (e.g., 'web.my-project.localhost'). \
                 No debug windows for external or dashboard URLs.",
            input_schema: json!({
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Target URL for debugging (e.g., 'web.my-project.localhost:3000')"
                    }
                },
                "required": ["url"]
            }),
        },
    ]
}

/// MCP request from client.
#[derive(Debug, Deserialize)]
struct McpRequest {
    method: String,
    params: Option<Value>,
    id: Option<Value>,
}

/// MCP response to client.
#[derive(Debug, Serialize)]
struct McpResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<Value>,
}

/// Tool call parameters.
#[derive(Debug, Deserialize)]
struct ToolCall {
    name: String,
    arguments: Option<Value>,
}

/// Connect to the tray's Unix socket and request a browser window.
///
/// Protocol: send JSON-RPC envelope, read response.
/// Tray expects: `{ "method": "open_browser_window", "params": { "project": "...", "url": "...", "window_type": "..." }`
///
/// @trace spec:browser-mcp-server
#[cfg(unix)]
fn request_browser_window(project: &str, url: &str, window_type: &str) -> Result<(), String> {
    if !Path::new(TRAY_SOCKET).exists() {
        return Err(format!(
            "Tray socket not found at '{}'. Is Tillandsias tray running?",
            TRAY_SOCKET
        ));
    }

    let mut stream = UnixStream::connect(TRAY_SOCKET)
        .map_err(|e| format!("Failed to connect to tray socket '{}': {}", TRAY_SOCKET, e))?;

    let request = json!({
        "jsonrpc": "2.0",
        "method": "open_browser_window",
        "params": {
            "project": project,
            "url": url,
            "window_type": window_type
        }
    });

    let request_str = serde_json::to_string(&request).map_err(|e| e.to_string())?;
    debug!(
        spec = "browser-mcp-server",
        request = %request_str,
        "Sending browser window request to tray"
    );

    writeln!(stream, "{}", request_str).map_err(|e| e.to_string())?;

    // Use BufReader for reading response
    let mut reader = std::io::BufReader::new(&stream);
    let mut response = String::new();
    reader
        .read_to_string(&mut response)
        .map_err(|e| e.to_string())?;

    info!(
        spec = "browser-mcp-server",
        response = %response,
        "Received response from tray"
    );

    Ok(())
}

/// Handle an MCP tool call.
#[cfg(unix)]
fn handle_tool_call(
    tool_name: &str,
    arguments: Option<&Value>,
    project: &str,
) -> Result<Value, String> {
    let url = arguments
        .and_then(|args| args.get("url"))
        .and_then(|u| u.as_str())
        .ok_or_else(|| "Missing 'url' parameter".to_string())?;

    let window_type = match tool_name {
        "open_safe_window" => "open_safe_window",
        "open_debug_window" => "open_debug_window",
        _ => return Err(format!("Unknown tool: {}", tool_name)),
    };

    // Validate URL matches expected pattern
    if window_type == "open_safe_window" && !is_safe_url(url, project) {
        return Err(format!(
            "Invalid URL for safe window: '{}'. Expected <service>.<project>.localhost or dashboard.localhost",
            url
        ));
    } else if window_type == "open_debug_window" && !is_debug_url(url, project) {
        return Err(format!(
            "Invalid URL for debug window: '{}'. Expected <service>.<project>.localhost only",
            url
        ));
    }

    request_browser_window(project, url, window_type)?;

    Ok(json!({
        "content": [{
            "type": "text",
            "text": format!("Browser window opened: {}", url)
        }]
    }))
}

/// Validate URL for safe windows.
#[cfg(unix)]
fn is_safe_url(url: &str, project: &str) -> bool {
    url.contains(&format!(".{}.localhost", project)) || url.contains("dashboard.localhost")
}

/// Validate URL for debug windows.
#[cfg(unix)]
fn is_debug_url(url: &str, project: &str) -> bool {
    url.contains(&format!(".{}.localhost", project))
}

/// Main MCP server loop.
///
/// Reads JSON-RPC requests from stdin, processes them, writes responses to stdout.
///
/// @trace spec:browser-mcp-server
#[cfg(unix)]
pub fn run_mcp_server(project: &str) -> Result<(), String> {
    info!(
        spec = "browser-mcp-server",
        project = %project,
        "Starting MCP browser server for project"
    );

    let stdin = std::io::stdin();
    let mut reader = std::io::BufReader::new(stdin);
    let mut stdout = std::io::BufWriter::new(std::io::stdout());

    let tools = get_tools();

    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            break; // EOF
        }

        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let request: McpRequest = match serde_json::from_str(line) {
            Ok(req) => req,
            Err(e) => {
                warn!(
                    spec = "browser-mcp-server",
                    error = %e,
                    "Failed to parse MCP request"
                );
                let response = McpResponse {
                    id: None,
                    result: None,
                    error: Some(json!({
                        "code": -32700,
                        "message": "Parse error"
                    })),
                };
                let _ = writeln!(
                    stdout,
                    "{}",
                    serde_json::to_string(&response).unwrap_or_default()
                );
                let _ = stdout.flush();
                continue;
            }
        };

        let response = match request.method.as_str() {
            "initialize" => {
                info!(spec = "browser-mcp-server", "Handling initialize request");
                McpResponse {
                    id: request.id,
                    result: Some(json!({
                        "protocolVersion": MCP_VERSION,
                        "capabilities": {
                            "tools": {}
                        },
                        "serverInfo": {
                            "name": "tillandsias-browser",
                            "version": "1.0.0"
                        }
                    })),
                    error: None,
                }
            }
            "tools/list" => {
                debug!(spec = "browser-mcp-server", "Listing tools");
                let tool_values: Vec<Value> = tools
                    .iter()
                    .map(|t| serde_json::to_value(t).unwrap())
                    .collect();
                McpResponse {
                    id: request.id,
                    result: Some(json!({ "tools": tool_values })),
                    error: None,
                }
            }
            "tools/call" => {
                let params = request.params.as_ref().ok_or("Missing params".to_string());
                let tool_call: Result<ToolCall, String> = params
                    .and_then(|p| serde_json::from_value(p.clone()).map_err(|e| e.to_string()));

                match tool_call {
                    Ok(call) => {
                        match handle_tool_call(&call.name, call.arguments.as_ref(), project) {
                            Ok(result) => McpResponse {
                                id: request.id,
                                result: Some(json!({ "content": result })),
                                error: None,
                            },
                            Err(e) => McpResponse {
                                id: request.id,
                                result: None,
                                error: Some(json!({
                                    "code": -32602,
                                    "message": e
                                })),
                            },
                        }
                    }
                    Err(e) => McpResponse {
                        id: request.id,
                        result: None,
                        error: Some(json!({
                            "code": -32602,
                            "message": e.to_string()
                        })),
                    },
                }
            }
            _ => {
                warn!(
                    spec = "browser-mcp-server",
                    method = %request.method,
                    "Unknown MCP method"
                );
                McpResponse {
                    id: request.id,
                    result: None,
                    error: Some(json!({
                        "code": -32601,
                        "message": format!("Method not found: {}", request.method)
                    })),
                }
            }
        };

        let response_str = serde_json::to_string(&response).map_err(|e| e.to_string())?;
        writeln!(stdout, "{}", response_str).map_err(|e| e.to_string())?;
        stdout.flush().map_err(|e| e.to_string())?;
    }

    info!(spec = "browser-mcp-server", "MCP server shutting down");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safe_url_validation() {
        assert!(is_safe_url("opencode.my-project.localhost", "my-project"));
        assert!(is_safe_url("dashboard.localhost", "my-project"));
        assert!(!is_safe_url("evil.com", "my-project"));
    }

    #[test]
    fn test_debug_url_validation() {
        assert!(is_debug_url("web.my-project.localhost:3000", "my-project"));
        assert!(!is_debug_url("dashboard.localhost", "my-project"));
        assert!(!is_debug_url("evil.com", "my-project"));
    }
}

/// Windows stub - MCP browser server is Unix-only
#[cfg(not(unix))]
fn main() {
    eprintln!("MCP browser server is not available on this platform (Unix/Linux only)");
    std::process::exit(1);
}
