// @trace order:1505-kyx8, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 1)
// @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
//! The Cloudflare OAuth core: `begin`, `exchange`, `refresh`, `revoke`.
//!
//! Cloudflare offers no device grant (design.md, Decision 1; research §1 of
//! `plan/issues/cloudflare-login-fleet-vpn-design-2026-09-29.md`), so this is
//! Authorization Code + PKCE (`S256`), implemented as pure functions over an
//! injected [`HttpClient`] trait object — the same seam
//! `GitHubTokenStore` gives the GitHub token bundle, so ordering rules are
//! testable without a real network client. Every fixture in this milestone
//! (1505-sm2j) runs against `tillandsias-fake-cloudflare` (1505-svve), never
//! the real App: `cargo test -p tillandsias-headless cloudflare_oauth`
//! constructs no [`ReqwestHttpClient`] at all, only the in-file
//! `MockHttpClient`; the real client is exercised, over real loopback, by
//! the `#[ignore]`d tests in `loopback_tests` below, which
//! `scripts/test-cloudflare-oauth-core.sh` runs explicitly.
//!
//! # What is NOT in this module
//!
//! - **The redirect receivers** (loopback listener, QR, paste) are a sibling
//!   packet (1505-kc5f, design.md Decision 1 items 2). This module only
//!   builds the authorize URL and completes the exchange once a `(code,
//!   state)` pair has arrived by whatever means.
//! - **Token storage** (Vault paths, rotation scheduler) is 1505-iysn /
//!   1505-8w1c (Decision 2). [`Bundle`] is handed back in memory; nothing
//!   here writes to disk.
//! - **The device grant itself.** Cloudflare does not offer one. The
//!   "device-flow shape... kept as an adapter" is [`device_grant_note`]: it
//!   reads the discovery document's `grant_types_supported` the same way
//!   `parse_device_code_response` reads a device-code reply, and reports
//!   the absence (or, the day Cloudflare ever lists it, the presence) as a
//!   `note:` line — never a fabricated device flow.
//!
//! # PKCE and state, concretely
//!
//! [`begin`] mints a 32-byte `state` and an RFC 7636 code verifier (43..=128
//! chars; this module mints 64 random bytes, base64url-no-pad, which is 86
//! chars — comfortably inside the range with no truncation logic to get
//! wrong) and keeps the verifier out of [`Pending`]'s public surface: no
//! field, no `Debug` output, ever exposes it. [`exchange`] checks the
//! returned `state` against the one `begin` minted BEFORE calling
//! `http.post_form` at all — a state mismatch never reaches the network,
//! which is exactly what
//! `scripts/test-cloudflare-oauth-core.sh` and this module's own
//! `loopback_state_mismatch_makes_zero_token_requests` prove against the
//! fake's ledger, not just against the fake's HTTP response.
//!
//! # Endpoints are read from discovery, not hard-coded
//!
//! `TILLANDSIAS_CLOUDFLARE_BASE_URL` (default
//! `https://dash.cloudflare.com`) names the issuer; [`begin`] fetches
//! `{base}/.well-known/openid-configuration` and takes
//! `authorization_endpoint`, `token_endpoint`, and `revocation_endpoint`
//! from THAT document, not from a compiled-in path list — the packet's
//! context note is explicit that the secondary-source endpoint list must be
//! verified from discovery, not assumed. `TILLANDSIAS_CLOUDFLARE_CLIENT_ID`
//! overrides [`CLOUDFLARE_APP_CLIENT_ID`] for fixtures and for the fake.

use std::time::Duration;

use base64::Engine;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// Default Cloudflare dashboard base URL (design.md Decision 1). Overridable
/// by `TILLANDSIAS_CLOUDFLARE_BASE_URL` so every fixture points at
/// `tillandsias-fake-cloudflare` instead.
pub const CLOUDFLARE_BASE_URL_DEFAULT: &str = "https://dash.cloudflare.com";

/// The public OAuth client id (`token_endpoint_auth_method: none` — no
/// client secret exists in this binary or in Vault). Cloudflare Apps are
/// operator-created and irreversible once made public (design.md Risks), so
/// this compiles in a placeholder until the operator registers the real
/// App; `TILLANDSIAS_CLOUDFLARE_CLIENT_ID` overrides it everywhere,
/// including in every fixture.
pub const CLOUDFLARE_APP_CLIENT_ID: &str = "tillandsias-cloudflare-app-client-id-unregistered";

/// The device-code grant's URN, as `grant_types_supported` would spell it if
/// Cloudflare ever listed it (RFC 8628 §1's registered value). Cloudflare
/// does not support this grant today; this constant exists so
/// [`device_grant_note`] has something exact to compare against, and so the
/// fake server's `TILLANDSIAS_FAKE_CLOUDFLARE_GRANT_TYPES` knob can be set
/// to exactly this string in a fixture.
pub const DEVICE_CODE_GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// RFC 7636 §4.1: the code verifier is 43..=128 characters. 64 random bytes,
/// base64url with no padding, are 86 characters — inside the range with
/// margin on both sides, so no length-clamping logic (a place to get an
/// off-by-one wrong) is needed.
const VERIFIER_RANDOM_BYTES: usize = 64;

/// "32 random bytes" per design.md Decision 1 step 1.
const STATE_RANDOM_BYTES: usize = 32;

/// `TILLANDSIAS_CLOUDFLARE_BASE_URL`, defaulting to
/// [`CLOUDFLARE_BASE_URL_DEFAULT`].
pub fn base_url() -> String {
    std::env::var("TILLANDSIAS_CLOUDFLARE_BASE_URL")
        .unwrap_or_else(|_| CLOUDFLARE_BASE_URL_DEFAULT.to_string())
}

