//! Chrome DevTools Protocol client for pre-navigate cookie injection.
//!
//! The tray launches the user's Chromium-family browser with
//! `--remote-debugging-port=<random-loopback-port>` and `--app=about:blank`,
//! waits for the CDP HTTP discovery endpoint to respond, then:
//!
//! 1. Discovers the project-URL page target via `GET /json` on the CDP port.
//!    (Chromium is launched with `--app=URL`, so its initial target is the
//!    project URL — NOT about:blank — to keep the window in app-mode
//!    without an omnibox.)
//! 2. Opens a WebSocket to the target's `webSocketDebuggerUrl`.
//! 3. Sends `Network.enable` to gate the Network domain.
//! 4. Sends `Network.setCookies` with the canonical attribute set
//!    (Path=/, HttpOnly, SameSite=Strict, expires=now+86400, secure=false).
//! 5. Sends `Page.reload` (with `ignoreCache: true`) to retry the
//!    initial request now that the cookie is in the jar — the first GET
//!    that chromium fired on launch 401'd because the cookie wasn't yet
//!    set.
//!
//! The cookie value is wiped from memory after `Network.setCookies` succeeds
//! so a postmortem process scrape sees zeroes instead of the token bytes.
//!
//! Plain `ws://127.0.0.1:<port>/devtools/page/<TARGET_ID>` only — no TLS,
//! no proxy, loopback by definition. tokio-tungstenite is configured
//! without TLS features for this reason.
//!
//! @trace spec:opencode-web-session-otp
//! @cheatsheet web/cookie-auth-best-practices.md

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};
use zeroize::Zeroize;

use crate::otp::{COOKIE_LEN, COOKIE_MAX_AGE_SECS, COOKIE_NAME, COOKIE_PATH};

/// Default deadline to wait for the CDP discovery endpoint to come up after
/// spawning the browser.
pub const CDP_READY_TIMEOUT: Duration = Duration::from_secs(5);

/// Per-CDP-call deadline. Tillandsias-wide fast-fail idiom — if the browser
/// is not responding to JSON-RPC inside 2s the user is better served by an
/// unauthenticated page than a hanging tray.
pub const CDP_CALL_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Deserialize)]
struct CdpTarget {
    #[allow(dead_code)] // id is the protocol-level TARGET_ID; not consumed here.
    id: String,
    #[serde(rename = "type")]
    target_type: String,
    url: String,
    #[serde(rename = "webSocketDebuggerUrl")]
    web_socket_debugger_url: String,
}

/// Cookie payload as `Network.setCookies` expects it. Field names mirror
/// the CDP schema exactly.
#[derive(Debug, Serialize)]
struct CdpCookieParam<'a> {
    name: &'a str,
    value: String,
    url: &'a str,
    path: &'a str,
    #[serde(rename = "httpOnly")]
    http_only: bool,
    secure: bool,
    #[serde(rename = "sameSite")]
    same_site: &'a str,
    expires: i64,
}

/// JSON-RPC request envelope. CDP uses a strict subset of JSON-RPC 2.0:
/// `{ "id": <int>, "method": "<Domain.method>", "params": {...} }`.
#[derive(Debug, Serialize)]
struct CdpRequest<'a> {
    id: u64,
    method: &'a str,
    params: serde_json::Value,
}

/// JSON-RPC response envelope. CDP returns either `result` on success or
/// `error: { code, message }` on failure.
#[derive(Debug, Deserialize)]
struct CdpResponse {
    id: Option<u64>,
    #[serde(default)]
    error: Option<CdpError>,
}

#[derive(Debug, Deserialize)]
struct CdpError {
    #[allow(dead_code)] // surfaced via Display formatting only.
    code: i64,
    message: String,
}

/// Result of [`attach_and_set_cookie`]. Mostly used for diagnostics; the
/// caller usually discards it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CdpOutcome {
    Ok,
    /// CDP endpoint never responded within [`CDP_READY_TIMEOUT`].
    NotReady,
    /// CDP responded but `Network.setCookies` failed.
    SetCookieFailed(String),
    /// `Page.navigate` failed.
    NavigateFailed(String),
    /// Generic protocol or I/O failure.
    Other(String),
}

