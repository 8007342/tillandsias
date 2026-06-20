//! Host-resident MCP server for NanoClawV2 project-scoped orchestration.
//!
//! Listens on a Unix socket (path from `--socket` / `TILLANDSIAS_NANOCLAW_SOCKET`),
//! accepts connections from the NanoClawV2 container via `socat`, and dispatches
//! only the five approved orchestration actions through the project-locked allowlist.
//!
//! Architecture mirror: identical transport pattern to `tillandsias-browser-mcp`
//! (Unix socket + socat bridge + JSON-RPC 2.0 newline-framed stdio).
//!
//! @trace spec:nanoclawv2-orchestration

pub mod allowlist;
pub mod server;

pub use allowlist::NanoClawAllowlist;
pub use server::serve_connection;

/// Default in-container path the server socket is bind-mounted at.
/// Must match the path used in the container launch spec in `tray/mod.rs`.
pub const DEFAULT_CONTAINER_SOCKET_PATH: &str = "/run/host/tillandsias/nanoclaw.sock";

/// Env var name for overriding the host-side socket path.
pub const SOCKET_ENV: &str = "TILLANDSIAS_NANOCLAW_SOCKET";

#[cfg(test)]
mod integration_tests {
    //! Slice 4 smoke tests: launch smoke + broker smoke.
    //!
    //! These tests exercise the full serve_connection path over an in-process
    //! UnixStream pair — no real process spawn, no filesystem socket required.
    //! They validate that the server responds to the MCP handshake and that one
    //! approved broker action (nanoclaw.status) returns a well-formed tool result.

    use crate::{NanoClawAllowlist, serve_connection};
    use serde_json::{Value, json};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;

    /// Send one JSON-RPC line and read back the next response line.
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

    /// 4.1 — Launch smoke: verify the server accepts a connection, returns a
    /// valid `initialize` response, and lists exactly 5 approved tools.
    #[tokio::test]
    async fn launch_smoke_initialize_and_tools_list() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = NanoClawAllowlist::new("/tmp/nanoclaw-test-project");

        tokio::spawn(async move {
            serve_connection(server, &allowlist).await;
        });

        let (r, mut w) = client.into_split();
        let mut reader = BufReader::new(r);

        // initialize handshake
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
            server_name.contains("nanoclawv2"),
            "initialize: serverInfo.name must contain 'nanoclawv2', got '{server_name}'"
        );

        // tools/list must return exactly the 5 approved tools
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
            "nanoclaw.advance_work",
            "nanoclaw.build",
            "nanoclaw.service_launch",
            "nanoclaw.forge_delegate",
            "nanoclaw.status",
        ] {
            assert!(
                names.contains(expected),
                "tools/list: missing tool '{expected}'; got {names:?}"
            );
        }
    }

    /// 4.2 — Broker smoke: verify that `nanoclaw.status` (the safest approved
    /// action — read-only plan status) flows through the allowlist and returns a
    /// well-formed tool result, even when the project dir has no loop_status.md.
    #[tokio::test]
    async fn broker_smoke_status_action_returns_tool_result() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = NanoClawAllowlist::new("/tmp/nanoclaw-test-project");

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
                    "name": "nanoclaw.status",
                    "arguments": {}
                }
            }),
        )
        .await;

        assert_eq!(resp["id"], 1, "broker smoke: id mismatch");
        // Must get a result, not a JSON-RPC error
        assert!(
            resp.get("result").is_some(),
            "broker smoke: nanoclaw.status must return a tool result, not a protocol error; got: {resp}"
        );
        // result.content must be a non-empty array (MCP tool result envelope)
        let content = resp["result"]["content"]
            .as_array()
            .expect("broker smoke: result.content must be an array");
        assert!(
            !content.is_empty(),
            "broker smoke: result.content must not be empty"
        );
        // Each content item must have a type
        for item in content {
            assert!(
                item.get("type").is_some(),
                "broker smoke: each content item must have a 'type' field"
            );
        }
    }

    /// 4.2b — Broker smoke: verify that an unknown tool is denied at the broker
    /// level (returns a tool result with isError=true, not an RPC error).
    #[tokio::test]
    async fn broker_smoke_denied_tool_returns_tool_error_not_rpc_error() {
        let (client, server) = UnixStream::pair().unwrap();
        let allowlist = NanoClawAllowlist::new("/tmp/nanoclaw-test-project");

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
        // Must be a tool result, not a JSON-RPC protocol error
        assert!(
            resp.get("result").is_some(),
            "deny smoke: denied tool must return tool result, not RPC error; got: {resp}"
        );
        // isError must be true
        assert_eq!(
            resp["result"]["isError"], true,
            "deny smoke: denied tool call must set isError=true"
        );
    }
}
