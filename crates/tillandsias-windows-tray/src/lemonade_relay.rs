//! The forge -> host Lemonade relay (order 2456-lrly).
//!
//! Forges run in the WSL2 guest and must reach the Lemonade Server on the
//! Windows host's `127.0.0.1:13305` WITHOUT ever reaching host localhost
//! directly. The guest's `tillandsias-lemonade-forwarder` answers as the
//! enclave alias `lemonade:13305` and carries each connection over hvsocket to
//! this relay, which applies the policy below and only then opens a TCP
//! connection to Lemonade.
//!
//! # Relay policy (the approved security spec)
//!
//! 1. **Upstream** is fixed at `127.0.0.1:13305`, from tray config only
//!    ([`RelayConfig::tray_default`]). Nothing the guest sends names a host or
//!    a port: the request target must be origin-form, and `Host` is rebuilt.
//! 2. **Paths** are an exact allowlist ([`ROUTES`]), matched after
//!    normalisation. `..`/`.` segments, any percent-encoded `/`, `\` or `.`,
//!    backslashes, and a query string on a body route are refused. Every other
//!    route (`/pull`, `/load`, `/unload`, `/delete`, `/install`, `/params`,
//!    `/system-info`, `/health`, `/stats`, `/logs`, `/downloads`, admin routes,
//!    websockets) is a 403 with `refused:lemonade-relay:route-not-allowed:<path>`.
//! 3. **Models**: `model` in the JSON body must be in the approved set
//!    ([`approved_models`]: today, every model Lemonade reports downloaded;
//!    narrowed in that one function when a catalog exists). A duplicate
//!    top-level `model` key is refused. Multipart bodies must carry exactly
//!    one `model` part, and it must be approved.
//! 4. **`GET /api/v1/models`** is BUILT from the approved set; Lemonade's JSON
//!    is never edited in place, and the request never reaches Lemonade.
//! 5. **Identity**: every connection starts with a per-lane preamble
//!    `LRLY1 <lane> <64 hex>\n`. Credentials are minted per forge launch
//!    ([`LaneRegistry::mint`], which rotates), live in memory only, and are
//!    compared in constant time BEFORE any upstream byte flows. A mismatch is
//!    a silent drop: no status, no reason.
//! 6. **Headers** are rebuilt from scratch: `Host: 127.0.0.1:13305`,
//!    `Content-Type` and `Accept` passed through, `Content-Length` recomputed,
//!    `Connection: close`. Guest `Authorization`, `Cookie`, `X-Forwarded-*` and
//!    everything else are dropped; an `Upgrade` request is refused. Parsing is
//!    `httparse` only. Content-Length together with Transfer-Encoding is
//!    refused; Transfer-Encoding alone is refused too (bodies must be sized).
//!    No pipelining: one request per connection, one upstream connection each.
//! 7. **Caps**: body <= 1 MiB on JSON routes, <= 32 MiB on audio/image routes;
//!    connect timeout 10 s, idle 120 s, total 30 min; at most 2 concurrent
//!    requests per lane; image and audio-generation routes are serialised
//!    globally. Every refusal and cap hit is logged with the lane and route.
//!
//! The core is platform-neutral (any `AsyncRead + AsyncWrite` guest stream,
//! plain TCP upstream) so it is tested on every host. Only [`hv`], the
//! hvsocket listener, is Windows-only.
//!
//! FOLLOW-UP (credential delivery): minting is implemented here, but handing a
//! lane's credential to the guest forwarder for one forge is not yet wired, so
//! the tray registers no lanes and the relay drops every connection. That is
//! the fail-closed default until delivery lands.
//!
//! @trace order:2456-lrly

use std::collections::{BTreeSet, HashMap};
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Semaphore;

/// Body cap on JSON-only routes.
pub const JSON_BODY_CAP: usize = 1024 * 1024;
/// Body cap on audio and image routes.
pub const MEDIA_BODY_CAP: usize = 32 * 1024 * 1024;
/// Concurrent requests one lane may have in flight.
pub const PER_LANE_CONCURRENCY: u32 = 2;
/// The only upstream, as tray config. Never derived from guest input.
pub const LEMONADE_UPSTREAM: &str = "127.0.0.1:13305";
/// The `Host` header every upstream request carries.
const UPSTREAM_HOST_HEADER: &str = "127.0.0.1:13305";
const PREAMBLE_MAGIC: &str = "LRLY1";
const MAX_PREAMBLE: usize = 160;
const MAX_HEAD: usize = 16 * 1024;
const MAX_HEADERS: usize = 64;

/// How a route's body is checked and capped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BodyKind {
    /// No body; answered locally from the approved set.
    None,
    /// JSON only, `JSON_BODY_CAP`.
    Json,
    /// JSON or multipart, `MEDIA_BODY_CAP`.
    Media,
}

/// One allowlisted route.
#[derive(Debug)]
struct Route {
    method: &'static str,
    path: &'static str,
    body: BodyKind,
    /// Serialised globally (image, audio-generation, 3D, video).
    serialised: bool,
}

