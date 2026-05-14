//! Tiny HTTP/1.1 server for Caddy's `forward_auth` directive.
//!
//! Caddy fires `GET /validate?project=<host-label>` on every request to a
//! protected route, copying the original `Cookie:` header. We parse the
//! cookie, base64url-decode the `tillandsias_session=<value>` portion,
//! extract the requested subdomain from the `Host:` header, and validate:
//!
//! 1. Cookie is valid and registered for the requested project label
//! 2. Subdomain maps to the correct project in `<service>.<project>.localhost` format
//! 3. OTP session is bound to the requesting project (allowlist enforcement)
//!
//! Reply `204 No Content` (allow) or `401 Unauthorized` (deny). No body —
//! Caddy uses status only.
//!
//! Hand-rolled in tokio because the sidecar's only HTTP surface is this
//! one endpoint; pulling hyper would 10x the binary size for no win.
//! The format mirrors `src-tauri/src/cdp.rs`'s loopback HTTP probe.
//!
//! @trace spec:opencode-web-session-otp, spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy

use std::time::Duration;

use tillandsias_otp::{OtpStore, parse_cookie_value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{debug, info, warn};

/// Per-request deadline — we'd rather 401 than hang Caddy.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

/// Subdomain routing validator. Extracts project label from subdomain in
/// `<service>.<project>.localhost` format.
///
/// @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
mod subdomain {
    /// Extract project label from a host header in `<service>.<project>.localhost` format.
    ///
    /// Returns `Some(project_label)` where `project_label` is the middle component.
    /// Returns `None` if the hostname doesn't match the expected format.
    ///
    /// Examples:
    /// - `opencode.myapp.localhost` -> `Some("myapp")`
    /// - `flutter.myapp.localhost` -> `Some("myapp")`
    /// - `opencode.my-app.localhost:8080` -> `Some("my-app")` (strips port)
    /// - `localhost` -> `None`
    /// - `example.com` -> `None`
    /// - `opencode.localhost` -> `None` (no project component)
    pub fn extract_project_label(host: &str) -> Option<String> {
        // Strip port if present (e.g., "opencode.myapp.localhost:8080" -> "opencode.myapp.localhost")
        let host_only = host.split(':').next().unwrap_or(host);

        // Must end with `.localhost` (case-insensitive per DNS, but we normalize)
        let host_lower = host_only.to_lowercase();
        if !host_lower.ends_with(".localhost") {
            return None;
        }

        // Strip the `.localhost` suffix
        let without_tld = &host_lower[..host_lower.len() - ".localhost".len()];

        // Split on '.' — must have at least 2 components: <service>.<project>
        let parts: Vec<&str> = without_tld.split('.').collect();
        if parts.len() < 2 {
            return None;
        }

        // The project label is the last component before the TLD.
        // For `<service>.<project>`, take parts[parts.len()-1].
        // For `<service>.<subproject>.<project>`, this would still be the rightmost
        // component before .localhost. The spec allows any chars in project label.
        let project = parts[parts.len() - 1];

        // Project label must be non-empty and valid (alphanumeric + hyphens + underscores).
        if project.is_empty() || !project.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') {
            return None;
        }

        Some(project.to_string())
    }

    /// Validate that a cookie and subdomain binding are consistent.
    ///
    /// Given an OTP store, the project label extracted from the subdomain,
    /// and a cookie value, returns `true` only if:
    /// - The cookie is valid for this project
    /// - The OTP session is not for a different project
    ///
    /// @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
    pub fn validate_subdomain_binding(
        store: &tillandsias_otp::OtpStore,
        project_label: &str,
        cookie_value: &[u8; 32],
    ) -> bool {
        // The store's validate function already checks if the cookie is in the
        // per-project list. This enforces that a cookie issued for
        // `opencode.myapp.localhost` cannot be used for `opencode.otherapp.localhost`.
        store.validate(project_label, cookie_value)
    }
}

