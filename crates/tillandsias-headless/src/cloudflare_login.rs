// @trace order:1505-kc5f, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 1, Decision 7)
// @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
//! `tillandsias --cloudflare-login [--via loopback|qr|paste]` and
//! `tillandsias --cloudflare-logout`.
//!
//! Cloudflare offers NO device grant (design.md Decision 1), so this is the
//! Authorization Code + PKCE flow of [`crate::cloudflare_oauth`] with three
//! receivers for the redirect:
//!
//! - **loopback**: a listener on `127.0.0.1` (never `0.0.0.0`) on the first
//!   free port of [`REGISTERED_LOOPBACK_PORTS`] at [`CALLBACK_PATH`]; the
//!   browser is opened on the authorize URL; the listener takes EXACTLY ONE
//!   callback, checks `state` before reading anything else, and closes. It
//!   gives up after [`LOGIN_WINDOW`].
//! - **qr**: a terminal QR of the authorize URL whose `redirect_uri` is the
//!   operator's static relay page (`TILLANDSIAS_CLOUDFLARE_RELAY_URL`,
//!   `assets/cloudflare-relay/index.html`); the code comes back by paste, or
//!   by polling `TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL` when set.
//! - **paste**: the operator pastes the line the relay page shows
//!   (`code=…&state=…`) or the whole address-bar URL. This is an
//!   AUTHORIZATION CODE — single-use and useless without the PKCE verifier
//!   that never leaves this process — NOT a token: 777-kyjp removed the
//!   token-paste prompt and nothing here brings one back.
//!
//! # What never leaves this process
//!
//! The PKCE verifier goes only to the token endpoint. Tokens go only to the
//! Vault store. The code goes only to the token endpoint. None of the three
//! is printed, logged, put in argv or in a child's environment, or included
//! in a refusal: every refusal is a FIXED reason word plus `why:`/`remedy:`
//! lines, and [`AuthCode`]'s `Debug` is redacted. The QR and the printed URL
//! carry only what the authorize URL must: `client_id`, `redirect_uri`,
//! `state`, `code_challenge` (+ `response_type`, `code_challenge_method`,
//! and `scope` when scopes are configured).
//!
//! # Order of checks, and why the Vault preflight is where it is
//!
//! state (in the receiver, before `error` or `code` is read) -> `error` ->
//! code shape -> Vault preflight (`read_bundle`: an unreachable, sealed or
//! refusing Vault is refused BEFORE the code is spent) -> exchange -> store
//! through [`crate::vault_bootstrap::store_cloudflare_token_bundle`] (1505-iysn:
//! refresh record first). The preflight follows the receiver so a refused
//! consent or a forged callback never touches Vault at all.

use std::io::{BufRead, Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

use crate::cloudflare_oauth::{self, HttpClient, Pending};
use crate::vault_bootstrap::{
    self, CLOUDFLARE_REFRESH_PATH, CLOUDFLARE_TOKEN_PATH, CloudflareTokenBundle,
    CloudflareTokenStore,
};

/// The loopback ports registered with the Cloudflare App. EXACT match: the
/// redirect URI must equal a registered one including the port, so each port
/// is its own registration (design note, operator checklist item 3).
pub const REGISTERED_LOOPBACK_PORTS: [u16; 3] = [48631, 48632, 48633];
/// The redirect path, on loopback and on the relay host alike.
pub const CALLBACK_PATH: &str = "/tillandsias/cloudflare/callback";
/// The operator's static relay page, e.g.
/// `https://<relay-host>/tillandsias/cloudflare/callback`.
pub const RELAY_URL_ENV: &str = "TILLANDSIAS_CLOUDFLARE_RELAY_URL";
/// Optional: a relay Worker the host polls with `?state=` for the code.
pub const RELAY_POLL_URL_ENV: &str = "TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL";
/// How long any receiver waits (spec: "for at most five minutes").
pub const LOGIN_WINDOW: Duration = Duration::from_secs(300);
/// Scopes requested at login. EMPTY until the operator registers the App and
/// records the exact scope ids its consent screen lists (the design note's
/// scope names are UNVERIFIED permission names, not ids); Cloudflare adds
/// `openid`/`offline_access` itself.
pub const CLOUDFLARE_LOGIN_SCOPES: &[&str] = &[];

const RELAY_POLL_INTERVAL: Duration = Duration::from_secs(2);
const RELAY_POLL_MAX_TRANSPORT_FAILURES: u32 = 5;
/// Requests on the loopback port that are NOT the callback (a favicon, a
/// stray local client) are answered 404 and counted; past this many the
/// listener is treated as under attack and the login refuses.
const MAX_STRAY_REQUESTS: usize = 16;
const MAX_REQUEST_HEAD_BYTES: usize = 8 * 1024;
const MAX_CODE_LEN: usize = 2048;
const MAX_PASTE_BYTES: u64 = 8 * 1024;

// ── verdicts ────────────────────────────────────────────────────────────────

/// A named refusal: `refused:<command>:<reason>`, then `why:` and `remedy:`.
/// `reason` is ALWAYS a fixed word (a literal, or a reduced token passed
/// through [`fixed_word`]) — never response text, never a secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub command: &'static str,
    pub reason: String,
    pub why: String,
    pub remedy: String,
}

impl Refusal {
    fn login(reason: impl Into<String>, why: impl Into<String>, remedy: impl Into<String>) -> Self {
        Self {
            command: "cloudflare-login",
            reason: fixed_word(&reason.into()),
            why: why.into(),
            remedy: remedy.into(),
        }
    }

    fn logout(
        reason: impl Into<String>,
        why: impl Into<String>,
        remedy: impl Into<String>,
    ) -> Self {
        Self {
            command: "cloudflare-logout",
            reason: fixed_word(&reason.into()),
            why: why.into(),
            remedy: remedy.into(),
        }
    }

    pub fn verdict(&self) -> String {
        format!("refused:{}:{}", self.command, self.reason)
    }

    /// The three lines printed on stderr (the repo's `_afford` shape).
    pub fn render(&self) -> String {
        format!(
            "{}\n  why: {}\n  remedy: {}\n",
            self.verdict(),
            self.why,
            self.remedy
        )
    }
}

/// Keep a dynamic reason only when it is made of the verdict alphabet
/// (`[a-z0-9_:-]`, at most 120 bytes); anything else becomes `unrecognised`.
/// Belt and braces: every producer already emits fixed words.
fn fixed_word(s: &str) -> String {
    if !s.is_empty()
        && s.len() <= 120
        && s.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'_' | b':' | b'-')
        })
    {
        s.to_string()
    } else {
        "unrecognised".to_string()
    }
}

/// A core (`cloudflare_oauth`) error reduced to a reason word: the core
/// emits `refused:cloudflare-login:<fixed words>` (1505-kc5f prerequisite);
/// the prefix is dropped and the rest passes [`fixed_word`].
fn core_reason(e: &str) -> String {
    fixed_word(
        e.strip_prefix("refused:cloudflare-login:")
            .unwrap_or("core-error"),
    )
}

// ── the authorization code, which must never be printed ─────────────────────

/// The authorization code. No `Display`; `Debug` is redacted; the only read
/// is [`AuthCode::expose_to_token_endpoint`], at the exchange.
#[derive(Clone, PartialEq, Eq)]
pub struct AuthCode(String);

impl std::fmt::Debug for AuthCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AuthCode(<redacted>)")
    }
}

impl AuthCode {
    fn expose_to_token_endpoint(&self) -> &str {
        &self.0
    }
}

/// A code is 1..=2048 RFC 3986 unreserved characters. Anything else (a
/// space, a quote, a `<`, a newline) is refused rather than forwarded.
fn valid_code(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_CODE_LEN
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~'))
}

/// Constant-time equality for the `state` comparison.
fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Strict `application/x-www-form-urlencoded` decoding of one component:
/// `+` is a space, `%XY` must be two hex digits, the result must be UTF-8.
fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' => {
                let hex = bytes.get(i + 1..i + 3)?;
                let hex = std::str::from_utf8(hex).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

fn parse_query(query: &str) -> Option<Vec<(String, String)>> {
    let mut out = Vec::new();
    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        out.push((percent_decode(k)?, percent_decode(v)?));
    }
    Some(out)
}

const REMEDY_RETRY: &str = "run `tillandsias --cloudflare-login` again; nothing was stored";

/// The ONE place a callback (loopback request, pasted line, relay poll
/// answer) is judged. `state` FIRST — a missing, repeated or different
/// `state` is refused before `error` or `code` is even looked at — then a
/// provider `error`, then the code's shape.
fn judge_callback(params: &[(String, String)], expected_state: &str) -> Result<AuthCode, Refusal> {
    let states: Vec<&str> = params
        .iter()
        .filter(|(k, _)| k == "state")
        .map(|(_, v)| v.as_str())
        .collect();
    if states.len() != 1 || !ct_eq(states[0], expected_state) {
        return Err(Refusal::login(
            "state-mismatch",
            "the redirect's state is not the one minted for this login, so it may be a forged or replayed callback; no code was exchanged",
            REMEDY_RETRY,
        ));
    }
    if let Some((_, err)) = params.iter().find(|(k, _)| k == "error") {
        return Err(match cloudflare_oauth::known_oauth_error(err) {
            Some("access_denied") => Refusal::login(
                "access-denied",
                "the Cloudflare consent screen was declined (error=access_denied); no code was issued",
                "run `tillandsias --cloudflare-login` again and approve the Tillandsias App",
            ),
            Some(code) => Refusal::login(
                format!("authorization-error:{code}"),
                "Cloudflare answered the authorization request with an error instead of a code",
                REMEDY_RETRY,
            ),
            None => Refusal::login(
                "authorization-error:unrecognised-error-code",
                "Cloudflare answered the authorization request with an error this binary does not recognise",
                REMEDY_RETRY,
            ),
        });
    }
    let codes: Vec<&str> = params
        .iter()
        .filter(|(k, _)| k == "code")
        .map(|(_, v)| v.as_str())
        .collect();
    match codes.as_slice() {
        [c] if valid_code(c) => Ok(AuthCode((*c).to_string())),
        [] => Err(Refusal::login(
            "callback-without-code",
            "the redirect carried the right state but no authorization code",
            REMEDY_RETRY,
        )),
        _ => Err(Refusal::login(
            "code-malformed",
            "the authorization code is repeated, empty, too long, or holds characters outside the URL-safe set",
            REMEDY_RETRY,
        )),
    }
}

// ── receivers ───────────────────────────────────────────────────────────────

/// Via which receiver the redirect comes back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Via {
    Loopback,
    Qr,
    Paste,
}

impl Via {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "loopback" => Some(Self::Loopback),
            "qr" => Some(Self::Qr),
            "paste" => Some(Self::Paste),
            _ => None,
        }
    }
}

