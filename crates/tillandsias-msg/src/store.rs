// @trace order:1506-nvqt, order:1506-q7ab, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
//
// store — the lane store shared by the msg CLI (tillandsias-plan, 1506-nvqt)
// and the resident mover (tillandsias --msg-serve, 1506-q7ab). Moved here from
// tillandsias-plan's msg_store.rs so the mover can link it without pulling the
// plan engine into the tray binary; the CLI half stayed and re-exports this.
//
// OPERATOR RULINGS 2026-09-29 (plan fragment ...-1506-3xu7-ack-semantics-ruling):
//   * ACK means DELIVERED — the destination mailbox durably accepted the
//     message — and is produced by the infrastructure, never by an agent.
//   * Every message carries a TTL (default 86400 s, 60 … 604800 s).
//   * Broadcasts ack per recipient and are never replied to.
//   * At-least-once with idempotent ids, deduplicated at the mailbox.
//
// LAYOUT (design Decision 2), per lane:
//   <lane>/outbox/{tmp,new}  inbox/{tmp,new,cur}  dead/  receipts/
//   <lane>/seq          the sender's per-destination counters (YAML map)
//   <lane>/seen         the mailbox's (from, id, expires) dedupe set
//   <lane>/recv-state   recv's local gap bookkeeping (never reported)
// Every write is tmp → fsync → rename → fsync(dir).
//
// Every function the INFRASTRUCTURE calls inside a lane (mailbox_accept,
// record_ack, record_undelivered, ensure_receipt, resolve_wildcard,
// sweep_lane) goes through lanefs::Lane: fd-relative and no-follow, because a
// forge holds its lane directory and the mover runs on the host.

use crate::lanefs::{self, Lane, SyncFn};
use crate::shape;
use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Where a forge's own lane directory is bind-mounted (1506-q7ab).
pub const FORGE_LANE_MOUNT: &str = "/run/host/tillandsias-msg";

/// Every directory of a lane, created by [`ensure_lane`].
pub const LANE_DIRS: &[&str] = &[
    "outbox/tmp",
    "outbox/new",
    "inbox/tmp",
    "inbox/new",
    "inbox/cur",
    "dead",
    "receipts",
];

// ── envelope and receipt ─────────────────────────────────────────────────────

/// One message. On disk as YAML so a human can read a mailbox. In an outbox,
/// `to` lists every recipient of the send; the copy a mailbox holds carries
/// exactly one.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Envelope {
    pub id: String,
    pub from: String,
    pub to: Vec<String>,
    #[serde(default)]
    pub from_agent: String,
    /// Per (sender lane, destination) counter for a unicast; 0 on a broadcast,
    /// which is unsequenced (no gap can be judged across differing groups).
    #[serde(default)]
    pub seq: u64,
    pub ts: String,
    pub ttl_s: u64,
    #[serde(default)]
    pub broadcast: bool,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_reply_to: Option<String>,
    pub body: String,
}

impl Envelope {
    /// Parse the on-disk YAML form.
    pub fn from_yaml(bytes: &[u8]) -> Result<Self, String> {
        serde_yaml::from_slice(bytes).map_err(|e| e.to_string())
    }

    /// The on-disk YAML form.
    pub fn to_yaml(&self) -> String {
        serde_yaml::to_string(self).unwrap_or_default()
    }

    pub fn sent_at(&self) -> Option<DateTime<Utc>> {
        parse_ts(&self.ts)
    }

    /// True once `now` is at or past `ts + ttl_s`. An unparseable `ts` is not
    /// judged here; callers skip such a file rather than guess its age.
    pub fn expired(&self, now: DateTime<Utc>) -> bool {
        self.sent_at()
            .is_some_and(|t| now >= t + chrono::Duration::seconds(self.ttl_s as i64))
    }
}