/// The exact allowlist. Anything absent is refused.
const ROUTES: &[Route] = &[
    Route {
        method: "GET",
        path: "/api/v1/models",
        body: BodyKind::None,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/chat/completions",
        body: BodyKind::Json,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/completions",
        body: BodyKind::Json,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/embeddings",
        body: BodyKind::Json,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/reranking",
        body: BodyKind::Json,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/audio/transcriptions",
        body: BodyKind::Media,
        serialised: false,
    },
    Route {
        method: "POST",
        path: "/api/v1/audio/speech",
        body: BodyKind::Media,
        serialised: true,
    },
    Route {
        method: "POST",
        path: "/api/v1/images/generations",
        body: BodyKind::Media,
        serialised: true,
    },
    Route {
        method: "POST",
        path: "/api/v1/images/edits",
        body: BodyKind::Media,
        serialised: true,
    },
];

/// Relay limits and the fixed upstream. Built by [`RelayConfig::tray_default`];
/// tests point `upstream` at a stub, nothing else may.
#[derive(Debug, Clone)]
pub struct RelayConfig {
    pub upstream: SocketAddr,
    pub connect_timeout: Duration,
    pub idle_timeout: Duration,
    pub total_timeout: Duration,
    pub preamble_timeout: Duration,
}

impl RelayConfig {
    pub fn tray_default() -> Self {
        Self {
            upstream: LEMONADE_UPSTREAM
                .parse()
                .expect("constant loopback address"),
            connect_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(120),
            total_timeout: Duration::from_secs(30 * 60),
            preamble_timeout: Duration::from_secs(10),
        }
    }
}

// ─── Identity ────────────────────────────────────────────────────────────────

/// One lane's credential. `Debug` never prints the token.
#[derive(Clone)]
pub struct LaneCredential {
    lane: String,
    token: [u8; 32],
}

impl std::fmt::Debug for LaneCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneCredential")
            .field("lane", &self.lane)
            .field("token", &"<redacted>")
            .finish()
    }
}

impl LaneCredential {
    pub fn lane(&self) -> &str {
        &self.lane
    }

    /// The line the guest forwarder writes first on every connection. The
    /// delivery of this line into one forge's forwarder is the follow-up.
    pub fn preamble(&self) -> String {
        format!("{PREAMBLE_MAGIC} {} {}\n", self.lane, hex(&self.token))
    }

    #[cfg(test)]
    pub fn for_test(lane: &str, token_hex: &str) -> Self {
        Self {
            lane: lane.to_string(),
            token: unhex32(token_hex).expect("64 hex chars"),
        }
    }

    #[cfg(test)]
    pub fn token_hex_for_test(&self) -> String {
        hex(&self.token)
    }
}

struct LaneEntry {
    token: [u8; 32],
    inflight: Arc<Semaphore>,
}

/// In-memory lane credentials. Nothing here is ever written to disk.
#[derive(Default)]
pub struct LaneRegistry {
    lanes: Mutex<HashMap<String, LaneEntry>>,
}

impl LaneRegistry {
    /// Mint (or rotate) the credential for `lane`; call on every forge launch.
    /// The previous token for the lane stops verifying immediately; the
    /// in-flight gate is kept so a relaunch cannot reset the concurrency cap.
    pub fn mint(&self, lane: &str) -> LaneCredential {
        let token = random_token();
        let mut lanes = self.lanes.lock().unwrap_or_else(|p| p.into_inner());
        let inflight = lanes
            .get(lane)
            .map(|e| e.inflight.clone())
            .unwrap_or_else(|| Arc::new(Semaphore::new(PER_LANE_CONCURRENCY as usize)));
        lanes.insert(lane.to_string(), LaneEntry { token, inflight });
        LaneCredential {
            lane: lane.to_string(),
            token,
        }
    }

    /// Forget a lane (forge stopped).
    #[allow(dead_code)]
    pub fn revoke(&self, lane: &str) {
        self.lanes
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(lane);
    }

    /// The lane's in-flight gate when `token_hex` is its current token.
    pub fn verify(&self, lane: &str, token_hex: &str) -> Option<Arc<Semaphore>> {
        let presented = unhex32(token_hex)?;
        let lanes = self.lanes.lock().unwrap_or_else(|p| p.into_inner());
        let entry = lanes.get(lane)?;
        constant_time_eq(&entry.token, &presented).then(|| entry.inflight.clone())
    }
}

fn random_token() -> [u8; 32] {
    // Two v4 UUIDs: 244 bits from the OS RNG (getrandom, via uuid).
    let mut out = [0u8; 32];
    out[..16].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
    out[16..].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
    out
}

fn constant_time_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

// ─── Models ──────────────────────────────────────────────────────────────────

/// A boxed future, so the catalog trait stays object-safe without a new dep.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Where the downloaded-model list comes from.
pub trait ModelCatalog: Send + Sync {
    fn downloaded(&self) -> BoxFuture<'_, io::Result<Vec<String>>>;
}

