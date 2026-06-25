//! ZeroClaw MCP server — JSON-RPC dispatch for the five approved tools.
//!
//! Handles one connection at a time (one container per project launch). Uses
//! the same JSON-RPC framing as the browser-mcp crate.
//!
//! @trace spec:zeroclaw-orchestration

use crate::allowlist::{ApprovedAction, ZeroClawAllowlist};
use serde_json::json;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tillandsias_browser_mcp::framing::{RpcRequest, RpcResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::process::Command;
use tracing::{debug, info, warn};

/// Run the MCP server over an established `UnixStream` connection.
pub async fn serve_connection(stream: UnixStream, allowlist: &ZeroClawAllowlist) {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    info!(
        project = %allowlist.project().display(),
        "zeroclaw-mcp: connection accepted"
    );

    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        debug!(line = %line, "zeroclaw-mcp: rx");

        let response = match RpcRequest::from_line(&line) {
            Err(e) => {
                warn!(err = %e, "zeroclaw-mcp: framing error");
                continue;
            }
            Ok(req) => dispatch(req, allowlist).await,
        };

        match response {
            RpcResponse::Notification => {}
            other => match other.to_line() {
                Ok(mut s) => {
                    s.push('\n');
                    if let Err(e) = writer.write_all(s.as_bytes()).await {
                        warn!(err = %e, "zeroclaw-mcp: write error");
                        break;
                    }
                    debug!("zeroclaw-mcp: tx ok");
                }
                Err(e) => warn!(err = %e, "zeroclaw-mcp: serialize error"),
            },
        }
    }

    info!("zeroclaw-mcp: connection closed");
}

async fn dispatch(req: RpcRequest, allowlist: &ZeroClawAllowlist) -> RpcResponse {
    let id = match req.id {
        Some(id) => id,
        None => {
            if req.method == "notifications/initialized" {
                return RpcResponse::Notification;
            }
            return RpcResponse::Notification;
        }
    };

    match req.method.as_str() {
        "initialize" => handle_initialize(id),
        "tools/list" => handle_tools_list(id),
        "prompts/list" | "resources/list" | "resources/templates/list" => RpcResponse::Success {
            id,
            result: json!({ "prompts": [], "resources": [], "resourceTemplates": [] }),
        },
        "tools/call" => handle_tools_call(id, &req.params, allowlist).await,
        other => RpcResponse::Error {
            id,
            code: -32601,
            message: format!("Method not found: {other}"),
        },
    }
}

fn handle_initialize(id: u64) -> RpcResponse {
    RpcResponse::Success {
        id,
        result: json!({
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "tillandsias-zeroclaw",
                "version": env!("CARGO_PKG_VERSION")
            }
        }),
    }
}

fn handle_tools_list(id: u64) -> RpcResponse {
    RpcResponse::Success {
        id,
        result: json!({
            "tools": [
                {
                    "name": "zeroclaw.advance_work",
                    "description": "Advance the next ready work item from the project plan on the host.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "project_path": {
                                "type": "string",
                                "description": "Must match the locked project path (optional; server enforces it)."
                            }
                        }
                    }
                },
                {
                    "name": "zeroclaw.build",
                    "description": "Run the project build check (./build.sh --check). Pass full_test=true for --test.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "full_test": { "type": "boolean" },
                            "project_path": { "type": "string" }
                        }
                    }
                },
                {
                    "name": "zeroclaw.service_launch",
                    "description": "Start an approved local service (dev-proxy, inference, vault, router).",
                    "inputSchema": {
                        "type": "object",
                        "required": ["service_name"],
                        "properties": {
                            "service_name": { "type": "string", "enum": ["dev-proxy","inference","vault","router"] },
                            "project_path": { "type": "string" }
                        }
                    }
                },
                {
                    "name": "zeroclaw.forge_delegate",
                    "description": "Launch a forge container for the locked project with the given prompt.",
                    "inputSchema": {
                        "type": "object",
                        "required": ["prompt"],
                        "properties": {
                            "prompt": { "type": "string" },
                            "project_path": { "type": "string" }
                        }
                    }
                },
                {
                    "name": "zeroclaw.status",
                    "description": "Return current plan/loop status for the locked project.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "project_path": { "type": "string" }
                        }
                    }
                }
            ]
        }),
    }
}