/// The default receiver (spec): loopback when a desktop session AND a
/// browser opener exist, else qr when a relay is configured, else paste.
pub fn default_via(desktop_with_opener: bool, relay_configured: bool) -> Via {
    if desktop_with_opener {
        Via::Loopback
    } else if relay_configured {
        Via::Qr
    } else {
        Via::Paste
    }
}

/// Bind `127.0.0.1` (never `0.0.0.0`) on the first free port of `ports`.
fn bind_first_free(ports: &[u16]) -> Result<(TcpListener, u16), Refusal> {
    for &port in ports {
        if let Ok(l) = TcpListener::bind((Ipv4Addr::LOCALHOST, port)) {
            let bound = l.local_addr().map(|a| a.port()).unwrap_or(port);
            return Ok((l, bound));
        }
    }
    Err(Refusal::login(
        "no-registered-port-free",
        format!(
            "every registered loopback port ({}) is in use, and the redirect must name a registered port exactly",
            ports
                .iter()
                .map(u16::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        "close whatever holds those ports (another login?), or use `--via qr` or `--via paste`",
    ))
}

struct RequestHead {
    method: String,
    path: String,
    query: String,
}

/// Read one request head (request line + headers), at most
/// [`MAX_REQUEST_HEAD_BYTES`]. A GET callback carries no body.
fn read_request_head(stream: &mut TcpStream) -> Option<RequestHead> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
        if buf.len() > MAX_REQUEST_HEAD_BYTES {
            return None;
        }
    }
    let head = std::str::from_utf8(&buf).ok()?;
    let line = head.lines().next()?;
    let mut parts = line.split(' ');
    let method = parts.next()?.to_string();
    let target = parts.next()?;
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    Some(RequestHead {
        method,
        path: path.to_string(),
        query: query.split('#').next().unwrap_or("").to_string(),
    })
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let resp = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
         Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\
         Content-Security-Policy: default-src 'none'\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

/// The page the browser shows. Fixed text: it never echoes the code, the
/// state or anything else from the request.
fn callback_page(ok: bool) -> String {
    let msg = if ok {
        "Tillandsias received the Cloudflare sign-in. You can close this tab and return to the terminal."
    } else {
        "Tillandsias refused this sign-in. Return to the terminal for the reason."
    };
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Tillandsias</title></head><body><p>{msg}</p></body></html>"
    )
}

/// The loopback receiver: take connections until ONE request hits
/// [`CALLBACK_PATH`] with GET, judge it ([`judge_callback`]: state first),
/// answer the browser with a fixed page, and return. The caller drops the
/// listener, so the port closes after exactly one callback. Requests to any
/// other path are answered 404 and counted; the whole wait is bounded by
/// `deadline`.
fn receive_loopback(
    listener: &TcpListener,
    expected_state: &str,
    deadline: Instant,
) -> Result<AuthCode, Refusal> {
    listener.set_nonblocking(true).map_err(|_| {
        Refusal::login(
            "listener-failed",
            "the loopback listener could not be configured",
            "use `--via paste`",
        )
    })?;
    let mut strays = 0usize;
    loop {
        if Instant::now() >= deadline {
            return Err(Refusal::login(
                "timeout",
                "no callback reached the loopback listener within the login window; the listener is closed",
                "run `tillandsias --cloudflare-login` again and approve in the browser that opens, or use `--via paste`",
            ));
        }
        match listener.accept() {
            Ok((mut stream, peer)) => {
                if !peer.ip().is_loopback() {
                    // Unreachable for a 127.0.0.1 bind; refused anyway.
                    continue;
                }
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
                let head = read_request_head(&mut stream);
                let is_callback = head
                    .as_ref()
                    .is_some_and(|h| h.method == "GET" && h.path == CALLBACK_PATH);
                if !is_callback {
                    respond(&mut stream, "404 Not Found", "");
                    strays += 1;
                    if strays > MAX_STRAY_REQUESTS {
                        return Err(Refusal::login(
                            "too-many-stray-requests",
                            "the loopback port kept receiving requests that were not the sign-in callback; the listener is closed",
                            "run `tillandsias --cloudflare-login` again, or use `--via paste`",
                        ));
                    }
                    continue;
                }
                let query = head.map(|h| h.query).unwrap_or_default();
                let verdict = match parse_query(&query) {
                    Some(params) => judge_callback(&params, expected_state),
                    None => Err(Refusal::login(
                        "state-mismatch",
                        "the callback's query string is not valid URL encoding, so its state cannot be verified",
                        REMEDY_RETRY,
                    )),
                };
                let (status, ok) = if verdict.is_ok() {
                    ("200 OK", true)
                } else {
                    ("400 Bad Request", false)
                };
                respond(&mut stream, status, &callback_page(ok));
                return verdict;
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(_) => {
                return Err(Refusal::login(
                    "listener-failed",
                    "the loopback listener stopped accepting connections",
                    "use `--via paste`",
                ));
            }
        }
    }
}

/// A pasted line: the relay page's `code=…&state=…`, or the whole URL the
/// browser landed on. A bare value is refused: the state must come with it.
fn judge_pasted(line: &str, expected_state: &str) -> Result<AuthCode, Refusal> {
    let line = line.trim();
    if line.is_empty() {
        return Err(Refusal::login(
            "paste-empty",
            "nothing was pasted",
            "paste the line the relay page shows (code=…&state=…), or the whole address-bar URL",
        ));
    }
    let query = match line.split_once('?') {
        Some((_, q)) => q,
        None if line.contains('=') => line,
        None => {
            return Err(Refusal::login(
                "paste-needs-code-and-state",
                "a bare value carries no state, and the state is what proves the code belongs to THIS login",
                "paste the line the relay page shows (code=…&state=…), or the whole address-bar URL",
            ));
        }
    };
    let query = query.split('#').next().unwrap_or("");
    match parse_query(query) {
        Some(params) => judge_callback(&params, expected_state),
        None => Err(Refusal::login(
            "state-mismatch",
            "the pasted line is not valid URL encoding, so its state cannot be verified",
            REMEDY_RETRY,
        )),
    }
}

/// Poll the relay Worker: `GET <poll>?state=<state>` until it answers 200
/// with `{"state":…, "code":…}` (state checked first) or the window closes.
/// 202/204/404 mean "not yet".
fn poll_relay(
    http: &dyn HttpClient,
    poll_url: &str,
    expected_state: &str,
    deadline: Instant,
    interval: Duration,
) -> Result<AuthCode, Refusal> {
    let sep = if poll_url.contains('?') { '&' } else { '?' };
    let url = format!("{poll_url}{sep}state={expected_state}");
    let mut failures = 0u32;
    loop {
        if Instant::now() >= deadline {
            return Err(Refusal::login(
                "timeout",
                "the relay did not hand back a code within the login window",
                "scan the QR again after re-running `tillandsias --cloudflare-login --via qr`, or use `--via paste`",
            ));
        }
        match http.get(&url) {
            Ok(r) if r.status == 200 => {
                let v: serde_json::Value = serde_json::from_str(&r.body).map_err(|_| {
                    Refusal::login(
                        "relay-poll-unusable",
                        "the relay's answer is not the JSON object {state, code}",
                        "check the relay Worker, or use `--via paste`",
                    )
                })?;
                let mut params = Vec::new();
                for key in ["state", "error", "code"] {
                    if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
                        params.push((key.to_string(), s.to_string()));
                    }
                }
                return judge_callback(&params, expected_state);
            }
            Ok(r) if matches!(r.status, 202 | 204 | 404) => {}
            Ok(r) => {
                return Err(Refusal::login(
                    format!("relay-poll-http-{}", r.status),
                    "the relay Worker answered the poll with an unexpected status",
                    "check the relay Worker, or use `--via paste`",
                ));
            }
            Err(_) => {
                failures += 1;
                if failures >= RELAY_POLL_MAX_TRANSPORT_FAILURES {
                    return Err(Refusal::login(
                        "relay-poll-unreachable",
                        "the relay poll URL could not be reached repeatedly",
                        "check TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL, or unset it and paste the code",
                    ));
                }
            }
        }
        std::thread::sleep(interval);
    }
}

/// The relay page must be https (the phone reaches it over the internet),
/// with no userinfo, query or fragment (the redirect URI must match a
/// registered one exactly).
fn validate_relay_url(url: &str) -> Result<(), Refusal> {
    let ok = url.strip_prefix("https://").is_some_and(|rest| {
        let authority = rest.split('/').next().unwrap_or("");
        !authority.is_empty()
            && !authority.contains('@')
            && !rest.contains('?')
            && !rest.contains('#')
            && rest.len() > authority.len()
    });
    if ok {
        Ok(())
    } else {
        Err(Refusal::login(
            "relay-url-invalid",
            format!(
                "{RELAY_URL_ENV} must be an https URL with a path and no userinfo, query or fragment, exactly as registered with the Cloudflare App"
            ),
            format!("set {RELAY_URL_ENV}=https://<relay-host>{CALLBACK_PATH}"),
        ))
    }
}

// ── the login ──────────────────────────────────────────────────────────────

/// Everything the login touches, injected so the whole flow runs against the
/// fake Cloudflare and an in-memory store in tests. [`run_cli`] builds the
/// live one: `ReqwestHttpClient`, `VaultCloudflareTokenStore` (the only
/// production store; no env switch selects another), the real registered
/// ports, the real browser opener and the real terminal.
pub struct LoginDeps<'a> {
    pub http: &'a dyn HttpClient,
    pub store: &'a dyn CloudflareTokenStore,
    pub base_url: String,
    pub client_id: String,
    pub relay_url: Option<String>,
    pub relay_poll_url: Option<String>,
    pub loopback_ports: Vec<u16>,
    /// Opens the system browser on a URL. Receives the authorize URL only.
    pub open_browser: &'a dyn Fn(&str) -> Result<(), String>,
    pub desktop_with_opener: bool,
    pub stdin_is_terminal: bool,
    /// Reads one pasted line from the terminal.
    pub read_paste: &'a mut dyn FnMut() -> Result<String, String>,
    pub litmus_stop: bool,
    pub host_is_forge: bool,
    pub window: Duration,
    pub poll_interval: Duration,
    pub qr_tier: tillandsias_progress_tty::Tier,
    pub now_unix: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginOutcome {
    Stored { expires_at: Option<u64> },
    LitmusStopped,
}

fn forge_refusal(command: &'static str) -> Refusal {
    Refusal {
        command,
        reason: "in-forge".into(),
        why: "a forge never holds the host's Cloudflare credential; only the host's resident process may".into(),
        remedy: format!("run `tillandsias --{command}` on the host, outside any forge"),
    }
}

fn endpoint_refusal(reason: &str, what: &str) -> Refusal {
    Refusal::login(
        reason.to_string(),
        format!(
            "the discovery document names a plain-http, non-loopback {what}, and the code, verifier or token must never travel in clear"
        ),
        "check TILLANDSIAS_CLOUDFLARE_BASE_URL; the default is https://dash.cloudflare.com",
    )
}

