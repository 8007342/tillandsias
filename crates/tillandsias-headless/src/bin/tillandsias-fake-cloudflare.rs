//! tillandsias-fake-cloudflare — the fake Cloudflare every fixture in the
//! cloudflare-login-and-fleet-vpn milestone runs against.
//!
//! @trace order:1505-svve
//! @trace openspec:changes/cloudflare-login-and-fleet-vpn/design.md#decision-3
//!
//! Serves, on `127.0.0.1:0` (the OS-assigned port is printed to stdout as a
//! single line the instant the socket is bound, before any request is
//! served):
//!
//!   * `GET  /.well-known/openid-configuration` — endpoints plus
//!     `grant_types_supported`, configurable via
//!     `TILLANDSIAS_FAKE_CLOUDFLARE_GRANT_TYPES` (comma-separated; default
//!     `authorization_code,refresh_token`) so the device-grant adapter note
//!     (1505-kyx8) can be tested by listing the device-code grant.
//!   * `GET  /oauth2/auth` — with `?auto=approve` completes the redirect
//!     immediately (issuing a single-use code bound to the caller's PKCE
//!     `code_challenge` and exact `redirect_uri`); `?auto=deny` redirects
//!     with `error=access_denied`; with neither, renders a minimal consent
//!     page linking to both.
//!   * `POST /oauth2/token` — `grant_type=authorization_code` validates
//!     `code_verifier` (SHA-256, base64url, no padding) against the stored
//!     challenge, the single-use code, and an EXACT `redirect_uri` match
//!     (a trailing-slash difference is a mismatch); `grant_type=refresh_token`
//!     rotates the pair and invalidates the old refresh token. A `?fail=`
//!     query knob short-circuits to `invalid_grant` for callers that just
//!     need a scripted failure.
//!   * `POST /oauth2/revoke`, `GET /oauth2/userinfo`.
//!   * The Zero Trust API routes `fleet-vpn init` needs: `GET /accounts`,
//!     `POST`/`DELETE /accounts/{id}/access/service_tokens[/{id}]`,
//!     `POST /accounts/{id}/teamnet/virtual_networks`, the default device
//!     profile (`PUT /accounts/{id}/devices/policy`), its split-tunnel
//!     exclude list (`PUT /accounts/{id}/devices/policy/exclude`), and a
//!     Gateway rule (`POST /accounts/{id}/gateway/rules`).
//!
//! EVERY request — OAuth and API alike — appends one JSON line
//! `{"method","path","body"}` to the file named by `--ledger`, in arrival
//! order, before the response is sent, so a fixture that captured the
//! ledger's length before an action can assert on exactly the lines after
//! it.
//!
//! `TILLANDSIAS_FAKE_CLOUDFLARE_LAX=1` disables the `code_verifier` check —
//! it exists ONLY so a fixture can prove its own wrong-verifier arm reaches
//! the check: run the arm once normally (expect 400) and once under LAX
//! (expect 200); if LAX still returns 400 the arm was never gated by the
//! check it claims to test.
//!
//! Std + serde_json + sha2 + base64 + getrandom only (all already
//! dependencies of this crate) — no new HTTP crate, per the packet's
//! next_action. Single-threaded; serves until killed. No network call ever
//! leaves this process: there is no code path to a real Cloudflare host.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

use base64::Engine;
use sha2::{Digest, Sha256};

const FAKE_ACCOUNT_ID: &str = "0123456789abcdef0123456789abcdef";

struct AuthCode {
    code_challenge: String,
    code_challenge_method: String,
    redirect_uri: String,
    client_id: String,
    scope: String,
    used: bool,
}

struct TokenGrant {
    client_id: String,
    scope: String,
}

struct State {
    ledger_path: String,
    lax: bool,
    grant_types: Vec<String>,
    codes: HashMap<String, AuthCode>,
    access_tokens: HashMap<String, TokenGrant>,
    refresh_tokens: HashMap<String, TokenGrant>,
}