/// THE narrowing point: approved = downloaded ∩ approved list. Today the list
/// is "everything downloaded"; a catalog narrows it here and nowhere else.
pub fn approved_models(downloaded: &[String]) -> BTreeSet<String> {
    downloaded.iter().cloned().collect()
}

/// A fixed list (tests, and a future pinned catalog).
pub struct StaticCatalog(pub Vec<String>);

impl ModelCatalog for StaticCatalog {
    fn downloaded(&self) -> BoxFuture<'_, io::Result<Vec<String>>> {
        let v = self.0.clone();
        Box::pin(async move { Ok(v) })
    }
}

/// Asks Lemonade itself (`GET /api/v1/models` on the fixed upstream).
#[allow(dead_code)]
pub struct UpstreamCatalog {
    pub upstream: SocketAddr,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
}

impl ModelCatalog for UpstreamCatalog {
    fn downloaded(&self) -> BoxFuture<'_, io::Result<Vec<String>>> {
        Box::pin(async move {
            let mut sock = tokio::time::timeout(
                self.connect_timeout,
                tokio::net::TcpStream::connect(self.upstream),
            )
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "catalog connect timeout"))??;
            sock.write_all(
                format!(
                    "GET /api/v1/models HTTP/1.1\r\nHost: {UPSTREAM_HOST_HEADER}\r\n\
                     Accept: application/json\r\nConnection: close\r\n\r\n"
                )
                .as_bytes(),
            )
            .await?;
            let mut raw = Vec::new();
            tokio::time::timeout(self.read_timeout, async {
                let mut chunk = [0u8; 16 * 1024];
                loop {
                    let n = sock.read(&mut chunk).await?;
                    if n == 0 {
                        return Ok::<(), io::Error>(());
                    }
                    raw.extend_from_slice(&chunk[..n]);
                    if raw.len() > 16 * 1024 * 1024 {
                        return Err(io::Error::other("catalog response too large"));
                    }
                }
            })
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "catalog read timeout"))??;
            let body = response_body(&raw).map_err(io::Error::other)?;
            parse_downloaded_models(&body).map_err(io::Error::other)
        })
    }
}

/// Split one HTTP response into its (de-chunked) body; 200 only.
fn response_body(raw: &[u8]) -> Result<Vec<u8>, String> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut resp = httparse::Response::new(&mut headers);
    let head_len = match resp.parse(raw) {
        Ok(httparse::Status::Complete(n)) => n,
        Ok(httparse::Status::Partial) => return Err("truncated catalog response".into()),
        Err(e) => return Err(format!("bad catalog response: {e}")),
    };
    if resp.code != Some(200) {
        return Err(format!("catalog answered {:?}", resp.code));
    }
    let chunked = resp.headers.iter().any(|h| {
        h.name.eq_ignore_ascii_case("transfer-encoding")
            && String::from_utf8_lossy(h.value)
                .to_ascii_lowercase()
                .contains("chunked")
    });
    let body = &raw[head_len..];
    if !chunked {
        return Ok(body.to_vec());
    }
    let mut out = Vec::new();
    let mut rest = body;
    loop {
        match httparse::parse_chunk_size(rest) {
            Ok(httparse::Status::Complete((idx, 0))) => {
                let _ = idx;
                return Ok(out);
            }
            Ok(httparse::Status::Complete((idx, size))) => {
                let size = usize::try_from(size).map_err(|_| "chunk too large")?;
                let start = idx;
                let end = start + size;
                if rest.len() < end + 2 {
                    return Err("truncated chunk".into());
                }
                out.extend_from_slice(&rest[start..end]);
                rest = &rest[end + 2..];
            }
            _ => return Err("bad chunk".into()),
        }
    }
}

/// The ids Lemonade reports downloaded (`downloaded != false`).
pub fn parse_downloaded_models(body: &[u8]) -> Result<Vec<String>, String> {
    let v: serde_json::Value =
        serde_json::from_slice(body).map_err(|e| format!("catalog is not JSON: {e}"))?;
    let data = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or("catalog has no data array")?;
    Ok(data
        .iter()
        .filter(|m| m.get("downloaded").and_then(|d| d.as_bool()) != Some(false))
        .filter_map(|m| m.get("id").and_then(|i| i.as_str()).map(str::to_string))
        .collect())
}

// ─── Refusals ────────────────────────────────────────────────────────────────

/// A named refusal: status code + `refused:lemonade-relay:<name>[:<detail>]`.
#[derive(Debug)]
struct Refusal {
    status: u16,
    name: &'static str,
    detail: Option<String>,
}

impl Refusal {
    fn new(status: u16, name: &'static str) -> Self {
        Self {
            status,
            name,
            detail: None,
        }
    }

    fn with(status: u16, name: &'static str, detail: &str) -> Self {
        Self {
            status,
            name,
            detail: Some(printable(detail)),
        }
    }