/// One recipient's delivery state, written by `send` as `pending` and changed
/// only by the infrastructure ([`record_ack`], [`record_undelivered`]) or by
/// the TTL sweep.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RecipientState {
    pub to: String,
    /// `pending` | `acked` | `undelivered`
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl RecipientState {
    pub fn pending(to: &str) -> Self {
        Self {
            to: to.to_string(),
            state: "pending".into(),
            at: None,
            via: None,
            reason: None,
        }
    }
}

/// `receipts/<id>` in the SENDER's lane.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Receipt {
    pub id: String,
    pub from: String,
    pub ts: String,
    pub ttl_s: u64,
    pub broadcast: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row: Option<String>,
    pub recipients: Vec<RecipientState>,
}

impl Receipt {
    /// The latest terminal time when EVERY recipient is terminal, else None.
    pub fn terminal_at(&self) -> Option<DateTime<Utc>> {
        let mut last: Option<DateTime<Utc>> = None;
        for r in &self.recipients {
            if r.state == "pending" {
                return None;
            }
            let at = r.at.as_deref().and_then(parse_ts)?;
            last = Some(last.map_or(at, |l| l.max(at)));
        }
        last
    }

    /// `status` output lines, exactly the grammar of the spec.
    pub fn status_lines(&self) -> Vec<String> {
        let one = |r: &RecipientState, bcast: bool| -> Vec<String> {
            match r.state.as_str() {
                "acked" => {
                    let mut v = vec![format!("acked:{}@{}", r.to, r.at.as_deref().unwrap_or("?"))];
                    if !bcast && let Some(via) = &r.via {
                        v.push(format!("via:{via}"));
                    }
                    v
                }
                "undelivered" => {
                    let reason = r.reason.as_deref().unwrap_or("unknown");
                    if bcast {
                        vec![format!("undelivered:{reason}:{}", r.to)]
                    } else {
                        vec![format!("undelivered:{reason}")]
                    }
                }
                _ if bcast => vec![format!("pending:{}", r.to)],
                _ => vec!["pending".to_string()],
            }
        };
        if !self.broadcast && self.recipients.len() == 1 {
            return one(&self.recipients[0], false);
        }
        let mut out = vec![format!("broadcast:{}", self.recipients.len())];
        for r in &self.recipients {
            out.extend(one(r, true));
        }
        out
    }
}

// ── time, ids, tokens ────────────────────────────────────────────────────────