/// `TILLANDSIAS_CLOUDFLARE_CLIENT_ID`, defaulting to
/// [`CLOUDFLARE_APP_CLIENT_ID`].
pub fn client_id() -> String {
    std::env::var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID")
        .unwrap_or_else(|_| CLOUDFLARE_APP_CLIENT_ID.to_string())
}

/// One HTTP response as far as this module's decisions go: a status code
/// and a body to parse. Never carries response headers — nothing here needs
/// one (the redirect receivers that DO need `Location` are a sibling
/// packet, and this module's own tests read it by a test-only raw socket
/// helper, never through this type).
///
/// NO derived `Debug`: the body of a token-endpoint response IS the token
/// pair, so the hand-written `Debug` below prints the status and the body's
/// LENGTH only.
#[derive(Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
}

impl std::fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpResponse")
            .field("status", &self.status)
            .field("body_len", &self.body.len())
            .finish()
    }
}

/// A transport failure reduced to a fixed reason word. `reqwest`'s own
/// `Display` names the request URL (which, for a discovery-named endpoint,
/// is response-derived text) and its source chain; none of it is kept.
fn transport_error(method: &str, e: &reqwest::Error) -> String {
    let kind = if e.is_timeout() {
        "timeout"
    } else if e.is_connect() {
        "connect"
    } else if e.is_body() || e.is_decode() {
        "body"
    } else if e.is_builder() {
        "request-build"
    } else {
        "request"
    };
    format!("refused:cloudflare-login:transport-{method}-{kind}")
}

/// The network seam. Every PKCE decision — endpoint selection, the state
/// check, verifier/challenge construction — is exercised through this trait
/// so `cargo test -p tillandsias-headless cloudflare_oauth` never
/// constructs a [`ReqwestHttpClient`]; only the `#[ignore]`d
/// `loopback_tests` (run explicitly by
/// `scripts/test-cloudflare-oauth-core.sh`) do.
pub trait HttpClient {
    /// `GET url`, no request body.
    fn get(&self, url: &str) -> Result<HttpResponse, String>;
    /// `POST url` with an `application/x-www-form-urlencoded` body built
    /// from `form`, in order.
    fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpResponse, String>;
}

/// The real client: `reqwest` behind a short-lived current-thread `tokio`
/// runtime per call, the same shape `observatorium_probe_status` (main.rs)
/// already uses to keep an async crate behind a synchronous call site. This
/// crate's `reqwest` dependency has no `blocking` feature (workspace
/// Cargo.toml pins `json` + `rustls-tls` only), so this is the seam, not a
/// shortcut.
pub struct ReqwestHttpClient {
    timeout: Duration,
}

impl Default for ReqwestHttpClient {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(15),
        }
    }
}

impl ReqwestHttpClient {
    pub fn new(timeout: Duration) -> Self {
        Self { timeout }
    }
}

fn run_blocking<T>(fut: impl std::future::Future<Output = Result<T, String>>) -> Result<T, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| "refused:cloudflare-login:transport-runtime".to_string())?;
    rt.block_on(fut)
}

impl HttpClient for ReqwestHttpClient {
    fn get(&self, url: &str) -> Result<HttpResponse, String> {
        let url = url.to_string();
        let timeout = self.timeout;
        run_blocking(async move {
            let client = reqwest::Client::builder()
                .timeout(timeout)
                .build()
                .map_err(|_| "refused:cloudflare-login:transport-client".to_string())?;
            let resp = client
                .get(&url)
                .send()
                .await
                .map_err(|e| transport_error("get", &e))?;
            let status = resp.status().as_u16();
            let body = resp.text().await.map_err(|e| transport_error("get", &e))?;
            Ok(HttpResponse { status, body })
        })
    }

    fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpResponse, String> {
        let url = url.to_string();
        let timeout = self.timeout;
        let owned_form: Vec<(String, String)> = form
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        run_blocking(async move {
            let client = reqwest::Client::builder()
                .timeout(timeout)
                .build()
                .map_err(|_| "refused:cloudflare-login:transport-client".to_string())?;
            let resp = client
                .post(&url)
                .form(&owned_form)
                .send()
                .await
                .map_err(|e| transport_error("post", &e))?;
            let status = resp.status().as_u16();
            let body = resp.text().await.map_err(|e| transport_error("post", &e))?;
            Ok(HttpResponse { status, body })
        })
    }
}

/// The OpenID discovery document, narrowed to what this module reads.
/// Extra fields are ignored (`serde`'s default: unknown fields do not
/// error).
#[derive(Debug, Clone, Deserialize)]
struct Discovery {
    authorization_endpoint: String,
    token_endpoint: String,
    #[serde(default)]
    revocation_endpoint: Option<String>,
    #[serde(default)]
    grant_types_supported: Vec<String>,
}

fn fetch_discovery(http: &dyn HttpClient, base_url: &str) -> Result<Discovery, String> {
    let url = format!(
        "{}/.well-known/openid-configuration",
        base_url.trim_end_matches('/')
    );
    let resp = http.get(&url)?;
    if resp.status != 200 {
        return Err(format!(
            "refused:cloudflare-login:discovery-http-{}",
            resp.status
        ));
    }
    // The serde message is DROPPED: a type error quotes the offending value.
    serde_json::from_str(&resp.body)
        .map_err(|_| "refused:cloudflare-login:discovery-unusable".to_string())
}

/// The device-grant adapter (design.md Decision 1: "The GitHub device-flow
/// shape is kept as an adapter"). Cloudflare does not support
/// [`DEVICE_CODE_GRANT_TYPE`] today; this reports whichever is true rather
/// than assuming the absence, so the switch — if Cloudflare ever ships one
/// — is a discovery-driven note, not a code change nobody remembers to
/// make. Pure and separately unit-tested so the decision does not depend on
/// capturing `begin`'s `eprintln!`.
fn device_grant_note(grant_types: &[String]) -> Option<&'static str> {
    if grant_types.iter().any(|g| g == DEVICE_CODE_GRANT_TYPE) {
        Some("note:cloudflare-login:device-grant-available")
    } else {
        None
    }
}