struct Request {
    method: String,
    /// Raw request-target, exactly as sent on the request line (path plus
    /// an optional `?query`).
    target: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: String,
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    out.push(byte);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_form(body: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for pair in body.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        out.insert(url_decode(k), url_decode(v));
    }
    out
}

fn split_target(target: &str) -> (String, HashMap<String, String>) {
    match target.split_once('?') {
        Some((path, query)) => (path.to_string(), parse_form(query)),
        None => (target.to_string(), HashMap::new()),
    }
}

fn read_request(stream: &mut TcpStream) -> Option<Request> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];
    let header_end = loop {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
        if let Some(pos) = find(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > 1 << 20 {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let request_line = lines.next()?.to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();

    let mut headers = HashMap::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let content_length: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    while buf.len() < header_end + content_length {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
        }
    }
    let body =
        String::from_utf8_lossy(&buf[header_end..(header_end + content_length).min(buf.len())])
            .into_owned();
    let (path, query) = split_target(&target);
    Some(Request {
        method,
        target,
        path,
        query,
        headers,
        body,
    })
}

fn respond(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    extra_headers: &[(&str, String)],
    body: &str,
) {
    let mut head = format!("HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\n");
    for (k, v) in extra_headers {
        head += &format!("{k}: {v}\r\n");
    }
    head += &format!(
        "Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
}

fn respond_json(stream: &mut TcpStream, status: &str, body: &serde_json::Value) {
    respond(stream, status, "application/json", &[], &body.to_string());
}

fn append_ledger(state: &State, req: &Request) {
    let entry = serde_json::json!({
        "method": req.method,
        "path": req.target,
        "body": req.body,
    });
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&state.ledger_path)
    {
        let _ = writeln!(f, "{entry}");
    }
}

fn random_hex(n: usize) -> String {
    let mut bytes = vec![0u8; n];
    // A CSPRNG failure here means the host has no entropy source at all;
    // there is no meaningful fallback, so fail loudly rather than mint a
    // predictable "secret".
    getrandom::fill(&mut bytes).expect("tillandsias-fake-cloudflare: host CSPRNG unavailable");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn s256_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

fn redirect_with(redirect_uri: &str, params: &[(&str, &str)]) -> String {
    let sep = if redirect_uri.contains('?') { '&' } else { '?' };
    let mut out = format!("{redirect_uri}{sep}");
    for (i, (k, v)) in params.iter().enumerate() {
        if i > 0 {
            out.push('&');
        }
        out.push_str(k);
        out.push('=');
        out.push_str(v);
    }
    out
}

fn handle_discovery(state: &State, stream: &mut TcpStream, base: &str) {
    let body = serde_json::json!({
        "issuer": base,
        "authorization_endpoint": format!("{base}/oauth2/auth"),
        "token_endpoint": format!("{base}/oauth2/token"),
        "revocation_endpoint": format!("{base}/oauth2/revoke"),
        "userinfo_endpoint": format!("{base}/oauth2/userinfo"),
        "grant_types_supported": state.grant_types,
        "code_challenge_methods_supported": ["S256"],
        "response_types_supported": ["code"],
    });
    respond_json(stream, "200 OK", &body);
}

fn handle_authorize(state: &mut State, stream: &mut TcpStream, req: &Request) {
    let q = &req.query;
    let redirect_uri = q.get("redirect_uri").cloned().unwrap_or_default();
    let state_param = q.get("state").cloned().unwrap_or_default();
    let client_id = q.get("client_id").cloned().unwrap_or_default();
    let scope = q.get("scope").cloned().unwrap_or_default();
    let code_challenge = q.get("code_challenge").cloned().unwrap_or_default();
    let code_challenge_method = q.get("code_challenge_method").cloned().unwrap_or_default();

    match q.get("auto").map(|s| s.as_str()) {
        Some("deny") => {
            let location = redirect_with(
                &redirect_uri,
                &[("error", "access_denied"), ("state", &state_param)],
            );
            respond(
                stream,
                "302 Found",
                "text/plain",
                &[("Location", location)],
                "",
            );
        }
        Some("approve") => {
            if redirect_uri.is_empty()
                || code_challenge.is_empty()
                || code_challenge_method != "S256"
            {
                let location = redirect_with(
                    &redirect_uri,
                    &[("error", "invalid_request"), ("state", &state_param)],
                );
                respond(
                    stream,
                    "302 Found",
                    "text/plain",
                    &[("Location", location)],
                    "",
                );
                return;
            }
            let code = random_hex(20);
            state.codes.insert(
                code.clone(),
                AuthCode {
                    code_challenge,
                    code_challenge_method,
                    redirect_uri: redirect_uri.clone(),
                    client_id,
                    scope,
                    used: false,
                },
            );
            let location =
                redirect_with(&redirect_uri, &[("code", &code), ("state", &state_param)]);
            respond(
                stream,
                "302 Found",
                "text/plain",
                &[("Location", location)],
                "",
            );
        }
        _ => {
            let body = format!(
                "<html><body><p>fake-cloudflare consent for client_id={client_id}</p>\
                 <a href=\"{path}&auto=approve\">Approve</a> \
                 <a href=\"{path}&auto=deny\">Deny</a></body></html>",
                path = req.target,
            );
            respond(stream, "200 OK", "text/html", &[], &body);
        }
    }
}

fn handle_token(state: &mut State, stream: &mut TcpStream, req: &Request) {
    if req.query.contains_key("fail") {
        respond_json(
            stream,
            "400 Bad Request",
            &serde_json::json!({"error": "invalid_grant"}),
        );
        return;
    }
    let form = parse_form(&req.body);
    match form.get("grant_type").map(|s| s.as_str()) {
        Some("authorization_code") => {
            let code = form.get("code").cloned().unwrap_or_default();
            let redirect_uri = form.get("redirect_uri").cloned().unwrap_or_default();
            let code_verifier = form.get("code_verifier").cloned().unwrap_or_default();

            let Some(entry) = state.codes.get(&code) else {
                respond_json(
                    stream,
                    "400 Bad Request",
                    &serde_json::json!({"error": "invalid_grant"}),
                );
                return;
            };
            if entry.used {
                respond_json(
                    stream,
                    "400 Bad Request",
                    &serde_json::json!({"error": "invalid_grant"}),
                );
                return;
            }
            if entry.redirect_uri != redirect_uri {
                respond_json(
                    stream,
                    "400 Bad Request",
                    &serde_json::json!({"error": "invalid_grant"}),
                );
                return;
            }
            // Only S256 is ever issued by /oauth2/auth (Decision 1: PKCE
            // S256 required), so a stored method of anything else means the
            // challenge was never comparable to a verifier at all.
            if !state.lax
                && (entry.code_challenge_method != "S256"
                    || s256_challenge(&code_verifier) != entry.code_challenge)
            {
                respond_json(
                    stream,
                    "400 Bad Request",
                    &serde_json::json!({"error": "invalid_grant"}),
                );
                return;
            }

            let (client_id, scope) = (entry.client_id.clone(), entry.scope.clone());
            state.codes.get_mut(&code).unwrap().used = true;

            let access_token = random_hex(24);
            let refresh_token = random_hex(24);
            state.access_tokens.insert(
                access_token.clone(),
                TokenGrant {
                    client_id: client_id.clone(),
                    scope: scope.clone(),
                },
            );
            state
                .refresh_tokens
                .insert(refresh_token.clone(), TokenGrant { client_id, scope });
            respond_json(
                stream,
                "200 OK",
                &serde_json::json!({
                    "access_token": access_token,
                    "refresh_token": refresh_token,
                    "expires_in": 3600,
                    "token_type": "bearer",
                }),
            );
        }
        Some("refresh_token") => {
            let refresh_token = form.get("refresh_token").cloned().unwrap_or_default();
            let Some(grant) = state.refresh_tokens.remove(&refresh_token) else {
                respond_json(
                    stream,
                    "400 Bad Request",
                    &serde_json::json!({"error": "invalid_grant"}),
                );
                return;
            };
            let new_access = random_hex(24);
            let new_refresh = random_hex(24);
            state.access_tokens.insert(
                new_access.clone(),
                TokenGrant {
                    client_id: grant.client_id.clone(),
                    scope: grant.scope.clone(),
                },
            );
            state.refresh_tokens.insert(
                new_refresh.clone(),
                TokenGrant {
                    client_id: grant.client_id,
                    scope: grant.scope,
                },
            );
            respond_json(
                stream,
                "200 OK",
                &serde_json::json!({
                    "access_token": new_access,
                    "refresh_token": new_refresh,
                    "expires_in": 3600,
                    "token_type": "bearer",
                }),
            );
        }
        _ => {
            respond_json(
                stream,
                "400 Bad Request",
                &serde_json::json!({"error": "unsupported_grant_type"}),
            );
        }
    }
}

fn handle_revoke(state: &mut State, stream: &mut TcpStream, req: &Request) {
    let form = parse_form(&req.body);
    if let Some(token) = form.get("token") {
        state.access_tokens.remove(token);
        state.refresh_tokens.remove(token);
    }
    respond(stream, "200 OK", "application/json", &[], "{}");
}

fn handle_userinfo(state: &State, stream: &mut TcpStream, req: &Request) {
    let token = req
        .headers
        .get("authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if let Some(grant) = state.access_tokens.get(token) {
        respond_json(
            stream,
            "200 OK",
            &serde_json::json!({
                "sub": format!("fake-user:{}", grant.client_id),
                "email": "fake-user@example.invalid",
            }),
        );
    } else {
        respond_json(
            stream,
            "401 Unauthorized",
            &serde_json::json!({"error": "invalid_token"}),
        );
    }
}

fn cf_envelope(result: serde_json::Value) -> serde_json::Value {
    serde_json::json!({
        "success": true,
        "errors": [],
        "messages": [],
        "result": result,
    })
}

fn handle_api(stream: &mut TcpStream, req: &Request) {
    let body_json: serde_json::Value =
        serde_json::from_str(&req.body).unwrap_or(serde_json::Value::Null);
    let segments: Vec<&str> = req.path.split('/').filter(|s| !s.is_empty()).collect();

    // GET /accounts
    if req.method == "GET" && segments == ["accounts"] {
        respond_json(
            stream,
            "200 OK",
            &cf_envelope(serde_json::json!([{
                "id": FAKE_ACCOUNT_ID,
                "name": "fake-account",
            }])),
        );
        return;
    }

    // /accounts/{id}/access/service_tokens[/...]
    if segments.len() >= 4
        && segments[0] == "accounts"
        && segments[2] == "access"
        && segments[3] == "service_tokens"
    {
        if req.method == "POST" && segments.len() == 4 {
            let id = random_hex(16);
            let client_secret = random_hex(24);
            respond_json(
                stream,
                "200 OK",
                &cf_envelope(serde_json::json!({
                    "id": id,
                    "client_id": format!("{id}.access"),
                    "client_secret": client_secret,
                    "name": body_json.get("name").cloned().unwrap_or(serde_json::Value::Null),
                })),
            );
            return;
        }
        if req.method == "DELETE" && segments.len() == 5 {
            respond_json(
                stream,
                "200 OK",
                &cf_envelope(serde_json::json!({"id": segments[4]})),
            );
            return;
        }
    }

    // POST /accounts/{id}/teamnet/virtual_networks
    if req.method == "POST"
        && segments.len() == 4
        && segments[0] == "accounts"
        && segments[2] == "teamnet"
        && segments[3] == "virtual_networks"
    {
        respond_json(
            stream,
            "200 OK",
            &cf_envelope(serde_json::json!({
                "id": random_hex(16),
                "name": body_json.get("name").cloned().unwrap_or(serde_json::Value::Null),
                "comment": body_json.get("comment").cloned().unwrap_or(serde_json::Value::Null),
                "is_default": false,
            })),
        );
        return;
    }

    // PUT /accounts/{id}/devices/policy(/exclude)?  — default device profile
    // and its split-tunnel exclude list.
    if req.method == "PUT"
        && segments.len() >= 3
        && segments[0] == "accounts"
        && segments[2] == "devices"
    {
        if segments.len() == 3 || (segments.len() == 4 && segments[3] == "policy") {
            respond_json(
                stream,
                "200 OK",
                &cf_envelope(serde_json::json!({"id": "default-device-settings-policy"})),
            );
            return;
        }
        if segments.len() == 5 && segments[3] == "policy" && segments[4] == "exclude" {
            let result = if body_json.is_null() {
                serde_json::json!([])
            } else {
                body_json.clone()
            };
            respond_json(stream, "200 OK", &cf_envelope(result));
            return;
        }
    }

    // POST /accounts/{id}/gateway/rules
    if req.method == "POST"
        && segments.len() == 4
        && segments[0] == "accounts"
        && segments[2] == "gateway"
        && segments[3] == "rules"
    {
        respond_json(
            stream,
            "200 OK",
            &cf_envelope(serde_json::json!({
                "id": random_hex(16),
                "name": body_json.get("name").cloned().unwrap_or(serde_json::Value::Null),
            })),
        );
        return;
    }

    respond_json(
        stream,
        "404 Not Found",
        &serde_json::json!({"success": false, "errors": [{"code": 1000, "message": "no such route"}]}),
    );
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 0;
    let mut ledger_path: Option<String> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--port" => port = args.next().and_then(|v| v.parse().ok()).unwrap_or(0),
            "--ledger" => ledger_path = args.next(),
            other => {
                eprintln!("tillandsias-fake-cloudflare: unknown arg {other}");
                std::process::exit(2);
            }
        }
    }
    let Some(ledger_path) = ledger_path else {
        eprintln!("tillandsias-fake-cloudflare: --ledger <path> is required");
        std::process::exit(2);
    };
    // An existing ledger from a previous run would make "the ledger lists
    // every call in order" ambiguous about which run a line belongs to.
    let _ = std::fs::remove_file(&ledger_path);

    let lax = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_LAX").as_deref() == Ok("1");
    let grant_types: Vec<String> = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_GRANT_TYPES")
        .unwrap_or_else(|_| "authorization_code,refresh_token".to_string())
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|e| {
        eprintln!("tillandsias-fake-cloudflare: bind 127.0.0.1:{port}: {e}");
        std::process::exit(1);
    });
    let bound_port = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    // The ONLY thing ever written to stdout: fixtures capture this line to
    // learn the port before making a single request.
    println!("{bound_port}");
    let _ = std::io::stdout().flush();
    eprintln!(
        "tillandsias-fake-cloudflare: listening on 127.0.0.1:{bound_port}, ledger={ledger_path}"
    );

    let mut state = State {
        ledger_path,
        lax,
        grant_types,
        codes: HashMap::new(),
        access_tokens: HashMap::new(),
        refresh_tokens: HashMap::new(),
    };
    let base = format!("http://127.0.0.1:{bound_port}");

    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let Some(req) = read_request(&mut stream) else {
            continue;
        };
        append_ledger(&state, &req);
        match (req.method.as_str(), req.path.as_str()) {
            ("GET", "/.well-known/openid-configuration") => {
                handle_discovery(&state, &mut stream, &base)
            }
            ("GET", "/oauth2/auth") => handle_authorize(&mut state, &mut stream, &req),
            ("POST", "/oauth2/token") => handle_token(&mut state, &mut stream, &req),
            ("POST", "/oauth2/revoke") => handle_revoke(&mut state, &mut stream, &req),
            ("GET", "/oauth2/userinfo") => handle_userinfo(&state, &mut stream, &req),
            _ => handle_api(&mut stream, &req),
        }
    }
}