/// The login: receiver selection, `begin`, the receiver, the Vault preflight,
/// the exchange, the store. Progress and the QR go to `out`; a refusal is the
/// `Err`.
pub fn login(
    via: Option<Via>,
    deps: &mut LoginDeps<'_>,
    out: &mut dyn Write,
) -> Result<LoginOutcome, Refusal> {
    if deps.host_is_forge {
        return Err(forge_refusal("cloudflare-login"));
    }
    let via =
        via.unwrap_or_else(|| default_via(deps.desktop_with_opener, deps.relay_url.is_some()));

    // Receiver preconditions, before any network call.
    if let Some(relay) = deps.relay_url.as_deref()
        && via != Via::Loopback
    {
        validate_relay_url(relay)?;
    }
    if let Some(poll) = deps.relay_poll_url.as_deref()
        && via == Via::Qr
        && !vault_bootstrap::cloudflare_token_endpoint_is_safe(poll)
    {
        return Err(Refusal::login(
            "relay-poll-url-not-https",
            "the relay poll URL hands back an authorization code, so it must be https",
            format!("set {RELAY_POLL_URL_ENV} to an https URL, or unset it and paste the code"),
        ));
    }
    let mut listener = None;
    let redirect_uri = match via {
        Via::Qr => match deps.relay_url.clone() {
            Some(r) => r,
            None => {
                return Err(Refusal::login(
                    "no-relay-configured",
                    format!(
                        "a phone that scans the QR cannot reach 127.0.0.1 on this host, so the QR redirect must be the operator's relay page, and {RELAY_URL_ENV} is not set"
                    ),
                    format!(
                        "use `--via loopback` on a desktop with a browser, or `--via paste`; or set {RELAY_URL_ENV}=https://<relay-host>{CALLBACK_PATH}"
                    ),
                ));
            }
        },
        Via::Paste => {
            if !deps.stdin_is_terminal {
                return Err(paste_needs_terminal());
            }
            match deps.relay_url.clone() {
                Some(r) => r,
                None => format!(
                    "http://127.0.0.1:{}{CALLBACK_PATH}",
                    deps.loopback_ports
                        .first()
                        .copied()
                        .unwrap_or(REGISTERED_LOOPBACK_PORTS[0])
                ),
            }
        }
        Via::Loopback => {
            let (l, port) = bind_first_free(&deps.loopback_ports)?;
            listener = Some(l);
            format!("http://127.0.0.1:{port}{CALLBACK_PATH}")
        }
    };

    let pending = cloudflare_oauth::begin(
        deps.http,
        &deps.base_url,
        &deps.client_id,
        &redirect_uri,
        CLOUDFLARE_LOGIN_SCOPES,
    )
    .map_err(|e| {
        Refusal::login(
            core_reason(&e),
            "the Cloudflare OpenID discovery document could not be read",
            "check the network and TILLANDSIAS_CLOUDFLARE_BASE_URL, then retry",
        )
    })?;
    let authorize_endpoint = pending.authorize_url.split('?').next().unwrap_or_default();
    if !vault_bootstrap::cloudflare_token_endpoint_is_safe(authorize_endpoint) {
        return Err(endpoint_refusal(
            "authorize-endpoint-not-https",
            "authorization endpoint",
        ));
    }
    if !vault_bootstrap::cloudflare_token_endpoint_is_safe(&pending.token_endpoint) {
        return Err(endpoint_refusal(
            "token-endpoint-not-https",
            "token endpoint",
        ));
    }

    show_authorize_url(via, &pending, deps, out);

    // The litmus switch (an ENVIRONMENT flag, never a reply's content) stops
    // here, as the GitHub device login does: it proves discovery, the URL and
    // the QR, and cannot reach a receiver, the exchange or any Vault access.
    if deps.litmus_stop {
        let _ = writeln!(
            out,
            "skip:cloudflare-login:litmus-stop-before-exchange (nothing was written)"
        );
        return Ok(LoginOutcome::LitmusStopped);
    }

    let deadline = Instant::now() + deps.window;
    let code = match via {
        Via::Loopback => {
            if (deps.open_browser)(&pending.authorize_url).is_err() {
                let _ = writeln!(
                    out,
                    "note:cloudflare-login:browser-not-opened (open the URL above in a browser on THIS machine)"
                );
            }
            let l = listener.take().expect("loopback bound above");
            let r = receive_loopback(&l, &pending.state, deadline);
            drop(l);
            r?
        }
        Via::Qr => match deps.relay_poll_url.as_deref() {
            Some(poll) => {
                let _ = writeln!(out, "Waiting for the relay to hand back the code...");
                poll_relay(
                    deps.http,
                    poll,
                    &pending.state,
                    deadline,
                    deps.poll_interval,
                )?
            }
            None => {
                if !deps.stdin_is_terminal {
                    return Err(paste_needs_terminal());
                }
                read_and_judge_paste(deps, &pending, out)?
            }
        },
        Via::Paste => read_and_judge_paste(deps, &pending, out)?,
    };

    // Vault preflight: an unreachable, sealed or refusing Vault is refused
    // BEFORE the single-use code is spent.
    let previous = deps.store.read_bundle().map_err(|r| {
        Refusal::login(
            format!("vault:{}", fixed_word(&r)),
            "the Vault that must hold the Cloudflare credential is unreachable, sealed or refused the host; the code was NOT exchanged",
            "run `tillandsias --init`, then `tillandsias --cloudflare-login` again",
        )
    })?;
    if previous.is_some() {
        let _ = writeln!(out, "note:cloudflare-login:replacing-the-stored-sign-in");
    }

    let bundle = cloudflare_oauth::exchange(
        deps.http,
        &pending,
        &pending.state,
        code.expose_to_token_endpoint(),
    )
    .map_err(|e| {
        let reason = core_reason(&e);
        let remedy = if reason.ends_with(":invalid_grant") {
            "the code was already used or expired; run `tillandsias --cloudflare-login` again"
        } else {
            REMEDY_RETRY
        };
        Refusal::login(
            format!("exchange:{reason}"),
            "the token endpoint did not exchange the code for a token pair",
            remedy,
        )
    })?;
    if bundle.access_token.is_empty() {
        return Err(Refusal::login(
            "exchange:token-response-unusable",
            "the token endpoint answered without an access token",
            REMEDY_RETRY,
        ));
    }

    let expires_at = bundle.expires_in.map(|s| deps.now_unix.saturating_add(s));
    let record = CloudflareTokenBundle {
        access_token: bundle.access_token.clone(),
        expires_at,
        account_id: previous.as_ref().and_then(|p| p.account_id.clone()),
        client_id: deps.client_id.clone(),
        refresh_token: bundle.refresh_token.clone().filter(|r| !r.is_empty()),
        refresh_token_expires_at: None,
    };
    vault_bootstrap::store_cloudflare_token_bundle(deps.store, &record).map_err(|r| {
        Refusal::login(
            format!("store-failed:{}", fixed_word(&r)),
            "the token pair was issued but could not be stored in Vault; it exists only in this exiting process",
            "run `tillandsias --init`, then `tillandsias --cloudflare-login` again",
        )
    })?;

    let _ = writeln!(out, "ok:cloudflare-login:stored");
    let _ = writeln!(
        out,
        "  records: {CLOUDFLARE_TOKEN_PATH}, {}",
        if record.refresh_token.is_some() {
            CLOUDFLARE_REFRESH_PATH
        } else {
            "(no refresh token issued)"
        }
    );
    match bundle.expires_in {
        Some(s) => {
            let _ = writeln!(out, "  expires: in {s} s (rotated automatically)");
        }
        None => {
            let _ = writeln!(
                out,
                "  expires: expiry unknown (Cloudflare did not report it)"
            );
        }
    }
    Ok(LoginOutcome::Stored { expires_at })
}

fn paste_needs_terminal() -> Refusal {
    Refusal::login(
        "paste-needs-a-terminal",
        "--cloudflare-login reads the pasted authorization CODE (not a token) from a terminal; a pipe or file is refused so the code never passes through another process or a file",
        "run it in a terminal, or use `--via loopback` on a desktop with a browser, or set TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL for `--via qr`",
    )
}

fn read_and_judge_paste(
    deps: &mut LoginDeps<'_>,
    pending: &Pending,
    out: &mut dyn Write,
) -> Result<AuthCode, Refusal> {
    let _ = writeln!(
        out,
        "Paste the line the relay page shows (code=…&state=…), or the whole address-bar URL, then press Enter (input is hidden):"
    );
    let _ = out.flush();
    let line = (deps.read_paste)().map_err(|_| {
        Refusal::login(
            "paste-unreadable",
            "the terminal closed before a line was pasted",
            REMEDY_RETRY,
        )
    })?;
    judge_pasted(&line, &pending.state)
}

fn show_authorize_url(via: Via, pending: &Pending, deps: &LoginDeps<'_>, out: &mut dyn Write) {
    match via {
        Via::Loopback => {
            let _ = writeln!(
                out,
                "Opening your browser to sign in to Cloudflare. If it does not open, visit this URL on THIS machine:"
            );
            let _ = writeln!(out, "  {}", pending.authorize_url);
        }
        Via::Qr => {
            let _ = writeln!(
                out,
                "\nScan this QR code with your phone to sign in to Cloudflare:\n"
            );
            match crate::render_terminal_qr_in(&pending.authorize_url, deps.qr_tier) {
                Ok(qr) => {
                    let _ = write!(out, "{qr}");
                }
                Err(_) => {
                    let _ = writeln!(out, "note:cloudflare-login:qr-unrenderable");
                }
            }
            let _ = writeln!(out);
            let _ = writeln!(out, "  Or open: {}", pending.authorize_url);
        }
        Via::Paste => {
            let _ = writeln!(
                out,
                "Open this URL in any browser and approve the Tillandsias App:"
            );
            let _ = writeln!(out, "  {}", pending.authorize_url);
        }
    }
    let _ = out.flush();
}

// ── the logout ─────────────────────────────────────────────────────────────

pub struct LogoutDeps<'a> {
    pub http: &'a dyn HttpClient,
    pub store: &'a dyn CloudflareTokenStore,
    pub base_url: String,
    pub host_is_forge: bool,
}

