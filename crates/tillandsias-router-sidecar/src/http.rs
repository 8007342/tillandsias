//! Tiny HTTP/1.1 server for Caddy's `forward_auth` directive.
//!
//! Caddy fires `GET /validate?project=<host-label>` on every request to a
//! protected route, copying the original `Cookie:` header. We parse the
//! cookie, base64url-decode the `tillandsias_session=<value>` portion,
//! call [`OtpStore::validate`], and reply `204 No Content` (allow) or
//! `401 Unauthorized` (deny). No body — Caddy uses status only.
//!
//! Hand-rolled in tokio because the sidecar's only HTTP surface is this
//! one endpoint; pulling hyper would 10x the binary size for no win.
//! The format mirrors `src-tauri/src/cdp.rs`'s loopback HTTP probe.
//!
//! @trace spec:opencode-web-session-otp

use std::time::Duration;

use tillandsias_otp::{OtpStore, parse_cookie_value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, info, warn};

/// Per-request deadline — we'd rather 401 than hang Caddy.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

/// Bind on `127.0.0.1:<port>` and serve forever. Spawned from `main`.
///
/// @trace spec:opencode-web-session-otp
pub async fn serve(port: u16, store: &'static OtpStore) {
    let bind = format!("127.0.0.1:{port}");
    let listener = match TcpListener::bind(&bind).await {
        Ok(l) => l,
        Err(e) => {
            warn!(
                spec = "opencode-web-session-otp",
                error = %e,
                bind = %bind,
                "Failed to bind validate HTTP server — Caddy forward_auth will 502"
            );
            return;
        }
    };
    info!(
        spec = "opencode-web-session-otp",
        bind = %bind,
        "Validate endpoint listening"
    );

    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(p) => p,
            Err(e) => {
                warn!(
                    spec = "opencode-web-session-otp",
                    error = %e,
                    "Validate accept failed; continuing"
                );
                continue;
            }
        };
        debug!(
            spec = "opencode-web-session-otp",
            peer = %peer,
            "Validate connection accepted"
        );
        tokio::spawn(handle_request(sock, store));
    }
}

async fn handle_request(mut sock: TcpStream, store: &'static OtpStore) {
    let outcome = tokio::time::timeout(REQUEST_TIMEOUT, read_and_dispatch(&mut sock, store)).await;
    let status = match outcome {
        Ok(Some(true)) => 204u16,
        Ok(Some(false)) | Ok(None) => 401u16,
        Err(_) => {
            debug!(
                spec = "opencode-web-session-otp",
                "Validate request timed out — replying 401"
            );
            401
        }
    };
    let _ = write_status(&mut sock, status).await;
    let _ = sock.shutdown().await;
}

/// Read the request, parse, validate. Returns:
/// - `Some(true)` — cookie present + valid → 204
/// - `Some(false)` — cookie present but invalid → 401
/// - `None` — malformed request or missing cookie → 401
async fn read_and_dispatch(
    sock: &mut TcpStream,
    store: &'static OtpStore,
) -> Option<bool> {
    let head = read_head(sock).await?;

    // Parse request line: "GET /validate?project=<label> HTTP/1.1"
    let first_line = head.lines().next()?;
    let mut parts = first_line.split_whitespace();
    let method = parts.next()?;
    let target = parts.next()?;
    if method != "GET" {
        return None;
    }
    let project_label = parse_project_query(target)?;

    // Find the Cookie header (case-insensitive). Headers are CRLF-separated.
    let cookie_header = head
        .lines()
        .skip(1)
        .find_map(|l| {
            let mut split = l.splitn(2, ':');
            let name = split.next()?.trim();
            if !name.eq_ignore_ascii_case("cookie") {
                return None;
            }
            Some(split.next()?.trim().to_string())
        })?;

    let cookie_b64 = parse_session_cookie(&cookie_header)?;
    let cookie_bytes = parse_cookie_value(cookie_b64)?;

    Some(store.validate(&project_label, &cookie_bytes))
}

/// Read until "\r\n\r\n" or 8 KiB, whichever comes first. Returns the
/// header block as a UTF-8-lossy string.
async fn read_head(sock: &mut TcpStream) -> Option<String> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        let n = sock.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > 8 * 1024 {
            return None;
        }
    }
    let head_end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    Some(String::from_utf8_lossy(&buf[..head_end]).to_string())
}

/// Pull `<label>` out of `/validate?project=<label>`. Returns `None` if the
/// path doesn't start with `/validate?project=` or the label is empty.
fn parse_project_query(target: &str) -> Option<String> {
    let prefix = "/validate?project=";
    let label = target.strip_prefix(prefix)?;
    // Strip any trailing query params (`&...`) or fragment (`#...`).
    let label = label
        .split('&')
        .next()
        .and_then(|s| s.split('#').next())
        .unwrap_or(label);
    if label.is_empty() {
        None
    } else {
        Some(label.to_string())
    }
}

/// Pull `tillandsias_session=<value>` out of a `Cookie:` header value.
/// Returns the base64url value (still encoded). The header may carry
/// multiple cookies separated by `; ` — find ours by name.
fn parse_session_cookie(header: &str) -> Option<&str> {
    for kv in header.split(';') {
        let kv = kv.trim();
        if let Some(rest) = kv.strip_prefix("tillandsias_session=") {
            return Some(rest);
        }
    }
    None
}

