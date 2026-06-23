//! Host-resident MCP server for ZeroClaw project-scoped orchestration.
//!
//! Listens on a Unix socket (path from `--socket` / `TILLANDSIAS_ZEROCLAW_SOCKET`),
//! accepts connections from the ZeroClaw container via `socat`, and dispatches
//! only the five approved orchestration actions through the project-locked allowlist.
//!
//! Architecture mirror: identical transport pattern to `tillandsias-browser-mcp`
//! (Unix socket + socat bridge + JSON-RPC 2.0 newline-framed stdio).
//!
//! @trace spec:zeroclaw-orchestration

pub mod allowlist;
pub mod server;

pub use allowlist::ZeroClawAllowlist;
pub use server::serve_connection;

/// Default in-container path the server socket is bind-mounted at.
pub const DEFAULT_CONTAINER_SOCKET_PATH: &str = "/run/host/tillandsias/zeroclaw.sock";

/// Env var name for overriding the host-side socket path.
pub const SOCKET_ENV: &str = "TILLANDSIAS_ZEROCLAW_SOCKET";

#[cfg(test)]
mod integration_tests {
    use crate::{ZeroClawAllowlist, serve_connection};
    use serde_json::{Value, json};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;

    async fn rpc(
        writer: &mut tokio::net::unix::OwnedWriteHalf,
        reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
        msg: Value,
    ) -> Value {
        let mut line = serde_json::to_string(&msg).unwrap();
        line.push('\n');
        writer.write_all(line.as_bytes()).await.unwrap();
        let mut response = String::new();
        reader.read_line(&mut response).await.unwrap();
        serde_json::from_str(response.trim()).unwrap()
    }

    #[tokio::test]
    async fn launch_smoke_initialize_and_tools_list() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = ZeroClawAllowlist::new("/tmp/zeroclaw-test-project");

        tokio::spawn(async move {
            serve_connection(server, &allowlist).await;
        });

        let (r, mut w) = client.into_split();
        let mut reader = BufReader::new(r);

        let resp = rpc(
            &mut w,
            &mut reader,
            json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {}
            }),
        )
        .await;
        assert_eq!(resp["id"], 1, "initialize: id mismatch");
        let server_name = resp["result"]["serverInfo"]["name"].as_str().unwrap_or("");
        assert!(
            server_name.contains("zeroclaw"),
            "initialize: serverInfo.name must contain 'zeroclaw', got '{server_name}'"
        );

        let resp = rpc(
            &mut w,
            &mut reader,
            json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": {}
            }),
        )
        .await;
        let tools = resp["result"]["tools"]
            .as_array()
            .expect("tools/list: missing tools array");
        assert_eq!(
            tools.len(),
            5,
            "tools/list: expected 5 approved tools, got {}",
            tools.len()
        );

        let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
        for expected in &[
            "zeroclaw.advance_work",
            "zeroclaw.build",
            "zeroclaw.service_launch",
            "zeroclaw.forge_delegate",
            "zeroclaw.status",
        ] {
            assert!(
                names.contains(expected),
                "tools/list: missing tool '{expected}'; got {names:?}"
            );
        }
    }

    #[tokio::test]
    async fn broker_smoke_status_action_returns_tool_result() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = ZeroClawAllowlist::new("/tmp/zeroclaw-test-project");

        tokio::spawn(async move {
            serve_connection(server, &allowlist).await;
        });

        let (r, mut w) = client.into_split();
        let mut reader = BufReader::new(r);

        let resp = rpc(
            &mut w,
            &mut reader,
            json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "zeroclaw.status",
                    "arguments": {}
                }
            }),
        )
        .await;

        assert_eq!(resp["id"], 1, "broker smoke: id mismatch");
        assert!(
            resp.get("result").is_some(),
            "broker smoke: zeroclaw.status must return a tool result; got: {resp}"
        );
        let content = resp["result"]["content"]
            .as_array()
            .expect("broker smoke: result.content must be an array");
        assert!(
            !content.is_empty(),
            "broker smoke: result.content must not be empty"
        );
        for item in content {
            assert!(
                item.get("type").is_some(),
                "broker smoke: content item missing 'type'"
            );
        }
    }

    #[tokio::test]
    async fn broker_smoke_denied_tool_returns_tool_error_not_rpc_error() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = ZeroClawAllowlist::new("/tmp/zeroclaw-test-project");

        tokio::spawn(async move {
            serve_connection(server, &allowlist).await;
        });

        let (r, mut w) = client.into_split();
        let mut reader = BufReader::new(r);

        let resp = rpc(
            &mut w,
            &mut reader,
            json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "podman.run",
                    "arguments": {}
                }
            }),
        )
        .await;

        assert_eq!(resp["id"], 1, "deny smoke: id mismatch");
        assert!(
            resp.get("result").is_some(),
            "deny smoke: denied tool must return tool result; got: {resp}"
        );
        assert_eq!(
            resp["result"]["isError"], true,
            "deny smoke: denied tool call must set isError=true"
        );
    }
}
