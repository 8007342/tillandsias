//! Fleet coordinator client (order 1826-gi8e).
//!
//! The coordinator (`cloud/coordinator/`, wire contract in
//! `openspec/changes/fleet-coordinator-warm-cache/contract.md`) is a
//! best-effort warm cache in front of the git ledger: project queues, claim
//! overlays and a folded overview. It is never authoritative. Every answer
//! this client gives says where it came from, and when the coordinator cannot
//! be asked (unconfigured, unreachable, 429, or our own budget spent) the
//! caller falls back to the local git-ledger fold with `source: git-ledger`.
//!
//! The coordinator queue has NO receipts and NO acks. That vocabulary belongs
//! to the lane bus (`msg_store.rs`, 1506-nvqt) and is deliberately not reused.
//!
//! Load discipline, which is where "no fixed polling" lives:
//! - [`Limiter`]: a client-side token bucket, so a burst past budget is
//!   refused before any network call.
//! - [`Heartbeat`]: a self-measured interval of at most 120 s that doubles
//!   while the host is busy and emits nothing while a gate or agent turn holds
//!   the lane marker.
//! - [`Client::batch`]: up to 20 ops per request, the server's cap.
//!
//! Credentials come from the environment only (the vault child of 1824-58bm
//! is what puts them there); nothing here writes them to disk or prints them.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// The server's `/v1/batch` cap.
pub const BATCH_MAX: usize = 20;
/// The heartbeat ceiling from the binding design: never more than 2 min.
pub const HEARTBEAT_MAX: Duration = Duration::from_secs(120);
/// The heartbeat floor, so a fast round-trip never turns into a tight loop.
pub const HEARTBEAT_MIN: Duration = Duration::from_secs(15);
/// Client budget per minute. Half the server's default bucket, so one host
/// cannot spend the whole identity's allowance.
pub const DEFAULT_BUDGET_PER_MIN: u32 = 60;
/// A lane marker older than this is a crashed holder, not a held lane.
pub const MARKER_STALE_AFTER: Duration = Duration::from_secs(6 * 3600);

/// Client-side token bucket. `now` is passed in so tests need no clock.
#[derive(Debug, Clone)]
pub struct Limiter {
    capacity: f64,
    tokens: f64,
    per_sec: f64,
    last: Instant,
}

impl Limiter {
    pub fn new(per_min: u32, now: Instant) -> Self {
        let cap = f64::from(per_min.max(1));
        Self { capacity: cap, tokens: cap, per_sec: cap / 60.0, last: now }
    }

    /// Take `cost` tokens, or refuse without spending any.
    pub fn take(&mut self, cost: u32, now: Instant) -> bool {
        let dt = now.saturating_duration_since(self.last).as_secs_f64();
        self.tokens = (self.tokens + dt * self.per_sec).min(self.capacity);
        self.last = now;
        let cost = f64::from(cost);
        if self.tokens >= cost {
            self.tokens -= cost;
            true
        } else {
            false
        }
    }
}

/// Adaptive heartbeat scheduler. Pure: the caller supplies the measured
/// round-trip, the busy signal and whether the lane marker is held.
#[derive(Debug, Clone)]
pub struct Heartbeat {
    current: Duration,
}

impl Default for Heartbeat {
    fn default() -> Self {
        Self { current: HEARTBEAT_MIN }
    }
}

impl Heartbeat {
    /// The wait before the next tick, or `None` while the lane marker is held
    /// (no tick at all during a gate or an agent turn).
    ///
    /// Idle: the interval is measured, 20 round-trips, clamped to
    /// [`HEARTBEAT_MIN`]..=[`HEARTBEAT_MAX`]. Busy: the previous interval
    /// doubles, still capped at [`HEARTBEAT_MAX`].
    pub fn next(&mut self, rtt: Duration, busy: bool, marker_held: bool) -> Option<Duration> {
        if marker_held {
            return None;
        }
        self.current = if busy {
            self.current.saturating_mul(2)
        } else {
            rtt.saturating_mul(20)
        }
        .clamp(HEARTBEAT_MIN, HEARTBEAT_MAX);
        Some(self.current)
    }
}

/// Is the host busy? The 1-minute load average per CPU over 0.8.
pub fn host_busy() -> bool {
    #[cfg(unix)]
    {
        let mut loads = [0f64; 3];
        // SAFETY: getloadavg writes at most `nelem` doubles into the buffer.
        let n = unsafe { libc::getloadavg(loads.as_mut_ptr(), 3) };
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get()) as f64;
        n >= 1 && loads[0] / cpus > 0.8
    }
    #[cfg(not(unix))]
    {
        false
    }
}

/// The lane-marker directory: a gate or an agent turn drops a file here while
/// it runs, and the heartbeat stands down until the directory has no fresh file.
pub fn lane_marker_dir(root: &Path) -> PathBuf {
    root.join(".cache").join("lane-markers")
}

