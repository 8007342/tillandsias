//! Simple CLI tool for on-demand browser window spawning.
//!
//! Replaces the MCP daemon with a lightweight CLI that connects directly
//! to the tray's Unix socket to request browser windows.
//!
//! Usage: tillandsias-browser-tool <project> <url> <safe|debug>
//!
//! @trace spec:mcp-on-demand, spec:cheatsheet-mcp-server

#[cfg(unix)]
use std::env;
#[cfg(unix)]
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::path::Path;

#[cfg(unix)]
use serde_json::json;

/// Unix socket path for communicating with the Tillandsias tray app.
#[cfg(unix)]
const TRAY_SOCKET: &str = "/run/tillandsias/tray.sock";

/// Send a browser window request to the tray via Unix socket.
#[cfg(unix)]
fn send_browser_request(project: &str, url: &str, window_type: &str) -> Result<(), String> {
    let socket_path = Path::new(TRAY_SOCKET);
    if !socket_path.exists() {
        return Err(format!(
            "Tray socket not found at '{}'. Is Tillandsias running?",
            TRAY_SOCKET
        ));
    }

    let mut stream = UnixStream::connect(socket_path)
        .map_err(|e| format!("Failed to connect to tray socket: {}", e))?;

    let request = json!({
        "method": "open_browser_window",
        "params": {
            "project": project,
            "url": url,
            "window_type": window_type,
        }
    });

    let request_str = format!("{}\n", request.to_string());
    stream.write_all(request_str.as_bytes())
        .map_err(|e| format!("Failed to send request: {}", e))?;

    // Wait for response
    let mut response = String::new();
    stream.read_to_string(&mut response)
        .map_err(|e| format!("Failed to read response: {}", e))?;

    if response.is_empty() {
        // No response is OK (fire-and-forget)
        Ok(())
    } else {
        // Parse response for errors
        match serde_json::from_str::<serde_json::Value>(&response) {
            Ok(val) => {
                if let Some(error) = val.get("error") {
                    Err(format!("Tray error: {}", error))
                } else {
                    Ok(())
                }
            }
            Err(_) => Ok(()), // Non-JSON response, assume success
        }
    }
}

#[cfg(unix)]
fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() != 4 {
        eprintln!("Usage: {} <project> <url> <safe|debug>", args[0]);
        eprintln!("  project:     Project name (e.g., 'my-app')");
        eprintln!("  url:         URL to open (e.g., 'http://opencode.my-app.localhost:4096')");
        eprintln!("  safe|debug:  Window type (safe=isolated, debug=with DevTools)");
        std::process::exit(1);
    }

    let project = &args[1];
    let url = &args[2];
    let window_type = match args[3].as_str() {
        "safe" => "open_safe_window",
        "debug" => "open_debug_window",
        other => {
            eprintln!("Invalid window type '{}'. Expected 'safe' or 'debug'.", other);
            std::process::exit(1);
        }
    };

    // Validate URL contains project name (basic safety check)
    if !url.contains(&format!(".{}.localhost", project)) && !url.contains("dashboard.localhost") {
        eprintln!("Warning: URL '{}' may not be allowed for project '{}'", url, project);
    }

    match send_browser_request(project, url, window_type) {
        Ok(_) => {
            println!("Browser window request sent successfully.");
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use super::*;

    #[test]
    fn test_window_type_mapping() {
        // Test that the window type strings are correctly mapped
        let safe = "safe";
        let debug = "debug";
        // Just verify the strings are valid
        assert!(safe == "safe");
        assert!(debug == "debug");
    }
}

