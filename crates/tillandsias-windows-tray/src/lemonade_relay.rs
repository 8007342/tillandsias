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
//!    `LRLY1 <lane> <64 hex>\n`. The guest mints one credential per forge
//!    launch (rotated on relaunch, memory only) and attaches it itself, so
//!    neither the forge nor its forwarder ever holds it. The tray learns the
//!    live lanes over the authenticated control wire
//!    (`LemonadeLanesRequest`, via [`LaneSource`]) into memory only, and
//!    compares in constant time BEFORE any upstream byte flows. A mismatch
//!    is a silent drop: no status, no reason.
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
//! # Transport: the guest listens, the tray dials
//!
//! There is NO host listener (no HKLM registration, no admin). The tray dials
//! out to the guest's vsock `LEMONADE_RELAY_VSOCK_PORT` through the same
//! privilege-routed, handshake-authenticated path as the control channel
//! (`open_and_wrap_hvsocket_stream`), so a connection the tray serves is one
//! whose guest end proved the control wire's key. Each dialed connection
//! PARKS until the guest pairs it with one forge request; the first bytes the
//! tray then reads are the lane preamble and the forge's own HTTP request,
//! which this module parses with httparse and nothing else. A small pool of
//! parked connections is kept per VM boot by [`Dialer`]; a new guest boot id
//! re-arms it and the previous pool's workers exit.
//!
//! The core is platform-neutral (any `AsyncRead + AsyncWrite` guest stream,
//! plain TCP upstream) so it is tested on every host. Only [`hv`], the
//! hvsocket dial and the control-wire lane fetch, is Windows-only.
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
    /// Replace the lane table with what the guest reported. A lane that
    /// survives keeps its in-flight gate, so a rotation cannot reset the
    /// concurrency cap; a lane that vanished stops verifying at once.
    pub fn replace_all(&self, fresh: Vec<(String, [u8; 32])>) {
        let mut lanes = self.lanes.lock().unwrap_or_else(|p| p.into_inner());
        let mut next = HashMap::new();
        for (lane, token) in fresh {
            let inflight = lanes
                .get(&lane)
                .map(|e| e.inflight.clone())
                .unwrap_or_else(|| Arc::new(Semaphore::new(PER_LANE_CONCURRENCY as usize)));
            next.insert(lane, LaneEntry { token, inflight });
        }
        *lanes = next;
    }

    /// Mint (or rotate) a credential locally. Production credentials come
    /// from the guest ([`LaneRegistry::replace_all`]); tests mint directly.
    #[cfg(test)]
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

#[cfg(test)]
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

/// The guest's live lanes, as the control wire reports them.
pub struct LaneSnapshot {
    pub boot_id: String,
    pub lanes: Vec<(String, [u8; 32])>,
}

/// Where the tray learns lane credentials (the guest, over the control wire).
pub trait LaneSource: Send + Sync {
    fn fetch(&self) -> BoxFuture<'_, io::Result<LaneSnapshot>>;
}

/// Parse one `LemonadeLane` token; a malformed one is dropped, never trusted.
pub fn lane_token(token_hex: &str) -> Option<[u8; 32]> {
    unhex32(token_hex)
}

/// How often an unknown preamble may trigger a lane refresh.
const LANE_REFRESH_MIN_INTERVAL: Duration = Duration::from_millis(500);