async fn handle_tools_call(
    id: u64,
    params: &serde_json::Value,
    allowlist: &ZeroClawAllowlist,
) -> RpcResponse {
    let tool_name = match params.get("name").and_then(|v| v.as_str()) {
        Some(n) => n,
        None => {
            return RpcResponse::Success {
                id,
                result: tool_error_result("missing 'name' in tools/call params"),
            };
        }
    };
    let args = params.get("arguments").cloned().unwrap_or(json!({}));

    match allowlist.check(tool_name, &args) {
        Err(deny) => {
            warn!(tool = tool_name, reason = %deny, "zeroclaw-mcp: DENIED");
            RpcResponse::Success {
                id,
                result: tool_error_result(format!("DENIED: {deny}")),
            }
        }
        Ok(action) => {
            info!(tool = tool_name, "zeroclaw-mcp: executing approved action");
            let result = execute_action(action, allowlist.project()).await;
            RpcResponse::Success { id, result }
        }
    }
}

async fn execute_action(action: ApprovedAction, project: &Path) -> serde_json::Value {
    match action {
        ApprovedAction::AdvanceWork => {
            run_in_project(
                project,
                "bash",
                &[
                    "-c",
                    "./codex --no-repeat \"Use the /advance-work-from-plan skill\" 2>&1 | tail -40",
                ],
                Duration::from_secs(300),
            )
            .await
        }

        ApprovedAction::Build { full_test } => {
            let flag = if full_test { "--test" } else { "--check" };
            run_in_project(
                project,
                "bash",
                &["-c", &format!("./build.sh {flag} 2>&1 | tail -80")],
                Duration::from_secs(180),
            )
            .await
        }

        ApprovedAction::ServiceLaunch { service_name } => {
            run_in_project(
                project,
                "bash",
                &[
                    "-c",
                    &format!("tillandsias --start-service {service_name} 2>&1 | tail -20"),
                ],
                Duration::from_secs(60),
            )
            .await
        }

        ApprovedAction::ForgeDelegate { prompt } => {
            let cmd = format!(
                "tillandsias --forge-opencode --project . --prompt {prompt:?} 2>&1 | tail -40"
            );
            run_in_project(project, "bash", &["-c", &cmd], Duration::from_secs(300)).await
        }

        ApprovedAction::Status => {
            run_in_project(
                project,
                "bash",
                &[
                    "-c",
                    "head -60 plan/loop_status.md 2>/dev/null || echo '(no loop_status.md found)'",
                ],
                Duration::from_secs(5),
            )
            .await
        }
    }
}

async fn run_in_project(
    cwd: &Path,
    program: &str,
    args: &[&str],
    timeout: Duration,
) -> serde_json::Value {
    let result = tokio::time::timeout(timeout, async {
        Command::new(program)
            .args(args)
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .await
    })
    .await;

    match result {
        Err(_) => tool_error_result(format!("timed out after {}s", timeout.as_secs())),
        Ok(Err(e)) => tool_error_result(format!("spawn error: {e}")),
        Ok(Ok(output)) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            let combined = if stderr.is_empty() {
                stdout.to_string()
            } else {
                format!("{stdout}\nstderr:\n{stderr}")
            };
            let success = output.status.success();
            json!({
                "content": [{ "type": "text", "text": combined }],
                "isError": !success
            })
        }
    }
}

fn tool_error_result(msg: impl Into<String>) -> serde_json::Value {
    json!({
        "content": [{ "type": "text", "text": msg.into() }],
        "isError": true
    })
}
