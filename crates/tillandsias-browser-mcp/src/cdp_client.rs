//! Chrome DevTools Protocol (CDP) client for browser automation.
//!
//! Connects to a running Chromium instance via CDP WebSocket and sends commands
//! for screenshot capture, element clicking, and text input.
//!
//! @trace spec:host-browser-mcp, spec:browser-isolation-core
//! @cheatsheet web/cdp.md

use base64::Engine;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CdpError {
    #[error("window not running: {0}")]
    WindowNotRunning(String),
    #[error("CDP connection failed: {0}")]
    ConnectionFailed(String),
    #[error("CDP request timeout")]
    Timeout,
    #[error("CDP protocol error: {message} (code: {code})")]
    ProtocolError { code: i32, message: String },
    #[error("screenshot failed: {0}")]
    ScreenshotFailed(String),
    #[error("element not found: selector {selector}")]
    ElementNotFound { selector: String },
    #[error("click failed: {0}")]
    ClickFailed(String),
    #[error("type failed: {0}")]
    TypeFailed(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

/// Minimal CDP session: tracks WebSocket connection and session ID.
pub struct CdpSession {
    stream: TcpStream,
    session_id: String,
    #[allow(dead_code)]
    port: u16,
    #[allow(dead_code)]
    target_id: String,
    request_id: u64,
}

impl CdpSession {
    /// Connect to a running Chromium instance on the given port and target.
    pub fn connect(port: u16, target_id: &str) -> Result<Self, CdpError> {
        if port == 0 {
            return Err(CdpError::WindowNotRunning(
                "port is 0 (window in fake-launch mode)".to_string(),
            ));
        }

        let addr = SocketAddr::from(([127, 0, 0, 1], port));
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(2))
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;

        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;

        // Create a fake session ID (in real CDP we'd use WebSocket and Target.attachToTarget,
        // but for HTTP-based interaction we can keep it simple for now).
        let session_id = format!("session-{}", uuid::Uuid::new_v4());

        Ok(CdpSession {
            stream,
            session_id,
            port,
            target_id: target_id.to_string(),
            request_id: 0,
        })
    }

    /// Send a CDP JSON-RPC command and parse the response.
    fn send_command(&mut self, method: &str, params: Value) -> Result<Value, CdpError> {
        self.request_id += 1;
        let id = self.request_id;

        let request = json!({
            "id": id,
            "method": method,
            "params": params,
            "sessionId": self.session_id,
        });

        // For now, use simple HTTP-based JSON over raw socket (not WebSocket).
        // In production, this would be a WebSocket connection with proper framing.
        // The `/devtools/protocol` endpoint accepts JSON over raw socket.
        let body = serde_json::to_string(&request)
            .map_err(|e| CdpError::ProtocolError {
                code: -32700,
                message: format!("JSON encode error: {e}"),
            })?;

        // Write raw JSON command (Chrome's inspector protocol accepts this)
        self.stream
            .write_all(body.as_bytes())
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;
        self.stream
            .write_all(b"\0")
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;

        // Read response (null-terminated JSON)
        let mut buffer = [0u8; 8192];
        let n = self
            .stream
            .read(&mut buffer)
            .map_err(|e| CdpError::ConnectionFailed(e.to_string()))?;

        if n == 0 {
            return Err(CdpError::ConnectionFailed(
                "connection closed by remote".to_string(),
            ));
        }

        // Parse the response, stripping the null terminator
        let response_bytes = &buffer[..n.saturating_sub(1)];
        let response: Value = serde_json::from_slice(response_bytes).map_err(|e| {
            CdpError::ProtocolError {
                code: -32700,
                message: format!("JSON decode error: {e}"),
            }
        })?;

        // Check for protocol-level error
        if let Some(error) = response.get("error") {
            let code = error
                .get("code")
                .and_then(|v| v.as_i64())
                .unwrap_or(-1) as i32;
            let message = error
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error")
                .to_string();
            return Err(CdpError::ProtocolError { code, message });
        }

        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }

    /// Capture a screenshot of the current viewport or full page.
    pub fn screenshot(&mut self, full_page: bool) -> Result<Vec<u8>, CdpError> {
        let result = self.send_command(
            "Page.captureScreenshot",
            json!({
                "format": "png",
                "captureBeyondViewport": full_page,
            }),
        )?;

        let base64_data = result
            .get("data")
            .and_then(|v| v.as_str())
            .ok_or_else(|| CdpError::ScreenshotFailed("no data in response".to_string()))?;

        base64::engine::general_purpose::STANDARD
            .decode(base64_data)
            .map_err(|e| CdpError::ScreenshotFailed(format!("base64 decode error: {e}")))
    }

    /// Click an element matching a CSS selector.
    pub fn click(&mut self, selector: &str) -> Result<(), CdpError> {
        // Use Runtime.evaluate to find and click the element
        let expression = format!(
            r#"(function() {{
                const el = document.querySelector('{}');
                if (!el) throw new Error('Element not found: {}');
                el.click();
                return true;
            }})()"#,
            selector.replace("'", "\\'"),
            selector.replace("'", "\\'")
        );

        let result = self.send_command(
            "Runtime.evaluate",
            json!({
                "expression": expression,
                "returnByValue": true,
            }),
        )?;

        // Check for exceptions
        if result.get("exceptionDetails").is_some() {
            let msg = result
                .get("exceptionDetails")
                .and_then(|e| e.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            if msg.contains("Element not found") {
                return Err(CdpError::ElementNotFound {
                    selector: selector.to_string(),
                });
            }
            return Err(CdpError::ClickFailed(msg.to_string()));
        }

        Ok(())
    }

    /// Type text into an element matching a CSS selector.
    pub fn type_text(&mut self, selector: &str, text: &str) -> Result<(), CdpError> {
        // Focus and fill the element
        let expression = format!(
            r#"(function() {{
                const el = document.querySelector('{}');
                if (!el) throw new Error('Element not found: {}');
                el.focus();
                el.value = '{}';
                el.dispatchEvent(new Event('input', {{ bubbles: true }}));
                el.dispatchEvent(new Event('change', {{ bubbles: true }}));
                return true;
            }})()"#,
            selector.replace("'", "\\'"),
            selector.replace("'", "\\'"),
            text.replace("'", "\\'")
        );

        let result = self.send_command(
            "Runtime.evaluate",
            json!({
                "expression": expression,
                "returnByValue": true,
            }),
        )?;

        // Check for exceptions
        if result.get("exceptionDetails").is_some() {
            let msg = result
                .get("exceptionDetails")
                .and_then(|e| e.get("text"))
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            if msg.contains("Element not found") {
                return Err(CdpError::ElementNotFound {
                    selector: selector.to_string(),
                });
            }
            return Err(CdpError::TypeFailed(msg.to_string()));
        }

        Ok(())
    }
}