pub struct Relay {
    config: RelayConfig,
    lanes: Arc<LaneRegistry>,
    catalog: Arc<dyn ModelCatalog>,
    /// One at a time across all lanes for the serialised routes.
    media_gate: Arc<Semaphore>,
    lane_source: Option<Arc<dyn LaneSource>>,
    last_refresh: tokio::sync::Mutex<Option<std::time::Instant>>,
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
            lane_source: None,
            last_refresh: tokio::sync::Mutex::new(None),
        }
    }

    /// Learn lanes from `source` when a preamble names an unknown or rotated
    /// credential (a forge launched since the last fetch).
    pub fn with_lane_source(mut self, source: Arc<dyn LaneSource>) -> Self {
        self.lane_source = Some(source);
        self
    }

    pub fn lanes(&self) -> &LaneRegistry {
        &self.lanes
    }

    /// Serve ONE guest connection: credential, one request, one response, close.
    pub async fn serve_connection<S>(&self, guest: S)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        self.serve_timed(guest, Vec::new()).await;
    }

    /// Serve one tray-DIALED connection: it parks, with no timer, until the
    /// guest pairs it with a forge request (or closes it); from the first byte
    /// on, every rule and cap of [`Relay::serve_connection`] applies.
    pub async fn serve_parked<S>(&self, mut guest: S)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        let mut first = vec![0u8; 256];
        let n = match guest.read(&mut first).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        first.truncate(n);
        self.serve_timed(guest, first).await;
    }

    async fn serve_timed<S>(&self, guest: S, initial: Vec<u8>)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        let total = self.config.total_timeout;
        if tokio::time::timeout(total, self.serve_inner(guest, initial))
            .await
            .is_err()
        {
            tracing::warn!(
                route = "-",
                "lemonade relay: total timeout (30 min cap) hit"
            );
        }
    }

    /// Re-read the guest's lanes, at most once per interval.
    async fn refresh_lanes(&self) {
        let Some(source) = &self.lane_source else {
            return;
        };
        let mut last = self.last_refresh.lock().await;
        if last.is_some_and(|t| t.elapsed() < LANE_REFRESH_MIN_INTERVAL) {
            return;
        }
        *last = Some(std::time::Instant::now());
        match source.fetch().await {
            Ok(snap) => self.lanes.replace_all(snap.lanes),
            Err(e) => tracing::warn!(error = %e, "lemonade relay: lane refresh failed"),
        }
    }

    async fn serve_inner<S>(&self, mut guest: S, initial: Vec<u8>)
    where
        S: AsyncRead + AsyncWrite + Unpin + Send,
    {
        // 1. Identity, before anything else and before any upstream byte.
        let (lane, gate, mut buf) = match self.read_preamble(&mut guest, initial).await {
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
        mut buf: Vec<u8>,
    ) -> Option<(String, Arc<Semaphore>, Vec<u8>)> {
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
        // Verify against the guest's CURRENT table: a cache older than the
        // refresh interval is re-read first, so a relaunch's rotation (and a
        // stopped forge's revocation) take effect on the next request rather
        // than lingering in the tray. Rate-limited inside.
        self.refresh_lanes().await;
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

/// Whether the tray runs the relay at all. OPT-IN
/// (`TILLANDSIAS_LEMONADE_RELAY=1`): without it the tray never dials, so the
/// guest never arms a lane, mints a credential or starts a forwarder.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn relay_opted_in() -> bool {
    std::env::var("TILLANDSIAS_LEMONADE_RELAY")
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "on" | "true"))
        .unwrap_or(false)
}

// ─── The dialer (platform-neutral) ───────────────────────────────────────────

/// Parked tray connections kept open per VM boot. Two per lane is the lane
/// cap; four covers two busy lanes without a dial on the request path.
pub const PARKED_DIALS: usize = 4;
/// Pause after a failed dial before the next (the guest may be booting).
const DIAL_RETRY: Duration = Duration::from_secs(2);

/// Keeps [`PARKED_DIALS`] outbound connections parked on the guest's relay
/// listener, for ONE guest boot at a time. [`Dialer::arm`] with a new boot id
/// bumps the generation: every worker of the old generation exits (even one
/// parked mid-dial or mid-wait), and a fresh pool starts.
pub struct Dialer {
    generation: tokio::sync::watch::Sender<u64>,
    armed_for: Mutex<Option<String>>,
}

impl Default for Dialer {
    fn default() -> Self {
        Self {
            generation: tokio::sync::watch::channel(0).0,
            armed_for: Mutex::new(None),
        }
    }
}

impl Dialer {
    /// Arm for `boot_id`. `None` when already armed for it (no new workers);
    /// otherwise the new workers' handles.
    pub fn arm<D, F, S>(
        &self,
        boot_id: &str,
        relay: Arc<Relay>,
        parked: usize,
        dial: D,
    ) -> Option<Vec<tokio::task::JoinHandle<()>>>
    where
        D: Fn() -> F + Clone + Send + Sync + 'static,
        F: Future<Output = io::Result<S>> + Send + 'static,
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        {
            let mut armed = self.armed_for.lock().unwrap_or_else(|p| p.into_inner());
            if armed.as_deref() == Some(boot_id) {
                return None;
            }
            *armed = Some(boot_id.to_string());
        }
        let mine = {
            let mut next = 0;
            self.generation.send_modify(|g| {
                *g += 1;
                next = *g;
            });
            next
        };
        tracing::info!(boot_id, generation = mine, "lemonade relay dialer armed");
        Some(
            (0..parked)
                .map(|_| {
                    let (rx, relay, dial) =
                        (self.generation.subscribe(), relay.clone(), dial.clone());
                    tokio::spawn(dial_worker(mine, rx, relay, dial))
                })
                .collect(),
        )
    }
}