/// True while any marker in `dir` is younger than [`MARKER_STALE_AFTER`].
pub fn lane_marker_held(dir: &Path, now: SystemTime) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().any(|e| {
        e.metadata()
            .and_then(|m| m.modified())
            .ok()
            // A marker stamped after `now` (clock skew, or written mid-check)
            // is as fresh as it gets, not absent.
            .map(|t| now.duration_since(t).unwrap_or(Duration::ZERO))
            .is_some_and(|age| age < MARKER_STALE_AFTER)
    })
}

/// Why the coordinator was not (successfully) asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Offline {
    Unconfigured,
    LocalBudget,
    RateLimited { retry_after_s: u64 },
    Unreachable(String),
    Refused { status: u16, error: String },
}

impl Offline {
    pub fn reason(&self) -> String {
        match self {
            Offline::Unconfigured => "coordinator-unconfigured".into(),
            Offline::LocalBudget => "client-budget-spent".into(),
            Offline::RateLimited { retry_after_s } => format!("rate-limited:retry-after-{retry_after_s}s"),
            Offline::Unreachable(e) => format!("unreachable:{e}"),
            Offline::Refused { status, error } => format!("refused:{status}:{error}"),
        }
    }
}

/// One POST of a JSON body. A trait so tests drive the client without a network.
pub trait Transport {
    fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String>;
}

/// Credentials and endpoint, read from the environment.
#[derive(Clone)]
pub struct Config {
    pub url: String,
    /// Cloudflare Access service token, exchanged for a JWT at the edge.
    pub client_id: Option<String>,
    pub client_secret: Option<String>,
    /// A ready JWT, for a local `wrangler dev` Worker with no Access edge.
    pub jwt: Option<String>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print a secret, not even through {:?}.
        f.debug_struct("Config")
            .field("url", &self.url)
            .field("client_id", &self.client_id.as_ref().map(|_| "<set>"))
            .field("client_secret", &self.client_secret.as_ref().map(|_| "<set>"))
            .field("jwt", &self.jwt.as_ref().map(|_| "<set>"))
            .finish()
    }
}

impl Config {
    pub fn from_env() -> Option<Self> {
        let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let url = get("TILLANDSIAS_COORD_URL")?;
        Some(Self {
            url: url.trim_end_matches('/').to_string(),
            client_id: get("TILLANDSIAS_COORD_CLIENT_ID"),
            client_secret: get("TILLANDSIAS_COORD_CLIENT_SECRET"),
            jwt: get("TILLANDSIAS_COORD_JWT"),
        })
    }
}

/// The real transport: reqwest on a one-shot current-thread runtime, with a
/// short timeout so an unreachable coordinator degrades fast to the ledger.
pub struct HttpTransport {
    cfg: Config,
    timeout: Duration,
}

impl HttpTransport {
    pub fn new(cfg: Config) -> Self {
        Self { cfg, timeout: Duration::from_secs(5) }
    }
}

impl Transport for HttpTransport {
    fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("runtime: {e}"))?;
        rt.block_on(async {
            let client = reqwest::Client::builder()
                .timeout(self.timeout)
                .build()
                .map_err(|e| format!("client: {e}"))?;
            let mut req = client.post(format!("{}{path}", self.cfg.url)).json(body);
            if let (Some(id), Some(secret)) = (&self.cfg.client_id, &self.cfg.client_secret) {
                req = req.header("CF-Access-Client-Id", id).header("CF-Access-Client-Secret", secret);
            }
            if let Some(jwt) = &self.cfg.jwt {
                req = req.header("Cf-Access-Jwt-Assertion", jwt);
            }
            // The error text never carries headers, so no secret can leak here.
            let res = req.send().await.map_err(|e| e.without_url().to_string())?;
            let status = res.status().as_u16();
            let text = res.text().await.map_err(|e| e.without_url().to_string())?;
            let value = serde_json::from_str(&text).unwrap_or(Value::Null);
            Ok((status, value))
        })
    }
}

/// The client: a transport behind a client-side budget.
pub struct Client<T: Transport> {
    transport: T,
    limiter: Limiter,
}

impl<T: Transport> Client<T> {
    pub fn new(transport: T, budget_per_min: u32) -> Self {
        Self { transport, limiter: Limiter::new(budget_per_min, Instant::now()) }
    }

    /// One op. A non-2xx status becomes [`Offline`]; 409 on `claim` is a real
    /// answer (another holder), so it comes back as `Ok` with its body.
    pub fn op(&mut self, op: Value) -> Result<Value, Offline> {
        if !self.limiter.take(1, Instant::now()) {
            return Err(Offline::LocalBudget);
        }
        let (status, body) = self.transport.post("/v1/op", &op).map_err(Offline::Unreachable)?;
        classify(status, body)
    }