    fn body(&self) -> String {
        match &self.detail {
            Some(d) => format!("refused:lemonade-relay:{}:{d}", self.name),
            None => format!("refused:lemonade-relay:{}", self.name),
        }
    }

    fn response(&self) -> Vec<u8> {
        let reason = match self.status {
            400 => "Bad Request",
            403 => "Forbidden",
            411 => "Length Required",
            413 => "Payload Too Large",
            415 => "Unsupported Media Type",
            429 => "Too Many Requests",
            502 => "Bad Gateway",
            504 => "Gateway Timeout",
            _ => "Error",
        };
        let body = format!("{}\n", self.body());
        format!(
            "HTTP/1.1 {} {reason}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\
             Connection: close\r\n\r\n{body}",
            self.status,
            body.len()
        )
        .into_bytes()
    }
}

/// Guest-supplied text, safe to echo: printable ASCII, bounded.
fn printable(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_graphic())
        .take(200)
        .collect()
}

// ─── Path normalisation ──────────────────────────────────────────────────────

/// Normalise an origin-form target into `(path, has_query)`, or refuse.
fn normalise_target(target: &str) -> Result<(String, bool), Refusal> {
    let refuse = || Refusal::with(403, "route-not-allowed", target);
    if !target.starts_with('/') {
        // absolute-form or authority-form would let the guest name a host
        return Err(refuse());
    }
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (target, None),
    };
    if path.contains('#') || path.contains('\\') {
        return Err(refuse());
    }
    let lower = path.to_ascii_lowercase();
    // Any percent-encoded slash, backslash or dot is refused outright rather
    // than decoded, so no decoder downstream can see a different path.
    for bad in ["%2f", "%5c", "%2e", "%00"] {
        if lower.contains(bad) {
            return Err(refuse());
        }
    }
    let mut segments = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" => {}
            "." | ".." => return Err(refuse()),
            s => segments.push(s),
        }
    }
    Ok((format!("/{}", segments.join("/")), query.is_some()))
}

fn find_route(method: &str, path: &str) -> Option<&'static Route> {
    ROUTES.iter().find(|r| r.method == method && r.path == path)
}

// ─── Model checks ────────────────────────────────────────────────────────────

/// The top-level `model` of a JSON object body, refusing a duplicate key.
fn json_model(body: &[u8]) -> Result<String, Refusal> {
    use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};

    struct ModelOnly;
    impl<'de> Visitor<'de> for ModelOnly {
        type Value = Result<String, &'static str>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a JSON object")
        }
        fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
            let mut model: Option<serde_json::Value> = None;
            let mut dup = false;
            while let Some(key) = map.next_key::<String>()? {
                if key == "model" {
                    let v: serde_json::Value = map.next_value()?;
                    if model.is_some() {
                        dup = true;
                    }
                    model = Some(v);
                } else {
                    map.next_value::<IgnoredAny>()?;
                }
            }
            Ok(match (dup, model) {
                (true, _) => Err("model-duplicate"),
                (false, None) => Err("model-missing"),
                (false, Some(serde_json::Value::String(s))) => Ok(s),
                (false, Some(_)) => Err("model-not-a-string"),
            })
        }
    }

    let mut de = serde_json::Deserializer::from_slice(body);
    let parsed = (&mut de)
        .deserialize_map(ModelOnly)
        .map_err(|_| Refusal::new(400, "malformed-json-body"))?;
    de.end()
        .map_err(|_| Refusal::new(400, "malformed-json-body"))?;
    parsed.map_err(|name| Refusal::new(403, name))
}

/// The single `model` part of a multipart/form-data body.
fn multipart_model(content_type: &str, body: &[u8]) -> Result<String, Refusal> {
    let malformed = || Refusal::new(400, "malformed-multipart-body");
    let boundary = content_type
        .split(';')
        .skip(1)
        .filter_map(|p| p.trim().split_once('='))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("boundary"))
        .map(|(_, v)| v.trim().trim_matches('"').to_string())
        .filter(|b| !b.is_empty() && b.len() <= 70)
        .ok_or_else(malformed)?;
    let delim = format!("--{boundary}").into_bytes();
    let mut positions = Vec::new();
    let mut i = 0;
    while let Some(p) = find_bytes(&body[i..], &delim) {
        positions.push(i + p);
        i += p + delim.len();
    }
    if positions.len() < 2 {
        return Err(malformed());
    }
    let mut models = Vec::new();
    let mut terminated = false;
    for w in positions.windows(2) {
        let seg = &body[w[0] + delim.len()..w[1]];
        let seg = seg.strip_prefix(b"\r\n").ok_or_else(malformed)?;
        let seg = seg.strip_suffix(b"\r\n").ok_or_else(malformed)?;
        let mut headers = [httparse::EMPTY_HEADER; 16];
        let (head_len, parsed) = match httparse::parse_headers(seg, &mut headers) {
            Ok(httparse::Status::Complete((n, h))) => (n, h),
            _ => return Err(malformed()),
        };
        let name = parsed
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case("content-disposition"))
            .and_then(|h| std::str::from_utf8(h.value).ok())
            .and_then(disposition_name);
        if name.as_deref() == Some("model") {
            let value = std::str::from_utf8(&seg[head_len..]).map_err(|_| malformed())?;
            models.push(value.trim().to_string());
        }
    }
    if let Some(&last) = positions.last() {
        terminated = body[last + delim.len()..].starts_with(b"--");
    }
    if !terminated {
        return Err(malformed());
    }
    match models.len() {
        0 => Err(Refusal::new(403, "model-missing")),
        1 => Ok(models.remove(0)),
        _ => Err(Refusal::new(403, "model-duplicate")),
    }
}