pub fn fmt_ts(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn parse_ts(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

/// `[a-z0-9][a-z0-9-]*`, at most 63 bytes: a host or a lane label.
pub fn valid_label(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !s.starts_with('-')
}

/// `<host>/<lane>`.
pub fn valid_address(s: &str) -> bool {
    s.split_once('/')
        .is_some_and(|(h, l)| valid_label(h) && valid_label(l))
}

/// `@<host>/*` — every lane present on `<host>` at delivery time. Returns the
/// host when `s` is one.
pub fn wildcard_host(s: &str) -> Option<&str> {
    s.strip_prefix('@')
        .and_then(|n| n.strip_suffix("/*"))
        .filter(|h| valid_label(h))
}

/// A receipt id: `m-<utc>-<8 hex>` or a caller's `--id` of the same alphabet.
pub fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        && !s.starts_with('.')
        && !s.starts_with('-')
}

/// A ledger order token such as `1506-nvqt`.
pub fn valid_order(s: &str) -> bool {
    let Some((n, t)) = s.split_once('-') else {
        return false;
    };
    (3..=5).contains(&n.len())
        && n.bytes().all(|b| b.is_ascii_digit())
        && t.len() == 4
        && t.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

fn random_hex8() -> String {
    let mut buf = [0u8; 4];
    let ok = File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !ok {
        use sha2::{Digest, Sha256};
        let seed = format!(
            "{:?}{}{:?}",
            std::time::SystemTime::now(),
            std::process::id(),
            std::thread::current().id()
        );
        let h = Sha256::digest(seed.as_bytes());
        return h[..4].iter().map(|b| format!("{b:02x}")).collect();
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn new_id(now: DateTime<Utc>) -> String {
    format!("m-{}-{}", now.format("%Y%m%dt%H%M%Sz"), random_hex8())
}

/// The send time a generated id encodes, if it is one.
pub fn id_time(id: &str) -> Option<DateTime<Utc>> {
    let stamp = id.strip_prefix("m-")?.get(..16)?;
    NaiveDateTime::parse_from_str(stamp, "%Y%m%dt%H%M%Sz")
        .ok()
        .map(|n| n.and_utc())
}

/// Lowercase, domain-stripped, `[a-z0-9-]` only: `agent-identity.sh node-name`'s rule.
pub fn sanitize_host(raw: &str) -> String {
    let short = raw.split('.').next().unwrap_or("").to_ascii_lowercase();
    let out = sanitize_label(&short);
    if out.is_empty() {
        "unknown-host".into()
    } else {
        out
    }
}

/// `[a-z0-9-]` only, runs of anything else collapsed to one `-`, trimmed of
/// `-`, at most 63 bytes. Empty when nothing usable remains.
pub fn sanitize_label(raw: &str) -> String {
    let mut out = String::new();
    for c in raw.to_ascii_lowercase().chars() {
        let c = if c.is_ascii_lowercase() || c.is_ascii_digit() {
            c
        } else {
            '-'
        };
        if !(c == '-' && out.ends_with('-')) {
            out.push(c);
        }
    }
    let mut out = out.trim_matches('-').to_string();
    out.truncate(63);
    out.trim_end_matches('-').to_string()
}

/// This host's label: `TILLANDSIAS_MSG_HOST` when set, else gethostname(2),
/// sanitized. The launcher exports it into every forge so a forge's `from`
/// names the host, not the container's hostname.
pub fn local_host_label() -> String {
    if let Ok(h) = std::env::var("TILLANDSIAS_MSG_HOST")
        && !h.is_empty()
    {
        return sanitize_host(&h);
    }
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: `buf` is valid for `buf.len()` bytes; a truncated name is cut
        // at the first NUL or the buffer's end below.
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
        if rc == 0 {
            let n = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            if n > 0 {
                return sanitize_host(&String::from_utf8_lossy(&buf[..n]));
            }
        }
    }
    #[cfg(windows)]
    {
        if let Ok(h) = std::env::var("COMPUTERNAME")
            && !h.is_empty()
        {
            return sanitize_host(&h);
        }
    }
    "unknown-host".into()
}

/// The store root when nothing overrides it:
/// `$XDG_STATE_HOME/tillandsias/msg`, else `$HOME/.local/state/tillandsias/msg`.
/// Lanes live at `<root>/lanes/<lane>`.
pub fn default_store_root(xdg_state_home: Option<PathBuf>, home: Option<PathBuf>) -> PathBuf {
    let state = xdg_state_home.unwrap_or_else(|| {
        home.unwrap_or_else(|| PathBuf::from("."))
            .join(".local/state")
    });
    state.join("tillandsias/msg")
}

// ── the wake socket ──────────────────────────────────────────────────────────
//
// The mover binds a Unix stream socket and writes ONE byte to every connected
// waiter per delivery; `recv --wait` connects and blocks on it. A wake is a
// hint, never a message: the waiter re-reads its own inbox/new after every
// wake and at least every 250 ms, so a missed wake, an absent mover or a
// forge (which has no route to the host's runtime directory) costs latency,
// never mail.

/// `explicit` (TILLANDSIAS_MSG_WAKE_SOCK), else
/// `$XDG_RUNTIME_DIR/tillandsias/msg.sock`, else none.
pub fn wake_socket_path(
    explicit: Option<PathBuf>,
    xdg_runtime_dir: Option<PathBuf>,
) -> Option<PathBuf> {
    explicit.or_else(|| xdg_runtime_dir.map(|d| d.join("tillandsias/msg.sock")))
}

/// Block until `lane_dir/inbox/new` holds a message or `deadline` passes.
pub fn wait_for_mail(lane_dir: &Path, wake: Option<&Path>, deadline: std::time::Instant) {
    use std::time::{Duration, Instant};
    let has_mail = || !box_files(&lane_dir.join("inbox/new")).is_empty();
    #[cfg(unix)]
    let mut sock = wake.and_then(|p| std::os::unix::net::UnixStream::connect(p).ok());
    #[cfg(not(unix))]
    let _ = wake;
    while !has_mail() {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        let slice = (deadline - now).min(Duration::from_millis(250));
        #[cfg(unix)]
        if let Some(s) = sock.as_mut() {
            let _ = s.set_read_timeout(Some(slice.max(Duration::from_millis(1))));
            let mut b = [0u8; 64];
            // Ok(0): the mover closed the socket (it stopped) — poll from here
            // on. A byte or a timeout: re-read inbox/new either way.
            if let Ok(0) = s.read(&mut b) {
                sock = None;
            }
            continue;
        }
        std::thread::sleep(slice.min(Duration::from_millis(100)));
    }
}

// ── path-based helpers (the CLI's own lane) ──────────────────────────────────

pub fn sync_dir(dir: &Path) {
    #[cfg(unix)]
    if let Ok(f) = File::open(dir) {
        let _ = f.sync_all();
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// tmp → fsync → rename → fsync(dir). `tmp_dir` and `dir` share a filesystem.
/// Path-based: used by the CLI for its OWN lane's bookkeeping (`seq`,
/// `recv-state`, the outbox). The infrastructure uses [`Lane::write_durable`].
pub fn write_durable(tmp_dir: &Path, dir: &Path, name: &str, bytes: &[u8]) -> io::Result<PathBuf> {
    fs::create_dir_all(tmp_dir)?;
    fs::create_dir_all(dir)?;
    let tmp = tmp_dir.join(format!(".{name}.{}.{}", std::process::id(), random_hex8()));
    {
        let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    let dst = dir.join(name);
    if let Err(e) = fs::rename(&tmp, &dst) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    sync_dir(dir);
    Ok(dst)
}

pub fn read_yaml<T: for<'de> Deserialize<'de>>(p: &Path) -> Option<T> {
    serde_yaml::from_str(&fs::read_to_string(p).ok()?).ok()
}

/// Files of a box directory, dot-files (in-flight tmp names) excluded.
pub fn box_files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| {
                    p.is_file()
                        && !p
                            .file_name()
                            .and_then(|n| n.to_str())
                            .is_some_and(|n| n.starts_with('.'))
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

// ── lane-relative helpers (the infrastructure) ───────────────────────────────

/// Create a lane's directories (refusing any that exists as a symlink).
pub fn ensure_lane(lane_dir: &Path) -> io::Result<()> {
    Lane::create(lane_dir)?.ensure_dirs(LANE_DIRS)
}

fn yaml_in<T: for<'de> Deserialize<'de>>(lane: &Lane, rel: &str, name: &str) -> Option<T> {
    let bytes = lane.read(rel, name).ok()??;
    serde_yaml::from_slice(&bytes).ok()
}

pub fn read_receipt(lane_dir: &Path, id: &str) -> Option<Receipt> {
    read_receipt_in(&Lane::open(lane_dir).ok()?, id)
}

pub fn read_receipt_in(lane: &Lane, id: &str) -> Option<Receipt> {
    if !valid_id(id) {
        return None;
    }
    yaml_in(lane, "receipts", id)
}

pub fn read_envelope_in(lane: &Lane, rel: &str, name: &str) -> Option<Envelope> {
    yaml_in(lane, rel, name)
}

pub fn write_receipt(lane_dir: &Path, r: &Receipt) -> io::Result<()> {
    let lane = Lane::open(lane_dir)?;
    lane.ensure_dirs(&["outbox/tmp", "receipts"])?;
    write_receipt_in(&lane, r)
}

fn write_receipt_in(lane: &Lane, r: &Receipt) -> io::Result<()> {
    if !valid_id(&r.id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("not a receipt id: {:?}", r.id),
        ));
    }
    let y = serde_yaml::to_string(r).map_err(io::Error::other)?;
    lane.write_durable("outbox/tmp", "receipts", &r.id, y.as_bytes(), lanefs::fsync)
}

/// A tiny exclusive lock for read-modify-write of a lane file (`seq`, `seen`,
/// `receipts/`), created fd-relative and never through a symlink.
pub struct LaneLock<'a> {
    lane: &'a Lane,
    name: &'static str,
}

impl<'a> LaneLock<'a> {
    pub fn take(lane: &'a Lane, name: &'static str) -> io::Result<Self> {
        for _ in 0..500 {
            if lane.create_excl(name)? {
                return Ok(Self { lane, name });
            }
            // A lock older than 10 s belongs to a dead process.
            if lane.age("", name).is_some_and(|a| a.as_secs() > 10) {
                let _ = lane.remove("", name);
            } else {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            format!("lock busy: {}/{name}", lane.path().display()),
        ))
    }
}

impl Drop for LaneLock<'_> {
    fn drop(&mut self) {
        let _ = self.lane.remove("", self.name);
    }
}

// ── the infrastructure side (called by the mover / daemon, never by a verb) ──

/// What a mailbox did with an arriving copy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Accept {
    /// Written into `inbox/new` and fsync'd: the caller may now ack.
    Accepted,
    /// `(from, id)` was already seen: nothing written, and the caller acks
    /// AGAIN (at-least-once, deduplicated at the mailbox).
    Duplicate,
    /// Past its TTL on arrival: nothing written, no ack.
    Expired,
}

/// The mailbox's durable acceptance of one copy (`to` = this mailbox). This is
/// the fact an ack reports; the mover (1506-q7ab) and the LAN daemon
/// (1506-7tq4) call it and no `msg` verb does.
pub fn mailbox_accept(
    dest_lane_dir: &Path,
    copy: &Envelope,
    now: DateTime<Utc>,
) -> io::Result<Accept> {
    mailbox_accept_with(dest_lane_dir, copy, now, lanefs::fsync)
}

/// [`mailbox_accept`] with the sync injected. The copy is fsync'd into
/// `inbox/new`, the directory fsync'd, and only then is `(from, id)` appended
/// to `seen` and fsync'd; any sync failure returns the error with nothing
/// recorded as seen, so the caller neither acks nor loses the retry.
pub fn mailbox_accept_with(
    dest_lane_dir: &Path,
    copy: &Envelope,
    now: DateTime<Utc>,
    sync: SyncFn,
) -> io::Result<Accept> {
    if copy.expired(now) {
        return Ok(Accept::Expired);
    }
    if !valid_id(&copy.id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("not a message id: {:?}", copy.id),
        ));
    }
    let lane = Lane::create(dest_lane_dir)?;
    lane.ensure_dirs(LANE_DIRS)?;
    let _lock = LaneLock::take(&lane, ".seen.lock")?;
    let seen = lane
        .read("", "seen")?
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    let key = format!("{} {} ", copy.from, copy.id);
    if seen.lines().any(|l| l.starts_with(&key)) {
        return Ok(Accept::Duplicate);
    }
    let y = serde_yaml::to_string(copy).map_err(io::Error::other)?;
    lane.write_durable("inbox/tmp", "inbox/new", &copy.id, y.as_bytes(), sync)?;
    let expires = copy
        .sent_at()
        .map(|t| t.timestamp() + copy.ttl_s as i64)
        .unwrap_or(0);
    lane.append("seen", format!("{key}{expires}\n").as_bytes(), sync)?;
    lane.sync_root(sync)?;
    Ok(Accept::Accepted)
}