    /// Many ops, `BATCH_MAX` per request. Each request costs one budget token
    /// per op, so batching saves round-trips, not budget.
    pub fn batch(&mut self, ops: Vec<Value>) -> Result<Vec<Value>, Offline> {
        let mut out = Vec::with_capacity(ops.len());
        for chunk in ops.chunks(BATCH_MAX) {
            if !self.limiter.take(chunk.len() as u32, Instant::now()) {
                return Err(Offline::LocalBudget);
            }
            let (status, body) = self
                .transport
                .post("/v1/batch", &json!({ "ops": chunk }))
                .map_err(Offline::Unreachable)?;
            let body = classify(status, body)?;
            match body.get("results").and_then(Value::as_array) {
                Some(r) => out.extend(r.iter().cloned()),
                None => return Err(Offline::Unreachable("batch answer had no results".into())),
            }
        }
        Ok(out)
    }

    /// The orders other identities hold live overlays on.
    pub fn claimed_orders(&mut self, ns: &str) -> Result<std::collections::BTreeSet<String>, Offline> {
        let r = self.op(json!({ "op": "claims", "ns": ns }))?;
        Ok(r.get("claims")
            .and_then(Value::as_array)
            .map(|cs| {
                cs.iter()
                    .filter_map(|c| c.get("order").and_then(Value::as_str).map(str::to_string))
                    .collect()
            })
            .unwrap_or_default())
    }
}

fn classify(status: u16, body: Value) -> Result<Value, Offline> {
    match status {
        200..=299 | 409 => Ok(body),
        429 => Err(Offline::RateLimited {
            retry_after_s: body.get("retry_after_s").and_then(Value::as_u64).unwrap_or(60),
        }),
        s => Err(Offline::Refused {
            status: s,
            error: body.get("error").and_then(Value::as_str).unwrap_or("").chars().take(120).collect(),
        }),
    }
}