fn disposition_name(value: &str) -> Option<String> {
    let mut parts = value.split(';');
    if !parts.next()?.trim().eq_ignore_ascii_case("form-data") {
        return None;
    }
    parts
        .filter_map(|p| p.trim().split_once('='))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("name"))
        .map(|(_, v)| v.trim().trim_matches('"').to_string())
}

fn find_bytes(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

// ─── The relay ───────────────────────────────────────────────────────────────

/// A parsed, policy-checked request, ready to rebuild upstream.
struct Checked {
    route: &'static Route,
    content_type: Option<String>,
    accept: Option<String>,
    body: Vec<u8>,
}

pub struct Relay {
    config: RelayConfig,
    lanes: Arc<LaneRegistry>,
    catalog: Arc<dyn ModelCatalog>,
    /// One at a time across all lanes for the serialised routes.
    media_gate: Arc<Semaphore>,
}

impl Relay {
    pub fn new(
        config: RelayConfig,
        lanes: Arc<LaneRegistry>,
        catalog: Arc<dyn ModelCatalog>,
    ) -> Self {
        Self {
            config,
            lanes,
            catalog,
            media_gate: Arc::new(Semaphore::new(1)),
        }
    }

    pub fn lanes(&self) -> &LaneRegistry {
        &self.lanes
    }

    /// Serve ONE guest connection: credential, one request, one response, close.
    pub async fn serve_connection<S>(&self, guest: S)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        let total = self.config.total_timeout;
        if tokio::time::timeout(total, self.serve_inner(guest))
            .await
            .is_err()
        {
            tracing::warn!(
                route = "-",
                "lemonade relay: total timeout (30 min cap) hit"
            );
        }
    }

    async fn serve_inner<S>(&self, mut guest: S)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        // 1. Identity, before anything else and before any upstream byte.
        let (lane, gate, mut buf) = match self.read_preamble(&mut guest).await {
            Some(v) => v,
            None => {
                // Silent drop: no status, no reason.
                tracing::warn!(
                    "lemonade relay: connection dropped, bad or missing lane credential"
                );
                return;
            }
        };
        // 2. Per-lane concurrency.
        let Ok(_permit) = gate.try_acquire_owned() else {
            self.refuse(
                &mut guest,
                &lane,
                "-",
                Refusal::new(429, "lane-concurrency-cap"),
            )
            .await;
            return;
        };
        // 3. Parse + policy.
        let checked = match self.read_and_check(&mut guest, &mut buf, &lane).await {
            Ok(c) => c,
            Err((route, refusal)) => {
                self.refuse(&mut guest, &lane, &route, refusal).await;
                return;
            }
        };
        let route = checked.route.path;
        // 4. GET /models: built locally from the approved set.
        if checked.route.body == BodyKind::None {
            match self.approved().await {
                Ok(set) => {
                    let data: Vec<serde_json::Value> = set
                        .iter()
                        .map(|id| {
                            serde_json::json!({"id": id, "object": "model", "owned_by": "lemonade"})
                        })
                        .collect();
                    let body = serde_json::json!({"object": "list", "data": data}).to_string();
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = guest.write_all(resp.as_bytes()).await;
                    let _ = guest.shutdown().await;
                }
                Err(e) => {
                    tracing::warn!(%lane, route, error = %e, "lemonade relay: catalog unavailable");
                    self.refuse(
                        &mut guest,
                        &lane,
                        route,
                        Refusal::new(502, "catalog-unavailable"),
                    )
                    .await;
                }
            }
            return;
        }
        // 5. Global serialisation for media generation.
        let _media = if checked.route.serialised {
            match self.media_gate.clone().acquire_owned().await {
                Ok(p) => Some(p),
                Err(_) => return,
            }
        } else {
            None
        };
        // 6. Upstream: fixed address, rebuilt head, exactly one request.
        let mut upstream = match tokio::time::timeout(
            self.config.connect_timeout,
            tokio::net::TcpStream::connect(self.config.upstream),
        )
        .await
        {
            Ok(Ok(s)) => s,
            Ok(Err(_)) => {
                self.refuse(
                    &mut guest,
                    &lane,
                    route,
                    Refusal::new(502, "upstream-unreachable"),
                )
                .await;
                return;
            }
            Err(_) => {
                self.refuse(
                    &mut guest,
                    &lane,
                    route,
                    Refusal::new(504, "upstream-connect-timeout"),
                )
                .await;
                return;
            }
        };
        let mut head = format!(
            "{} {} HTTP/1.1\r\nHost: {UPSTREAM_HOST_HEADER}\r\n",
            checked.route.method, checked.route.path
        );
        if let Some(ct) = &checked.content_type {
            head.push_str(&format!("Content-Type: {ct}\r\n"));
        }
        if let Some(acc) = &checked.accept {
            head.push_str(&format!("Accept: {acc}\r\n"));
        }
        head.push_str(&format!(
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
            checked.body.len()
        ));
        if upstream.write_all(head.as_bytes()).await.is_err()
            || upstream.write_all(&checked.body).await.is_err()
        {
            self.refuse(
                &mut guest,
                &lane,
                route,
                Refusal::new(502, "upstream-write-failed"),
            )
            .await;
            return;
        }
        // 7. Response back, under the idle cap.
        let idle = self.config.idle_timeout;
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            match tokio::time::timeout(idle, upstream.read(&mut chunk)).await {
                Ok(Ok(0)) => break,
                Ok(Ok(n)) => {
                    if guest.write_all(&chunk[..n]).await.is_err() {
                        break;
                    }
                }
                Ok(Err(_)) => break,
                Err(_) => {
                    tracing::warn!(%lane, route, "lemonade relay: idle timeout (120 s) hit");
                    break;
                }
            }
        }
        let _ = guest.shutdown().await;
    }

    async fn approved(&self) -> io::Result<BTreeSet<String>> {
        Ok(approved_models(&self.catalog.downloaded().await?))
    }

    async fn refuse<S: AsyncWrite + Unpin>(
        &self,
        guest: &mut S,
        lane: &str,
        route: &str,
        refusal: Refusal,
    ) {
        tracing::warn!(lane, route = %printable(route), refusal = %refusal.body(), "lemonade relay: refused");
        let _ = guest.write_all(&refusal.response()).await;
        let _ = guest.shutdown().await;
    }

    /// Read and verify `LRLY1 <lane> <hex>\n`. Returns the lane, its gate, and
    /// any bytes already read past the preamble.
    async fn read_preamble<S: AsyncRead + Unpin>(
        &self,
        guest: &mut S,
    ) -> Option<(String, Arc<Semaphore>, Vec<u8>)> {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 256];
        let nl = tokio::time::timeout(self.config.preamble_timeout, async {
            loop {
                if let Some(p) = buf.iter().position(|&b| b == b'\n') {
                    return Some(p);
                }
                if buf.len() > MAX_PREAMBLE {
                    return None;
                }
                let n = guest.read(&mut chunk).await.ok()?;
                if n == 0 {
                    return None;
                }
                buf.extend_from_slice(&chunk[..n]);
            }
        })
        .await
        .ok()??;
        if nl > MAX_PREAMBLE {
            return None;
        }
        let line = std::str::from_utf8(&buf[..nl]).ok()?;
        let mut parts = line.trim_end_matches('\r').split(' ');
        let (magic, lane, token) = (parts.next()?, parts.next()?, parts.next()?);
        if magic != PREAMBLE_MAGIC || parts.next().is_some() {
            return None;
        }
        let lane_ok = !lane.is_empty()
            && lane.len() <= 64
            && lane
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
        if !lane_ok {
            return None;
        }
        let gate = self.lanes.verify(lane, token)?;
        Some((lane.to_string(), gate, buf[nl + 1..].to_vec()))
    }

    /// Parse one request head with httparse, apply the route, framing and cap
    /// rules, read the body, and check the model. Errors carry the route label
    /// for the log.
    async fn read_and_check<S: AsyncRead + AsyncWrite + Unpin>(
        &self,
        guest: &mut S,
        buf: &mut Vec<u8>,
        lane: &str,
    ) -> Result<Checked, (String, Refusal)> {
        let idle = self.config.idle_timeout;
        let mut chunk = vec![0u8; 64 * 1024];
        // Head.
        let head_len = loop {
            let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
            let mut req = httparse::Request::new(&mut headers);
            match req.parse(buf) {
                Ok(httparse::Status::Complete(n)) => break n,
                Ok(httparse::Status::Partial) => {}
                Err(_) => return Err(("-".into(), Refusal::new(400, "malformed-request"))),
            }
            if buf.len() > MAX_HEAD {
                return Err(("-".into(), Refusal::new(400, "request-head-too-large")));
            }
            match tokio::time::timeout(idle, guest.read(&mut chunk)).await {
                Ok(Ok(0)) | Ok(Err(_)) => {
                    return Err(("-".into(), Refusal::new(400, "malformed-request")));
                }
                Ok(Ok(n)) => buf.extend_from_slice(&chunk[..n]),
                Err(_) => {
                    tracing::warn!(lane, "lemonade relay: idle timeout (120 s) reading head");
                    return Err(("-".into(), Refusal::new(400, "idle-timeout")));
                }
            }
        };
        let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
        let mut req = httparse::Request::new(&mut headers);
        let _ = req.parse(&buf[..head_len]);
        let method = req.method.unwrap_or("").to_string();
        let target = req.path.unwrap_or("").to_string();
        let route_label = printable(&target);

        let header = |name: &str| -> Vec<String> {
            req.headers
                .iter()
                .filter(|h| h.name.eq_ignore_ascii_case(name))
                .map(|h| String::from_utf8_lossy(h.value).trim().to_string())
                .collect()
        };
        let err = |r: Refusal| (route_label.clone(), r);

        // Upgrades (websockets) never pass.
        let upgrade = !header("upgrade").is_empty()
            || header("connection")
                .iter()
                .any(|v| v.to_ascii_lowercase().contains("upgrade"));
        if upgrade {
            return Err(err(Refusal::with(403, "upgrade-not-allowed", &target)));
        }
        // Route.
        let (path, has_query) = normalise_target(&target).map_err(err)?;
        let route = find_route(&method, &path)
            .ok_or_else(|| err(Refusal::with(403, "route-not-allowed", &path)))?;
        if has_query && route.body != BodyKind::None {
            return Err(err(Refusal::with(403, "query-not-allowed", &path)));
        }
        // Framing.
        let cl = header("content-length");
        let te = header("transfer-encoding");
        if !cl.is_empty() && !te.is_empty() {
            return Err(err(Refusal::new(
                400,
                "content-length-with-transfer-encoding",
            )));
        }
        if !te.is_empty() {
            return Err(err(Refusal::new(411, "transfer-encoding-not-supported")));
        }
        if cl.len() > 1 {
            return Err(err(Refusal::new(400, "duplicate-content-length")));
        }
        let content_length: usize = match cl.first() {
            Some(v) if !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()) => v
                .parse()
                .map_err(|_| err(Refusal::new(413, "body-too-large")))?,
            Some(_) => return Err(err(Refusal::new(400, "malformed-content-length"))),
            None => 0,
        };
        let cap = match route.body {
            BodyKind::None => 0,
            BodyKind::Json => JSON_BODY_CAP,
            BodyKind::Media => MEDIA_BODY_CAP,
        };
        if content_length > cap {
            tracing::warn!(
                lane,
                route = route.path,
                content_length,
                cap,
                "lemonade relay: body cap hit"
            );
            return Err(err(Refusal::new(413, "body-too-large")));
        }
        if route.body != BodyKind::None && cl.is_empty() {
            return Err(err(Refusal::new(411, "length-required")));
        }
        let content_type = header("content-type").into_iter().next();
        let accept = header("accept")
            .into_iter()
            .next()
            .filter(|a| a.bytes().all(|b| b.is_ascii_graphic() || b == b' '));
        let expect_continue = header("expect")
            .iter()
            .any(|v| v.eq_ignore_ascii_case("100-continue"));

        // Body: exactly Content-Length bytes; anything after is pipelining.
        let mut body = buf[head_len..].to_vec();
        if body.len() > content_length {
            return Err(err(Refusal::new(400, "pipelining-not-allowed")));
        }
        if expect_continue && body.len() < content_length {
            let _ = guest.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").await;
        }
        while body.len() < content_length {
            let want = (content_length - body.len()).min(chunk.len());
            match tokio::time::timeout(idle, guest.read(&mut chunk[..want])).await {
                Ok(Ok(0)) | Ok(Err(_)) => return Err(err(Refusal::new(400, "truncated-body"))),
                Ok(Ok(n)) => body.extend_from_slice(&chunk[..n]),
                Err(_) => {
                    tracing::warn!(
                        lane,
                        route = route.path,
                        "lemonade relay: idle timeout (120 s) reading body"
                    );
                    return Err(err(Refusal::new(400, "idle-timeout")));
                }
            }
        }

        // Model.
        if route.body != BodyKind::None {
            let ct = content_type.clone().unwrap_or_default();
            let mime = ct
                .split(';')
                .next()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase();
            let model = match (mime.as_str(), route.body) {
                ("application/json", _) => json_model(&body),
                ("multipart/form-data", BodyKind::Media) => multipart_model(&ct, &body),
                _ => Err(Refusal::with(415, "content-type-not-allowed", &mime)),
            }
            .map_err(err)?;
            let approved = self.approved().await.map_err(|e| {
                tracing::warn!(lane, error = %e, "lemonade relay: catalog unavailable");
                err(Refusal::new(502, "catalog-unavailable"))
            })?;
            if !approved.contains(&model) {
                return Err(err(Refusal::with(403, "model-not-approved", &model)));
            }
        }
        Ok(Checked {
            route,
            content_type,
            accept,
            body,
        })
    }
}