fn set_recipient(
    sender_lane_dir: &Path,
    id: &str,
    mailbox: &str,
    update: impl Fn(&mut RecipientState),
) -> io::Result<()> {
    let lane = Lane::open(sender_lane_dir)?;
    let _lock = LaneLock::take(&lane, ".receipts.lock")?;
    let mut r = read_receipt_in(&lane, id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("no receipt for {id}")))?;
    match r.recipients.iter_mut().find(|x| x.to == mailbox) {
        Some(x) => update(x),
        None => {
            // A wildcard group (`@<host>/*`) is resolved at delivery time: the
            // concrete lane joins the receipt when the infrastructure reports it.
            let mut x = RecipientState::pending(mailbox);
            update(&mut x);
            r.recipients.push(x);
        }
    }
    write_receipt_in(&lane, &r)
}

/// The ack: `mailbox` durably accepted `id`. Infrastructure only.
pub fn record_ack(
    sender_lane_dir: &Path,
    id: &str,
    mailbox: &str,
    at: DateTime<Utc>,
    via: &str,
) -> io::Result<()> {
    set_recipient(sender_lane_dir, id, mailbox, |x| {
        x.state = "acked".into();
        x.at = Some(fmt_ts(at));
        x.via = Some(via.to_string());
        x.reason = None;
    })
}

