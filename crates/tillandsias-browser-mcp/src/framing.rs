//! JSON-RPC 2.0 framing over newline-delimited stdin/stdout.
//!
//! Each request/response is a single-line JSON object followed by `\n`.
//! No multi-line JSON, no empty lines, no preamble.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/mcp.md

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum FramingError {
    #[error("JSON parse error: {0}")]
    JsonParse(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] io::Error),

    #[error("Missing 'method' field in RPC request")]
    MissingMethod,

    #[error("Invalid RPC id (must be integer or string)")]
    InvalidId,
}

/// A JSON-RPC 2.0 request parsed from a line.
#[derive(Debug, Clone)]
pub struct RpcRequest {
    pub id: Option<u64>,
    pub method: String,
    pub params: Value,
}

/// A JSON-RPC 2.0 response (either result or error).
#[derive(Debug)]
pub enum RpcResponse {
    Success { id: u64, result: Value },
    Error { id: u64, code: i32, message: String },
    Notification, // No id field for notifications
}

impl RpcRequest {
    /// Parse a single line of JSON into an RPC request.
    pub fn from_line(line: &str) -> Result<Self, FramingError> {
        let obj: Value = serde_json::from_str(line)?;

        let method = obj
            .get("method")
            .and_then(|m| m.as_str())
            .ok_or(FramingError::MissingMethod)?
            .to_string();

        let id = obj.get("id").and_then(|i| i.as_u64());

        let params = obj.get("params").cloned().unwrap_or(Value::Object(Default::default()));

        Ok(RpcRequest { id, method, params })
    }
}

impl RpcResponse {
    /// Serialize to a single-line JSON string (without trailing newline).
    pub fn to_line(&self) -> Result<String, serde_json::Error> {
        let obj = match self {
            RpcResponse::Success { id, result } => {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": result
                })
            }
            RpcResponse::Error { id, code, message } => {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": {
                        "code": code,
                        "message": message
                    }
                })
            }
            RpcResponse::Notification => {
                return Ok(String::new()); // Empty; notifications don't write anything back
            }
        };
        serde_json::to_string(&obj)
    }
}

/// Read a single RPC request line from stdin.
pub fn read_request<R: BufRead>(reader: &mut R) -> Result<RpcRequest, FramingError> {
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let trimmed = line.trim();
    if trimmed.is_empty() {
        // End of input
        return Err(FramingError::Io(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "empty line",
        )));
    }
    RpcRequest::from_line(trimmed)
}

/// Write a single RPC response line to stdout.
pub fn write_response<W: Write>(writer: &mut W, response: &RpcResponse) -> Result<(), FramingError> {
    let line = response.to_line()?;
    if !line.is_empty() {
        writeln!(writer, "{}", line)?;
        writer.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_initialize_request() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude","version":"v0"}}}"#;
        let req = RpcRequest::from_line(line).unwrap();
        assert_eq!(req.method, "initialize");
        assert_eq!(req.id, Some(1));
    }

    #[test]
    fn parse_tools_list_request() {
        let line = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#;
        let req = RpcRequest::from_line(line).unwrap();
        assert_eq!(req.method, "tools/list");
        assert_eq!(req.id, Some(2));
    }

    #[test]
    fn serialize_success_response() {
        let resp = RpcResponse::Success {
            id: 1,
            result: json!({"protocolVersion": "2025-06-18"}),
        };
        let line = resp.to_line().unwrap();
        assert!(line.contains("\"jsonrpc\":\"2.0\""));
        assert!(line.contains("\"id\":1"));
        assert!(line.contains("\"result\""));
    }

    #[test]
    fn serialize_error_response() {
        let resp = RpcResponse::Error {
            id: 1,
            code: -32601,
            message: "Method not found".to_string(),
        };
        let line = resp.to_line().unwrap();
        assert!(line.contains("\"error\""));
        assert!(line.contains("-32601"));
    }
}