/// The namespace for a checkout: `owner/repo` from its origin URL, lower-cased,
/// else the directory name. Matches the server's normaliser.
pub fn namespace_for(origin_url: Option<&str>, dir_name: &str) -> String {
    let from_origin = origin_url.and_then(|u| {
        let u = u.trim().trim_end_matches('/').trim_end_matches(".git");
        let tail = u.rsplit_once(':').map_or(u, |(_, t)| t);
        let mut parts = tail.rsplit('/');
        let repo = parts.next()?;
        let owner = parts.next()?;
        Some(format!("{owner}/{repo}"))
    });
    let raw = from_origin.unwrap_or_else(|| dir_name.to_string()).to_ascii_lowercase();
    raw.chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/') { c } else { '-' })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn heartbeat_never_exceeds_two_minutes() {
        let mut hb = Heartbeat::default();
        for rtt_ms in [1u64, 50, 900, 6_000, 60_000, 3_600_000] {
            let d = hb.next(Duration::from_millis(rtt_ms), false, false).unwrap();
            assert!(d <= HEARTBEAT_MAX && d >= HEARTBEAT_MIN, "rtt {rtt_ms}ms -> {d:?}");
        }
        for _ in 0..20 {
            let d = hb.next(Duration::from_millis(100), true, false).unwrap();
            assert!(d <= HEARTBEAT_MAX, "busy -> {d:?}");
        }
    }

    #[test]
    fn heartbeat_doubles_under_busy_then_settles_when_idle() {
        let mut hb = Heartbeat::default();
        let idle = hb.next(Duration::from_millis(1_000), false, false).unwrap();
        assert_eq!(idle, Duration::from_secs(20));
        assert_eq!(hb.next(Duration::from_millis(1_000), true, false), Some(Duration::from_secs(40)));
        assert_eq!(hb.next(Duration::from_millis(1_000), true, false), Some(Duration::from_secs(80)));
        assert_eq!(hb.next(Duration::from_millis(1_000), true, false), Some(HEARTBEAT_MAX));
        assert_eq!(hb.next(Duration::from_millis(1_000), false, false), Some(Duration::from_secs(20)));
    }

    #[test]
    fn heartbeat_emits_no_tick_while_the_marker_is_held() {
        let mut hb = Heartbeat::default();
        assert_eq!(hb.next(Duration::from_millis(10), false, true), None);
        assert_eq!(hb.next(Duration::from_millis(10), true, true), None);
    }

    #[test]
    fn lane_marker_is_held_only_while_fresh() {
        let dir = tempfile::tempdir().unwrap();
        let now = SystemTime::now();
        assert!(!lane_marker_held(&dir.path().join("absent"), now));
        assert!(!lane_marker_held(dir.path(), now));
        std::fs::write(dir.path().join("gate"), "").unwrap();
        assert!(lane_marker_held(dir.path(), now));
        assert!(!lane_marker_held(dir.path(), now + MARKER_STALE_AFTER + Duration::from_secs(1)));
    }

    #[test]
    fn limiter_refuses_a_burst_and_refills() {
        let t0 = Instant::now();
        let mut l = Limiter::new(6, t0);
        assert!((0..6).all(|_| l.take(1, t0)));
        assert!(!l.take(1, t0));
        assert!(l.take(1, t0 + Duration::from_secs(10)));
        assert!(!l.take(5, t0 + Duration::from_secs(10)));
    }

    /// Counts calls; answers from a fixed script.
    struct Fake {
        calls: RefCell<Vec<(String, Value)>>,
        answer: Box<dyn Fn(&str, &Value) -> Result<(u16, Value), String>>,
    }

    impl Transport for &Fake {
        fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
            self.calls.borrow_mut().push((path.into(), body.clone()));
            (self.answer)(path, body)
        }
    }

    fn fake(answer: impl Fn(&str, &Value) -> Result<(u16, Value), String> + 'static) -> Fake {
        Fake { calls: RefCell::new(Vec::new()), answer: Box::new(answer) }
    }

    #[test]
    fn a_burst_past_budget_is_refused_without_a_network_call() {
        let f = fake(|_, _| Ok((200, json!({}))));
        let mut c = Client::new(&f, 3);
        for _ in 0..3 {
            c.op(json!({"op": "recv", "ns": "a/b"})).unwrap();
        }
        assert_eq!(c.op(json!({"op": "recv", "ns": "a/b"})), Err(Offline::LocalBudget));
        assert_eq!(f.calls.borrow().len(), 3, "the refused call must not reach the transport");
    }

    #[test]
    fn batch_splits_at_the_server_cap_and_keeps_order() {
        let f = fake(|_, body| {
            let n = body["ops"].as_array().unwrap().len();
            let results: Vec<Value> = body["ops"].as_array().unwrap().iter().map(|o| json!({"ok": true, "seq": o["i"]})).collect();
            assert!(n <= BATCH_MAX);
            Ok((200, json!({ "results": results })))
        });
        let mut c = Client::new(&f, 1000);
        let ops: Vec<Value> = (0..45).map(|i| json!({"op": "recv", "ns": "a/b", "i": i})).collect();
        let r = c.batch(ops).unwrap();
        assert_eq!(f.calls.borrow().len(), 3);
        assert_eq!(r.iter().map(|v| v["seq"].as_u64().unwrap()).collect::<Vec<_>>(), (0..45).collect::<Vec<_>>());
    }

    #[test]
    fn statuses_degrade_to_typed_offline_reasons() {
        let f = fake(|_, b| match b["op"].as_str().unwrap() {
            "a" => Ok((429, json!({"retry_after_s": 7}))),
            "b" => Ok((401, json!({"error": "unauthenticated"}))),
            "c" => Err("connection refused".into()),
            _ => Ok((409, json!({"holder": "h", "until": 1}))),
        });
        let mut c = Client::new(&f, 100);
        assert_eq!(c.op(json!({"op": "a"})), Err(Offline::RateLimited { retry_after_s: 7 }));
        assert!(matches!(c.op(json!({"op": "b"})), Err(Offline::Refused { status: 401, .. })));
        assert!(matches!(c.op(json!({"op": "c"})), Err(Offline::Unreachable(_))));
        assert_eq!(c.op(json!({"op": "claim"})).unwrap()["holder"], "h");
    }

    #[test]
    fn claimed_orders_reads_the_overlay_list() {
        let f = fake(|_, _| Ok((200, json!({"claims": [{"order": "1826-gi8e", "holder": "x", "until": 9}]}))));
        let mut c = Client::new(&f, 10);
        let got = c.claimed_orders("a/b").unwrap();
        assert!(got.contains("1826-gi8e") && got.len() == 1);
    }

    #[test]
    fn config_debug_never_prints_a_secret() {
        let cfg = Config {
            url: "https://c".into(),
            client_id: Some("ID-VALUE".into()),
            client_secret: Some("SECRET-VALUE".into()),
            jwt: Some("JWT-VALUE".into()),
        };
        let s = format!("{cfg:?}");
        assert!(!s.contains("ID-VALUE") && !s.contains("SECRET-VALUE") && !s.contains("JWT-VALUE"), "{s}");
    }

    #[test]
    fn namespace_matches_the_server_normaliser() {
        assert_eq!(namespace_for(Some("https://github.com/8007342/Tillandsias.git"), "x"), "8007342/tillandsias");
        assert_eq!(namespace_for(Some("git@github.com:Owner/Repo.git"), "x"), "owner/repo");
        assert_eq!(namespace_for(None, "My Project"), "my-project");
    }
}