/// A terminal failure for one recipient (`expired`, `refused:<verdict>`).
pub fn record_undelivered(
    sender_lane_dir: &Path,
    id: &str,
    mailbox: &str,
    reason: &str,
    at: DateTime<Utc>,
) -> io::Result<()> {
    set_recipient(sender_lane_dir, id, mailbox, |x| {
        x.state = "undelivered".into();
        x.at = Some(fmt_ts(at));
        x.reason = Some(reason.to_string());
    })
}

/// Write a pending receipt for `env` when the sender lane holds none — an
/// envelope written straight into an outbox directory, bypassing `send`. The
/// receipt's `from` is `mount_from`, the address the MOUNT vouches for, never
/// the envelope's claim.
pub fn ensure_receipt(sender_lane_dir: &Path, env: &Envelope, mount_from: &str) -> io::Result<()> {
    let lane = Lane::open(sender_lane_dir)?;
    lane.ensure_dirs(&["outbox/tmp", "receipts"])?;
    let _lock = LaneLock::take(&lane, ".receipts.lock")?;
    if read_receipt_in(&lane, &env.id).is_some() {
        return Ok(());
    }
    let r = Receipt {
        id: env.id.clone(),
        from: mount_from.to_string(),
        ts: env.ts.clone(),
        ttl_s: env.ttl_s,
        broadcast: env.broadcast || env.to.len() > 1 || env.to.iter().any(|t| t.starts_with('@')),
        row: env.row.clone().filter(|r| valid_order(r)),
        recipients: env.to.iter().map(|t| RecipientState::pending(t)).collect(),
    };
    write_receipt_in(&lane, &r)
}