/// Whether the tray announces the relay to the guest. OPT-IN
/// (`TILLANDSIAS_LEMONADE_RELAY=1`) until credential delivery lands: without
/// it every connection is dropped, so announcing by default would start a
/// guest forwarder that can never carry a request.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn relay_opted_in() -> bool {
    std::env::var("TILLANDSIAS_LEMONADE_RELAY")
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "on" | "true"))
        .unwrap_or(false)
}

// ─── hvsocket binding (Windows only) ─────────────────────────────────────────

/// The hvsocket listener: accepts guest connections on
/// `LEMONADE_RELAY_VSOCK_PORT` from the WSL utility VM and hands each to
/// [`Relay::serve_connection`].
#[cfg(target_os = "windows")]
pub mod hv {
    use super::*;
    use crate::hvsocket::{parse_guid, vsock_service_guid, wsa_startup, wsl_utility_vm_id};
    use std::os::windows::io::FromRawSocket;
    use std::sync::OnceLock;
    use windows::Win32::Networking::WinSock::{
        SOCK_STREAM, SOCKADDR, accept, bind, closesocket, listen, socket,
    };

    const AF_HYPERV: u16 = 34;
    const HV_PROTOCOL_RAW: i32 = 1;

    #[repr(C)]
    struct SockaddrHv {
        family: u16,
        reserved: u16,
        vm_id: windows::core::GUID,
        service_id: windows::core::GUID,
    }