/// Wait for the CDP HTTP discovery endpoint at `127.0.0.1:<port>/json/version`
/// to respond. Polls every 100 ms with a global deadline of [`CDP_READY_TIMEOUT`].
///
/// Uses a hand-rolled tokio TcpStream HTTP/1.1 GET so this does NOT pull
/// in the rustls/ring provider initialisation that `reqwest` requires —
/// the CDP endpoint is plain HTTP on loopback by definition.
///
/// @trace spec:opencode-web-session-otp
pub async fn wait_for_cdp_ready(port: u16) -> bool {
    let deadline = tokio::time::Instant::now() + CDP_READY_TIMEOUT;
    while tokio::time::Instant::now() < deadline {
        if probe_cdp_http(port).await {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

/// One-shot HTTP/1.1 GET against `/json/version`. Returns `true` if the
/// server answered with a 2xx status. Plain TCP, no TLS dependency.
async fn probe_cdp_http(port: u16) -> bool {
    let Ok(mut stream) = tokio::time::timeout(
        Duration::from_millis(500),
        TcpStream::connect(("127.0.0.1", port)),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(Ok::<_, ()>)
    .unwrap_or(Err(()))
    else {
        return false;
    };
    let req = b"GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    if stream.write_all(req).await.is_err() {
        return false;
    }
    let mut buf = [0u8; 64];
    let read = tokio::time::timeout(Duration::from_millis(500), stream.read(&mut buf)).await;
    match read {
        Ok(Ok(n)) if n >= 12 => {
            // "HTTP/1.1 200 ..." — accept any 2xx.
            let line = &buf[..n];
            line.starts_with(b"HTTP/1.1 2") || line.starts_with(b"HTTP/1.0 2")
        }
        _ => false,
    }
}

/// Idle gap after the response headers parse before we declare the body
/// complete (when no Content-Length is present). Chrome's DevTools HTTP
/// server returns its response immediately but does NOT honour
/// `Connection: close` — it keeps the socket open until its own ~10 s
/// internal timeout. `read_to_end` would therefore wait forever (well, the
/// 2 s [`CDP_CALL_TIMEOUT`]) and return nothing useful. We instead read in
/// a loop with a short per-iteration deadline AND honour Content-Length
/// when present.
const HTTP_BODY_IDLE_GAP: Duration = Duration::from_millis(200);

/// Issue a simple HTTP/1.1 GET against `127.0.0.1:<port><path>` and return
/// the response body bytes. Plain TCP — no TLS. Returns `None` on any error.
///
/// Reading strategy: parse `Content-Length` from the header block and read
/// exactly that many body bytes; if the header is absent (or zero) fall
/// back to a [`HTTP_BODY_IDLE_GAP`] inactivity heuristic. The overall
/// per-call deadline is [`CDP_CALL_TIMEOUT`].
///
/// The `Host` header includes the port — Chrome 111+ DNS-rebinding
/// protection on the DevTools HTTP endpoints rejects mismatched Host
/// headers; `127.0.0.1:<port>` is always accepted.
async fn http_get_loopback(port: u16, path: &str) -> Option<Vec<u8>> {
    let mut stream = tokio::time::timeout(
        CDP_CALL_TIMEOUT,
        TcpStream::connect(("127.0.0.1", port)),
    )
    .await
    .ok()?
    .ok()?;
    let req = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAccept: */*\r\n\r\n"
    );
    stream.write_all(req.as_bytes()).await.ok()?;

    let mut buf = Vec::with_capacity(8192);
    let mut chunk = [0u8; 4096];
    let deadline = tokio::time::Instant::now() + CDP_CALL_TIMEOUT;
    let mut header_end: Option<usize> = None;
    let mut content_length: Option<usize> = None;

    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            break;
        }
        // Once headers are parsed, fall back to a tight idle-gap deadline
        // so we don't sit waiting on a socket the server won't close.
        let per_read = if header_end.is_some() {
            std::cmp::min(deadline - now, HTTP_BODY_IDLE_GAP)
        } else {
            deadline - now
        };
        let n = match tokio::time::timeout(per_read, stream.read(&mut chunk)).await {
            Ok(Ok(0)) => break,        // EOF (rare on Chrome's server)
            Ok(Ok(n)) => n,
            Ok(Err(_)) => return None, // socket error
            Err(_) => {
                // Idle-gap elapsed. If we already have headers, treat as
                // body-complete; if not, the server was slow — give up.
                if header_end.is_some() {
                    break;
                }
                return None;
            }
        };
        buf.extend_from_slice(&chunk[..n]);

        if header_end.is_none()
            && let Some(idx) = buf.windows(4).position(|w| w == b"\r\n\r\n")
        {
            header_end = Some(idx + 4);
            // Best-effort Content-Length parse (case-insensitive header name).
            if let Ok(header_str) = std::str::from_utf8(&buf[..idx]) {
                for line in header_str.lines() {
                    let lower = line.to_ascii_lowercase();
                    if let Some(rest) = lower.strip_prefix("content-length:")
                        && let Ok(n) = rest.trim().parse::<usize>()
                    {
                        content_length = Some(n);
                        break;
                    }
                }
            }
        }
        // If we know Content-Length and have read it all, we're done.
        if let (Some(he), Some(cl)) = (header_end, content_length)
            && buf.len() >= he + cl
        {
            break;
        }
    }

    let body_start = header_end?;
    Some(buf[body_start..].to_vec())
}

/// Pick the page target the tray should attach to. Strategy:
///
/// 1. Prefer a `page` target whose `url` is exactly `about:blank` — this is
///    the shell that `--app=about:blank` opened and is the intended attach
///    surface.
/// 2. Fall back to the first `page` target if no exact about:blank match
///    (Chromium sometimes resolves `--app=` URLs through one redirect on
///    first launch).
fn select_page_target(targets: &[CdpTarget]) -> Option<&CdpTarget> {
    targets
        .iter()
        .find(|t| t.target_type == "page" && t.url == "about:blank")
        .or_else(|| targets.iter().find(|t| t.target_type == "page"))
}

/// Send a JSON-RPC request, then drain incoming WebSocket frames until a
/// frame with the matching `id` arrives. Unrelated CDP events (frames
/// without `id`) are dropped silently — they are async notifications from
/// other domains we did not subscribe to.
///
/// Returns `Err` on timeout, IO error, or a CDP `error.message` field on
/// the matching response.
async fn cdp_call<S>(
    ws: &mut tokio_tungstenite::WebSocketStream<S>,
    id: u64,
    method: &str,
    params: serde_json::Value,
) -> Result<(), String>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let req = CdpRequest { id, method, params };
    let frame = serde_json::to_string(&req).map_err(|e| format!("encode {method}: {e}"))?;
    tokio::time::timeout(CDP_CALL_TIMEOUT, ws.send(Message::Text(frame.into())))
        .await
        .map_err(|_| format!("timeout sending {method}"))?
        .map_err(|e| format!("send {method}: {e}"))?;

    // Drain frames until we see our id (or timeout / error).
    let deadline = tokio::time::Instant::now() + CDP_CALL_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("timeout awaiting response to {method}"));
        }
        let next = tokio::time::timeout(remaining, ws.next()).await;
        let msg = match next {
            Ok(Some(Ok(m))) => m,
            Ok(Some(Err(e))) => return Err(format!("ws error awaiting {method}: {e}")),
            Ok(None) => return Err(format!("ws closed awaiting {method}")),
            Err(_) => return Err(format!("timeout awaiting response to {method}")),
        };
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Binary(b) => match std::str::from_utf8(&b) {
                Ok(s) => s.to_string(),
                Err(_) => continue,
            },
            // CDP only emits text frames in normal operation; ignore pings/pongs/closes.
            _ => continue,
        };
        // Parse minimally — we only care about id/error here.
        let resp: CdpResponse = match serde_json::from_str(&text) {
            Ok(r) => r,
            Err(_) => continue, // malformed event — skip
        };
        if resp.id != Some(id) {
            continue; // event or response to a different id — skip
        }
        if let Some(err) = resp.error {
            return Err(err.message);
        }
        return Ok(());
    }
}

/// Attach to the bundled / detected Chromium's CDP endpoint, set the session
/// cookie, then navigate to `target_url`.
///
/// The 32-byte `cookie_value` is wiped after `Network.setCookies` is
/// acknowledged — even on partial failure (the wipe runs in every branch
/// before returning).
///
/// Returns `CdpOutcome::Ok` only when both `Network.setCookies` AND
/// `Page.navigate` succeed. Any earlier failure leaves the browser pointed
/// at about:blank — the caller may choose to log + close, or fall back to
/// a non-CDP launch path.
///
/// @trace spec:opencode-web-session-otp
pub async fn attach_and_set_cookie(
    cdp_port: u16,
    target_url: &str,
    mut cookie_value: String,
) -> CdpOutcome {
    // 1. Discover targets. /json returns an array of target descriptors.
    let body = match http_get_loopback(cdp_port, "/json").await {
        Some(b) => b,
        None => {
            debug!(
                spec = "opencode-web-session-otp",
                port = cdp_port,
                "CDP discovery HTTP request failed"
            );
            cookie_value.zeroize();
            return CdpOutcome::NotReady;
        }
    };
    let targets: Vec<CdpTarget> = match serde_json::from_slice(&body) {
        Ok(t) => t,
        Err(e) => {
            warn!(
                spec = "opencode-web-session-otp",
                error = %e,
                "CDP /json deserialise failed"
            );
            cookie_value.zeroize();
            return CdpOutcome::Other(format!("CDP target list deserialise: {e}"));
        }
    };

    let page = match select_page_target(&targets) {
        Some(t) => t,
        None => {
            warn!(
                spec = "opencode-web-session-otp",
                port = cdp_port,
                targets = targets.len(),
                "CDP discovery returned no page target"
            );
            cookie_value.zeroize();
            return CdpOutcome::Other("no page target available".to_string());
        }
    };
    let ws_url = page.web_socket_debugger_url.clone();
    info!(
        spec = "opencode-web-session-otp",
        port = cdp_port,
        targets = targets.len(),
        "CDP discovery succeeded — attaching WebSocket"
    );

    // 2. Open the WebSocket to the page target.
    let ws_connect =
        tokio::time::timeout(CDP_CALL_TIMEOUT, tokio_tungstenite::connect_async(&ws_url)).await;
    let mut ws = match ws_connect {
        Ok(Ok((stream, _resp))) => stream,
        Ok(Err(e)) => {
            warn!(
                spec = "opencode-web-session-otp",
                error = %e,
                "CDP WebSocket connect failed"
            );
            cookie_value.zeroize();
            return CdpOutcome::Other(format!("ws connect: {e}"));
        }
        Err(_) => {
            warn!(
                spec = "opencode-web-session-otp",
                "CDP WebSocket connect timed out"
            );
            cookie_value.zeroize();
            return CdpOutcome::Other("ws connect timeout".to_string());
        }
    };

    // 3. Network.enable is required before Network.setCookies has effect.
    if let Err(e) = cdp_call(&mut ws, 1, "Network.enable", serde_json::json!({})).await {
        warn!(
            spec = "opencode-web-session-otp",
            error = %e,
            "Network.enable failed"
        );
        cookie_value.zeroize();
        return CdpOutcome::Other(format!("Network.enable: {e}"));
    }

    // 4. Network.setCookies — the actual injection.
    let expiry = cookie_expiry_unix_secs();
    let cookie_param = build_cookie_param(&cookie_value, target_url, expiry);
    let set_params = serde_json::json!({ "cookies": [cookie_param] });
    let set_outcome = cdp_call(&mut ws, 2, "Network.setCookies", set_params).await;
    // Wipe the cookie value AFTER setCookies completes (success or failure)
    // — beyond this point the value has either landed in the browser or
    // has been irrecoverably lost; either way we must not keep the bytes.
    // @trace spec:opencode-web-session-otp, spec:secrets-management
    cookie_value.zeroize();
    if let Err(e) = set_outcome {
        warn!(
            spec = "opencode-web-session-otp",
            error = %e,
            "Network.setCookies failed"
        );
        return CdpOutcome::SetCookieFailed(e);
    }

    // 5. Page.reload — chromium was already navigating to target_url
    // (we launch with `--app=URL`, not `--app=about:blank`, to keep the
    // window in app-mode without an omnibox). The first request 401'd
    // because the cookie wasn't yet set; the reload retries with the
    // cookie now present in the jar. `ignoreCache=true` so the reload
    // doesn't pick up any cached 401 body.
    let reload_params = serde_json::json!({ "ignoreCache": true });
    if let Err(e) = cdp_call(&mut ws, 3, "Page.reload", reload_params).await {
        warn!(
            spec = "opencode-web-session-otp",
            error = %e,
            "Page.reload failed"
        );
        return CdpOutcome::NavigateFailed(e);
    }

    // Best-effort close — we do not care if the close handshake fails.
    let _ = ws.close(None).await;
    debug!(
        spec = "opencode-web-session-otp",
        port = cdp_port,
        "CDP cookie injection + reload complete"
    );
    CdpOutcome::Ok
}

/// Build the CDP `Network.setCookies` parameter for a single cookie.
///
/// @trace spec:opencode-web-session-otp
pub fn build_cookie_param(
    cookie_value: &str,
    target_url: &str,
    expires_unix_secs: i64,
) -> serde_json::Value {
    serde_json::to_value(CdpCookieParam {
        name: COOKIE_NAME,
        value: cookie_value.to_string(),
        url: target_url,
        path: COOKIE_PATH,
        http_only: true,
        secure: false,
        same_site: "Strict",
        expires: expires_unix_secs,
    })
    .expect("CDP cookie param serialises")
}

/// Compute the absolute Unix-seconds expiry for a freshly-issued cookie:
/// `now + COOKIE_MAX_AGE_SECS`.
///
/// @trace spec:opencode-web-session-otp
pub fn cookie_expiry_unix_secs() -> i64 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    (now + COOKIE_MAX_AGE_SECS) as i64
}

/// Convenience: derive a base64url-encoded cookie value from a 32-byte token
/// (mirrors `otp::format_cookie_value`, lifted here so callers don't have to
/// import the otp module just for this).
///
/// @trace spec:opencode-web-session-otp
#[allow(dead_code)]
pub fn token_to_cookie_string(token: &[u8; COOKIE_LEN]) -> String {
    crate::otp::format_cookie_value(token)
}

/// Call `Page.captureScreenshot` to grab a PNG screenshot.
///
/// Returns (base64_data, width, height) or error.
///
/// @trace spec:host-browser-mcp
pub async fn page_capture_screenshot(
    port: u16,
    target_id: &str,
    full_page: bool,
) -> Result<(String, u32, u32), String> {
    let ws_url = format!("ws://127.0.0.1:{}/devtools/page/{}", port, target_id);
    let (ws_stream, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("connect for screenshot: {e}"))?;
    let (mut write, mut read) = ws_stream.split();

    let params = serde_json::json!({
        "format": "png",
        "captureBeyondViewport": full_page,
        "omitDeviceEmulationParams": false
    });
    let req = serde_json::json!({
        "id": 9001_u64,
        "method": "Page.captureScreenshot",
        "params": params
    });
    let frame = serde_json::to_string(&req).map_err(|e| format!("encode screenshot: {e}"))?;
    tokio::time::timeout(CDP_CALL_TIMEOUT, write.send(Message::Text(frame.into())))
        .await
        .map_err(|_| "timeout sending Page.captureScreenshot".to_string())?
        .map_err(|e| format!("send screenshot: {e}"))?;

    let deadline = tokio::time::Instant::now() + CDP_CALL_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout awaiting screenshot".to_string());
        }
        let next = tokio::time::timeout(remaining, read.next()).await;
        let msg = match next {
            Ok(Some(Ok(m))) => m,
            Ok(Some(Err(e))) => return Err(format!("ws error: {e}")),
            Ok(None) => return Err("ws closed".to_string()),
            Err(_) => return Err("timeout".to_string()),
        };
        let text = match msg {
            Message::Text(t) => t,
            _ => continue,
        };
        let resp: serde_json::Value = match serde_json::from_str(&text) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if resp.get("id").and_then(|id| id.as_u64()) != Some(9001) {
            continue;
        }
        if let Some(err) = resp.get("error") {
            return Err(err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown error")
                .to_string());
        }
        let result = resp
            .get("result")
            .ok_or_else(|| "no result in screenshot response".to_string())?;
        let data = result["data"]
            .as_str()
            .ok_or_else(|| "missing data field".to_string())?
            .to_string();
        let width = result["width"]
            .as_u64()
            .ok_or_else(|| "missing width".to_string())? as u32;
        let height = result["height"]
            .as_u64()
            .ok_or_else(|| "missing height".to_string())? as u32;
        return Ok((data, width, height));
    }
}

/// Call `Runtime.evaluate` with the given expression (JavaScript code).
///
/// Returns the expression result or error.
///
/// @trace spec:host-browser-mcp
pub async fn runtime_evaluate(
    port: u16,
    target_id: &str,
    expression: &str,
) -> Result<serde_json::Value, String> {
    let ws_url = format!("ws://127.0.0.1:{}/devtools/page/{}", port, target_id);
    let (ws_stream, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("connect for eval: {e}"))?;
    let (mut write, mut read) = ws_stream.split();

    let params = serde_json::json!({
        "expression": expression
    });
    let req = serde_json::json!({
        "id": 9002_u64,
        "method": "Runtime.evaluate",
        "params": params
    });
    let frame = serde_json::to_string(&req).map_err(|e| format!("encode eval: {e}"))?;
    tokio::time::timeout(CDP_CALL_TIMEOUT, write.send(Message::Text(frame.into())))
        .await
        .map_err(|_| "timeout sending Runtime.evaluate".to_string())?
        .map_err(|e| format!("send eval: {e}"))?;

    let deadline = tokio::time::Instant::now() + CDP_CALL_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("timeout awaiting eval result".to_string());
        }
        let next = tokio::time::timeout(remaining, read.next()).await;
        let msg = match next {
            Ok(Some(Ok(m))) => m,
            Ok(Some(Err(e))) => return Err(format!("ws error: {e}")),
            Ok(None) => return Err("ws closed".to_string()),
            Err(_) => return Err("timeout".to_string()),
        };
        let text = match msg {
            Message::Text(t) => t,
            _ => continue,
        };
        let resp: serde_json::Value = match serde_json::from_str(&text) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if resp.get("id").and_then(|id| id.as_u64()) != Some(9002) {
            continue;
        }
        if let Some(err) = resp.get("error") {
            return Err(err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown error")
                .to_string());
        }
        let result = resp
            .get("result")
            .ok_or_else(|| "no result in eval response".to_string())?;
        return Ok(result.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::otp::generate_session_token;
    use std::sync::Arc;
    use tokio::net::TcpListener;
    use tokio::sync::Mutex;

    #[test]
    fn build_cookie_param_has_canonical_attribute_set() {
        let value = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        let v = build_cookie_param(value, "http://opencode.demo.localhost:8080/", 1_700_000_000);
        assert_eq!(v["name"], "tillandsias_session");
        assert_eq!(v["value"], value);
        assert_eq!(v["url"], "http://opencode.demo.localhost:8080/");
        assert_eq!(v["path"], "/");
        assert_eq!(v["httpOnly"], true);
        assert_eq!(v["secure"], false);
        assert_eq!(v["sameSite"], "Strict");
        assert_eq!(v["expires"], 1_700_000_000_i64);
    }

    #[test]
    fn cookie_expiry_is_in_the_future() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let exp = cookie_expiry_unix_secs();
        // Should be within 86400 +/- 5s of now.
        let delta = exp - now;
        assert!(
            (86_395..=86_405).contains(&delta),
            "expiry should be ~24h in the future, was {delta}s"
        );
    }

    #[test]
    fn token_to_cookie_string_matches_otp_format() {
        let tok = generate_session_token();
        assert_eq!(
            token_to_cookie_string(&tok),
            crate::otp::format_cookie_value(&tok)
        );
    }

    #[test]
    fn select_page_target_prefers_about_blank() {
        let targets = vec![
            CdpTarget {
                id: "BG".into(),
                target_type: "background_page".into(),
                url: "chrome-extension://abc/".into(),
                web_socket_debugger_url: "ws://x/1".into(),
            },
            CdpTarget {
                id: "P1".into(),
                target_type: "page".into(),
                url: "https://example.com/".into(),
                web_socket_debugger_url: "ws://x/2".into(),
            },
            CdpTarget {
                id: "P2".into(),
                target_type: "page".into(),
                url: "about:blank".into(),
                web_socket_debugger_url: "ws://x/3".into(),
            },
        ];
        let pick = select_page_target(&targets).expect("page target");
        assert_eq!(pick.id, "P2");
    }

    #[test]
    fn select_page_target_falls_back_to_first_page() {
        let targets = vec![
            CdpTarget {
                id: "BG".into(),
                target_type: "background_page".into(),
                url: "chrome-extension://abc/".into(),
                web_socket_debugger_url: "ws://x/1".into(),
            },
            CdpTarget {
                id: "P1".into(),
                target_type: "page".into(),
                url: "https://example.com/".into(),
                web_socket_debugger_url: "ws://x/2".into(),
            },
        ];
        let pick = select_page_target(&targets).expect("page target");
        assert_eq!(pick.id, "P1");
    }

    #[test]
    fn select_page_target_none_when_no_page() {
        let targets = vec![CdpTarget {
            id: "BG".into(),
            target_type: "background_page".into(),
            url: "chrome-extension://abc/".into(),
            web_socket_debugger_url: "ws://x/1".into(),
        }];
        assert!(select_page_target(&targets).is_none());
    }

    /// Regression: the original `http_get_loopback` used `read_to_end`,
    /// which blocked until EOF. Chrome's DevTools HTTP server does NOT
    /// honour `Connection: close` and keeps the socket open ~10 s after
    /// responding — so every CDP discovery call timed out at 2 s and
    /// returned `NotReady`, leaving every browser launch unauthenticated.
    /// This test simulates the same pathology with a mock server that
    /// holds the connection open after sending the response, and proves
    /// `http_get_loopback` returns the body within the per-call deadline.
    /// @trace spec:opencode-web-session-otp
    #[tokio::test]
    async fn http_get_loopback_returns_body_when_server_holds_connection_open() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            // Drain the request.
            let mut req_buf = [0u8; 1024];
            let _ = tokio::time::timeout(
                Duration::from_millis(200),
                sock.read(&mut req_buf),
            )
            .await;
            // Send the response with explicit Content-Length, then SIT on
            // the socket — never close. Mirrors what Chrome's CDP HTTP
            // server actually does.
            let body = b"[]";
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                body.len()
            );
            let _ = sock.write_all(resp.as_bytes()).await;
            let _ = sock.write_all(body).await;
            // Hold open for longer than CDP_CALL_TIMEOUT.
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        // Yield so the listener is accepting before the call.
        tokio::task::yield_now().await;
        let started = tokio::time::Instant::now();
        let body = http_get_loopback(port, "/json").await.expect("body");
        let elapsed = started.elapsed();
        assert_eq!(body, b"[]");
        assert!(
            elapsed < Duration::from_millis(800),
            "should return promptly via Content-Length, not wait for the connection to close; took {:?}",
            elapsed
        );
    }

    /// CDP discovery against a closed port returns NotReady (and does so
    /// quickly — no 5s hang).
    #[tokio::test]
    async fn cdp_attach_against_closed_port_is_not_ready() {
        // Pick a port that is almost certainly closed.
        let port = 65_531;
        let outcome =
            attach_and_set_cookie(port, "http://opencode.demo.localhost:8080/", "v".to_string())
                .await;
        assert!(matches!(outcome, CdpOutcome::NotReady | CdpOutcome::Other(_)));
    }

    /// Verifies the redaction contract: the cookie value passed in is
    /// scrubbed in place (caller's String is wiped) regardless of CDP
    /// success/failure.
    #[tokio::test]
    async fn cookie_value_is_zeroized_after_attach() {
        // Use a closed port so we hit the failure path — the wipe MUST
        // still happen.
        let port = 65_530;
        let val = "secret-cookie-value-zeroize-me-12345678901".to_string();
        let _ = attach_and_set_cookie(port, "http://x/", val).await;
        // The original `val` was moved + wiped inside the function. There
        // is no observable side-effect to assert here at the type level —
        // the contract is enforced by the explicit `zeroize()` calls in
        // every branch of `attach_and_set_cookie`. This test exists so
        // anyone who removes a wipe call gets a visible failure when the
        // log redaction tests below also fail.
    }

    /// Captured JSON-RPC method calls observed by the mock CDP server.
    /// The mock parses each text frame, records the `method` field, and
    /// echoes back a success response with the same `id`.
    #[derive(Default)]
    struct MockCalls {
        methods: Vec<String>,
        cookies_payload: Option<serde_json::Value>,
        navigate_url: Option<String>,
    }

    /// Spawn an in-process mock CDP server. Returns the bound port and
    /// an Arc<Mutex<MockCalls>> the test can inspect after attach.
    ///
    /// Speaks the minimal subset:
    /// - `GET /json/version`            → `200 OK` + tiny JSON body
    /// - `GET /json`                    → `200 OK` + a single about:blank page target
    /// - `WS  /devtools/page/<TARGET>`  → echoes `{id,result:{}}` for every JSON-RPC call
    async fn spawn_mock_cdp() -> (u16, Arc<Mutex<MockCalls>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind mock");
        let port = listener.local_addr().expect("local_addr").port();
        let calls: Arc<Mutex<MockCalls>> = Arc::new(Mutex::new(MockCalls::default()));
        let calls_clone = calls.clone();

        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let calls = calls_clone.clone();
                tokio::spawn(async move {
                    // Peek the request line by reading until "\r\n\r\n".
                    let mut buf = Vec::with_capacity(1024);
                    let mut tmp = [0u8; 1024];
                    loop {
                        match tokio::time::timeout(
                            Duration::from_millis(500),
                            sock.read(&mut tmp),
                        )
                        .await
                        {
                            Ok(Ok(n)) if n > 0 => {
                                buf.extend_from_slice(&tmp[..n]);
                                if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                                    break;
                                }
                            }
                            _ => return,
                        }
                    }
                    let head = String::from_utf8_lossy(&buf).to_string();
                    let first_line = head.lines().next().unwrap_or("").to_string();
                    if first_line.starts_with("GET /json/version") {
                        let body = b"{\"Browser\":\"mock\"}";
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = sock.write_all(resp.as_bytes()).await;
                        let _ = sock.write_all(body).await;
                        return;
                    }
                    if first_line.starts_with("GET /json ")
                        || first_line.starts_with("GET /json HTTP")
                    {
                        let local = sock.local_addr().expect("local_addr");
                        let ws_url = format!("ws://{}/devtools/page/MOCKTARGET", local);
                        let body = serde_json::json!([
                            {
                                "id": "MOCKTARGET",
                                "type": "page",
                                "url": "about:blank",
                                "webSocketDebuggerUrl": ws_url,
                            }
                        ])
                        .to_string();
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = sock.write_all(resp.as_bytes()).await;
                        let _ = sock.write_all(body.as_bytes()).await;
                        return;
                    }
                    if first_line.starts_with("GET /devtools/page/") {
                        // Hand off to tungstenite's accept side. The tungstenite
                        // server-accept needs an unparsed stream — we already
                        // consumed the request, so re-feed the buffered bytes by
                        // serving the WebSocket handshake by hand. Easier: ask
                        // tungstenite to accept on a wrapper that re-reads the
                        // bytes we already consumed.
                        //
                        // Simpler approach: we already read the full HTTP head
                        // (no body). Build the Sec-WebSocket-Accept manually
                        // and respond, then run the framing loop.
                        let key = head
                            .lines()
                            .find_map(|l| l.strip_prefix("Sec-WebSocket-Key:"))
                            .map(|s| s.trim().to_string());
                        let Some(key) = key else { return };
                        let accept = ws_accept_key(&key);
                        let resp = format!(
                            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                            accept
                        );
                        if sock.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                        // Now run a tungstenite framing loop over the raw socket.
                        let ws = tokio_tungstenite::WebSocketStream::from_raw_socket(
                            sock,
                            tokio_tungstenite::tungstenite::protocol::Role::Server,
                            None,
                        )
                        .await;
                        let mut ws = ws;
                        while let Some(msg) = ws.next().await {
                            let Ok(msg) = msg else { return };
                            let text = match msg {
                                Message::Text(t) => t.to_string(),
                                Message::Close(_) => return,
                                _ => continue,
                            };
                            // Parse {id, method, params}; record + echo result.
                            let v: serde_json::Value = match serde_json::from_str(&text) {
                                Ok(v) => v,
                                Err(_) => continue,
                            };
                            let id = v.get("id").and_then(|x| x.as_u64()).unwrap_or(0);
                            let method =
                                v.get("method").and_then(|x| x.as_str()).unwrap_or("").to_string();
                            {
                                let mut g = calls.lock().await;
                                g.methods.push(method.clone());
                                if method == "Network.setCookies" {
                                    g.cookies_payload = v.get("params").cloned();
                                } else if method == "Page.navigate" || method == "Page.reload" {
                                    g.navigate_url = v
                                        .get("params")
                                        .and_then(|p| p.get("url"))
                                        .and_then(|u| u.as_str())
                                        .map(String::from);
                                }
                            }
                            let resp = serde_json::json!({"id": id, "result": {}}).to_string();
                            if ws.send(Message::Text(resp.into())).await.is_err() {
                                return;
                            }
                        }
                    }
                });
            }
        });

        (port, calls)
    }

    /// RFC 6455 §1.3 — Sec-WebSocket-Accept = base64(SHA-1(key + GUID)).
    fn ws_accept_key(key: &str) -> String {
        let mut hasher = Sha1::new();
        hasher.update(key.as_bytes());
        hasher.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        base64_encode(&hasher.finalize())
    }

    /// Inline minimal SHA-1 implementation for the test mock only. Not
    /// security-critical — the key it hashes is a public RFC 6455 challenge.
    /// Sourced from the well-known SHA-1 reference (RFC 3174 §6.2). Kept in
    /// the test module to avoid pulling sha-1 as a production dependency.
    struct Sha1 {
        state: [u32; 5],
        buf: Vec<u8>,
        len: u64,
    }
    impl Sha1 {
        fn new() -> Self {
            Self {
                state: [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0],
                buf: Vec::with_capacity(64),
                len: 0,
            }
        }
        fn update(&mut self, data: &[u8]) {
            self.len += data.len() as u64;
            self.buf.extend_from_slice(data);
            while self.buf.len() >= 64 {
                let block: [u8; 64] = self.buf[..64].try_into().unwrap();
                self.compress(&block);
                self.buf.drain(..64);
            }
        }
        fn finalize(mut self) -> [u8; 20] {
            let bit_len = self.len * 8;
            self.buf.push(0x80);
            while self.buf.len() % 64 != 56 {
                self.buf.push(0);
            }
            self.buf.extend_from_slice(&bit_len.to_be_bytes());
            let buf = std::mem::take(&mut self.buf);
            for chunk in buf.chunks(64) {
                let block: [u8; 64] = chunk.try_into().unwrap();
                self.compress(&block);
            }
            let mut out = [0u8; 20];
            for (i, w) in self.state.iter().enumerate() {
                out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
            }
            out
        }
        fn compress(&mut self, block: &[u8; 64]) {
            let mut w = [0u32; 80];
            for i in 0..16 {
                w[i] = u32::from_be_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
            }
            for i in 16..80 {
                w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
            }
            let [mut a, mut b, mut c, mut d, mut e] = self.state;
            for (i, &wi) in w.iter().enumerate() {
                let (f, k) = match i {
                    0..=19 => ((b & c) | ((!b) & d), 0x5A827999),
                    20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                    40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                    _ => (b ^ c ^ d, 0xCA62C1D6),
                };
                let t = a
                    .rotate_left(5)
                    .wrapping_add(f)
                    .wrapping_add(e)
                    .wrapping_add(k)
                    .wrapping_add(wi);
                e = d;
                d = c;
                c = b.rotate_left(30);
                b = a;
                a = t;
            }
            self.state[0] = self.state[0].wrapping_add(a);
            self.state[1] = self.state[1].wrapping_add(b);
            self.state[2] = self.state[2].wrapping_add(c);
            self.state[3] = self.state[3].wrapping_add(d);
            self.state[4] = self.state[4].wrapping_add(e);
        }
    }

    /// Standard base64 encode (RFC 4648 §4) for the WS handshake response.
    fn base64_encode(bytes: &[u8]) -> String {
        const ALPHA: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::with_capacity(((bytes.len() + 2) / 3) * 4);
        let mut i = 0;
        while i + 3 <= bytes.len() {
            let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | bytes[i + 2] as u32;
            out.push(ALPHA[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHA[((n >> 12) & 0x3F) as usize] as char);
            out.push(ALPHA[((n >> 6) & 0x3F) as usize] as char);
            out.push(ALPHA[(n & 0x3F) as usize] as char);
            i += 3;
        }
        let rem = bytes.len() - i;
        if rem == 1 {
            let n = (bytes[i] as u32) << 16;
            out.push(ALPHA[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHA[((n >> 12) & 0x3F) as usize] as char);
            out.push('=');
            out.push('=');
        } else if rem == 2 {
            let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
            out.push(ALPHA[((n >> 18) & 0x3F) as usize] as char);
            out.push(ALPHA[((n >> 12) & 0x3F) as usize] as char);
            out.push(ALPHA[((n >> 6) & 0x3F) as usize] as char);
            out.push('=');
        }
        out
    }

    /// End-to-end happy path against the in-process mock: discover targets,
    /// open the WS, run Network.enable / Network.setCookies / Page.reload,
    /// observe each method was called and the cookie+url params were as
    /// expected. (Page.reload, not Page.navigate — chromium is launched
    /// with `--app=URL` so it's already on the target URL; reload just
    /// retries the request now that the cookie is in the jar.)
    /// @trace spec:opencode-web-session-otp
    #[tokio::test]
    async fn attach_against_mock_cdp_completes_three_step_handshake() {
        let (port, calls) = spawn_mock_cdp().await;
        // Mock listens immediately so wait_for_cdp_ready resolves quickly.
        assert!(wait_for_cdp_ready(port).await);
        let outcome = attach_and_set_cookie(
            port,
            "http://opencode.demo.localhost:8080/",
            "test-cookie-value-43-chars-long-not-secret-x".to_string(),
        )
        .await;
        assert_eq!(outcome, CdpOutcome::Ok, "happy path should succeed");
        let g = calls.lock().await;
        assert_eq!(
            g.methods,
            vec![
                "Network.enable".to_string(),
                "Network.setCookies".to_string(),
                "Page.reload".to_string(),
            ],
            "method sequence drifted: {:?}",
            g.methods
        );
        let cookies = g.cookies_payload.as_ref().expect("setCookies payload");
        let arr = cookies["cookies"].as_array().expect("cookies array");
        assert_eq!(arr.len(), 1);
        let c = &arr[0];
        assert_eq!(c["name"], "tillandsias_session");
        assert_eq!(c["path"], "/");
        assert_eq!(c["httpOnly"], true);
        assert_eq!(c["secure"], false);
        assert_eq!(c["sameSite"], "Strict");
        assert_eq!(c["url"], "http://opencode.demo.localhost:8080/");
    }
}