async fn dial_worker<D, F, S>(
    mine: u64,
    mut generation: tokio::sync::watch::Receiver<u64>,
    relay: Arc<Relay>,
    dial: D,
) where
    D: Fn() -> F + Send + Sync + 'static,
    F: Future<Output = io::Result<S>> + Send + 'static,
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    loop {
        if *generation.borrow() != mine {
            return;
        }
        let superseded = async {
            while generation.changed().await.is_ok() {
                if *generation.borrow() != mine {
                    return;
                }
            }
        };
        let work = async {
            match dial().await {
                Ok(stream) => relay.serve_parked(stream).await,
                Err(e) => {
                    tracing::debug!(error = %e, "lemonade relay: dial failed; retrying");
                    tokio::time::sleep(DIAL_RETRY).await;
                }
            }
        };
        tokio::select! {
            _ = superseded => return,
            _ = work => {}
        }
    }
}

// ─── hvsocket dial + control-wire lanes (Windows only) ───────────────────────

#[cfg(target_os = "windows")]
pub mod hv {
    use super::*;
    use tillandsias_control_wire::transport::{
        CONTROL_WIRE_VSOCK_PORT, LEMONADE_RELAY_VSOCK_PORT, Transport,
    };
    use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};

    /// The guest's lanes, asked over a fresh authenticated control-wire
    /// connection (the same open/handshake as every tray request).
    pub struct ControlWireLanes;

    impl LaneSource for ControlWireLanes {
        fn fetch(&self) -> BoxFuture<'_, io::Result<LaneSnapshot>> {
            Box::pin(async {
                let stream =
                    crate::hvsocket::open_and_wrap_hvsocket_stream(CONTROL_WIRE_VSOCK_PORT).await?;
                let mut client = tillandsias_host_shell::vsock_client::Client::from_stream(
                    stream,
                    Transport::Vsock {
                        cid: 0,
                        port: CONTROL_WIRE_VSOCK_PORT,
                    },
                );
                client
                    .handshake()
                    .await
                    .map_err(|e| io::Error::other(format!("handshake: {e}")))?;
                let seq = client.allocate_seq();
                let reply = client
                    .request(&ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq,
                        body: ControlMessage::LemonadeLanesRequest { seq },
                    })
                    .await
                    .map_err(|e| io::Error::other(format!("LemonadeLanesRequest: {e}")))?;
                match reply.body {
                    ControlMessage::LemonadeLanesReply { boot_id, lanes, .. } => Ok(LaneSnapshot {
                        boot_id,
                        lanes: lanes
                            .into_iter()
                            .filter_map(|l| lane_token(&l.token_hex).map(|t| (l.lane, t)))
                            .collect(),
                    }),
                    other => Err(io::Error::other(format!(
                        "expected LemonadeLanesReply, got {}",
                        other.kind()
                    ))),
                }
            })
        }
    }

    static RELAY: std::sync::OnceLock<Arc<Relay>> = std::sync::OnceLock::new();
    static DIALER: std::sync::OnceLock<Dialer> = std::sync::OnceLock::new();

    fn relay() -> Arc<Relay> {
        RELAY
            .get_or_init(|| {
                let config = RelayConfig::tray_default();
                let catalog = Arc::new(UpstreamCatalog {
                    upstream: config.upstream,
                    connect_timeout: config.connect_timeout,
                    read_timeout: Duration::from_secs(30),
                });
                Arc::new(
                    Relay::new(config, Arc::new(LaneRegistry::default()), catalog)
                        .with_lane_source(Arc::new(ControlWireLanes)),
                )
            })
            .clone()
    }

    /// Fetch the guest's lanes and boot id, then (re)arm the dialer for that
    /// boot. Called on every control-subscription (re)establishment, which is
    /// how a VM restart reaches the tray.
    pub async fn announce() -> io::Result<()> {
        let snap = ControlWireLanes.fetch().await?;
        let relay = relay();
        relay.lanes().replace_all(snap.lanes);
        let rearmed =
            DIALER
                .get_or_init(Dialer::default)
                .arm(&snap.boot_id, relay, PARKED_DIALS, || {
                    crate::hvsocket::open_and_wrap_hvsocket_stream(LEMONADE_RELAY_VSOCK_PORT)
                });
        if rearmed.is_some() {
            tracing::info!(boot_id = %snap.boot_id, "lemonade relay dialing the guest");
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "lemonade_relay_tests.rs"]
mod tests;