/// Replace the literal `wildcard` recipient (`@<host>/*`) by the concrete
/// mailboxes it resolved to at delivery time, each `pending`; with none, the
/// wildcard itself becomes `undelivered:refused:empty-group`.
pub fn resolve_wildcard(
    sender_lane_dir: &Path,
    id: &str,
    wildcard: &str,
    mailboxes: &[String],
    at: DateTime<Utc>,
) -> io::Result<()> {
    let lane = Lane::open(sender_lane_dir)?;
    let _lock = LaneLock::take(&lane, ".receipts.lock")?;
    let mut r = read_receipt_in(&lane, id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("no receipt for {id}")))?;
    let Some(pos) = r
        .recipients
        .iter()
        .position(|x| x.to == wildcard && x.state == "pending")
    else {
        return Ok(());
    };
    if mailboxes.is_empty() {
        let x = &mut r.recipients[pos];
        x.state = "undelivered".into();
        x.at = Some(fmt_ts(at));
        x.reason = Some("refused:empty-group".into());
    } else {
        r.recipients.remove(pos);
        for m in mailboxes {
            if !r.recipients.iter().any(|x| &x.to == m) {
                r.recipients.push(RecipientState::pending(m));
            }
        }
        r.broadcast = true;
    }
    write_receipt_in(&lane, &r)
}