/// `--cloudflare-logout`: revoke best-effort (refresh token, then access
/// token), then delete `secret/cloudflare/refresh` and
/// `secret/cloudflare/token`. `secret/cloudflare/mesh` is never touched.
pub fn logout(deps: &LogoutDeps<'_>, out: &mut dyn Write) -> Result<(), Refusal> {
    if deps.host_is_forge {
        return Err(forge_refusal("cloudflare-logout"));
    }
    let stored = deps.store.read_bundle().map_err(|r| {
        Refusal::logout(
            format!("vault:{}", fixed_word(&r)),
            "the Vault that holds the Cloudflare credential is unreachable, sealed or refused the host; nothing was revoked or deleted",
            "run `tillandsias --init`, then `tillandsias --cloudflare-logout` again",
        )
    })?;
    match &stored {
        Some(b) => revoke_best_effort(deps, b, out),
        None => {
            let _ = writeln!(out, "note:cloudflare-logout:no-stored-sign-in");
        }
    }
    vault_bootstrap::delete_cloudflare_token_bundle(deps.store).map_err(|r| {
        Refusal::logout(
            format!("delete-failed:{}", fixed_word(&r)),
            "a Cloudflare record could not be deleted from Vault (the reason names which one remains)",
            "run `tillandsias --init`, then `tillandsias --cloudflare-logout` again",
        )
    })?;
    let _ = writeln!(out, "ok:cloudflare-logout:deleted");
    let _ = writeln!(
        out,
        "  deleted: {CLOUDFLARE_TOKEN_PATH}, {CLOUDFLARE_REFRESH_PATH}; secret/cloudflare/mesh left untouched"
    );
    Ok(())
}

fn revoke_best_effort(deps: &LogoutDeps<'_>, b: &CloudflareTokenBundle, out: &mut dyn Write) {
    let endpoint = match cloudflare_oauth::discover_revocation_endpoint(deps.http, &deps.base_url) {
        Ok(Some(e)) => e,
        Ok(None) => {
            let _ = writeln!(
                out,
                "note:cloudflare-logout:revoke-skipped:no-revocation-endpoint"
            );
            return;
        }
        Err(e) => {
            let _ = writeln!(
                out,
                "note:cloudflare-logout:revoke-skipped:{}",
                core_reason(&e)
            );
            return;
        }
    };
    if !vault_bootstrap::cloudflare_token_endpoint_is_safe(&endpoint) {
        let _ = writeln!(
            out,
            "note:cloudflare-logout:revoke-skipped:endpoint-not-https"
        );
        return;
    }
    let mut tokens: Vec<(&str, &str)> = Vec::new();
    if let Some(r) = b.refresh_token.as_deref().filter(|r| !r.is_empty()) {
        tokens.push(("refresh-token", r));
    }
    tokens.push(("access-token", b.access_token.as_str()));
    for (label, token) in tokens {
        match cloudflare_oauth::revoke(deps.http, &endpoint, &b.client_id, token) {
            Ok(()) => {
                let _ = writeln!(out, "ok:cloudflare-logout:revoked:{label}");
            }
            Err(e) => {
                let _ = writeln!(
                    out,
                    "note:cloudflare-logout:revoke-failed:{label}:{}",
                    core_reason(&e)
                );
            }
        }
    }
}

// ── the command line ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Login { via: Option<Via> },
    Logout,
}

/// A flag this command does not take is named in the refusal only when it
/// LOOKS like a flag; a positional argument is never echoed (it might be a
/// code someone pasted onto the command line).
fn describe_arg(a: &str) -> String {
    let looks_like_flag = a.len() <= 40
        && a.starts_with("--")
        && a[2..]
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if looks_like_flag {
        format!("`{a}`")
    } else {
        "a positional argument (not echoed)".to_string()
    }
}

/// Parse `--cloudflare-login [--via loopback|qr|paste] [--debug]` or
/// `--cloudflare-logout [--debug]`. Anything else is refused.
pub fn parse_args(args: &[String]) -> Result<Command, Refusal> {
    let login = args.iter().any(|a| a == "--cloudflare-login");
    let logout = args.iter().any(|a| a == "--cloudflare-logout");
    let cmd: &'static str = if logout && !login {
        "cloudflare-logout"
    } else {
        "cloudflare-login"
    };
    let refuse = |reason: &str, why: String, remedy: &str| Refusal {
        command: cmd,
        reason: fixed_word(reason),
        why,
        remedy: remedy.to_string(),
    };
    if login && logout {
        return Err(refuse(
            "both-login-and-logout",
            "--cloudflare-login and --cloudflare-logout were both given".into(),
            "run one of them",
        ));
    }
    let mut via = None;
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--cloudflare-login" | "--cloudflare-logout" | "--debug" => {}
            "--via" if login => {
                let v = args.get(i + 1).map(String::as_str).unwrap_or("");
                via = Some(Via::parse(v).ok_or_else(|| {
                    refuse(
                        "bad-via",
                        "--via takes exactly one of loopback, qr, paste".into(),
                        "tillandsias --cloudflare-login --via loopback|qr|paste",
                    )
                })?);
                i += 1;
            }
            _ => {
                let why = if a.starts_with('-') {
                    format!("{} is not an option of --{cmd}", describe_arg(a))
                } else {
                    format!(
                        "--{cmd} takes {}; an authorization code is pasted on the terminal under --via paste, never put on the command line (argv is visible to every process on the host)",
                        describe_arg(a)
                    )
                };
                return Err(refuse(
                    "unsupported-argument",
                    why,
                    "tillandsias --cloudflare-login [--via loopback|qr|paste] [--debug] | tillandsias --cloudflare-logout [--debug]",
                ));
            }
        }
        i += 1;
    }
    Ok(if logout {
        Command::Logout
    } else {
        Command::Login { via }
    })
}

/// The system browser opener, if one is on PATH.
fn browser_opener() -> Option<std::path::PathBuf> {
    let name = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}

/// Open `url` with the opener. The URL is the authorize URL (public data
/// only); nothing secret is placed in argv or in the child's environment.
fn open_with(opener: &std::path::Path, url: &str) -> Result<(), String> {
    let mut child = std::process::Command::new(opener)
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| "opener-spawn-failed".to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// One line from the terminal with echo OFF (restored before returning), at
/// most [`MAX_PASTE_BYTES`].
fn read_paste_line_from_terminal() -> Result<String, String> {
    let stdin = std::io::stdin();
    #[cfg(unix)]
    let restore = {
        use std::os::fd::AsRawFd;
        let fd = stdin.as_raw_fd();
        // SAFETY: tcgetattr/tcsetattr on our own stdin fd with a zeroed,
        // then kernel-filled, termios; restored below on every path.
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(fd, &mut t) == 0 {
                let saved = t;
                t.c_lflag &= !libc::ECHO;
                libc::tcsetattr(fd, libc::TCSANOW, &t);
                Some((fd, saved))
            } else {
                None
            }
        }
    };
    let mut line = String::new();
    let r = stdin.lock().take(MAX_PASTE_BYTES).read_line(&mut line);
    #[cfg(unix)]
    if let Some((fd, saved)) = restore {
        // SAFETY: restores the termios captured above on the same fd.
        unsafe {
            libc::tcsetattr(fd, libc::TCSANOW, &saved);
        }
        eprintln!();
    }
    match r {
        Ok(0) | Err(_) => Err("stdin-closed".into()),
        Ok(_) => Ok(line),
    }
}