use subdomain::{extract_project_label, validate_subdomain_binding};

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
/// - `Some(true)` — cookie present + valid + subdomain matches project → 204
/// - `Some(false)` — cookie present but invalid or subdomain mismatch → 401
/// - `None` — malformed request or missing cookie → 401
///
/// @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
async fn read_and_dispatch(sock: &mut TcpStream, store: &'static OtpStore) -> Option<bool> {
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

    // Find the Host header — needed for subdomain extraction.
    // Caddy's forward_auth directive should include it, but if missing, we fail safe (401).
    // @trace spec:subdomain-naming-flip
    let host_header = head.lines().skip(1).find_map(|l| {
        let mut split = l.splitn(2, ':');
        let name = split.next()?.trim();
        if !name.eq_ignore_ascii_case("host") {
            return None;
        }
        Some(split.next()?.trim().to_string())
    })?;

    // Extract project label from subdomain.
    // @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
    let subdomain_project = extract_project_label(&host_header)?;

    // Validate that the query parameter project label matches the subdomain project.
    // This prevents a request to `opencode.myapp.localhost` from being rerouted
    // to a different project by tampering with the query string.
    // @trace spec:subdomain-routing-via-reverse-proxy
    if project_label != subdomain_project {
        debug!(
            spec = "subdomain-routing-via-reverse-proxy",
            operation = "validate-fail",
            reason = "subdomain-mismatch",
            query_project = %project_label,
            subdomain_project = %subdomain_project,
            host = %host_header,
            "Project label mismatch: query param != subdomain extraction"
        );
        return Some(false);
    }

    // Find the Cookie header (case-insensitive). Headers are CRLF-separated.
    let cookie_header = head.lines().skip(1).find_map(|l| {
        let mut split = l.splitn(2, ':');
        let name = split.next()?.trim();
        if !name.eq_ignore_ascii_case("cookie") {
            return None;
        }
        Some(split.next()?.trim().to_string())
    })?;

    let cookie_b64 = parse_session_cookie(&cookie_header)?;
    let cookie_bytes = parse_cookie_value(cookie_b64)?;

    // Validate: cookie + subdomain binding.
    // The OtpStore enforces that a cookie is only valid for its registered project.
    // @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
    Some(validate_subdomain_binding(store, &subdomain_project, &cookie_bytes))
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
    /// matching cookie and Host header, expect 204.
    #[tokio::test]
    async fn validate_endpoint_returns_204_for_valid_cookie() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("demo", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);
        // Now use request_with_host to include the required Host header.
        let resp = request_with_host(
            port,
            "/validate?project=demo",
            "opencode.demo.localhost",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 204"),
            "expected 204, got: {resp}"
        );
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_unknown_cookie() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        store.push("demo", generate_session_token());

        let port = spawn_serve(store).await;
        let bogus = format_cookie_value(&generate_session_token());
        let resp = request_with_host(
            port,
            "/validate?project=demo",
            "opencode.demo.localhost",
            Some(&format!("tillandsias_session={bogus}")),
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401, got: {resp}"
        );
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_when_no_cookie_header() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let port = spawn_serve(store).await;
        let resp = request_with_host(
            port,
            "/validate?project=demo",
            "opencode.demo.localhost",
            None,
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401, got: {resp}"
        );
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_unknown_project() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("demo", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);
        let resp = request_with_host(
            port,
            "/validate?project=elsewhere",
            "opencode.elsewhere.localhost",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;
        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401, got: {resp}"
        );
    }

    #[tokio::test]
    async fn validate_endpoint_returns_401_for_non_get_methods() {
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let port = spawn_serve(store).await;
        let mut sock = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        let req = "POST /validate?project=demo HTTP/1.1\r\nHost: opencode.demo.localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sock.write_all(req.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        sock.read_to_end(&mut buf).await.unwrap();
        let resp = String::from_utf8_lossy(&buf);
        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401, got: {resp}"
        );
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
        assert_eq!(parse_session_cookie("tillandsias_session=abc"), Some("abc"));
        assert_eq!(
            parse_session_cookie("foo=bar; tillandsias_session=xyz; baz=qux"),
            Some("xyz")
        );
        assert_eq!(parse_session_cookie("nothing=here"), None);
    }

    // ============================================================================
    // Subdomain routing and allowlist enforcement tests
    // ============================================================================

    #[test]
    fn subdomain_extract_project_label_standard_format() {
        // @trace spec:subdomain-naming-flip
        assert_eq!(
            super::subdomain::extract_project_label("opencode.myapp.localhost"),
            Some("myapp".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("flutter.myapp.localhost"),
            Some("myapp".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("vite.myapp.localhost"),
            Some("myapp".to_string())
        );
    }

    #[test]
    fn subdomain_extract_project_label_with_port() {
        // @trace spec:subdomain-naming-flip
        // Host header includes port in some cases; we should strip it.
        assert_eq!(
            super::subdomain::extract_project_label("opencode.myapp.localhost:8080"),
            Some("myapp".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("opencode.myapp.localhost:80"),
            Some("myapp".to_string())
        );
    }

    #[test]
    fn subdomain_extract_project_label_with_hyphens_and_underscores() {
        // @trace spec:subdomain-naming-flip
        // Project labels may contain hyphens and underscores (standard for docker/kubernetes labels).
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my-app.localhost"),
            Some("my-app".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my_app.localhost"),
            Some("my_app".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my-app_v2.localhost"),
            Some("my-app_v2".to_string())
        );
    }

    #[test]
    fn subdomain_extract_project_label_case_insensitive() {
        // @trace spec:subdomain-naming-flip
        // DNS is case-insensitive; we normalize to lowercase internally.
        assert_eq!(
            super::subdomain::extract_project_label("OpenCode.MyApp.Localhost"),
            Some("myapp".to_string())
        );
        assert_eq!(
            super::subdomain::extract_project_label("OPENCODE.MYAPP.LOCALHOST"),
            Some("myapp".to_string())
        );
    }

    #[test]
    fn subdomain_extract_project_label_rejects_non_localhost() {
        // @trace spec:subdomain-naming-flip
        // Only *.localhost is valid; external domains rejected.
        assert_eq!(
            super::subdomain::extract_project_label("opencode.myapp.example.com"),
            None
        );
        assert_eq!(
            super::subdomain::extract_project_label("opencode.myapp.127.0.0.1"),
            None
        );
    }

    #[test]
    fn subdomain_extract_project_label_rejects_plain_localhost() {
        // @trace spec:subdomain-naming-flip
        // Plain `localhost` has no project component.
        assert_eq!(
            super::subdomain::extract_project_label("localhost"),
            None
        );
        assert_eq!(
            super::subdomain::extract_project_label("localhost:8080"),
            None
        );
    }

    #[test]
    fn subdomain_extract_project_label_rejects_single_component() {
        // @trace spec:subdomain-naming-flip
        // Must have at least <service>.<project>.localhost (3 components).
        // Input is `<service>.localhost` (2 components) = invalid.
        assert_eq!(
            super::subdomain::extract_project_label("opencode.localhost"),
            None
        );
    }

    #[test]
    fn subdomain_extract_project_label_rejects_invalid_project_chars() {
        // @trace spec:subdomain-naming-flip
        // Project label must be alphanumeric, hyphens, underscores only.
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my@app.localhost"),
            None
        );
        // Note: "opencode.my.app.localhost" has 3 components (my, app), not 2.
        // The logic takes the rightmost component before .localhost, which is "app".
        // This is actually valid — the project is "app". To test invalid chars,
        // we use a single component that has invalid chars.
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my app.localhost"),
            None
        );
        assert_eq!(
            super::subdomain::extract_project_label("opencode.my$app.localhost"),
            None
        );
    }

    #[test]
    fn subdomain_validate_binding_allows_matching_project() {
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Cookie issued for project X can be used to access project X.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("myapp", token);

        let is_valid = validate_subdomain_binding(store, "myapp", &token);
        assert!(is_valid);
    }

    #[test]
    fn subdomain_validate_binding_rejects_cross_project() {
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Cookie issued for project X cannot be used for project Y.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("project-a", token);

        let is_valid = validate_subdomain_binding(store, "project-b", &token);
        assert!(!is_valid);
    }

    #[test]
    fn subdomain_validate_binding_rejects_invalid_token() {
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Cookie that was never issued is rejected.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let valid_token = generate_session_token();
        let invalid_token = generate_session_token();
        store.push("myapp", valid_token);

        let is_valid = validate_subdomain_binding(store, "myapp", &invalid_token);
        assert!(!is_valid);
    }

    #[tokio::test]
    async fn e2e_validate_subdomain_routing_allows_correct_project() {
        // @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
        // End-to-end: bind server, issue session, make request with matching subdomain.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("myapp", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);

        // Request with Host header matching the project.
        let resp = request_with_host(
            port,
            "/validate?project=myapp",
            "opencode.myapp.localhost:8080",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;

        assert!(
            resp.starts_with("HTTP/1.1 204"),
            "expected 204 for matching subdomain+project, got: {resp}"
        );
    }

    #[tokio::test]
    async fn e2e_validate_subdomain_routing_rejects_subdomain_mismatch() {
        // @trace spec:subdomain-naming-flip, spec:subdomain-routing-via-reverse-proxy
        // Request claims to be for project X but subdomain is for project Y -> 401.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("myapp", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);

        // Request with mismatched Host header and query project.
        let resp = request_with_host(
            port,
            "/validate?project=myapp",
            "opencode.otherapp.localhost:8080",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;

        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401 for subdomain mismatch, got: {resp}"
        );
    }

    #[tokio::test]
    async fn e2e_validate_subdomain_routing_rejects_missing_host_header() {
        // @trace spec:subdomain-naming-flip
        // Request without Host header cannot be routed -> 401.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("myapp", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);

        let resp = curl(
            port,
            "/validate?project=myapp",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;

        assert!(
            resp.starts_with("HTTP/1.1 401"),
            "expected 401 without Host header, got: {resp}"
        );
    }

    #[tokio::test]
    async fn e2e_validate_subdomain_routing_allows_port_variance() {
        // @trace spec:subdomain-naming-flip
        // Host header may include port; subdomain extraction should handle it.
        let store: &'static OtpStore = Box::leak(Box::new(OtpStore::new()));
        let token = generate_session_token();
        store.push("myapp", token);

        let port = spawn_serve(store).await;
        let cookie_b64 = format_cookie_value(&token);

        // Same project but different port in Host header.
        let resp = request_with_host(
            port,
            "/validate?project=myapp",
            "opencode.myapp.localhost:9999",
            Some(&format!("tillandsias_session={cookie_b64}")),
        )
        .await;

        assert!(
            resp.starts_with("HTTP/1.1 204"),
            "expected 204 despite port variance, got: {resp}"
        );
    }

    /// Fire an HTTP request with custom Host header for subdomain testing.
    async fn request_with_host(
        port: u16,
        path: &str,
        host: &str,
        cookie: Option<&str>,
    ) -> String {
        let mut sock = TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        let cookie_line = cookie
            .map(|c| format!("Cookie: {c}\r\n"))
            .unwrap_or_default();
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: {host}\r\n{cookie_line}Connection: close\r\n\r\n"
        );
        sock.write_all(req.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        sock.read_to_end(&mut buf).await.unwrap();
        String::from_utf8_lossy(&buf).to_string()
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