/// Drop every inbox message past its TTL, read or unread. Returns the count.
pub fn sweep_inbox(lane_dir: &Path, now: DateTime<Utc>) -> usize {
    match Lane::open(lane_dir) {
        Ok(lane) => sweep_inbox_in(&lane, now),
        Err(_) => 0,
    }
}

fn sweep_inbox_in(lane: &Lane, now: DateTime<Utc>) -> usize {
    let mut n = 0;
    for sub in ["inbox/new", "inbox/cur"] {
        for name in lane.list(sub).unwrap_or_default() {
            if read_envelope_in(lane, sub, &name).is_some_and(|e| e.expired(now))
                && lane.remove(sub, &name).unwrap_or(false)
            {
                n += 1;
            }
        }
    }
    n
}

/// Counts of what one sweep removed or expired.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Swept {
    pub inbox: usize,
    pub outbox_expired: usize,
    pub dead: usize,
    pub receipts: usize,
}

/// The TTL sweep of one lane: expired inbox copies dropped; expired outbox
/// entries to `dead/` with `undelivered:expired` for every still-pending
/// recipient; dead entries and terminal receipts dropped after the retention.
pub fn sweep_lane(lane_dir: &Path, now: DateTime<Utc>) -> io::Result<Swept> {
    let lane = Lane::create(lane_dir)?;
    lane.ensure_dirs(LANE_DIRS)?;
    let mut s = Swept {
        inbox: sweep_inbox_in(&lane, now),
        ..Swept::default()
    };
    let retention = chrono::Duration::seconds(shape::RECEIPT_RETENTION_S as i64);
    for name in lane.list("outbox/new")? {
        let Some(e) = read_envelope_in(&lane, "outbox/new", &name) else {
            continue;
        };
        if !e.expired(now) || !valid_id(&e.id) {
            continue;
        }
        lane.rename("outbox/new", &name, "dead", &e.id)?;
        if let Some(r) = read_receipt_in(&lane, &e.id) {
            for x in r.recipients.iter().filter(|x| x.state == "pending") {
                record_undelivered(lane_dir, &e.id, &x.to, "expired", now)?;
            }
        }
        s.outbox_expired += 1;
    }
    for name in lane.list("dead")? {
        let old = read_envelope_in(&lane, "dead", &name).is_some_and(|e| {
            e.sent_at()
                .is_some_and(|t| now >= t + chrono::Duration::seconds(e.ttl_s as i64) + retention)
        });
        if old && lane.remove("dead", &name).unwrap_or(false) {
            s.dead += 1;
        }
    }
    for name in lane.list("receipts")? {
        let old = yaml_in::<Receipt>(&lane, "receipts", &name)
            .and_then(|r| r.terminal_at())
            .is_some_and(|t| now >= t + retention);
        if old && lane.remove("receipts", &name).unwrap_or(false) {
            s.receipts += 1;
        }
    }
    // Prune seen entries whose message has expired.
    let _lock = LaneLock::take(&lane, ".seen.lock")?;
    if let Some(bytes) = lane.read("", "seen")? {
        let seen = String::from_utf8_lossy(&bytes);
        let keep: Vec<&str> = seen
            .lines()
            .filter(|l| {
                l.rsplit(' ')
                    .next()
                    .and_then(|x| x.parse::<i64>().ok())
                    .is_none_or(|exp| exp > now.timestamp())
            })
            .collect();
        if keep.len() != seen.lines().count() {
            let mut body = keep.join("\n");
            if !body.is_empty() {
                body.push('\n');
            }
            lane.write_durable("inbox/tmp", "", "seen", body.as_bytes(), lanefs::fsync)?;
        }
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> DateTime<Utc> {
        parse_ts("2026-09-29T22:00:00Z").unwrap()
    }

    fn env(id: &str, to: &str) -> Envelope {
        Envelope {
            id: id.into(),
            from: "h/a-default".into(),
            to: vec![to.into()],
            from_agent: "t".into(),
            seq: 1,
            ts: fmt_ts(now()),
            ttl_s: 3600,
            broadcast: false,
            kind: "FYI".into(),
            row: None,
            in_reply_to: None,
            body: "FYI:x:y\n- 1506-q7ab".into(),
        }
    }

    #[test]
    fn a_failed_fsync_is_not_seen_so_the_retry_delivers() {
        fn fail(_: &File) -> io::Result<()> {
            Err(io::Error::other("injected"))
        }
        let t = tempfile::tempdir().unwrap();
        let b = t.path().join("b-default");
        let e = env("m-1", "h/b-default");
        assert!(mailbox_accept_with(&b, &e, now(), fail).is_err());
        assert!(box_files(&b.join("inbox/new")).is_empty());
        assert!(!b.join("seen").exists() || fs::read_to_string(b.join("seen")).unwrap().is_empty());
        // The retry is not mistaken for a duplicate: it writes and accepts.
        assert_eq!(mailbox_accept(&b, &e, now()).unwrap(), Accept::Accepted);
        assert_eq!(mailbox_accept(&b, &e, now()).unwrap(), Accept::Duplicate);
        assert_eq!(box_files(&b.join("inbox/new")).len(), 1);
    }

    #[test]
    fn ensure_receipt_attributes_by_mount_and_resolve_wildcard_fans_out() {
        let t = tempfile::tempdir().unwrap();
        let a = t.path().join("a-default");
        ensure_lane(&a).unwrap();
        let mut e = env("m-2", "@h/*");
        e.from = "h/b-default".into(); // the claim
        ensure_receipt(&a, &e, "h/a-default").unwrap();
        let r = read_receipt(&a, "m-2").unwrap();
        assert_eq!(r.from, "h/a-default");
        assert!(r.broadcast);
        resolve_wildcard(
            &a,
            "m-2",
            "@h/*",
            &["h/b-default".into(), "h/c-default".into()],
            now(),
        )
        .unwrap();
        record_ack(&a, "m-2", "h/b-default", now(), "local").unwrap();
        let r = read_receipt(&a, "m-2").unwrap();
        assert_eq!(
            r.status_lines(),
            vec![
                "broadcast:2".to_string(),
                "acked:h/b-default@2026-09-29T22:00:00Z".into(),
                "pending:h/c-default".into()
            ]
        );
        // An empty resolution is a positive refusal, not a silent pending.
        ensure_receipt(&a, &env("m-3", "@h/*"), "h/a-default").unwrap();
        resolve_wildcard(&a, "m-3", "@h/*", &[], now()).unwrap();
        assert_eq!(
            read_receipt(&a, "m-3").unwrap().status_lines()[1],
            "undelivered:refused:empty-group:@h/*"
        );
    }

    #[test]
    fn labels_sanitize_to_the_address_alphabet() {
        assert_eq!(sanitize_label("My_Project"), "my-project");
        assert_eq!(sanitize_label("--x..y--"), "x-y");
        assert_eq!(sanitize_label("___"), "");
        assert!(valid_label(&sanitize_label(&"a".repeat(100))));
        assert_eq!(wildcard_host("@yoga/*"), Some("yoga"));
        assert_eq!(wildcard_host("@Yoga/*"), None);
        assert_eq!(wildcard_host("yoga/host"), None);
    }
}