/// The binary's entry: parse, build the live dependencies, run, print the
/// verdict. Returns the process exit code.
pub fn run_cli(args: &[String]) -> i32 {
    use std::io::IsTerminal;
    let cmd = match parse_args(args) {
        Ok(c) => c,
        Err(r) => {
            eprint!("{}", r.render());
            return 2;
        }
    };
    let debug = args.iter().any(|a| a == "--debug");
    let http = cloudflare_oauth::ReqwestHttpClient::default();
    let store = vault_bootstrap::VaultCloudflareTokenStore { debug };
    let host_is_forge = std::env::var("TILLANDSIAS_HOST_KIND").as_deref() == Ok("forge");
    let nonempty = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let mut stdout = std::io::stdout();
    let result = match cmd {
        Command::Logout => logout(
            &LogoutDeps {
                http: &http,
                store: &store,
                base_url: cloudflare_oauth::base_url(),
                host_is_forge,
            },
            &mut stdout,
        ),
        Command::Login { via } => {
            let opener = browser_opener();
            let open = |url: &str| match opener.as_deref() {
                Some(o) => open_with(o, url),
                None => Err("no-opener".to_string()),
            };
            let mut read = read_paste_line_from_terminal;
            let mut deps = LoginDeps {
                http: &http,
                store: &store,
                base_url: cloudflare_oauth::base_url(),
                client_id: cloudflare_oauth::client_id(),
                relay_url: nonempty(RELAY_URL_ENV),
                relay_poll_url: nonempty(RELAY_POLL_URL_ENV),
                loopback_ports: REGISTERED_LOOPBACK_PORTS.to_vec(),
                open_browser: &open,
                desktop_with_opener: crate::has_graphical_session() && opener.is_some(),
                stdin_is_terminal: std::io::stdin().is_terminal(),
                read_paste: &mut read,
                litmus_stop: std::env::var_os("LITMUS_PODMAN_MODE").is_some(),
                host_is_forge,
                window: LOGIN_WINDOW,
                poll_interval: RELAY_POLL_INTERVAL,
                qr_tier: crate::qr_tier(),
                now_unix: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            };
            login(via, &mut deps, &mut stdout).map(|_| ())
        }
    };
    match result {
        Ok(()) => 0,
        Err(r) => {
            let _ = stdout.flush();
            eprint!("{}", r.render());
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloudflare_oauth::HttpResponse;
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::rc::Rc;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    // ── the in-memory Vault seam (the 1505-iysn CloudflareTokenStore trait) ──

    #[derive(Default)]
    pub(super) struct MemStore {
        records: Mutex<BTreeMap<String, serde_json::Value>>,
        pub(super) touched: AtomicUsize,
        fail_read: bool,
    }

    impl MemStore {
        fn with_mesh() -> Self {
            let s = MemStore::default();
            s.records.lock().unwrap().insert(
                "secret/cloudflare/mesh".into(),
                serde_json::json!({"client_id": "mesh-id", "team_name": "tillandsias-vpn-01234567"}),
            );
            s
        }
        fn snapshot(&self) -> BTreeMap<String, serde_json::Value> {
            self.records.lock().unwrap().clone()
        }
        fn touches(&self) -> usize {
            self.touched.load(Ordering::SeqCst)
        }
    }

    impl CloudflareTokenStore for MemStore {
        fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            if self.fail_read {
                return Err("vault-sealed".into());
            }
            let m = self.records.lock().unwrap();
            let Some(t) = m.get(CLOUDFLARE_TOKEN_PATH) else {
                return Ok(None);
            };
            let r = m.get(CLOUDFLARE_REFRESH_PATH);
            Ok(Some(CloudflareTokenBundle {
                access_token: t["access_token"].as_str().unwrap_or_default().into(),
                expires_at: t["expires_at"].as_u64(),
                account_id: t["account_id"].as_str().map(String::from),
                client_id: t["client_id"].as_str().unwrap_or_default().into(),
                refresh_token: r
                    .and_then(|r| r["refresh_token"].as_str())
                    .map(String::from),
                refresh_token_expires_at: None,
            }))
        }
        fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            self.records.lock().unwrap().insert(path.into(), value);
            Ok(())
        }
        fn delete_record(&self, path: &str) -> Result<(), String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            self.records.lock().unwrap().remove(path);
            Ok(())
        }
    }

    /// An HttpClient that must never be reached: proves a refusal happened
    /// before ANY network call.
    struct NoNetwork;
    impl HttpClient for NoNetwork {
        fn get(&self, _: &str) -> Result<HttpResponse, String> {
            panic!("no network call may happen on this path")
        }
        fn post_form(&self, _: &str, _: &[(&str, &str)]) -> Result<HttpResponse, String> {
            panic!("no network call may happen on this path")
        }
    }

    /// A scripted HttpClient: discovery at `https://fake.invalid`, other GETs
    /// and POSTs answered from queues keyed by URL prefix; records every call.
    #[derive(Default)]
    struct Scripted {
        gets: RefCell<Vec<(String, HttpResponse)>>,
        posts: RefCell<Vec<(String, HttpResponse)>>,
        calls: RefCell<Vec<String>>,
    }
    const BASE: &str = "https://fake.invalid";
    impl Scripted {
        fn with_discovery(revocation: &str) -> Self {
            let s = Scripted::default();
            s.gets.borrow_mut().push((
                format!("{BASE}/.well-known/openid-configuration"),
                HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "authorization_endpoint": format!("{BASE}/oauth2/auth"),
                        "token_endpoint": format!("{BASE}/oauth2/token"),
                        "revocation_endpoint": revocation,
                    })
                    .to_string(),
                },
            ));
            s
        }
        fn get_then(self, prefix: &str, status: u16, body: &str) -> Self {
            self.gets.borrow_mut().push((
                prefix.to_string(),
                HttpResponse {
                    status,
                    body: body.into(),
                },
            ));
            self
        }
        fn post_then(self, prefix: &str, status: u16, body: &str) -> Self {
            self.posts.borrow_mut().push((
                prefix.to_string(),
                HttpResponse {
                    status,
                    body: body.into(),
                },
            ));
            self
        }
        fn answer(
            q: &RefCell<Vec<(String, HttpResponse)>>,
            url: &str,
        ) -> Result<HttpResponse, String> {
            let mut q = q.borrow_mut();
            let i = q
                .iter()
                .position(|(p, _)| url.starts_with(p.as_str()))
                .ok_or_else(|| "scripted: nothing for this url".to_string())?;
            // Discovery answers every time; everything else is consumed.
            if q[i].0.ends_with("openid-configuration") {
                Ok(q[i].1.clone())
            } else {
                Ok(q.remove(i).1)
            }
        }
    }
    impl HttpClient for Scripted {
        fn get(&self, url: &str) -> Result<HttpResponse, String> {
            self.calls.borrow_mut().push(format!("GET {url}"));
            Self::answer(&self.gets, url)
        }
        fn post_form(&self, url: &str, _: &[(&str, &str)]) -> Result<HttpResponse, String> {
            self.calls.borrow_mut().push(format!("POST {url}"));
            Self::answer(&self.posts, url)
        }
    }

    const LEAK_A: &str = "cf-at-KC5FPROBE-19e2d7c4b8a1";
    const LEAK_R: &str = "cf-rt-KC5FPROBE-6b3f0a9d2e57";

    fn assert_absent(text: &str, secrets: &[&str], what: &str) {
        for s in secrets {
            assert!(s.len() >= 8, "probe too short to mean anything");
            assert!(!text.contains(s), "{what} carries a secret ({s}): {text}");
        }
    }

    fn params(q: &str) -> Vec<(String, String)> {
        parse_query(q).expect("valid query")
    }

    // ── the state check comes first ──────────────────────────────────────

    #[test]
    fn cloudflare_login_state_is_checked_before_error_and_code() {
        let st = "S".repeat(43);
        let wrong = "T".repeat(43);
        for q in [
            format!("state={wrong}&error=access_denied"),
            format!("error=access_denied&state={wrong}"),
            format!("code=abc123&state={wrong}"),
            format!("code=bad%20code&state={wrong}"),
            "code=abc123".to_string(),
            format!("code=abc123&state={st}&state={st}"),
            format!("code=abc123&state={}", &st[..42]),
        ] {
            let e = judge_callback(&params(&q), &st).unwrap_err();
            assert_eq!(
                e.verdict(),
                "refused:cloudflare-login:state-mismatch",
                "{q}"
            );
        }
        let e =
            judge_callback(&params(&format!("error=access_denied&state={st}")), &st).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:access-denied");
        let e = judge_callback(&params(&format!("error={LEAK_A}&state={st}&code=abc")), &st)
            .unwrap_err();
        assert_eq!(
            e.verdict(),
            "refused:cloudflare-login:authorization-error:unrecognised-error-code"
        );
        assert_absent(&e.render(), &[LEAK_A], "refusal");
        let e = judge_callback(&params(&format!("state={st}")), &st).unwrap_err();
        assert_eq!(e.reason, "callback-without-code");
        for bad in ["a%20b", "a%3Cb", "a%0Ab", "", "a\"b"] {
            let e = judge_callback(&params(&format!("code={bad}&state={st}")), &st);
            assert!(e.is_err(), "{bad:?} must be refused");
        }
        let code = judge_callback(&params(&format!("code=ory_ac_Ab-9.x~y&state={st}")), &st)
            .expect("a well-formed code with the right state");
        assert_eq!(code.expose_to_token_endpoint(), "ory_ac_Ab-9.x~y");
        assert_eq!(format!("{code:?}"), "AuthCode(<redacted>)");
    }

    #[test]
    fn cloudflare_login_paste_needs_the_state_with_the_code() {
        let st = "Q".repeat(43);
        let url =
            format!("http://127.0.0.1:48631/tillandsias/cloudflare/callback?code=c0de&state={st}");
        assert!(judge_pasted(&url, &st).is_ok());
        assert!(judge_pasted(&format!("  code=c0de&state={st}\n"), &st).is_ok());
        assert_eq!(
            judge_pasted("c0de", &st).unwrap_err().reason,
            "paste-needs-code-and-state"
        );
        assert_eq!(judge_pasted("  \n", &st).unwrap_err().reason, "paste-empty");
        assert_eq!(
            judge_pasted(&format!("code=c0de&state={st}x"), &st)
                .unwrap_err()
                .reason,
            "state-mismatch"
        );
    }

    #[test]
    fn cloudflare_login_default_receiver_order() {
        assert_eq!(default_via(true, true), Via::Loopback);
        assert_eq!(default_via(true, false), Via::Loopback);
        assert_eq!(default_via(false, true), Via::Qr);
        assert_eq!(default_via(false, false), Via::Paste);
    }

    #[test]
    fn cloudflare_login_loopback_binds_127_0_0_1_on_registered_ports_only() {
        assert_eq!(REGISTERED_LOOPBACK_PORTS, [48631, 48632, 48633]);
        assert_eq!(CALLBACK_PATH, "/tillandsias/cloudflare/callback");
        let (l, _) = bind_first_free(&[0]).unwrap();
        let addr = l.local_addr().unwrap();
        assert_eq!(
            addr.ip(),
            std::net::IpAddr::V4(Ipv4Addr::LOCALHOST),
            "never 0.0.0.0"
        );
        // Every port of the list taken -> the named refusal.
        let held: Vec<TcpListener> = (0..3)
            .map(|_| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap())
            .collect();
        let ports: Vec<u16> = held
            .iter()
            .map(|h| h.local_addr().unwrap().port())
            .collect();
        let e = bind_first_free(&ports).unwrap_err();
        assert_eq!(
            e.verdict(),
            "refused:cloudflare-login:no-registered-port-free"
        );
        // CONTROL: a freed port in the list binds. A test running in
        // parallel (the fake-server arms each bind an ephemeral port) can
        // take a port in the instant after it is freed, so the control
        // retries with fresh ports instead of racing one (land96, 2026-09-29).
        drop(held);
        let mut bound = None;
        for _ in 0..5 {
            let probe = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            let freed = probe.local_addr().unwrap().port();
            drop(probe);
            if let Ok((_l, got)) = bind_first_free(&[freed]) {
                bound = Some((freed, got));
                break;
            }
        }
        let (freed, got) = bound.expect("a freed port binds within five attempts");
        assert_eq!(got, freed);
    }

    fn http_get(port: u16, target: &str) -> String {
        let mut s = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect");
        write!(s, "GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
        let mut buf = String::new();
        let _ = s.read_to_string(&mut buf);
        buf
    }

    #[test]
    fn cloudflare_login_loopback_takes_exactly_one_callback_then_closes() {
        let st = "L".repeat(43);
        let (l, port) = bind_first_free(&[0]).unwrap();
        let st2 = st.clone();
        let h = std::thread::spawn(move || {
            let r = receive_loopback(&l, &st2, Instant::now() + Duration::from_secs(20));
            drop(l);
            r
        });
        // A stray request is answered 404 and does not end the wait.
        let stray = http_get(port, "/favicon.ico");
        assert!(stray.starts_with("HTTP/1.1 404"), "{stray}");
        let page = http_get(port, &format!("{CALLBACK_PATH}?code=c0de-1&state={st}"));
        assert!(page.starts_with("HTTP/1.1 200"), "{page}");
        assert!(
            !page.contains("c0de-1") && !page.contains(&st),
            "the page echoes nothing"
        );
        let code = h.join().unwrap().expect("callback accepted");
        assert_eq!(code.expose_to_token_endpoint(), "c0de-1");
        // Exactly one: the port is closed now.
        assert!(
            TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err(),
            "the listener must be closed after one callback"
        );
    }

    #[test]
    fn cloudflare_login_loopback_wrong_state_is_refused_and_closes() {
        let st = "M".repeat(43);
        let (l, port) = bind_first_free(&[0]).unwrap();
        let st2 = st.clone();
        let h = std::thread::spawn(move || {
            let r = receive_loopback(&l, &st2, Instant::now() + Duration::from_secs(20));
            drop(l);
            r
        });
        let page = http_get(port, &format!("{CALLBACK_PATH}?code=c0de&state=forged"));
        assert!(page.starts_with("HTTP/1.1 400"), "{page}");
        let e = h.join().unwrap().unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:state-mismatch");
        assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
    }

    #[test]
    fn cloudflare_login_loopback_times_out_and_closes() {
        let (l, port) = bind_first_free(&[0]).unwrap();
        let e = receive_loopback(&l, "x", Instant::now() + Duration::from_millis(200)).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:timeout");
        drop(l);
        assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
    }

    #[test]
    fn cloudflare_login_parse_args() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            parse_args(&a(&["--cloudflare-login"])).unwrap(),
            Command::Login { via: None }
        );
        assert_eq!(
            parse_args(&a(&["--cloudflare-login", "--via", "qr", "--debug"])).unwrap(),
            Command::Login { via: Some(Via::Qr) }
        );
        assert_eq!(
            parse_args(&a(&["--cloudflare-logout"])).unwrap(),
            Command::Logout
        );
        assert_eq!(
            parse_args(&a(&["--cloudflare-login", "--via", "device"]))
                .unwrap_err()
                .reason,
            "bad-via"
        );
        assert_eq!(
            parse_args(&a(&["--cloudflare-login", "--cloudflare-logout"]))
                .unwrap_err()
                .reason,
            "both-login-and-logout"
        );
        assert_eq!(
            parse_args(&a(&["--cloudflare-logout", "--via", "qr"]))
                .unwrap_err()
                .reason,
            "unsupported-argument"
        );
        // A positional argument (maybe a pasted code) is refused and NOT echoed.
        let e = parse_args(&a(&["--cloudflare-login", "--via", "paste", LEAK_A])).unwrap_err();
        assert_eq!(e.reason, "unsupported-argument");
        assert_absent(&e.render(), &[LEAK_A], "argv refusal");
        assert!(e.why.contains("never put on the command line"), "{}", e.why);
    }

    #[test]
    fn cloudflare_login_refusals_carry_why_and_remedy_and_fixed_words() {
        let r = Refusal::login("x:y-z_1", "because", "do this");
        assert_eq!(
            r.render(),
            "refused:cloudflare-login:x:y-z_1\n  why: because\n  remedy: do this\n"
        );
        assert_eq!(
            fixed_word(&format!("exchange:{LEAK_A} and more")),
            "unrecognised"
        );
        assert_eq!(
            fixed_word("store-failed:vault-sealed"),
            "store-failed:vault-sealed"
        );
        assert_eq!(
            core_reason("refused:cloudflare-login:token-exchange-http-400:invalid_grant"),
            "token-exchange-http-400:invalid_grant"
        );
    }

    #[test]
    fn cloudflare_login_relay_url_must_be_https_without_query() {
        assert!(
            validate_relay_url("https://relay.example/tillandsias/cloudflare/callback").is_ok()
        );
        for bad in [
            "http://relay.example/tillandsias/cloudflare/callback",
            "https://relay.example",
            "https://user@relay.example/cb",
            "https://relay.example/cb?x=1",
            "https://relay.example/cb#f",
        ] {
            assert_eq!(
                validate_relay_url(bad).unwrap_err().reason,
                "relay-url-invalid",
                "{bad}"
            );
        }
    }

    struct Harness {
        store: MemStore,
        paste: Vec<String>,
    }

    fn deps<'a>(
        http: &'a dyn HttpClient,
        store: &'a MemStore,
        open: &'a dyn Fn(&str) -> Result<(), String>,
        read: &'a mut dyn FnMut() -> Result<String, String>,
    ) -> LoginDeps<'a> {
        LoginDeps {
            http,
            store,
            base_url: BASE.into(),
            client_id: "fake-client".into(),
            relay_url: None,
            relay_poll_url: None,
            loopback_ports: vec![0],
            open_browser: open,
            desktop_with_opener: false,
            stdin_is_terminal: false,
            read_paste: read,
            litmus_stop: false,
            host_is_forge: false,
            window: Duration::from_secs(20),
            poll_interval: Duration::from_millis(10),
            qr_tier: tillandsias_progress_tty::Tier::Plain,
            now_unix: 1_000_000,
        }
    }

    fn no_open(_: &str) -> Result<(), String> {
        panic!("no browser may be opened on this path")
    }

    #[test]
    fn cloudflare_login_qr_without_relay_is_refused_before_any_network_call() {
        let h = Harness {
            store: MemStore::default(),
            paste: vec![],
        };
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = deps(&NoNetwork, &h.store, &no_open, &mut read);
        let mut out = Vec::new();
        let e = login(Some(Via::Qr), &mut d, &mut out).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:no-relay-configured");
        let text = e.render();
        assert!(
            text.contains("--via loopback") && text.contains("--via paste"),
            "{text}"
        );
        assert_eq!(h.store.touches(), 0);
        assert!(h.paste.is_empty());
        // CONTROL: with a relay configured the same call gets past that gate
        // (to discovery, then the litmus stop).
        let http = Scripted::with_discovery("");
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = deps(&http, &h.store, &no_open, &mut read);
        d.relay_url = Some("https://relay.example/tillandsias/cloudflare/callback".into());
        d.litmus_stop = true;
        let mut out = Vec::new();
        assert_eq!(
            login(Some(Via::Qr), &mut d, &mut out).unwrap(),
            LoginOutcome::LitmusStopped
        );
    }

    #[test]
    fn cloudflare_login_paste_without_a_terminal_is_refused_before_any_network_call() {
        let store = MemStore::default();
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = deps(&NoNetwork, &store, &no_open, &mut read);
        let mut out = Vec::new();
        let e = login(Some(Via::Paste), &mut d, &mut out).unwrap_err();
        assert_eq!(
            e.verdict(),
            "refused:cloudflare-login:paste-needs-a-terminal"
        );
        assert!(e.why.contains("CODE (not a token)"), "{}", e.why);
        assert_eq!(store.touches(), 0);
    }

    #[test]
    fn cloudflare_login_and_logout_refuse_in_a_forge_without_touching_anything() {
        let store = MemStore::with_mesh();
        let before = store.snapshot();
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = deps(&NoNetwork, &store, &no_open, &mut read);
        d.host_is_forge = true;
        let e = login(None, &mut d, &mut Vec::new()).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:in-forge");
        let e = logout(
            &LogoutDeps {
                http: &NoNetwork,
                store: &store,
                base_url: BASE.into(),
                host_is_forge: true,
            },
            &mut Vec::new(),
        )
        .unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-logout:in-forge");
        assert_eq!(store.touches(), 0);
        assert_eq!(store.snapshot(), before);
    }

    #[test]
    fn cloudflare_login_relay_poll_state_first_then_code() {
        let st = "P".repeat(43);
        let poll = "https://relay.example/poll";
        let http = Scripted::default()
            .get_then(poll, 404, "")
            .get_then(poll, 202, "")
            .get_then(
                poll,
                200,
                &serde_json::json!({"state": st, "code": "c0de"}).to_string(),
            );
        let code = poll_relay(
            &http,
            poll,
            &st,
            Instant::now() + Duration::from_secs(5),
            Duration::from_millis(1),
        )
        .unwrap();
        assert_eq!(code.expose_to_token_endpoint(), "c0de");
        assert_eq!(http.calls.borrow().len(), 3);
        // A forged state in the relay's answer is refused.
        let http = Scripted::default().get_then(
            poll,
            200,
            &serde_json::json!({"state": "forged", "code": "c0de"}).to_string(),
        );
        let e = poll_relay(
            &http,
            poll,
            &st,
            Instant::now() + Duration::from_secs(5),
            Duration::from_millis(1),
        )
        .unwrap_err();
        assert_eq!(e.reason, "state-mismatch");
        // A hostile body never reaches the refusal.
        let http = Scripted::default().get_then(poll, 200, &format!("not json {LEAK_A}"));
        let e = poll_relay(
            &http,
            poll,
            &st,
            Instant::now() + Duration::from_secs(5),
            Duration::from_millis(1),
        )
        .unwrap_err();
        assert_eq!(e.reason, "relay-poll-unusable");
        assert_absent(&e.render(), &[LEAK_A], "poll refusal");
    }

    #[test]
    fn cloudflare_login_vault_preflight_refuses_before_the_code_is_spent() {
        // A code arrives by paste, Vault is sealed -> refused with no POST to
        // the token endpoint (CONTROL below: with Vault up, the POST happens).
        let run = |fail_read: bool| {
            let http = Scripted::with_discovery("").post_then(
                &format!("{BASE}/oauth2/token"),
                200,
                &serde_json::json!({"access_token": LEAK_A, "refresh_token": LEAK_R, "expires_in": 3600})
                    .to_string(),
            );
            let store = MemStore {
                fail_read,
                ..MemStore::with_mesh()
            };
            let out = Rc::new(RefCell::new(Vec::new()));
            let out2 = out.clone();
            let mut read = move || -> Result<String, String> {
                let text = String::from_utf8(out2.borrow().clone()).unwrap();
                let url = text
                    .lines()
                    .find_map(|l| l.trim().strip_prefix(&format!("{BASE}/oauth2/auth?")))
                    .expect("authorize URL printed")
                    .to_string();
                let st = parse_query(&url)
                    .unwrap()
                    .into_iter()
                    .find(|(k, _)| k == "state")
                    .unwrap()
                    .1;
                Ok(format!("code=c0de&state={st}"))
            };
            let result;
            {
                let mut d = deps(&http, &store, &no_open, &mut read);
                d.stdin_is_terminal = true;
                let mut w = SharedOut(out.clone());
                result = login(Some(Via::Paste), &mut d, &mut w);
            }
            let posts = http
                .calls
                .borrow()
                .iter()
                .filter(|c| c.starts_with("POST"))
                .count();
            let text = String::from_utf8(out.borrow().clone()).unwrap();
            (result, posts, store.snapshot(), text)
        };
        let (r, posts, snap, _) = run(true);
        let e = r.unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:vault:vault-sealed");
        assert_eq!(
            posts, 0,
            "a sealed Vault must be refused before the exchange"
        );
        assert!(!snap.contains_key(CLOUDFLARE_TOKEN_PATH));
        let (r, posts, snap, text) = run(false);
        assert!(
            matches!(
                r,
                Ok(LoginOutcome::Stored {
                    expires_at: Some(1_003_600)
                })
            ),
            "{r:?}"
        );
        assert_eq!(posts, 1);
        assert_eq!(snap[CLOUDFLARE_TOKEN_PATH]["access_token"], LEAK_A);
        assert_eq!(snap[CLOUDFLARE_REFRESH_PATH]["refresh_token"], LEAK_R);
        assert!(snap.contains_key("secret/cloudflare/mesh"));
        assert!(text.contains("ok:cloudflare-login:stored"), "{text}");
        assert_absent(&text, &[LEAK_A, LEAK_R], "login output");
    }

    #[test]
    fn cloudflare_login_exchange_refusal_carries_no_response_bytes() {
        let http = Scripted::with_discovery("").post_then(
            &format!("{BASE}/oauth2/token"),
            400,
            &format!(r#"{{"error":"{LEAK_R}"}}"#),
        );
        let store = MemStore::default();
        let out = Rc::new(RefCell::new(Vec::new()));
        let out2 = out.clone();
        let mut read = move || -> Result<String, String> {
            let text = String::from_utf8(out2.borrow().clone()).unwrap();
            let st = text
                .split("state=")
                .nth(1)
                .unwrap()
                .split('&')
                .next()
                .unwrap()
                .to_string();
            Ok(format!("code=c0de&state={st}"))
        };
        let mut d = deps(&http, &store, &no_open, &mut read);
        d.stdin_is_terminal = true;
        let e = login(Some(Via::Paste), &mut d, &mut SharedOut(out.clone())).unwrap_err();
        assert_eq!(
            e.verdict(),
            "refused:cloudflare-login:exchange:token-exchange-http-400:unrecognised-error-code"
        );
        assert_absent(&e.render(), &[LEAK_R], "exchange refusal");
        assert!(!store.snapshot().contains_key(CLOUDFLARE_TOKEN_PATH));
    }

    #[test]
    fn cloudflare_logout_deletes_the_pair_and_keeps_mesh() {
        let store = MemStore::with_mesh();
        vault_bootstrap::store_cloudflare_token_bundle(
            &store,
            &CloudflareTokenBundle {
                access_token: LEAK_A.into(),
                expires_at: Some(5),
                account_id: None,
                client_id: "fake-client".into(),
                refresh_token: Some(LEAK_R.into()),
                refresh_token_expires_at: None,
            },
        )
        .unwrap();
        let before = store.snapshot();
        assert!(
            before.contains_key(CLOUDFLARE_TOKEN_PATH)
                && before.contains_key(CLOUDFLARE_REFRESH_PATH)
        );
        let revoke = format!("{BASE}/oauth2/revoke");
        let http = Scripted::with_discovery(&revoke)
            .post_then(&revoke, 200, "{}")
            .post_then(&revoke, 400, &format!(r#"{{"error":"{LEAK_A}"}}"#));
        let mut out = Vec::new();
        logout(
            &LogoutDeps {
                http: &http,
                store: &store,
                base_url: BASE.into(),
                host_is_forge: false,
            },
            &mut out,
        )
        .unwrap();
        let text = String::from_utf8(out).unwrap();
        let after = store.snapshot();
        assert!(!after.contains_key(CLOUDFLARE_TOKEN_PATH));
        assert!(!after.contains_key(CLOUDFLARE_REFRESH_PATH));
        assert_eq!(
            after["secret/cloudflare/mesh"],
            before["secret/cloudflare/mesh"]
        );
        assert!(text.contains("ok:cloudflare-logout:deleted"), "{text}");
        assert!(
            text.contains("ok:cloudflare-logout:revoked:refresh-token"),
            "{text}"
        );
        assert!(
            text.contains("note:cloudflare-logout:revoke-failed:access-token"),
            "{text}"
        );
        assert_absent(&text, &[LEAK_A, LEAK_R], "logout output");
        // A plain-http, non-loopback revocation endpoint is never sent a token.
        let store = MemStore::with_mesh();
        store
            .write_record(
                CLOUDFLARE_TOKEN_PATH,
                serde_json::json!({"access_token": LEAK_A, "client_id": "c"}),
            )
            .unwrap();
        let http = Scripted::with_discovery("http://evil.example/revoke");
        let mut out = Vec::new();
        logout(
            &LogoutDeps {
                http: &http,
                store: &store,
                base_url: BASE.into(),
                host_is_forge: false,
            },
            &mut out,
        )
        .unwrap();
        assert!(http.calls.borrow().iter().all(|c| !c.starts_with("POST")));
        assert!(!store.snapshot().contains_key(CLOUDFLARE_TOKEN_PATH));
    }

    #[test]
    fn cloudflare_logout_refuses_when_vault_is_unreadable() {
        let store = MemStore {
            fail_read: true,
            ..MemStore::with_mesh()
        };
        let before = store.snapshot();
        let e = logout(
            &LogoutDeps {
                http: &NoNetwork,
                store: &store,
                base_url: BASE.into(),
                host_is_forge: false,
            },
            &mut Vec::new(),
        )
        .unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-logout:vault:vault-sealed");
        assert_eq!(store.snapshot(), before);
    }

    /// A `Write` over a shared buffer so a test's fake browser / paste can
    /// read what the login printed so far.
    struct SharedOut(Rc<RefCell<Vec<u8>>>);
    impl Write for SharedOut {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.borrow_mut().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    // ── against the REAL tillandsias-fake-cloudflare (ignored; the script
    //    scripts/test-cloudflare-login.sh builds the fake and runs these) ──

    mod fake {
        use super::*;
        use std::io::BufReader;
        use std::path::{Path, PathBuf};
        use std::process::{Child, Stdio};

        pub(super) struct FakeServer {
            child: Child,
            pub(super) base_url: String,
            pub(super) ledger: PathBuf,
        }
        impl Drop for FakeServer {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }

        pub(super) fn start(name: &str) -> FakeServer {
            let bin = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_BIN")
                .map(PathBuf::from)
                .unwrap_or_else(|_| {
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join("../../target/debug/tillandsias-fake-cloudflare")
                });
            assert!(
                bin.exists(),
                "fake-cloudflare not found at {bin:?}; run scripts/test-cloudflare-login.sh"
            );
            let dir = std::env::temp_dir().join(format!("cf-login-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let ledger = dir.join("ledger.jsonl");
            let mut child = std::process::Command::new(&bin)
                .arg("--ledger")
                .arg(&ledger)
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn fake");
            let mut line = String::new();
            BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut line)
                .unwrap();
            let port: u16 = line.trim().parse().expect("port line");
            FakeServer {
                child,
                base_url: format!("http://127.0.0.1:{port}"),
                ledger,
            }
        }

        pub(super) fn ledger(p: &Path) -> Vec<serde_json::Value> {
            std::fs::read_to_string(p)
                .unwrap_or_default()
                .lines()
                .filter(|l| !l.is_empty())
                .map(|l| serde_json::from_str(l).unwrap())
                .collect()
        }

        pub(super) fn paths(p: &Path) -> Vec<String> {
            ledger(p)
                .iter()
                .map(|e| {
                    let path = e["path"].as_str().unwrap_or("");
                    path.split('?').next().unwrap_or("").to_string()
                })
                .collect()
        }

        /// The verifier and code the login actually sent, read from the
        /// fake's ledger (the only place outside the process they exist).
        pub(super) fn sent_verifier_and_code(p: &Path) -> (String, String) {
            let body = ledger(p)
                .into_iter()
                .find(|e| {
                    e["path"]
                        .as_str()
                        .unwrap_or("")
                        .starts_with("/oauth2/token")
                        && e["body"]
                            .as_str()
                            .unwrap_or("")
                            .contains("grant_type=authorization_code")
                })
                .expect("a code exchange in the ledger")["body"]
                .as_str()
                .unwrap()
                .to_string();
            let q = parse_query(&body).unwrap();
            let get = |k: &str| q.iter().find(|(kk, _)| kk == k).unwrap().1.clone();
            (get("code_verifier"), get("code"))
        }

        /// The operator's browser: GET the authorize URL with `auto=<mode>`,
        /// read the redirect's Location without following it.
        pub(super) fn consent(authorize_url: &str, mode: &str) -> String {
            let url = format!("{authorize_url}&auto={mode}");
            let rest = url.strip_prefix("http://").unwrap();
            let (authority, path) = rest.split_once('/').unwrap();
            let mut s = TcpStream::connect(authority).unwrap();
            write!(
                s,
                "GET /{path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            let mut buf = String::new();
            s.read_to_string(&mut buf).unwrap();
            buf.lines()
                .find_map(|l| {
                    l.strip_prefix("Location: ")
                        .or_else(|| l.strip_prefix("location: "))
                })
                .expect("Location")
                .trim()
                .to_string()
        }

        /// Follow a loopback Location like the browser would.
        pub(super) fn follow(location: &str) {
            let rest = location.strip_prefix("http://").unwrap();
            let (authority, path) = rest.split_once('/').unwrap();
            let mut s = TcpStream::connect(authority).unwrap();
            write!(
                s,
                "GET /{path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            let mut buf = String::new();
            let _ = s.read_to_string(&mut buf);
        }
    }

    fn browser(mode: &'static str, tamper_state: bool) -> impl Fn(&str) -> Result<(), String> {
        move |url: &str| {
            let url = url.to_string();
            std::thread::spawn(move || {
                let mut loc = fake::consent(&url, mode);
                if tamper_state {
                    loc = loc.replace("state=", "state=forged");
                }
                fake::follow(&loc);
            });
            Ok(())
        }
    }

    fn fake_deps<'a>(
        server: &fake::FakeServer,
        http: &'a dyn HttpClient,
        store: &'a MemStore,
        open: &'a dyn Fn(&str) -> Result<(), String>,
        read: &'a mut dyn FnMut() -> Result<String, String>,
    ) -> LoginDeps<'a> {
        let mut d = deps(http, store, open, read);
        d.base_url = server.base_url.clone();
        d
    }

    fn secrets_of(store: &MemStore) -> (String, String) {
        let s = store.snapshot();
        (
            s[CLOUDFLARE_TOKEN_PATH]["access_token"]
                .as_str()
                .unwrap()
                .to_string(),
            s[CLOUDFLARE_REFRESH_PATH]["refresh_token"]
                .as_str()
                .unwrap()
                .to_string(),
        )
    }

    // ARM loopback: ?auto=approve ends ok:cloudflare-login:stored and both
    // records are in the store; no token, verifier or code in the output.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_loopback_approve_stores() {
        let server = fake::start("loopback");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let store = MemStore::with_mesh();
        let open = browser("approve", false);
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = fake_deps(&server, &http, &store, &open, &mut read);
        let mut out = Vec::new();
        let r = login(Some(Via::Loopback), &mut d, &mut out);
        let text = String::from_utf8(out).unwrap();
        assert!(
            matches!(
                r,
                Ok(LoginOutcome::Stored {
                    expires_at: Some(_)
                })
            ),
            "{r:?}\n{text}"
        );
        assert!(text.contains("ok:cloudflare-login:stored"), "{text}");
        let (access, refresh) = secrets_of(&store);
        let (verifier, code) = fake::sent_verifier_and_code(&server.ledger);
        assert_absent(
            &text,
            &[&access, &refresh, &verifier, &code],
            "loopback login output",
        );
        assert!(store.snapshot().contains_key("secret/cloudflare/mesh"));
        assert_eq!(
            fake::paths(&server.ledger),
            vec![
                "/.well-known/openid-configuration",
                "/oauth2/auth",
                "/oauth2/token"
            ]
        );
    }

    // ARM deny: ?auto=deny ends refused:cloudflare-login:access-denied, the
    // ledger has nothing past /oauth2/auth, the store was never touched.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_deny_writes_nothing() {
        let server = fake::start("deny");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let store = MemStore::with_mesh();
        let open = browser("deny", false);
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = fake_deps(&server, &http, &store, &open, &mut read);
        let e = login(Some(Via::Loopback), &mut d, &mut Vec::new()).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:access-denied");
        let paths = fake::paths(&server.ledger);
        let auth = paths
            .iter()
            .position(|p| p == "/oauth2/auth")
            .expect("auth hit");
        assert!(
            paths[auth + 1..].is_empty(),
            "nothing past /oauth2/auth: {paths:?}"
        );
        assert_eq!(store.touches(), 0, "a denied consent never touches Vault");
    }

    // ARM state: a tampered state is refused and NO token request is made.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_state_mismatch_makes_no_exchange() {
        let server = fake::start("state");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let store = MemStore::with_mesh();
        let open = browser("approve", true);
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = fake_deps(&server, &http, &store, &open, &mut read);
        let e = login(Some(Via::Loopback), &mut d, &mut Vec::new()).unwrap_err();
        assert_eq!(e.verdict(), "refused:cloudflare-login:state-mismatch");
        assert!(
            !fake::paths(&server.ledger)
                .iter()
                .any(|p| p == "/oauth2/token")
        );
        assert_eq!(store.touches(), 0);
    }

    /// For the qr arm: every GET to the relay poll URL is answered by "the
    /// phone": it reads the authorize URL the login printed, approves it at
    /// the fake, and hands back {state, code} like the relay Worker would.
    struct PhoneRelay<'a> {
        real: &'a dyn HttpClient,
        out: Rc<RefCell<Vec<u8>>>,
        poll: &'static str,
    }
    impl HttpClient for PhoneRelay<'_> {
        fn get(&self, url: &str) -> Result<HttpResponse, String> {
            if !url.starts_with(self.poll) {
                return self.real.get(url);
            }
            let text = String::from_utf8(self.out.borrow().clone()).unwrap();
            let authorize = text
                .lines()
                .find_map(|l| l.trim().strip_prefix("Or open: "))
                .expect("URL printed under the QR")
                .to_string();
            let loc = fake::consent(&authorize, "approve");
            let q = parse_query(loc.split_once('?').unwrap().1).unwrap();
            let get = |k: &str| q.iter().find(|(kk, _)| kk == k).unwrap().1.clone();
            Ok(HttpResponse {
                status: 200,
                body: serde_json::json!({"state": get("state"), "code": get("code")}).to_string(),
            })
        }
        fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpResponse, String> {
            self.real.post_form(url, form)
        }
    }

    const RELAY: &str = "https://relay.example.invalid/tillandsias/cloudflare/callback";

    /// The QR in `text` is EXACTLY the QR of `url` (decode by re-encoding: the
    /// renderer is deterministic, so equal blocks mean equal payloads), and
    /// `url` carries only the authorize parameters, never the verifier.
    pub(super) fn assert_qr_is_only_the_authorize_url(
        text: &str,
        relay: &str,
        verifier: Option<&str>,
    ) -> String {
        let url = text
            .lines()
            .find_map(|l| l.trim().strip_prefix("Or open: "))
            .expect("the URL is printed as text under the QR")
            .to_string();
        let qr = crate::render_terminal_qr_in(&url, tillandsias_progress_tty::Tier::Plain).unwrap();
        assert!(
            text.contains(&qr),
            "the printed QR must encode exactly the printed URL"
        );
        // CONTROL: a QR of anything else (even one byte more) is a different block.
        let other =
            crate::render_terminal_qr_in(&format!("{url}x"), tillandsias_progress_tty::Tier::Plain)
                .unwrap();
        assert!(
            !text.contains(&other),
            "the comparison must be able to tell payloads apart"
        );
        let (_, query) = url.split_once('?').expect("query");
        let q = parse_query(query).unwrap();
        let mut keys: Vec<&str> = q.iter().map(|(k, _)| k.as_str()).collect();
        keys.sort_unstable();
        let mut allowed = vec![
            "client_id",
            "code_challenge",
            "code_challenge_method",
            "redirect_uri",
            "response_type",
            "state",
        ];
        if !CLOUDFLARE_LOGIN_SCOPES.is_empty() {
            allowed.push("scope");
            allowed.sort_unstable();
        }
        assert_eq!(keys, allowed, "the authorize URL carries nothing else");
        let get = |k: &str| q.iter().find(|(kk, _)| kk == k).unwrap().1.clone();
        assert_eq!(get("redirect_uri"), relay);
        assert_eq!(get("code_challenge_method"), "S256");
        assert_eq!(get("code_challenge").len(), 43, "an S256 digest, base64url");
        if let Some(v) = verifier {
            assert_absent(&url, &[v], "authorize URL");
            assert_absent(text, &[v], "QR output");
        }
        url
    }

    // ARM qr: the QR decodes to the authorize URL and nothing else; the relay
    // poll hands back the code; stored; no verifier anywhere in the output.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_qr_relay_poll_stores_and_qr_is_only_the_url() {
        let server = fake::start("qr");
        let real = cloudflare_oauth::ReqwestHttpClient::default();
        let out = Rc::new(RefCell::new(Vec::new()));
        let http = PhoneRelay {
            real: &real,
            out: out.clone(),
            poll: "https://relay.example.invalid/poll",
        };
        let store = MemStore::with_mesh();
        let mut read = || -> Result<String, String> { panic!("no paste") };
        let mut d = fake_deps(&server, &http, &store, &no_open, &mut read);
        d.relay_url = Some(RELAY.into());
        d.relay_poll_url = Some("https://relay.example.invalid/poll".into());
        let r = login(Some(Via::Qr), &mut d, &mut SharedOut(out.clone()));
        let text = String::from_utf8(out.borrow().clone()).unwrap();
        assert!(
            matches!(r, Ok(LoginOutcome::Stored { .. })),
            "{r:?}\n{text}"
        );
        let (verifier, code) = fake::sent_verifier_and_code(&server.ledger);
        assert_qr_is_only_the_authorize_url(&text, RELAY, Some(&verifier));
        let (access, refresh) = secrets_of(&store);
        assert_absent(
            &text,
            &[&access, &refresh, &verifier, &code],
            "qr login output",
        );
    }

    // ARM paste: a code from the fake, pasted as the address-bar URL, stores.
    // CONTROL: a bare code (no state) is refused and stores nothing.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_paste_stores() {
        let server = fake::start("paste");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let run = |bare: bool| {
            let store = MemStore::with_mesh();
            let out = Rc::new(RefCell::new(Vec::new()));
            let out2 = out.clone();
            let mut read = move || -> Result<String, String> {
                let text = String::from_utf8(out2.borrow().clone()).unwrap();
                let url = text
                    .lines()
                    .map(str::trim)
                    .find(|l| l.contains("/oauth2/auth?"))
                    .unwrap()
                    .to_string();
                let loc = fake::consent(&url, "approve");
                Ok(if bare {
                    loc.split("code=")
                        .nth(1)
                        .unwrap()
                        .split('&')
                        .next()
                        .unwrap()
                        .to_string()
                } else {
                    loc
                })
            };
            let r;
            {
                let mut d = fake_deps(&server, &http, &store, &no_open, &mut read);
                d.stdin_is_terminal = true;
                r = login(Some(Via::Paste), &mut d, &mut SharedOut(out.clone()));
            }
            let text = String::from_utf8(out.borrow().clone()).unwrap();
            (r, store, text)
        };
        let (r, store, text) = run(false);
        assert!(
            matches!(r, Ok(LoginOutcome::Stored { .. })),
            "{r:?}\n{text}"
        );
        let (access, refresh) = secrets_of(&store);
        let (verifier, code) = fake::sent_verifier_and_code(&server.ledger);
        assert_absent(
            &text,
            &[&access, &refresh, &verifier, &code],
            "paste login output",
        );
        let (r, store, _) = run(true);
        assert_eq!(r.unwrap_err().reason, "paste-needs-code-and-state");
        assert!(!store.snapshot().contains_key(CLOUDFLARE_TOKEN_PATH));
    }

    // ARM litmus: LITMUS stops every receiver before any exchange; the ledger
    // shows discovery only and the store is never touched.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_fake_litmus_stops_before_exchange() {
        let server = fake::start("litmus");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let store = MemStore::with_mesh();
        for via in [Via::Loopback, Via::Qr, Via::Paste] {
            let mut read = || -> Result<String, String> { panic!("no paste") };
            let mut d = fake_deps(&server, &http, &store, &no_open, &mut read);
            d.litmus_stop = true;
            d.stdin_is_terminal = true;
            d.relay_url = Some(RELAY.into());
            let mut out = Vec::new();
            assert_eq!(
                login(Some(via), &mut d, &mut out).unwrap(),
                LoginOutcome::LitmusStopped
            );
            let text = String::from_utf8(out).unwrap();
            assert!(
                text.contains("skip:cloudflare-login:litmus-stop-before-exchange"),
                "{text}"
            );
        }
        assert!(
            fake::paths(&server.ledger)
                .iter()
                .all(|p| p == "/.well-known/openid-configuration"),
            "{:?}",
            fake::paths(&server.ledger)
        );
        assert_eq!(store.touches(), 0);
    }

    // ARM logout: after a real login, logout revokes at the fake, deletes the
    // pair and leaves secret/cloudflare/mesh byte-for-byte unchanged.
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-login.sh"]
    fn cloudflare_logout_fake_deletes_pair_keeps_mesh() {
        let server = fake::start("logout");
        let http = cloudflare_oauth::ReqwestHttpClient::default();
        let store = MemStore::with_mesh();
        let open = browser("approve", false);
        let mut read = || -> Result<String, String> { panic!("no paste") };
        {
            let mut d = fake_deps(&server, &http, &store, &open, &mut read);
            login(Some(Via::Loopback), &mut d, &mut Vec::new()).expect("login");
        }
        let before = store.snapshot();
        let (access, refresh) = secrets_of(&store);
        let mut out = Vec::new();
        logout(
            &LogoutDeps {
                http: &http,
                store: &store,
                base_url: server.base_url.clone(),
                host_is_forge: false,
            },
            &mut out,
        )
        .expect("logout");
        let text = String::from_utf8(out).unwrap();
        let after = store.snapshot();
        assert!(!after.contains_key(CLOUDFLARE_TOKEN_PATH), "{text}");
        assert!(!after.contains_key(CLOUDFLARE_REFRESH_PATH), "{text}");
        assert_eq!(
            after["secret/cloudflare/mesh"],
            before["secret/cloudflare/mesh"]
        );
        assert_eq!(
            fake::paths(&server.ledger)
                .iter()
                .filter(|p| *p == "/oauth2/revoke")
                .count(),
            2,
            "refresh then access token revoked"
        );
        assert!(text.contains("ok:cloudflare-logout:deleted"), "{text}");
        assert_absent(&text, &[&access, &refresh], "logout output");
    }

    /// The REAL binary's `--via qr` output (captured by the script under
    /// LITMUS_PODMAN_MODE into $CF_LOGIN_QR_CAPTURE): the QR decodes to the
    /// printed authorize URL and nothing else.
    #[test]
    #[ignore = "reads a capture made by scripts/test-cloudflare-login.sh"]
    fn cloudflare_login_binary_qr_capture_is_only_the_authorize_url() {
        let path = std::env::var("CF_LOGIN_QR_CAPTURE").expect("CF_LOGIN_QR_CAPTURE");
        let relay = std::env::var("CF_LOGIN_QR_RELAY").expect("CF_LOGIN_QR_RELAY");
        let text = std::fs::read_to_string(path).unwrap();
        assert!(
            text.contains("skip:cloudflare-login:litmus-stop-before-exchange"),
            "{text}"
        );
        assert_qr_is_only_the_authorize_url(&text, &relay, None);
    }
}