    /// The VM id the running listener is bound to.
    static BOUND_VM: Mutex<Option<String>> = Mutex::new(None);
    static RELAY: OnceLock<Arc<Relay>> = OnceLock::new();

    /// The tray's one relay. Credentials are registered by the (follow-up)
    /// delivery path through `relay().lanes().mint(..)`.
    pub fn relay() -> Arc<Relay> {
        RELAY
            .get_or_init(|| {
                let config = RelayConfig::tray_default();
                let catalog = Arc::new(UpstreamCatalog {
                    upstream: config.upstream,
                    connect_timeout: config.connect_timeout,
                    read_timeout: Duration::from_secs(30),
                });
                Arc::new(Relay::new(
                    config,
                    Arc::new(LaneRegistry::default()),
                    catalog,
                ))
            })
            .clone()
    }

    /// Bind (once per WSL VM id) and start accepting. Bound to the WSL utility
    /// VM's id, not the wildcard, so no other partition can connect.
    pub fn ensure_listening(port: u32) -> io::Result<()> {
        let vm = wsl_utility_vm_id()?;
        {
            let mut bound = BOUND_VM.lock().unwrap_or_else(|p| p.into_inner());
            if bound.as_deref() == Some(vm.as_str()) {
                return Ok(());
            }
            *bound = Some(vm.clone());
        }
        let vm_guid = parse_guid(&vm).ok_or_else(|| io::Error::other("bad WSL VM GUID"))?;
        let svc_guid = parse_guid(&vsock_service_guid(port))
            .ok_or_else(|| io::Error::other("bad service GUID"))?;
        wsa_startup()?;
        let listener = unsafe {
            let sock = socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW)
                .map_err(|e| io::Error::other(format!("AF_HYPERV socket() failed: {e}")))?;
            let addr = SockaddrHv {
                family: AF_HYPERV,
                reserved: 0,
                vm_id: vm_guid,
                service_id: svc_guid,
            };
            if bind(
                sock,
                &addr as *const SockaddrHv as *const SOCKADDR,
                std::mem::size_of::<SockaddrHv>() as i32,
            ) != 0
                || listen(sock, 16) != 0
            {
                let _ = closesocket(sock);
                *BOUND_VM.lock().unwrap_or_else(|p| p.into_inner()) = None;
                return Err(io::Error::other(format!(
                    "AF_HYPERV bind/listen for the lemonade relay (vsock {port}) failed"
                )));
            }
            sock
        };
        let handle = tokio::runtime::Handle::current();
        std::thread::Builder::new()
            .name("lemonade-relay-accept".into())
            .spawn(move || {
                loop {
                    let accepted = unsafe { accept(listener, None, None) };
                    let Ok(conn) = accepted else {
                        tracing::warn!("lemonade relay: accept failed; listener stopped");
                        *BOUND_VM.lock().unwrap_or_else(|p| p.into_inner()) = None;
                        return;
                    };
                    let std_stream = unsafe { std::net::TcpStream::from_raw_socket(conn.0 as _) };
                    let relay = relay();
                    handle.spawn(async move {
                        if std_stream.set_nonblocking(true).is_err() {
                            return;
                        }
                        let Ok(stream) = tokio::net::TcpStream::from_std(std_stream) else {
                            return;
                        };
                        relay.serve_connection(stream).await;
                    });
                }
            })?;
        tracing::info!(port, vm = %vm, "lemonade relay listening on hvsocket");
        Ok(())
    }
}

#[cfg(test)]
#[path = "lemonade_relay_tests.rs"]
mod tests;