async fn write_status(sock: &mut TcpStream, code: u16) -> std::io::Result<()> {
    // Caddy's `forward_auth` directive returns the upstream's response
    // (status + body) to the client unchanged on non-2xx. So the friendly
    // 401 body lives HERE — putting it in the Caddyfile would require
    // `handle_errors` plumbing for no benefit.
    //
    // 204 has no body by definition (RFC 7230 §3.3.2 — "A 204 response
    // MUST NOT include a message body"); Caddy continues the request and
    // the user never sees this anyway.
    //
    // The em-dash is UTF-8 (E2 80 94, 3 bytes); .len() of the formatted
    // body gives the correct Content-Length.
    let (reason, body) = match code {
        204 => ("No Content", String::new()),
        401 => (
            "Unauthorized",
            "unauthorised \u{2014} open this project from the Tillandsias tray\n".to_string(),
        ),
        _ => ("OK", String::new()),
    };
    let mut resp = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    resp.push_str(&body);
    sock.write_all(resp.as_bytes()).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_otp::{OtpStore, format_cookie_value, generate_session_token};
    use tokio::io::AsyncReadExt;

    /// End-to-end through the validate endpoint: bind on a random port,
    /// push a token into a fresh store, fire HTTP `GET /validate` with the
    /// matching cookie, expect 204.
    #[tokio::test]
    async fn validate_endpoint_returns_204_for_valid_cookie() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("opencode.demo.localhost", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);
        let resp = curl(
            port,
            "/validate?project=opencode.demo.localhost",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 204"), "expected 204, got: {resp}");
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_unknown_cookie() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        store.push("opencode.demo.localhost", generate_session_token());

        let port = spawn_serve(store).await;
        let bogus = format_cookie_value(&generate_session_token());
        let resp = curl(
            port,
            "/validate?project=opencode.demo.localhost",
            Some(&format!("tillandsias_session={bogus}")),
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 401"), "expected 401, got: {resp}");
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_when_no_cookie_header() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let port = spawn_serve(store).await;
        let resp = curl(port, "/validate?project=opencode.demo.localhost", None).await;
        assert!(resp.starts_with("HTTP/1.1 401"), "expected 401, got: {resp}");
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_unknown_project() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("opencode.demo.localhost", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);
        let resp = curl(
            port,
            "/validate?project=opencode.elsewhere.localhost",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;
        assert!(resp.starts_with("HTTP/1.1 401"), "expected 401, got: {resp}");
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_non_get_methods() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let port = spawn_serve(store).await;
        let mut sock = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let req = "POST /validate?project=opencode.demo.localhost HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sock.write_all(req.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        sock.read_to_end(&mut buf).await.unwrap();
        let resp = String::from_utf8_lossy(&buf);
        assert!(resp.starts_with("HTTP/1.1 401"), "expected 401, got: {resp}");
    }

    #[test]
    fn parse_project_query_extracts_label() {
        assert_eq!(
            parse_project_query("/validate?project=opencode.demo.localhost"),
            Some("opencode.demo.localhost".to_string())
        );
        assert_eq!(
            parse_project_query("/validate?project=opencode.x.localhost&extra=1"),
            Some("opencode.x.localhost".to_string())
        );
        assert_eq!(parse_project_query("/validate"), None);
        assert_eq!(parse_project_query("/validate?project="), None);
        assert_eq!(parse_project_query("/other"), None);
    }

    #[test]
    fn parse_session_cookie_finds_named_value() {
        assert_eq!(
            parse_session_cookie("tillandsias_session=abc"),
            Some("abc")
        );
        assert_eq!(
            parse_session_cookie("foo=bar; tillandsias_session=xyz; baz=qux"),
            Some("xyz")
        );
        assert_eq!(parse_session_cookie("nothing=here"), None);
    }

    /// Spawn the validate server on a random free port and return that port.
    async fn spawn_serve(store: &'static OtpStore) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // Re-implement the accept loop here so we can pass a pre-bound
        // listener (the real `serve()` binds itself; for tests we want a
        // random port, which is easier to grab via bind("0")).
        tokio::spawn(async move {
            loop {
                let Ok((sock, _)) = listener.accept().await else {
                    return;
                };
                tokio::spawn(handle_request(sock, store));
            }
        });
        // Yield so the listener is actively accepting before the test fires.
        tokio::task::yield_now().await;
        port
    }

    /// Fire a one-shot HTTP/1.1 GET. `cookie` is the raw `Cookie:` header
    /// value (e.g. `"tillandsias_session=abc"`).
    async fn curl(port: u16, path: &str, cookie: Option<&str>) -> String {
        let mut sock = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let cookie_line = cookie
            .map(|c| format!("Cookie: {c}\r\n"))
            .unwrap_or_default();
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{cookie_line}Connection: close\r\n\r\n"
        );
        sock.write_all(req.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        sock.read_to_end(&mut buf).await.unwrap();
        String::from_utf8_lossy(&buf).to_string()
    }
}