fn random_urlsafe(n_bytes: usize) -> String {
    let mut buf = vec![0u8; n_bytes];
    // A CSPRNG failure means the host has no entropy source at all; there
    // is no meaningful fallback for a `state` or PKCE verifier, so fail
    // loudly (mirrors tillandsias-fake-cloudflare's `random_hex`).
    getrandom::fill(&mut buf).expect("cloudflare_oauth: host CSPRNG unavailable");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

fn s256_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

/// RFC 3986 unreserved characters pass through; everything else is
/// percent-encoded. Used only to build the authorize URL's query string —
/// `POST` bodies go through `reqwest`'s own form encoder in
/// [`ReqwestHttpClient`], and the fake's own decoder (`url_decode` in
/// `tillandsias-fake-cloudflare.rs`) accepts this exact encoding.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn form_urlencode(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// One in-flight login attempt, from [`begin`] to [`exchange`].
///
/// `verifier` is deliberately not `pub`, has no accessor, and is redacted
/// out of `Debug` below: [`exchange`] (in this module) is the only code
/// that ever reads it back, and it is never logged, written to disk, or
/// encoded into the QR a sibling packet renders from `authorize_url` (built
/// from the CHALLENGE, never the verifier).
pub struct Pending {
    pub authorize_url: String,
    pub state: String,
    pub redirect_uri: String,
    pub client_id: String,
    pub token_endpoint: String,
    pub revocation_endpoint: Option<String>,
    /// `Some(note)` when discovery's `grant_types_supported` ever lists
    /// [`DEVICE_CODE_GRANT_TYPE`]; already printed to stderr by [`begin`]
    /// when this is `Some`.
    pub device_grant_note: Option<&'static str>,
    verifier: String,
}

impl std::fmt::Debug for Pending {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Pending")
            .field("authorize_url", &self.authorize_url)
            .field("state", &self.state)
            .field("redirect_uri", &self.redirect_uri)
            .field("client_id", &self.client_id)
            .field("token_endpoint", &self.token_endpoint)
            .field("revocation_endpoint", &self.revocation_endpoint)
            .field("device_grant_note", &self.device_grant_note)
            .field("verifier", &"<redacted>")
            .finish()
    }
}

/// The token bundle `exchange`/`refresh` hand back. In-memory only —
/// writing it to Vault is 1505-iysn.
///
/// NO derived `Debug` and no `Display`: the hand-written `Debug` below
/// redacts both tokens, so a bundle that reaches a log line, a panic message
/// or an `{:?}` in an error carries no credential (1505-kc5f prerequisite;
/// `tests::bundle_debug_never_prints_a_token`).
#[derive(Clone, PartialEq, Eq)]
pub struct Bundle {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Seconds, as Cloudflare reported them (design.md Risks: token
    /// lifetimes are undocumented; `None` when the field was absent, never
    /// a guessed default).
    pub expires_in: Option<u64>,
    pub token_type: Option<String>,
}

impl std::fmt::Debug for Bundle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Bundle")
            .field("access_token", &"<redacted>")
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .field("expires_in", &self.expires_in)
            .field("token_type", &self.token_type)
            .finish()
    }
}

/// An OAuth `error` value kept only when it is a plain identifier
/// (RFC 6749 §5.2's registered codes are lowercase words joined by `_`);
/// anything else — a token echoed back, free text — becomes a fixed word.
fn oauth_error_code(body: &str) -> &'static str {
    const KNOWN: &[&str] = &[
        "invalid_request",
        "invalid_client",
        "invalid_grant",
        "unauthorized_client",
        "unsupported_grant_type",
        "invalid_scope",
        "access_denied",
        "server_error",
        "temporarily_unavailable",
    ];
    match serde_json::from_str::<ErrorResponse>(body) {
        Ok(e) => KNOWN
            .iter()
            .find(|k| **k == e.error)
            .copied()
            .unwrap_or("unrecognised-error-code"),
        Err(_) => "no-error-code",
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    token_type: Option<String>,
}

#[derive(Deserialize)]
struct ErrorResponse {
    error: String,
}

fn parse_token_response(resp: &HttpResponse) -> Result<Bundle, String> {
    // Errors are FIXED reason words: the status (a number) and an allow-listed
    // OAuth error code. Never the body, never a serde message (a serde type
    // error quotes the offending value, which may be a token).
    if resp.status != 200 {
        return Err(format!(
            "refused:cloudflare-login:token-exchange-http-{}:{}",
            resp.status,
            oauth_error_code(&resp.body)
        ));
    }
    let parsed: TokenResponse = serde_json::from_str(&resp.body)
        .map_err(|_| "refused:cloudflare-login:token-response-parse".to_string())?;
    Ok(Bundle {
        access_token: parsed.access_token,
        refresh_token: parsed.refresh_token,
        expires_in: parsed.expires_in,
        token_type: parsed.token_type,
    })
}

/// Step 1 (design.md Decision 1): fetch discovery, announce the device
/// grant if it is ever listed, mint `state` and the PKCE verifier, and
/// build the authorize URL with `code_challenge_method=S256`. Pure aside
/// from the one discovery `GET` (through `http`) and the one `eprintln!`
/// when the device grant is present.
pub fn begin(
    http: &dyn HttpClient,
    base_url: &str,
    client_id: &str,
    redirect_uri: &str,
    scopes: &[&str],
) -> Result<Pending, String> {
    let discovery = fetch_discovery(http, base_url)?;
    let device_grant_note = device_grant_note(&discovery.grant_types_supported);
    if let Some(note) = device_grant_note {
        eprintln!("{note}");
    }

    let state = random_urlsafe(STATE_RANDOM_BYTES);
    let verifier = random_urlsafe(VERIFIER_RANDOM_BYTES);
    debug_assert!(
        (43..=128).contains(&verifier.len()),
        "PKCE verifier must be 43..=128 chars (RFC 7636 §4.1); got {}",
        verifier.len()
    );
    let challenge = s256_challenge(&verifier);
    let scope = scopes.join(" ");

    let mut params: Vec<(&str, &str)> = vec![
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", redirect_uri),
        ("state", &state),
        ("code_challenge", &challenge),
        ("code_challenge_method", "S256"),
    ];
    if !scope.is_empty() {
        params.push(("scope", &scope));
    }
    let authorize_url = format!(
        "{}?{}",
        discovery.authorization_endpoint,
        form_urlencode(&params)
    );

    Ok(Pending {
        authorize_url,
        state,
        redirect_uri: redirect_uri.to_string(),
        client_id: client_id.to_string(),
        token_endpoint: discovery.token_endpoint,
        revocation_endpoint: discovery.revocation_endpoint,
        device_grant_note,
        verifier,
    })
}

/// Step 3: check `returned_state` against `pending.state` BEFORE any
/// network call — a mismatch is `Err` and `http.post_form` is never
/// invoked, which is what
/// `scripts/test-cloudflare-oauth-core.sh` and
/// `loopback_tests::loopback_state_mismatch_makes_zero_token_requests`
/// assert against the fake's ledger (not just the return value: moving
/// this check after the request would still return the same `Err` string
/// on the fake's own 400, but the ledger would then show the request).
pub fn exchange(
    http: &dyn HttpClient,
    pending: &Pending,
    returned_state: &str,
    code: &str,
) -> Result<Bundle, String> {
    if returned_state != pending.state {
        return Err("refused:cloudflare-login:state-mismatch".to_string());
    }
    let form = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", pending.redirect_uri.as_str()),
        ("code_verifier", pending.verifier.as_str()),
        ("client_id", pending.client_id.as_str()),
    ];
    let resp = http.post_form(&pending.token_endpoint, &form)?;
    parse_token_response(&resp)
}

/// `grant_type=refresh_token` against `token_endpoint` (the same endpoint
/// [`begin`] read from discovery — call sites keep `pending.token_endpoint`
/// or the value this returned last time, never a hard-coded path).
pub fn refresh(
    http: &dyn HttpClient,
    token_endpoint: &str,
    client_id: &str,
    refresh_token: &str,
) -> Result<Bundle, String> {
    let form = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("client_id", client_id),
    ];
    let resp = http.post_form(token_endpoint, &form)?;
    parse_token_response(&resp)
}

/// Best-effort revoke at `revocation_endpoint`. Callers that want
/// "best-effort" (design.md Decision 2: `--cloudflare-logout` revokes
/// best-effort) decide what to do with an `Err` themselves — this function
/// reports the real outcome rather than swallowing it.
pub fn revoke(
    http: &dyn HttpClient,
    revocation_endpoint: &str,
    client_id: &str,
    token: &str,
) -> Result<(), String> {
    let form = [("token", token), ("client_id", client_id)];
    let resp = http.post_form(revocation_endpoint, &form)?;
    if (200..300).contains(&resp.status) {
        Ok(())
    } else {
        Err(format!(
            "refused:cloudflare-login:revoke-http-{}",
            resp.status
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// An in-process fake so `cargo test -p tillandsias-headless
    /// cloudflare_oauth` never constructs a [`ReqwestHttpClient`] (exit
    /// criterion: "no test constructs a network client"). Keyed responses
    /// by exact URL; records every call so tests can assert on ORDER and
    /// COUNT, not just return values (the same style
    /// `tillandsias-fake-cloudflare`'s ledger gives the shell-level tests).
    #[derive(Default)]
    struct MockHttpClient {
        get_responses: HashMap<String, HttpResponse>,
        post_responses: HashMap<String, HttpResponse>,
        calls: RefCell<Vec<(String, String)>>,
    }

    impl MockHttpClient {
        fn with_get(mut self, url: &str, status: u16, body: &str) -> Self {
            self.get_responses.insert(
                url.to_string(),
                HttpResponse {
                    status,
                    body: body.to_string(),
                },
            );
            self
        }

        fn with_post(mut self, url: &str, status: u16, body: &str) -> Self {
            self.post_responses.insert(
                url.to_string(),
                HttpResponse {
                    status,
                    body: body.to_string(),
                },
            );
            self
        }

        fn post_call_count(&self) -> usize {
            self.calls
                .borrow()
                .iter()
                .filter(|(method, _)| method == "POST")
                .count()
        }
    }

    impl HttpClient for MockHttpClient {
        fn get(&self, url: &str) -> Result<HttpResponse, String> {
            self.calls
                .borrow_mut()
                .push(("GET".to_string(), url.to_string()));
            self.get_responses
                .get(url)
                .cloned()
                .ok_or_else(|| format!("mock: no GET response stubbed for {url}"))
        }

        fn post_form(&self, url: &str, _form: &[(&str, &str)]) -> Result<HttpResponse, String> {
            self.calls
                .borrow_mut()
                .push(("POST".to_string(), url.to_string()));
            self.post_responses
                .get(url)
                .cloned()
                .ok_or_else(|| format!("mock: no POST response stubbed for {url}"))
        }
    }

    const DISCOVERY_URL: &str = "https://fake.invalid/.well-known/openid-configuration";
    const AUTH_ENDPOINT: &str = "https://fake.invalid/oauth2/auth";
    const TOKEN_ENDPOINT: &str = "https://fake.invalid/oauth2/token";
    const REVOKE_ENDPOINT: &str = "https://fake.invalid/oauth2/revoke";
    const REDIRECT_URI: &str = "http://127.0.0.1:48631/tillandsias/cloudflare/callback";

    fn discovery_body(grant_types: &[&str]) -> String {
        serde_json::json!({
            "issuer": "https://fake.invalid",
            "authorization_endpoint": AUTH_ENDPOINT,
            "token_endpoint": TOKEN_ENDPOINT,
            "revocation_endpoint": REVOKE_ENDPOINT,
            "grant_types_supported": grant_types,
        })
        .to_string()
    }

    fn mock_with_discovery(grant_types: &[&str]) -> MockHttpClient {
        MockHttpClient::default().with_get(DISCOVERY_URL, 200, &discovery_body(grant_types))
    }

    #[test]
    fn begin_reads_endpoints_from_discovery_not_hardcoded() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]);
        let pending = begin(
            &mock,
            "https://fake.invalid",
            "test-client",
            REDIRECT_URI,
            &[],
        )
        .expect("begin");
        assert_eq!(pending.token_endpoint, TOKEN_ENDPOINT);
        assert_eq!(
            pending.revocation_endpoint.as_deref(),
            Some(REVOKE_ENDPOINT)
        );
        assert!(pending.authorize_url.starts_with(AUTH_ENDPOINT));
    }

    #[test]
    fn begin_verifier_is_rfc7636_length_and_challenge_is_s256_of_it() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]);
        let pending = begin(
            &mock,
            "https://fake.invalid",
            "test-client",
            REDIRECT_URI,
            &[],
        )
        .expect("begin");
        assert!(pending.authorize_url.contains("code_challenge_method=S256"));
        // The verifier itself must never appear in the authorize URL or
        // anywhere else public — only its S256 digest does.
        assert!(!pending.authorize_url.contains(&pending.verifier));
        let challenge_param = pending
            .authorize_url
            .split('?')
            .nth(1)
            .unwrap()
            .split('&')
            .find_map(|kv| kv.strip_prefix("code_challenge="))
            .expect("code_challenge present");
        assert_eq!(challenge_param, s256_challenge(&pending.verifier));
    }

    #[test]
    fn begin_state_is_32_bytes_of_randomness_base64url_encoded() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]);
        let a = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        let b = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        assert_ne!(a.state, b.state, "state must be freshly random each call");
        // 32 bytes base64url-no-pad is 43 chars.
        assert_eq!(a.state.len(), 43);
    }

    #[test]
    fn begin_no_device_grant_note_when_absent() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]);
        let pending = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        assert_eq!(pending.device_grant_note, None);
    }

    #[test]
    fn begin_prints_device_grant_note_when_discovery_lists_it() {
        let mock = mock_with_discovery(&[
            "authorization_code",
            "refresh_token",
            DEVICE_CODE_GRANT_TYPE,
        ]);
        let pending = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        assert_eq!(
            pending.device_grant_note,
            Some("note:cloudflare-login:device-grant-available")
        );
    }

    #[test]
    fn device_grant_note_pure_helper_matches_exact_urn() {
        assert_eq!(device_grant_note(&["authorization_code".to_string()]), None);
        assert_eq!(
            device_grant_note(&[DEVICE_CODE_GRANT_TYPE.to_string()]),
            Some("note:cloudflare-login:device-grant-available")
        );
        // A near-miss string must not fire — this is an exact grant-type
        // comparison, not a substring search.
        assert_eq!(
            device_grant_note(&["urn:ietf:params:oauth:grant-type:device".to_string()]),
            None
        );
    }

    #[test]
    fn exchange_returns_bundle_on_success() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]).with_post(
            TOKEN_ENDPOINT,
            200,
            &serde_json::json!({
                "access_token": "at-1",
                "refresh_token": "rt-1",
                "expires_in": 3600,
                "token_type": "bearer",
            })
            .to_string(),
        );
        let pending = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        let bundle = exchange(&mock, &pending, &pending.state.clone(), "some-code").unwrap();
        assert_eq!(bundle.access_token, "at-1");
        assert_eq!(bundle.refresh_token.as_deref(), Some("rt-1"));
        assert_eq!(bundle.expires_in, Some(3600));
    }

    #[test]
    fn exchange_state_mismatch_is_refused_and_makes_zero_post_calls() {
        // NEGATIVE CONTROL: stub the token endpoint to SUCCEED if reached,
        // so the assertion below only passes if the client-side state
        // check ran BEFORE any request — not because the mock happened to
        // refuse. This is the client-side check the fake's own ledger
        // proves the same way in scripts/test-cloudflare-oauth-core.sh.
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]).with_post(
            TOKEN_ENDPOINT,
            200,
            &serde_json::json!({"access_token": "should-never-be-seen", "expires_in": 3600})
                .to_string(),
        );
        let pending = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap();
        let tampered_state = format!("{}-tampered", pending.state);
        let err = exchange(&mock, &pending, &tampered_state, "some-code").unwrap_err();
        assert_eq!(err, "refused:cloudflare-login:state-mismatch");
        assert_eq!(
            mock.post_call_count(),
            0,
            "a state mismatch must be refused before any POST to the token endpoint"
        );
    }

    #[test]
    fn refresh_rotates_via_post_to_token_endpoint() {
        let mock = mock_with_discovery(&["authorization_code", "refresh_token"]).with_post(
            TOKEN_ENDPOINT,
            200,
            &serde_json::json!({
                "access_token": "at-2",
                "refresh_token": "rt-2",
                "expires_in": 3600,
            })
            .to_string(),
        );
        let bundle = refresh(&mock, TOKEN_ENDPOINT, "c", "rt-1").unwrap();
        assert_eq!(bundle.access_token, "at-2");
        assert_eq!(bundle.refresh_token.as_deref(), Some("rt-2"));
    }

    #[test]
    fn refresh_propagates_invalid_grant_as_err() {
        let mock = MockHttpClient::default().with_post(
            TOKEN_ENDPOINT,
            400,
            &serde_json::json!({"error": "invalid_grant"}).to_string(),
        );
        let err = refresh(&mock, TOKEN_ENDPOINT, "c", "stale-refresh-token").unwrap_err();
        assert!(err.contains("invalid_grant"), "got: {err}");
    }

    #[test]
    fn revoke_ok_on_2xx() {
        let mock = MockHttpClient::default().with_post(REVOKE_ENDPOINT, 200, "{}");
        revoke(&mock, REVOKE_ENDPOINT, "c", "at-1").expect("revoke ok");
    }

    #[test]
    fn revoke_err_on_non_2xx() {
        let mock = MockHttpClient::default().with_post(
            REVOKE_ENDPOINT,
            400,
            &serde_json::json!({"error": "invalid_request"}).to_string(),
        );
        let err = revoke(&mock, REVOKE_ENDPOINT, "c", "at-1").unwrap_err();
        assert!(err.contains("400"), "got: {err}");
    }

    #[test]
    fn percent_encode_escapes_reserved_and_passes_unreserved() {
        assert_eq!(percent_encode("a-Z_9.~"), "a-Z_9.~");
        assert_eq!(percent_encode(" /:?"), "%20%2F%3A%3F");
    }

    #[test]
    fn discovery_http_error_is_refused_not_panicked() {
        let mock = MockHttpClient::default().with_get(DISCOVERY_URL, 500, "boom");
        let err = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap_err();
        assert_eq!(err, "refused:cloudflare-login:discovery-http-500");
    }

    #[test]
    fn client_id_and_base_url_env_overrides() {
        // 1437-5czv: env-mutating tests serialize on the crate-wide lock.
        let _guard = crate::test_support::env_lock();
        let prev_base = std::env::var("TILLANDSIAS_CLOUDFLARE_BASE_URL").ok();
        let prev_client = std::env::var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID").ok();
        unsafe {
            std::env::set_var(
                "TILLANDSIAS_CLOUDFLARE_BASE_URL",
                "https://override.invalid",
            );
            std::env::set_var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID", "override-client");
        }
        assert_eq!(base_url(), "https://override.invalid");
        assert_eq!(client_id(), "override-client");
        unsafe {
            match prev_base {
                Some(v) => std::env::set_var("TILLANDSIAS_CLOUDFLARE_BASE_URL", v),
                None => std::env::remove_var("TILLANDSIAS_CLOUDFLARE_BASE_URL"),
            }
            match prev_client {
                Some(v) => std::env::set_var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID", v),
                None => std::env::remove_var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID"),
            }
        }
    }

    #[test]
    fn defaults_when_env_unset() {
        let _guard = crate::test_support::env_lock();
        let prev_base = std::env::var("TILLANDSIAS_CLOUDFLARE_BASE_URL").ok();
        let prev_client = std::env::var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID").ok();
        unsafe {
            std::env::remove_var("TILLANDSIAS_CLOUDFLARE_BASE_URL");
            std::env::remove_var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID");
        }
        assert_eq!(base_url(), CLOUDFLARE_BASE_URL_DEFAULT);
        assert_eq!(client_id(), CLOUDFLARE_APP_CLIENT_ID);
        unsafe {
            if let Some(v) = prev_base {
                std::env::set_var("TILLANDSIAS_CLOUDFLARE_BASE_URL", v);
            }
            if let Some(v) = prev_client {
                std::env::set_var("TILLANDSIAS_CLOUDFLARE_CLIENT_ID", v);
            }
        }
    }

    // ── No secret in Debug or in an error (the kc5f prerequisite) ─────────

    const LEAK_ACCESS: &str = "cf-at-LEAKPROBE-7f3a9c1e5b2d";
    const LEAK_REFRESH: &str = "cf-rt-LEAKPROBE-0e4b8d2a6c9f";

    fn assert_no_leak(text: &str, what: &str) {
        for probe in [LEAK_ACCESS, LEAK_REFRESH] {
            assert!(
                !text.contains(probe),
                "{what} carries token bytes ({probe}): {text}"
            );
        }
    }

    /// `{:?}` and `{:#?}` of a Bundle holding known token bytes contain
    /// neither token. NEGATIVE CONTROL (run by hand when this landed): with
    /// `#[derive(Debug)]` restored on `Bundle` this test FAILS on the first
    /// assertion, because a derived Debug prints both fields verbatim.
    #[test]
    fn bundle_debug_never_prints_a_token() {
        let b = Bundle {
            access_token: LEAK_ACCESS.into(),
            refresh_token: Some(LEAK_REFRESH.into()),
            expires_in: Some(3600),
            token_type: Some("bearer".into()),
        };
        for text in [format!("{b:?}"), format!("{b:#?}")] {
            assert_no_leak(&text, "Bundle Debug");
            // Not an empty impl: the non-secret fields are still visible.
            assert!(
                text.contains("3600") && text.contains("<redacted>"),
                "{text}"
            );
        }
        let no_refresh = Bundle {
            refresh_token: None,
            ..b.clone()
        };
        assert!(format!("{no_refresh:?}").contains("None"));
    }

    /// An HttpResponse's body can BE a token response: its Debug must not
    /// print the body.
    #[test]
    fn http_response_debug_never_prints_the_body() {
        let r = HttpResponse {
            status: 200,
            body: format!(r#"{{"access_token":"{LEAK_ACCESS}","refresh_token":"{LEAK_REFRESH}"}}"#),
        };
        assert_no_leak(&format!("{r:?} {r:#?}"), "HttpResponse Debug");
    }

    /// Errors built from a HOSTILE response body carry fixed reason words,
    /// never response bytes: a token in the OAuth `error` field, a token
    /// quoted back by a serde type error (a token sent where a number was
    /// expected), a token in the discovery document.
    #[test]
    fn errors_from_a_hostile_body_never_carry_a_token() {
        let cases: Vec<(u16, String)> = vec![
            (400, format!(r#"{{"error":"{LEAK_REFRESH}"}}"#)),
            (401, format!(r#"{{"error":"invalid_grant {LEAK_ACCESS}"}}"#)),
            (500, format!("upstream said {LEAK_ACCESS}")),
            (
                200,
                format!(r#"{{"access_token":"x","expires_in":"{LEAK_REFRESH}"}}"#),
            ),
            (200, format!(r#"{{"access_token":{{"{LEAK_ACCESS}":1}}}}"#)),
            (200, format!("not json {LEAK_ACCESS}")),
        ];
        for (status, body) in cases {
            let err = parse_token_response(&HttpResponse { status, body }).unwrap_err();
            assert_no_leak(&err, "token-response error");
            assert!(err.starts_with("refused:cloudflare-login:"), "{err}");
        }
        // A plain OAuth error code still survives (the 1505-iysn reduction
        // and the operator both need `invalid_grant`).
        let err = parse_token_response(&HttpResponse {
            status: 400,
            body: r#"{"error":"invalid_grant"}"#.into(),
        })
        .unwrap_err();
        assert_eq!(
            err,
            "refused:cloudflare-login:token-exchange-http-400:invalid_grant"
        );

        let mock = MockHttpClient::default().with_get(
            DISCOVERY_URL,
            200,
            &format!(r#"{{"authorization_endpoint":1,"token_endpoint":"{LEAK_ACCESS}"}}"#),
        );
        let err = begin(&mock, "https://fake.invalid", "c", REDIRECT_URI, &[]).unwrap_err();
        assert_no_leak(&err, "discovery error");
        assert!(err.starts_with("refused:cloudflare-login:"), "{err}");
    }
}

/// Drives the REAL [`ReqwestHttpClient`] over loopback against a spawned
/// `tillandsias-fake-cloudflare` (1505-svve). Every test here is
/// `#[ignore]`d so a plain `cargo test -p tillandsias-headless
/// cloudflare_oauth` (exit criterion: "no test constructs a network
/// client") never runs them; `scripts/test-cloudflare-oauth-core.sh` builds
/// the fake, then runs these explicitly with `--ignored --nocapture` so
/// `begin`'s `eprintln!` note reaches the script's own captured output.
#[cfg(test)]
mod loopback_tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};

    const REDIRECT_URI: &str = "http://127.0.0.1:48631/tillandsias/cloudflare/callback";

    struct FakeServer {
        child: Child,
        base_url: String,
        ledger_path: PathBuf,
    }

    impl Drop for FakeServer {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn fake_cloudflare_bin() -> PathBuf {
        if let Ok(p) = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_BIN") {
            return PathBuf::from(p);
        }
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/debug/tillandsias-fake-cloudflare")
    }

    fn start_fake(name: &str, grant_types: Option<&str>) -> FakeServer {
        let bin = fake_cloudflare_bin();
        assert!(
            bin.exists(),
            "cloudflare_oauth loopback test: fake-cloudflare binary not found at {bin:?}; \
             run scripts/test-cloudflare-oauth-core.sh (it builds this binary first), or set \
             TILLANDSIAS_FAKE_CLOUDFLARE_BIN to an already-built path."
        );
        let dir = std::env::temp_dir().join(format!(
            "cloudflare-oauth-core-test-{name}-{}-{}",
            std::process::id(),
            random_urlsafe(6)
        ));
        std::fs::create_dir_all(&dir).expect("create test work dir");
        let ledger_path = dir.join("ledger.jsonl");

        let mut cmd = Command::new(&bin);
        cmd.arg("--ledger").arg(&ledger_path);
        if let Some(gt) = grant_types {
            cmd.env("TILLANDSIAS_FAKE_CLOUDFLARE_GRANT_TYPES", gt);
        }
        let mut child = cmd
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn tillandsias-fake-cloudflare");
        let stdout = child.stdout.take().expect("fake-cloudflare stdout");
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .expect("read fake-cloudflare port line");
        let port: u16 = line
            .trim()
            .parse()
            .unwrap_or_else(|_| panic!("fake-cloudflare printed a non-port first line: {line:?}"));
        FakeServer {
            child,
            base_url: format!("http://127.0.0.1:{port}"),
            ledger_path,
        }
    }

    fn ledger_lines(path: &Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str(l).expect("ledger line is JSON"))
            .collect()
    }

    fn token_call_count(path: &Path) -> usize {
        ledger_lines(path)
            .iter()
            .filter(|entry| {
                entry
                    .get("path")
                    .and_then(|p| p.as_str())
                    .map(|p| p.starts_with("/oauth2/token"))
                    .unwrap_or(false)
            })
            .count()
    }

    /// Simulates the browser step a sibling packet (1505-kc5f) owns for
    /// real: hits `/oauth2/auth?...&auto=approve` the way the operator's
    /// click would, and returns the raw `Location` header the fake
    /// answered with. A minimal hand-rolled HTTP/1.1 client, not
    /// `reqwest`, because the target of that redirect
    /// (`REDIRECT_URI`, 127.0.0.1:48631) is never actually listening in
    /// this test and a redirect-following client would try to connect to
    /// it and fail; disabling redirects is exactly what a real receiver
    /// does too (it IS the thing listening on that port), so this
    /// scaffolding is test-only, not a second implementation of a receiver.
    fn raw_http_get_location(url: &str) -> String {
        let stripped = url.strip_prefix("http://").expect("http:// url");
        let (authority, rest) = stripped.split_once('/').unwrap_or((stripped, ""));
        let path = format!("/{rest}");
        let mut stream =
            std::net::TcpStream::connect(authority).expect("connect to fake-cloudflare");
        write!(
            stream,
            "GET {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
        )
        .expect("write request");
        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).expect("read response");
        let text = String::from_utf8_lossy(&buf).into_owned();
        for line in text.lines() {
            if let Some(v) = line
                .strip_prefix("Location: ")
                .or_else(|| line.strip_prefix("location: "))
            {
                return v.trim().to_string();
            }
        }
        panic!("fake-cloudflare /oauth2/auth did not answer with a Location header: {text}");
    }

    fn query_param(location: &str, key: &str) -> String {
        let query = location.split_once('?').map(|(_, q)| q).unwrap_or("");
        query
            .split('&')
            .find_map(|pair| {
                pair.split_once('=')
                    .filter(|(k, _)| *k == key)
                    .map(|(_, v)| v.to_string())
            })
            .unwrap_or_else(|| panic!("query param {key:?} not found in {location:?}"))
    }

    fn approve_and_get_code_state(pending: &Pending) -> (String, String) {
        let location = raw_http_get_location(&format!("{}&auto=approve", pending.authorize_url));
        let code = query_param(&location, "code");
        let state = query_param(&location, "state");
        (code, state)
    }

    #[test]
    #[ignore = "drives the real fake-cloudflare over loopback; run via scripts/test-cloudflare-oauth-core.sh"]
    fn loopback_exchange_succeeds_with_right_state_and_verifier() {
        let server = start_fake("happy", None);
        let http = ReqwestHttpClient::default();
        let pending = begin(
            &http,
            &server.base_url,
            "fake-client",
            REDIRECT_URI,
            &["read"],
        )
        .expect("begin against real loopback fake");
        let (code, state) = approve_and_get_code_state(&pending);
        assert_eq!(state, pending.state);

        let bundle = exchange(&http, &pending, &state, &code).expect("exchange succeeds");
        assert!(!bundle.access_token.is_empty());
        assert!(bundle.refresh_token.is_some());
    }

    #[test]
    #[ignore = "drives the real fake-cloudflare over loopback; run via scripts/test-cloudflare-oauth-core.sh"]
    fn loopback_state_mismatch_makes_zero_token_requests() {
        let server = start_fake("state-mismatch", None);
        let http = ReqwestHttpClient::default();
        let pending = begin(&http, &server.base_url, "fake-client", REDIRECT_URI, &[])
            .expect("begin against real loopback fake");
        let (code, _real_state) = approve_and_get_code_state(&pending);

        let before = token_call_count(&server.ledger_path);
        assert_eq!(
            before, 0,
            "no /oauth2/token call before exchange is even attempted"
        );

        let err = exchange(&http, &pending, "tampered-state-not-the-real-one", &code)
            .expect_err("a tampered state must be refused");
        assert_eq!(err, "refused:cloudflare-login:state-mismatch");

        let after = token_call_count(&server.ledger_path);
        assert_eq!(
            after, 0,
            "the fake's ledger must show ZERO /oauth2/token requests: the client-side \
             state check must run before any network call, not merely produce an Err"
        );
    }

    #[test]
    #[ignore = "drives the real fake-cloudflare over loopback; run via scripts/test-cloudflare-oauth-core.sh"]
    fn loopback_refresh_rotates_and_invalidates_old_refresh_token() {
        let server = start_fake("refresh", None);
        let http = ReqwestHttpClient::default();
        let pending = begin(&http, &server.base_url, "fake-client", REDIRECT_URI, &[])
            .expect("begin against real loopback fake");
        let (code, state) = approve_and_get_code_state(&pending);
        let bundle = exchange(&http, &pending, &state, &code).expect("initial exchange");
        let old_refresh = bundle.refresh_token.clone().expect("refresh token issued");

        let rotated = refresh(
            &http,
            &pending.token_endpoint,
            &pending.client_id,
            &old_refresh,
        )
        .expect("refresh rotates");
        assert_ne!(rotated.access_token, bundle.access_token);
        assert_ne!(rotated.refresh_token.as_deref(), Some(old_refresh.as_str()));

        let replay = refresh(
            &http,
            &pending.token_endpoint,
            &pending.client_id,
            &old_refresh,
        );
        assert!(
            replay.is_err(),
            "the old refresh_token must be invalidated once rotated, not still usable"
        );
    }

    #[test]
    #[ignore = "drives the real fake-cloudflare over loopback; run via scripts/test-cloudflare-oauth-core.sh"]
    fn loopback_revoke_succeeds_against_real_fake() {
        let server = start_fake("revoke", None);
        let http = ReqwestHttpClient::default();
        let pending = begin(&http, &server.base_url, "fake-client", REDIRECT_URI, &[])
            .expect("begin against real loopback fake");
        let (code, state) = approve_and_get_code_state(&pending);
        let bundle = exchange(&http, &pending, &state, &code).expect("exchange");
        let revocation_endpoint = pending
            .revocation_endpoint
            .clone()
            .expect("fake advertises a revocation_endpoint");

        revoke(
            &http,
            &revocation_endpoint,
            &pending.client_id,
            &bundle.access_token,
        )
        .expect("revoke ok against real fake");
    }

    #[test]
    #[ignore = "drives the real fake-cloudflare over loopback; run via scripts/test-cloudflare-oauth-core.sh"]
    fn loopback_device_grant_note_printed_when_discovery_lists_it() {
        let server = start_fake(
            "device-grant",
            Some("authorization_code,refresh_token,urn:ietf:params:oauth:grant-type:device_code"),
        );
        let http = ReqwestHttpClient::default();
        // `begin` eprintln!s the note as a side effect here; this test
        // asserts the returned field (deterministic, no stderr capture
        // needed in-process), while scripts/test-cloudflare-oauth-core.sh
        // greps the actual stderr this call just wrote for the literal
        // line, since eprintln! writes straight to the real fd 2 even
        // inside a `#[test]`, bypassing libtest's capture under
        // `--nocapture`.
        let pending = begin(&http, &server.base_url, "fake-client", REDIRECT_URI, &[])
            .expect("begin against real loopback fake");
        assert_eq!(
            pending.device_grant_note,
            Some("note:cloudflare-login:device-grant-available")
        );
    }
}
