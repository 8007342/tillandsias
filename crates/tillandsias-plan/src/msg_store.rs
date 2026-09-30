// @trace order:1506-nvqt, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
//
// msg_store — the LOCAL half of the fleet message bus (1506-nvqt): a
// Maildir-shaped lane store and the `tillandsias-plan msg` verbs over it.
//
// WHAT THIS MODULE IS NOT. It opens no socket and moves nothing between lanes:
// delivery is the resident mover (1506-q7ab) on one host and the LAN daemon
// (1506-7tq4) across hosts. The only thing here that the infrastructure calls
// and no verb reaches is [`mailbox_accept`] + [`record_ack`]: the durable
// (fsync'd) write into a destination mailbox and the ack that may follow it.
//
// OPERATOR RULINGS 2026-09-29 (plan fragment ...-1506-3xu7-ack-semantics-ruling):
//   * ACK means DELIVERED — the destination mailbox durably accepted the
//     message — and is produced by the infrastructure, never by an agent. There
//     is NO `ack` verb; `msg ack` is refused as an unknown verb.
//   * `send` prints the stable receipt id at once; `status <id>` answers
//     pending | acked:<mailbox>@<ts> (then via:<rung>) | undelivered:<reason>.
//   * Reading (`recv`) is local bookkeeping and is never reported back.
//   * Every message carries a TTL (default 86400 s, 60 … 604800 s); the queue
//     is ephemeral; unread messages drop at their TTL.
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
// COORDINATOR DEFAULTS (reversible; operator questions 2 and 3 are open): one
// bare-metal mailbox per host, lane `host` (sessions pass `--lane host`), and
// one lane per forge `<project>-<instance>`; no network discovery at all.

use crate::msg_shape as shape;
use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Where a forge's own lane directory is bind-mounted (1506-q7ab).
pub const FORGE_LANE_MOUNT: &str = "/run/host/tillandsias-msg";

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
    fn terminal_at(&self) -> Option<DateTime<Utc>> {
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

/// A receipt id: `m-<utc>-<8 hex>` or a caller's `--id` of the same alphabet.
pub fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        && !s.starts_with('.')
        && !s.starts_with('-')
}

fn valid_order(s: &str) -> bool {
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
        let seed = format!(
            "{:?}{}{:?}",
            std::time::SystemTime::now(),
            std::process::id(),
            std::thread::current().id()
        );
        let h = crate::host_verbs::sha256_hex(seed.as_bytes());
        return h[..8].to_string();
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn new_id(now: DateTime<Utc>) -> String {
    format!("m-{}-{}", now.format("%Y%m%dt%H%M%Sz"), random_hex8())
}

/// The send time a generated id encodes, if it is one.
fn id_time(id: &str) -> Option<DateTime<Utc>> {
    let stamp = id.strip_prefix("m-")?.get(..16)?;
    NaiveDateTime::parse_from_str(stamp, "%Y%m%dt%H%M%Sz")
        .ok()
        .map(|n| n.and_utc())
}

/// Lowercase, domain-stripped, `[a-z0-9-]` only: `agent-identity.sh node-name`'s rule.
pub fn sanitize_host(raw: &str) -> String {
    let short = raw.split('.').next().unwrap_or("").to_ascii_lowercase();
    let mut out = String::new();
    for c in short.chars() {
        let c = if c.is_ascii_lowercase() || c.is_ascii_digit() {
            c
        } else {
            '-'
        };
        if !(c == '-' && out.ends_with('-')) {
            out.push(c);
        }
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "unknown-host".into()
    } else {
        out
    }
}

// ── durable writes ───────────────────────────────────────────────────────────

fn sync_dir(dir: &Path) {
    #[cfg(unix)]
    if let Ok(f) = File::open(dir) {
        let _ = f.sync_all();
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// tmp → fsync → rename → fsync(dir). `tmp_dir` and `dir` share a filesystem.
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

pub fn ensure_lane(lane_dir: &Path) -> io::Result<()> {
    for sub in [
        "outbox/tmp",
        "outbox/new",
        "inbox/tmp",
        "inbox/new",
        "inbox/cur",
        "dead",
        "receipts",
    ] {
        fs::create_dir_all(lane_dir.join(sub))?;
    }
    Ok(())
}

fn read_yaml<T: for<'de> Deserialize<'de>>(p: &Path) -> Option<T> {
    serde_yaml::from_str(&fs::read_to_string(p).ok()?).ok()
}

pub fn read_receipt(lane_dir: &Path, id: &str) -> Option<Receipt> {
    read_yaml(&lane_dir.join("receipts").join(id))
}

fn write_receipt(lane_dir: &Path, r: &Receipt) -> io::Result<()> {
    let y = serde_yaml::to_string(r).map_err(io::Error::other)?;
    write_durable(
        &lane_dir.join("outbox/tmp"),
        &lane_dir.join("receipts"),
        &r.id,
        y.as_bytes(),
    )
    .map(|_| ())
}

/// Files of a box directory, dot-files (in-flight tmp names) excluded.
fn box_files(dir: &Path) -> Vec<PathBuf> {
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

/// A tiny exclusive lock for read-modify-write of a lane file (`seq`, `seen`).
struct LaneLock(PathBuf);
impl LaneLock {
    fn take(path: PathBuf) -> io::Result<Self> {
        for _ in 0..200 {
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(_) => return Ok(Self(path)),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    // A lock older than 10 s belongs to a dead process.
                    let stale = fs::metadata(&path)
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|m| m.elapsed().ok())
                        .is_some_and(|age| age.as_secs() > 10);
                    if stale {
                        let _ = fs::remove_file(&path);
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                }
                Err(e) => return Err(e),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            format!("lock busy: {}", path.display()),
        ))
    }
}
impl Drop for LaneLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn next_seq(lane_dir: &Path, to: &str) -> io::Result<u64> {
    let _lock = LaneLock::take(lane_dir.join(".seq.lock"))?;
    let path = lane_dir.join("seq");
    let mut map: BTreeMap<String, u64> = read_yaml(&path).unwrap_or_default();
    let n = map.get(to).copied().unwrap_or(0) + 1;
    map.insert(to.to_string(), n);
    let y = serde_yaml::to_string(&map).map_err(io::Error::other)?;
    write_durable(&lane_dir.join("outbox/tmp"), lane_dir, "seq", y.as_bytes())?;
    Ok(n)
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
/// the fact an ack reports; it is exported for 1506-q7ab / 1506-7tq4 and no
/// `msg` verb calls it.
pub fn mailbox_accept(
    dest_lane_dir: &Path,
    copy: &Envelope,
    now: DateTime<Utc>,
) -> io::Result<Accept> {
    if copy.expired(now) {
        return Ok(Accept::Expired);
    }
    ensure_lane(dest_lane_dir)?;
    let _lock = LaneLock::take(dest_lane_dir.join(".seen.lock"))?;
    let seen_path = dest_lane_dir.join("seen");
    let seen = fs::read_to_string(&seen_path).unwrap_or_default();
    let key = format!("{} {} ", copy.from, copy.id);
    if seen.lines().any(|l| l.starts_with(&key)) {
        return Ok(Accept::Duplicate);
    }
    let y = serde_yaml::to_string(copy).map_err(io::Error::other)?;
    write_durable(
        &dest_lane_dir.join("inbox/tmp"),
        &dest_lane_dir.join("inbox/new"),
        &copy.id,
        y.as_bytes(),
    )?;
    let expires = copy
        .sent_at()
        .map(|t| t.timestamp() + copy.ttl_s as i64)
        .unwrap_or(0);
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&seen_path)?;
    writeln!(f, "{key}{expires}")?;
    f.sync_all()?;
    sync_dir(dest_lane_dir);
    Ok(Accept::Accepted)
}

fn set_recipient(
    sender_lane_dir: &Path,
    id: &str,
    mailbox: &str,
    update: impl Fn(&mut RecipientState),
) -> io::Result<()> {
    let mut r = read_receipt(sender_lane_dir, id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("no receipt for {id}")))?;
    match r.recipients.iter_mut().find(|x| x.to == mailbox) {
        Some(x) => update(x),
        None => {
            // A wildcard group (`@<host>/*`) is resolved at delivery time: the
            // concrete lane joins the receipt when the infrastructure reports it.
            let mut x = RecipientState {
                to: mailbox.to_string(),
                state: "pending".into(),
                at: None,
                via: None,
                reason: None,
            };
            update(&mut x);
            r.recipients.push(x);
        }
    }
    write_receipt(sender_lane_dir, &r)
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

// ── the CLI ──────────────────────────────────────────────────────────────────

/// Everything the verbs read from the process environment, gathered once so
/// every test can point the store at a temp directory.
#[derive(Debug, Clone, Default)]
pub struct MsgEnv {
    /// TILLANDSIAS_MSG_ROOT — an explicit store root (`<root>/lanes/<lane>`).
    pub root_override: Option<PathBuf>,
    /// TILLANDSIAS_MSG_LANE_DIR — this lane's directory itself.
    pub lane_dir_override: Option<PathBuf>,
    /// The forge mount (TILLANDSIAS_MSG_FORGE_MOUNT, default [`FORGE_LANE_MOUNT`]).
    pub forge_mount: Option<PathBuf>,
    pub xdg_state_home: Option<PathBuf>,
    pub home: Option<PathBuf>,
    /// TILLANDSIAS_MSG_LANE, exported by the launcher.
    pub lane: Option<String>,
    /// This host's label (TILLANDSIAS_MSG_HOST, else gethostname).
    pub host: String,
    /// TILLANDSIAS_AGENT_ID — attribution only, never authentication.
    pub agent_id: Option<String>,
    /// `plan/fleet` of the checkout (peers/ and groups.yaml).
    pub fleet_dir: PathBuf,
    /// TILLANDSIAS_MSG_SHAPE_LAX=1 — a fixture seam that disables the secret
    /// check. Honoured ONLY with an explicit TILLANDSIAS_MSG_ROOT, so it can
    /// never switch the check off for a real store; the mover (1506-q7ab)
    /// repeats the check regardless.
    pub shape_lax: bool,
}

impl MsgEnv {
    pub fn from_process(fleet_dir: PathBuf) -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let host = var("TILLANDSIAS_MSG_HOST").unwrap_or_else(crate::command_policy::this_host);
        Self {
            root_override: var("TILLANDSIAS_MSG_ROOT").map(PathBuf::from),
            lane_dir_override: var("TILLANDSIAS_MSG_LANE_DIR").map(PathBuf::from),
            forge_mount: Some(PathBuf::from(
                var("TILLANDSIAS_MSG_FORGE_MOUNT").unwrap_or_else(|| FORGE_LANE_MOUNT.into()),
            )),
            xdg_state_home: var("XDG_STATE_HOME").map(PathBuf::from),
            home: var("HOME").map(PathBuf::from),
            lane: var("TILLANDSIAS_MSG_LANE"),
            host: sanitize_host(&host),
            agent_id: var("TILLANDSIAS_AGENT_ID"),
            fleet_dir: var("TILLANDSIAS_MSG_FLEET_DIR")
                .map(PathBuf::from)
                .unwrap_or(fleet_dir),
            shape_lax: var("TILLANDSIAS_MSG_SHAPE_LAX").as_deref() == Some("1"),
        }
    }

    /// The directory holding `lane`'s mailbox.
    pub fn lane_dir(&self, lane: &str) -> PathBuf {
        if let Some(root) = &self.root_override {
            return root.join("lanes").join(lane);
        }
        if let Some(d) = &self.lane_dir_override {
            return d.clone();
        }
        if let Some(m) = &self.forge_mount
            && m.is_dir()
        {
            return m.clone();
        }
        let state = self.xdg_state_home.clone().unwrap_or_else(|| {
            self.home
                .clone()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".local/state")
        });
        state.join("tillandsias/msg/lanes").join(lane)
    }

    fn lax(&self) -> bool {
        self.shape_lax && self.root_override.is_some()
    }
}

/// What a verb printed and how it exited.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Outcome {
    pub out: String,
    pub err: String,
    pub code: i32,
}

impl Outcome {
    fn ok(out: impl Into<String>) -> Self {
        Self {
            out: out.into(),
            err: String::new(),
            code: 0,
        }
    }
}

/// A refusal: the verdict token first, then why and remedy (1247-amcu).
fn refuse(token: impl Into<String>, why: &str, remedy: &str) -> Outcome {
    Outcome {
        out: String::new(),
        err: format!("{}\n  why: {why}\n  remedy: {remedy}\n", token.into()),
        code: 1,
    }
}

fn io_refusal(what: &str, e: io::Error) -> Outcome {
    refuse(
        format!("refused:msg:io:{what}"),
        &format!("the lane store could not be written or read: {e}"),
        "check the lane directory exists and is writable by this uid (TILLANDSIAS_MSG_ROOT / XDG_STATE_HOME), then retry",
    )
}

pub const MSG_USAGE: &str = "usage: tillandsias-plan msg <verb> [--lane <lane>]
  whoami                                   print <host>/<lane>
  send --to <addr|@group> [--to …] [--kind K] [--row <order>] [--in-reply-to <id>]
       [--ttl <s>] [--id <id>] [--body-file <path>]   (body on stdin otherwise; never argv)
  recv [--keep] [--json] [--wait <s>]      print inbox/new + inbox/cur by (from, seq)
  list [--box inbox|outbox|dead]
  status <id>                              pending | acked:<mailbox>@<ts> + via:<rung> | undelivered:<reason>
  lint [--body-file <path>]                the shape and secret checks alone
  gc                                       the TTL sweep of this lane, by hand
there is no ack verb: the ack is the infrastructure's (operator ruling 2026-09-29)";

#[derive(Default)]
struct Flags {
    lane: Option<String>,
    to: Vec<String>,
    kind: Option<String>,
    row: Option<String>,
    in_reply_to: Option<String>,
    ttl: Option<String>,
    id: Option<String>,
    body_file: Option<PathBuf>,
    boxes: Option<String>,
    wait: Option<String>,
    keep: bool,
    json: bool,
    positional: Vec<String>,
}

fn parse_flags(args: &[String]) -> Result<Flags, Outcome> {
    let mut f = Flags::default();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        let val = |i: usize| -> Result<String, Outcome> {
            args.get(i + 1).cloned().ok_or_else(|| {
                refuse(
                    format!("refused:msg:usage:{a}-needs-a-value"),
                    "this flag takes a value and none followed it",
                    &format!("pass `{a} <value>`; see `tillandsias-plan msg` for the grammar"),
                )
            })
        };
        match a {
            "--lane" => f.lane = Some(val(i)?),
            "--to" => f.to.push(val(i)?),
            "--kind" => f.kind = Some(val(i)?),
            "--row" => f.row = Some(val(i)?),
            "--in-reply-to" => f.in_reply_to = Some(val(i)?),
            "--ttl" => f.ttl = Some(val(i)?),
            "--id" => f.id = Some(val(i)?),
            "--body-file" => f.body_file = Some(PathBuf::from(val(i)?)),
            "--box" => f.boxes = Some(val(i)?),
            "--wait" => f.wait = Some(val(i)?),
            "--keep" => {
                f.keep = true;
                i += 1;
                continue;
            }
            "--json" => {
                f.json = true;
                i += 1;
                continue;
            }
            "--body" | "--message" | "-m" => {
                return Err(refuse(
                    "refused:msg:body-on-argv",
                    "argv is world-readable in `ps` and in shell history; a message body never travels on it",
                    "pipe the body on stdin or pass --body-file <path>",
                ));
            }
            _ if a.starts_with("--") => {
                return Err(refuse(
                    format!("refused:msg:usage:unknown-flag:{a}"),
                    "the flag is not part of the msg grammar",
                    "see `tillandsias-plan msg` for the flags each verb takes",
                ));
            }
            _ => {
                f.positional.push(a.to_string());
                i += 1;
                continue;
            }
        }
        i += 2;
    }
    Ok(f)
}

fn resolve_lane(env: &MsgEnv, f: &Flags) -> Result<String, Outcome> {
    let Some(lane) = f.lane.clone().or_else(|| env.lane.clone()) else {
        return Err(refuse(
            "refused:msg:no-lane",
            "no TILLANDSIAS_MSG_LANE is exported and no --lane was given; an address is printed by the tool, never composed by hand",
            "inside a forge, relaunch it through tillandsias so the launcher exports the lane; on bare metal pass `--lane host`",
        ));
    };
    if !valid_label(&lane) {
        return Err(refuse(
            format!("refused:msg:bad-lane:{lane}"),
            "a lane is [a-z0-9][a-z0-9-]* (at most 63 bytes): `host` or <project>-<instance>",
            "pass `--lane host` on bare metal, or the lane the launcher exported",
        ));
    }
    Ok(lane)
}

/// Run one `msg` verb. `stdin` is read only by `send` and `lint` without
/// `--body-file`.
pub fn run(args: &[String], env: &MsgEnv, stdin: &mut dyn Read, now: DateTime<Utc>) -> Outcome {
    let Some(verb) = args.first() else {
        return Outcome {
            out: String::new(),
            err: format!("{MSG_USAGE}\n"),
            code: 2,
        };
    };
    let f = match parse_flags(&args[1..]) {
        Ok(f) => f,
        Err(o) => return o,
    };
    match verb.as_str() {
        "whoami" => match resolve_lane(env, &f) {
            Ok(lane) => Outcome::ok(format!("{}/{lane}\n", env.host)),
            Err(o) => o,
        },
        "send" => send(env, &f, stdin, now),
        "recv" => recv(env, &f, now),
        "list" => list(env, &f),
        "status" => status(env, &f, now),
        "lint" => lint(&f, stdin, env),
        "gc" => gc_verb(env, &f, now),
        "ack" => refuse(
            "refused:msg:unknown-verb:ack",
            "there is no ack verb: an ack means the destination mailbox durably accepted the message, and only the infrastructure (the mover or the receiving daemon) writes it (operator ruling 2026-09-29)",
            "run `tillandsias-plan msg status <id>` to read the ack; reading a message with `msg recv` is local and needs no ack",
        ),
        other => refuse(
            format!("refused:msg:unknown-verb:{other}"),
            "the msg verbs are whoami, send, recv, list, status, lint and gc",
            "run `tillandsias-plan msg` for the grammar",
        ),
    }
}

fn read_body(f: &Flags, stdin: &mut dyn Read) -> Result<String, Outcome> {
    const CAP: u64 = 64 * 1024;
    let mut buf = String::new();
    let res = match &f.body_file {
        Some(p) => File::open(p).and_then(|fh| fh.take(CAP).read_to_string(&mut buf)),
        None => stdin.take(CAP).read_to_string(&mut buf),
    };
    match res {
        Ok(_) => Ok(buf),
        Err(e) => Err(refuse(
            "refused:msg:body-unreadable",
            &format!("the body could not be read as UTF-8 text: {e}"),
            "pipe a UTF-8 body on stdin or pass --body-file <readable path>",
        )),
    }
}

/// Secret then shape, shared by `send` and `lint`. Returns the KIND.
///
/// The secret check runs FIRST: a credential is named as one whatever else is
/// wrong with the body, so fixing the shape never becomes the step that lets
/// it through to the next refusal.
fn check_body(body: &str, env: &MsgEnv) -> Result<&'static str, Outcome> {
    if !env.lax()
        && let Some(p) = shape::secret_shaped(body)
    {
        let (why, remedy) = shape::secret_affordance(p);
        return Err(refuse(
            format!("refused:msg:secret-shaped:{p}"),
            why,
            &remedy,
        ));
    }
    shape::check_shape(body)
        .map_err(|e| refuse(format!("refused:msg:shape:{}", e.reason), e.why, e.remedy))
}

fn lint(f: &Flags, stdin: &mut dyn Read, env: &MsgEnv) -> Outcome {
    let body = match read_body(f, stdin) {
        Ok(b) => b,
        Err(o) => return o,
    };
    match check_body(&body, env) {
        Ok(kind) => Outcome::ok(format!("ok:msg:lint:{kind}\n")),
        Err(o) => o,
    }
}

/// Group and address resolution against the tree (`plan/fleet/`). A wildcard
/// `@<host>/*` stays literal: the mover resolves it at delivery time.
fn resolve_recipients(env: &MsgEnv, to: &[String]) -> Result<(Vec<String>, bool), Outcome> {
    let groups: BTreeMap<String, Vec<String>> =
        read_yaml::<BTreeMap<String, Vec<String>>>(&env.fleet_dir.join("groups.yaml"))
            .unwrap_or_default()
            .into_iter()
            .map(|(k, v)| (k.trim_start_matches('@').to_string(), v))
            .collect();
    let mut out: Vec<String> = Vec::new();
    let mut wildcard = false;
    let mut stack: Vec<(String, usize)> = to.iter().rev().map(|t| (t.clone(), 0)).collect();
    while let Some((t, depth)) = stack.pop() {
        if let Some(name) = t.strip_prefix('@') {
            if let Some(host) = name.strip_suffix("/*") {
                if !valid_label(host) {
                    return Err(bad_address(&t));
                }
                wildcard = true;
                if !out.contains(&t) {
                    out.push(t);
                }
                continue;
            }
            // Depth grows along each path, so a cycle always exceeds it while a
            // group reached twice through two parents (a diamond) does not.
            if depth > 8 {
                return Err(refuse(
                    format!("refused:msg:group-cycle:@{name}"),
                    "a group names itself, directly or through other groups, so it has no finite member list",
                    "fix plan/fleet/groups.yaml so every group bottoms out in <host>/<lane> addresses",
                ));
            }
            let members: Vec<String> = if name == "all-hosts" {
                peer_hosts(&env.fleet_dir)
                    .into_iter()
                    .map(|h| format!("{h}/host"))
                    .collect()
            } else if let Some(m) = groups.get(name) {
                m.clone()
            } else {
                return Err(refuse(
                    format!("refused:msg:unknown-group:@{name}"),
                    "a group is defined in the tree (plan/fleet/groups.yaml, or plan/fleet/peers/ for @all-hosts), never at runtime",
                    "send to <host>/<lane> addresses, or land the group in plan/fleet/groups.yaml first",
                ));
            };
            if members.is_empty() {
                return Err(refuse(
                    format!("refused:msg:empty-group:@{name}"),
                    "the group resolved to no recipient, so the send would reach nobody",
                    "add members to the group in the tree, or send to <host>/<lane> directly",
                ));
            }
            for m in members.into_iter().rev() {
                stack.push((m, depth + 1));
            }
            continue;
        }
        if !valid_address(&t) {
            return Err(bad_address(&t));
        }
        if !out.contains(&t) {
            out.push(t);
        }
    }
    let broadcast = wildcard || out.len() > 1;
    Ok((out, broadcast))
}

fn bad_address(t: &str) -> Outcome {
    refuse(
        format!("refused:msg:bad-address:{t}"),
        "an address is <host>/<lane> (both [a-z0-9-]) or a group @<name>, @all-hosts, @<host>/*",
        "ask the recipient for `tillandsias-plan msg whoami` and send to exactly that",
    )
}

/// Hosts listed in `plan/fleet/peers/*.yaml` (`host:`, else the file stem).
fn peer_hosts(fleet_dir: &Path) -> Vec<String> {
    let mut hosts = BTreeSet::new();
    for p in box_files(&fleet_dir.join("peers")) {
        if p.extension().and_then(|e| e.to_str()) != Some("yaml") {
            continue;
        }
        let from_field = read_yaml::<serde_yaml::Value>(&p).and_then(|v| {
            v.get("host")
                .and_then(serde_yaml::Value::as_str)
                .map(str::to_string)
        });
        let h = from_field.or_else(|| p.file_stem().and_then(|s| s.to_str()).map(str::to_string));
        if let Some(h) = h.filter(|h| valid_label(h)) {
            hosts.insert(h);
        }
    }
    hosts.into_iter().collect()
}

/// Unexpired envelopes in this lane's inbox (new, then cur).
fn inbox_envelopes(lane_dir: &Path, now: DateTime<Utc>) -> Vec<(PathBuf, Envelope, bool)> {
    let mut v = Vec::new();
    for (sub, is_new) in [("inbox/new", true), ("inbox/cur", false)] {
        for p in box_files(&lane_dir.join(sub)) {
            if let Some(e) = read_yaml::<Envelope>(&p)
                && !e.expired(now)
            {
                v.push((p, e, is_new));
            }
        }
    }
    v
}

fn check_reply_target(lane_dir: &Path, target: &str, now: DateTime<Utc>) -> Result<(), Outcome> {
    // The recipient side: a copy in this lane's inbox.
    if let Some((_, e, _)) = inbox_envelopes(lane_dir, now)
        .into_iter()
        .find(|(_, e, _)| e.id == target)
    {
        if e.broadcast {
            return Err(reply_to_broadcast(target, &e.from));
        }
        return Ok(());
    }
    // The sender side: this lane's own receipt.
    if let Some(r) = read_receipt(lane_dir, target) {
        if r.broadcast {
            let to: Vec<&str> = r.recipients.iter().map(|x| x.to.as_str()).collect();
            return Err(reply_to_broadcast(target, &to.join(" or ")));
        }
        return Ok(());
    }
    Err(refuse(
        format!("refused:msg:unknown-reply-target:{target}"),
        "--in-reply-to names an id this lane neither received (inbox) nor sent (receipts); it may have passed its TTL",
        "check the id with `tillandsias-plan msg list`, or send without --in-reply-to",
    ))
}

fn reply_to_broadcast(id: &str, from: &str) -> Outcome {
    refuse(
        format!(
            "refused:msg:reply-to-broadcast:{id}:a broadcast has no single counterpart; send a new message to {from} instead"
        ),
        "a broadcast went to many mailboxes with one id, so a reply to it has no single counterpart (operator ruling 2026-09-29)",
        &format!("send a new message with `--to {from}` and no --in-reply-to"),
    )
}

fn send(env: &MsgEnv, f: &Flags, stdin: &mut dyn Read, now: DateTime<Utc>) -> Outcome {
    let lane = match resolve_lane(env, f) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let ttl = match &f.ttl {
        None => shape::TTL_DEFAULT_S,
        Some(s) => {
            let Ok(v) = s.parse::<u64>() else {
                return refuse(
                    format!("refused:msg:ttl-not-a-number:{s}"),
                    "--ttl is a whole number of seconds",
                    "pass --ttl <seconds> between 60 and 604800, or omit it for 86400",
                );
            };
            match shape::check_ttl(v) {
                Ok(v) => v,
                Err(token) => {
                    return refuse(
                        token,
                        "the queue is ephemeral with a bounded TTL: at least the 60 s retry cap, at most the 7 d past which the ledger holds the fact (design Decision 5a)",
                        "pass --ttl between 60 and 604800, or omit it for the 86400 s default",
                    );
                }
            }
        }
    };
    let body = match read_body(f, stdin) {
        Ok(b) => shape::normalize_body(&b),
        Err(o) => return o,
    };
    let kind = match check_body(&body, env) {
        Ok(k) => k,
        Err(o) => return o,
    };
    if let Some(k) = &f.kind
        && k != kind
    {
        return refuse(
            format!("refused:msg:shape:kind-mismatch:{k}"),
            "--kind disagrees with the KIND on line 1 of the body",
            "drop --kind (line 1 decides) or make the two agree",
        );
    }
    if let Some(r) = &f.row
        && !valid_order(r)
    {
        return refuse(
            format!("refused:msg:bad-row:{r}"),
            "--row names a ledger order token such as 1506-nvqt",
            "pass the row's order token, or omit --row",
        );
    }
    if f.to.is_empty() {
        return refuse(
            "refused:msg:no-recipient",
            "a send needs at least one --to",
            "pass --to <host>/<lane> (ask the recipient for `msg whoami`) or --to @<group>",
        );
    }
    let (recipients, broadcast) = match resolve_recipients(env, &f.to) {
        Ok(x) => x,
        Err(o) => return o,
    };
    let lane_dir = env.lane_dir(&lane);
    if let Err(e) = ensure_lane(&lane_dir) {
        return io_refusal("lane", e);
    }
    if let Some(t) = &f.in_reply_to {
        if broadcast {
            return refuse(
                format!("refused:msg:broadcast-reply:{t}"),
                "a reply names one counterpart; this send resolved to several recipients",
                "send the reply to the one address it answers, or drop --in-reply-to",
            );
        }
        if let Err(o) = check_reply_target(&lane_dir, t, now) {
            return o;
        }
    }
    let id = match &f.id {
        Some(id) if !valid_id(id) => {
            return refuse(
                format!("refused:msg:bad-id:{id}"),
                "an id is [A-Za-z0-9._-] (at most 80 bytes, not starting with . or -)",
                "omit --id to get m-<utc>-<8 hex>, or pass an id of that alphabet",
            );
        }
        Some(id) => id.clone(),
        None => new_id(now),
    };
    let known = lane_dir.join("receipts").join(&id).exists()
        || lane_dir.join("outbox/new").join(&id).exists()
        || lane_dir.join("dead").join(&id).exists();
    if known {
        return Outcome::ok(format!("skip:msg:duplicate:{id}\n"));
    }
    let seq = if broadcast {
        0
    } else {
        match next_seq(&lane_dir, &recipients[0]) {
            Ok(n) => n,
            Err(e) => return io_refusal("seq", e),
        }
    };
    let from = format!("{}/{lane}", env.host);
    let ts = fmt_ts(now);
    let env_rec = Envelope {
        id: id.clone(),
        from: from.clone(),
        to: recipients.clone(),
        from_agent: env
            .agent_id
            .clone()
            .unwrap_or_else(|| "unattributed".into()),
        seq,
        ts: ts.clone(),
        ttl_s: ttl,
        broadcast,
        kind: kind.to_string(),
        row: f.row.clone(),
        in_reply_to: f.in_reply_to.clone(),
        body,
    };
    let yaml = match serde_yaml::to_string(&env_rec) {
        Ok(y) => y,
        Err(e) => return io_refusal("serialize", io::Error::other(e)),
    };
    if yaml.len() > shape::ENVELOPE_MAX_BYTES {
        return refuse(
            format!("refused:msg:envelope-too-large:{}", yaml.len()),
            "the whole envelope is capped at 4096 bytes so a mailbox and the wire stay bounded",
            "send to fewer recipients per message, or use a group defined in plan/fleet/groups.yaml",
        );
    }
    // The receipt FIRST: an ack that races the outbox rename must find it.
    let receipt = Receipt {
        id: id.clone(),
        from,
        ts,
        ttl_s: ttl,
        broadcast,
        row: f.row.clone(),
        recipients: recipients
            .iter()
            .map(|to| RecipientState {
                to: to.clone(),
                state: "pending".into(),
                at: None,
                via: None,
                reason: None,
            })
            .collect(),
    };
    if let Err(e) = write_receipt(&lane_dir, &receipt) {
        return io_refusal("receipt", e);
    }
    if let Err(e) = write_durable(
        &lane_dir.join("outbox/tmp"),
        &lane_dir.join("outbox/new"),
        &id,
        yaml.as_bytes(),
    ) {
        return io_refusal("outbox", e);
    }
    Outcome::ok(format!("ok:msg:queued:{id}\n"))
}

/// recv's local, never-reported gap bookkeeping.
#[derive(Serialize, Deserialize, Default)]
struct RecvState {
    #[serde(default)]
    hw: BTreeMap<String, u64>,
    #[serde(default)]
    gaps: BTreeSet<String>,
}

/// Drop every inbox message past its TTL, read or unread. Returns the count.
fn sweep_inbox(lane_dir: &Path, now: DateTime<Utc>) -> usize {
    let mut n = 0;
    for sub in ["inbox/new", "inbox/cur"] {
        for p in box_files(&lane_dir.join(sub)) {
            if read_yaml::<Envelope>(&p).is_some_and(|e| e.expired(now))
                && fs::remove_file(&p).is_ok()
            {
                n += 1;
            }
        }
    }
    if n > 0 {
        sync_dir(&lane_dir.join("inbox/new"));
        sync_dir(&lane_dir.join("inbox/cur"));
    }
    n
}

fn recv(env: &MsgEnv, f: &Flags, now: DateTime<Utc>) -> Outcome {
    let lane = match resolve_lane(env, f) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let lane_dir = env.lane_dir(&lane);
    if let Err(e) = ensure_lane(&lane_dir) {
        return io_refusal("lane", e);
    }
    if let Some(w) = &f.wait {
        let Ok(secs) = w.parse::<u64>() else {
            return refuse(
                format!("refused:msg:wait-not-a-number:{w}"),
                "--wait is a whole number of seconds",
                "pass --wait <seconds> (at most 3600), or omit it",
            );
        };
        // Filesystem poll; the wake socket is 1506-q7ab's.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs.min(3600));
        while box_files(&lane_dir.join("inbox/new")).is_empty()
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
    sweep_inbox(&lane_dir, now);
    let mut msgs = inbox_envelopes(&lane_dir, now);
    msgs.sort_by(|a, b| {
        (&a.1.from, a.1.seq, &a.1.ts, &a.1.id).cmp(&(&b.1.from, b.1.seq, &b.1.ts, &b.1.id))
    });
    let state_path = lane_dir.join("recv-state");
    let mut st: RecvState = read_yaml(&state_path).unwrap_or_default();
    let present: BTreeSet<(String, u64)> = msgs
        .iter()
        .filter(|m| !m.1.broadcast)
        .map(|m| (m.1.from.clone(), m.1.seq))
        .collect();
    let hw_before = st.hw.clone();
    let mut out = String::new();
    for (path, e, is_new) in &msgs {
        if !e.broadcast && e.seq > 1 && !st.gaps.contains(&e.id) {
            let prev = e.seq - 1;
            let prev_seen = present.contains(&(e.from.clone(), prev))
                || hw_before.get(&e.from).is_some_and(|h| *h >= prev);
            let first_time = hw_before.get(&e.from).is_none_or(|h| *h < e.seq);
            if !prev_seen && first_time {
                st.gaps.insert(e.id.clone());
            }
        }
        if !e.broadcast {
            let h = st.hw.entry(e.from.clone()).or_insert(0);
            *h = (*h).max(e.seq);
        }
        let gap = st.gaps.contains(&e.id);
        if f.json {
            let v = serde_json::json!({ "gap": gap, "envelope": e });
            out.push_str(&v.to_string());
            out.push('\n');
        } else {
            let mut head = format!(
                "{}msg:{} from={} seq={} kind={} ts={} ttl_s={}",
                if gap { "gap:" } else { "" },
                e.id,
                e.from,
                e.seq,
                e.kind,
                e.ts,
                e.ttl_s
            );
            if e.broadcast {
                head.push_str(" broadcast");
            }
            if let Some(r) = &e.row {
                head.push_str(&format!(" row={r}"));
            }
            if let Some(r) = &e.in_reply_to {
                head.push_str(&format!(" in_reply_to={r}"));
            }
            out.push_str(&head);
            out.push('\n');
            for l in e.body.lines() {
                out.push_str("  ");
                out.push_str(l);
                out.push('\n');
            }
        }
        if *is_new && !f.keep {
            let _ = fs::rename(path, lane_dir.join("inbox/cur").join(&e.id));
        }
    }
    if !f.keep {
        sync_dir(&lane_dir.join("inbox/new"));
        sync_dir(&lane_dir.join("inbox/cur"));
    }
    // Forget gap marks for messages no longer present.
    let ids: BTreeSet<&String> = msgs.iter().map(|m| &m.1.id).collect();
    st.gaps.retain(|g| ids.contains(g));
    if let Ok(y) = serde_yaml::to_string(&st) {
        let _ = write_durable(
            &lane_dir.join("outbox/tmp"),
            &lane_dir,
            "recv-state",
            y.as_bytes(),
        );
    }
    Outcome::ok(out)
}

fn list(env: &MsgEnv, f: &Flags) -> Outcome {
    let lane = match resolve_lane(env, f) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let lane_dir = env.lane_dir(&lane);
    let boxes: Vec<(&str, &str)> = match f.boxes.as_deref() {
        None => vec![
            ("inbox", "inbox/new"),
            ("inbox", "inbox/cur"),
            ("outbox", "outbox/new"),
            ("dead", "dead"),
        ],
        Some("inbox") => vec![("inbox", "inbox/new"), ("inbox", "inbox/cur")],
        Some("outbox") => vec![("outbox", "outbox/new")],
        Some("dead") => vec![("dead", "dead")],
        Some(other) => {
            return refuse(
                format!("refused:msg:bad-box:{other}"),
                "the boxes are inbox, outbox and dead",
                "pass --box inbox|outbox|dead, or omit it for all three",
            );
        }
    };
    let mut out = String::new();
    for (name, sub) in boxes {
        for p in box_files(&lane_dir.join(sub)) {
            let Some(e) = read_yaml::<Envelope>(&p) else {
                continue;
            };
            let state = match sub {
                "inbox/new" => " state=new",
                "inbox/cur" => " state=cur",
                _ => "",
            };
            out.push_str(&format!(
                "{name}:{} from={} to={} kind={} ts={}{state}\n",
                e.id,
                e.from,
                e.to.join(","),
                e.kind,
                e.ts
            ));
        }
    }
    Outcome::ok(out)
}

fn status(env: &MsgEnv, f: &Flags, now: DateTime<Utc>) -> Outcome {
    let lane = match resolve_lane(env, f) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let Some(id) = f.positional.first() else {
        return refuse(
            "refused:msg:usage:status-needs-an-id",
            "status reads one receipt, named by the id `send` printed",
            "run `tillandsias-plan msg status <id>`",
        );
    };
    if !valid_id(id) {
        return refuse(
            format!("refused:msg:bad-id:{id}"),
            "an id is [A-Za-z0-9._-] (at most 80 bytes)",
            "pass the id `send` printed after ok:msg:queued:",
        );
    }
    let lane_dir = env.lane_dir(&lane);
    let retention = chrono::Duration::seconds(shape::RECEIPT_RETENTION_S as i64);
    let expired_token = || {
        Outcome {
        out: "unknown:receipt-expired\n".into(),
        err: "  why: receipts are kept 604800 s after their terminal state, then dropped (design Decision 5a)\n  remedy: the ledger is the durable record; nothing is left to query for this id\n".into(),
        code: 1,
    }
    };
    match read_receipt(&lane_dir, id) {
        Some(r) => {
            if r.terminal_at().is_some_and(|t| now >= t + retention) {
                return expired_token();
            }
            let mut s = r.status_lines().join("\n");
            s.push('\n');
            Outcome::ok(s)
        }
        None => {
            let max_age =
                chrono::Duration::seconds((shape::TTL_MAX_S + shape::RECEIPT_RETENTION_S) as i64);
            if id_time(id).is_some_and(|t| now >= t + max_age) {
                return expired_token();
            }
            Outcome {
                out: "unknown:no-such-receipt\n".into(),
                err: format!(
                    "  why: lane {lane} holds no receipt {id}; status answers only for ids this lane sent\n  remedy: run status in the lane that ran send (check `msg whoami`), with the id printed after ok:msg:queued:\n"
                ),
                code: 1,
            }
        }
    }
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
    ensure_lane(lane_dir)?;
    let mut s = Swept {
        inbox: sweep_inbox(lane_dir, now),
        ..Swept::default()
    };
    let retention = chrono::Duration::seconds(shape::RECEIPT_RETENTION_S as i64);
    for p in box_files(&lane_dir.join("outbox/new")) {
        let Some(e) = read_yaml::<Envelope>(&p) else {
            continue;
        };
        if !e.expired(now) {
            continue;
        }
        fs::rename(&p, lane_dir.join("dead").join(&e.id))?;
        if let Some(r) = read_receipt(lane_dir, &e.id) {
            for x in r.recipients.iter().filter(|x| x.state == "pending") {
                record_undelivered(lane_dir, &e.id, &x.to, "expired", now)?;
            }
        }
        s.outbox_expired += 1;
    }
    sync_dir(&lane_dir.join("outbox/new"));
    for p in box_files(&lane_dir.join("dead")) {
        let old = read_yaml::<Envelope>(&p).is_some_and(|e| {
            e.sent_at()
                .is_some_and(|t| now >= t + chrono::Duration::seconds(e.ttl_s as i64) + retention)
        });
        if old && fs::remove_file(&p).is_ok() {
            s.dead += 1;
        }
    }
    for p in box_files(&lane_dir.join("receipts")) {
        let old = read_yaml::<Receipt>(&p)
            .and_then(|r| r.terminal_at())
            .is_some_and(|t| now >= t + retention);
        if old && fs::remove_file(&p).is_ok() {
            s.receipts += 1;
        }
    }
    // Prune seen entries whose message has expired.
    let seen_path = lane_dir.join("seen");
    if let Ok(seen) = fs::read_to_string(&seen_path) {
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
            write_durable(
                &lane_dir.join("inbox/tmp"),
                lane_dir,
                "seen",
                body.as_bytes(),
            )?;
        }
    }
    Ok(s)
}

fn gc_verb(env: &MsgEnv, f: &Flags, now: DateTime<Utc>) -> Outcome {
    let lane = match resolve_lane(env, f) {
        Ok(l) => l,
        Err(o) => return o,
    };
    match sweep_lane(&env.lane_dir(&lane), now) {
        Ok(s) => Outcome::ok(format!(
            "ok:msg:gc:inbox={}:outbox-expired={}:dead={}:receipts={}\n",
            s.inbox, s.outbox_expired, s.dead, s.receipts
        )),
        Err(e) => io_refusal("gc", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BODY: &str = "FYI:1506-nvqt:store landed\n- crates/tillandsias-plan/src/msg_store.rs";

    fn now() -> DateTime<Utc> {
        parse_ts("2026-09-29T22:00:00Z").unwrap()
    }

    fn env(root: &Path, lane: Option<&str>) -> MsgEnv {
        MsgEnv {
            root_override: Some(root.to_path_buf()),
            lane: lane.map(str::to_string),
            host: "hosta".into(),
            fleet_dir: root.join("fleet"),
            ..MsgEnv::default()
        }
    }

    fn run_s(e: &MsgEnv, args: &[&str], stdin: &str, at: DateTime<Utc>) -> Outcome {
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        run(&a, e, &mut stdin.as_bytes(), at)
    }

    fn queued_id(o: &Outcome) -> String {
        o.out
            .trim()
            .strip_prefix("ok:msg:queued:")
            .unwrap_or_else(|| panic!("not queued: {o:?}"))
            .to_string()
    }

    fn tree_bytes(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
        let mut v = Vec::new();
        if let Ok(rd) = fs::read_dir(dir) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    v.extend(tree_bytes(&p));
                } else {
                    v.push((p.clone(), fs::read(&p).unwrap()));
                }
            }
        }
        v.sort();
        v
    }

    #[test]
    fn whoami_refuses_without_a_lane_and_prints_the_address_with_one() {
        let t = tempfile::tempdir().unwrap();
        let o = run_s(&env(t.path(), None), &["whoami"], "", now());
        assert_eq!(o.code, 1);
        assert!(o.out.is_empty());
        assert!(o.err.starts_with("refused:msg:no-lane\n  why: "), "{o:?}");
        let o = run_s(
            &env(t.path(), Some("tillandsias-default")),
            &["whoami"],
            "",
            now(),
        );
        assert_eq!(o.out, "hosta/tillandsias-default\n");
    }

    #[test]
    fn send_queues_at_once_with_a_pending_receipt_and_a_default_ttl() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path(), Some("host"));
        let o = run_s(&e, &["send", "--to", "hostb/host"], BODY, now());
        let id = queued_id(&o);
        assert!(
            id.starts_with("m-20260929t220000z-") && id.len() == 27,
            "{id}"
        );
        let lane = e.lane_dir("host");
        let env_on_disk: Envelope = read_yaml(&lane.join("outbox/new").join(&id)).unwrap();
        assert_eq!(env_on_disk.ttl_s, 86_400);
        assert_eq!(env_on_disk.seq, 1);
        assert_eq!(env_on_disk.from, "hosta/host");
        assert!(!env_on_disk.broadcast);
        let st = run_s(&e, &["status", &id], "", now());
        assert_eq!(st.out, "pending\n");
        // The second unicast to the same mailbox is seq 2.
        let id2 = queued_id(&run_s(&e, &["send", "--to", "hostb/host"], BODY, now()));
        let e2: Envelope = read_yaml(&lane.join("outbox/new").join(&id2)).unwrap();
        assert_eq!(e2.seq, 2);
    }

    #[test]
    fn refusals_write_nothing() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path(), Some("host"));
        let nine = (0..9)
            .map(|i| format!("- {i:07x}"))
            .collect::<Vec<_>>()
            .join("\n");
        let secret = format!("FYI:x:y\n- 1506-nvqt ghp_{}", "a".repeat(36));
        let cases: Vec<(Vec<&str>, String, &str)> = vec![
            (
                vec!["send", "--to", "b/host"],
                format!("FYI:x:y\n{nine}"),
                "refused:msg:shape:lines>8",
            ),
            (
                vec!["send", "--to", "b/host"],
                secret.clone(),
                "refused:msg:secret-shaped:github-token",
            ),
            (
                vec!["send", "--to", "b/host", "--ttl", "30"],
                BODY.into(),
                "refused:msg:ttl-out-of-bounds:30:min=60:max=604800",
            ),
            (
                vec!["send", "--to", "b/host", "--ttl", "700000"],
                BODY.into(),
                "refused:msg:ttl-out-of-bounds:700000:min=60:max=604800",
            ),
            (
                vec!["send", "--to", "b/host", "--body", "x"],
                BODY.into(),
                "refused:msg:body-on-argv",
            ),
            (
                vec!["send", "--to", "@nobody"],
                BODY.into(),
                "refused:msg:unknown-group:@nobody",
            ),
            (
                vec!["send", "--to", "b/host", "--in-reply-to", "m-x"],
                BODY.into(),
                "refused:msg:unknown-reply-target:m-x",
            ),
        ];
        for (args, body, want) in cases {
            let before = tree_bytes(t.path());
            let o = run_s(&e, &args, &body, now());
            assert_eq!(o.code, 1, "{args:?}");
            assert_eq!(o.err.lines().next(), Some(want), "{args:?}: {o:?}");
            assert!(
                o.err.contains("  why: ") && o.err.contains("  remedy: "),
                "{o:?}"
            );
            assert_eq!(before, tree_bytes(t.path()), "{args:?} wrote a file");
        }
    }

    /// NEGATIVE CONTROL for the secret refusal: the lax seam lets the same
    /// body through, which proves the refusal above came from secret_shaped —
    /// and the seam is inert without an explicit test root.
    #[test]
    fn the_lax_seam_reaches_the_secret_check_only_on_an_explicit_root() {
        let t = tempfile::tempdir().unwrap();
        let secret = format!("FYI:x:y\n- 1506-nvqt ghp_{}", "a".repeat(36));
        let mut e = env(t.path(), Some("host"));
        e.shape_lax = true;
        let o = run_s(&e, &["send", "--to", "b/host"], &secret, now());
        assert!(o.out.starts_with("ok:msg:queued:"), "{o:?}");
        let mut real = e.clone();
        real.root_override = None;
        real.xdg_state_home = Some(t.path().join("xdg"));
        let o = run_s(&real, &["send", "--to", "b/host"], &secret, now());
        assert!(
            o.err.starts_with("refused:msg:secret-shaped:github-token"),
            "{o:?}"
        );
    }

    #[test]
    fn a_repeated_id_is_skipped_not_rewritten() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path(), Some("host"));
        let o = run_s(
            &e,
            &["send", "--to", "b/host", "--id", "fixed-1"],
            BODY,
            now(),
        );
        assert_eq!(o.out, "ok:msg:queued:fixed-1\n");
        let before = tree_bytes(t.path());
        let o = run_s(
            &e,
            &["send", "--to", "b/host", "--id", "fixed-1"],
            "FYI:other:body\n- abc1234",
            now(),
        );
        assert_eq!(
            (o.out.as_str(), o.code),
            ("skip:msg:duplicate:fixed-1\n", 0)
        );
        assert_eq!(before, tree_bytes(t.path()));
    }

    #[test]
    fn there_is_no_ack_verb() {
        let t = tempfile::tempdir().unwrap();
        let e = env(t.path(), Some("host"));
        let id = queued_id(&run_s(&e, &["send", "--to", "b/host"], BODY, now()));
        let before = tree_bytes(t.path());
        let o = run_s(&e, &["ack", &id], "", now());
        assert_eq!(o.code, 1);
        assert!(o.err.starts_with("refused:msg:unknown-verb:ack\n"), "{o:?}");
        assert_eq!(before, tree_bytes(t.path()));
        assert_eq!(run_s(&e, &["status", &id], "", now()).out, "pending\n");
    }

    /// The infrastructure path: accept is durable and idempotent, the ack is
    /// what the receipt then reads, and a duplicate is absorbed but acked again.
    #[test]
    fn mailbox_accept_dedupes_and_the_ack_reads_back_through_status() {
        let t = tempfile::tempdir().unwrap();
        let a = env(t.path(), Some("a-default"));
        let id = queued_id(&run_s(
            &a,
            &["send", "--to", "hosta/b-default"],
            BODY,
            now(),
        ));
        let out: Envelope =
            read_yaml(&a.lane_dir("a-default").join("outbox/new").join(&id)).unwrap();
        let b_dir = a.lane_dir("b-default");
        assert_eq!(
            mailbox_accept(&b_dir, &out, now()).unwrap(),
            Accept::Accepted
        );
        assert_eq!(
            mailbox_accept(&b_dir, &out, now()).unwrap(),
            Accept::Duplicate
        );
        assert_eq!(box_files(&b_dir.join("inbox/new")).len(), 1);
        record_ack(
            &a.lane_dir("a-default"),
            &id,
            "hosta/b-default",
            now(),
            "local",
        )
        .unwrap();
        let st = run_s(&a, &["status", &id], "", now());
        assert_eq!(
            st.out,
            "acked:hosta/b-default@2026-09-29T22:00:00Z\nvia:local\n"
        );
        // Past its TTL a copy is not accepted at all.
        let later = now() + chrono::Duration::seconds(86_400);
        let mut other = out.clone();
        other.id = "m-other".into();
        assert_eq!(
            mailbox_accept(&b_dir, &other, later).unwrap(),
            Accept::Expired
        );
    }

    #[test]
    fn recv_is_local_bookkeeping_and_keep_moves_nothing() {
        let t = tempfile::tempdir().unwrap();
        let a = env(t.path(), Some("a-default"));
        let b = env(t.path(), Some("b-default"));
        let id = queued_id(&run_s(
            &a,
            &["send", "--to", "hosta/b-default"],
            BODY,
            now(),
        ));
        let out: Envelope =
            read_yaml(&a.lane_dir("a-default").join("outbox/new").join(&id)).unwrap();
        mailbox_accept(&b.lane_dir("b-default"), &out, now()).unwrap();
        let receipt = a.lane_dir("a-default").join("receipts").join(&id);
        let before = fs::read(&receipt).unwrap();
        let k = run_s(&b, &["recv", "--keep"], "", now());
        assert!(
            k.out
                .starts_with(&format!("msg:{id} from=hosta/a-default seq=1")),
            "{k:?}"
        );
        assert_eq!(
            box_files(&b.lane_dir("b-default").join("inbox/new")).len(),
            1
        );
        let r1 = run_s(&b, &["recv"], "", now());
        let r2 = run_s(&b, &["recv"], "", now());
        assert_eq!(r1.out, r2.out);
        assert!(r1.out.contains(&id));
        assert!(box_files(&b.lane_dir("b-default").join("inbox/new")).is_empty());
        assert_eq!(
            fs::read(&receipt).unwrap(),
            before,
            "recv changed the sender's receipt"
        );
    }

    #[test]
    fn an_unread_message_drops_at_its_ttl_while_the_ack_stays() {
        let t = tempfile::tempdir().unwrap();
        let a = env(t.path(), Some("a-default"));
        let b = env(t.path(), Some("b-default"));
        let id = queued_id(&run_s(
            &a,
            &["send", "--to", "hosta/b-default", "--ttl", "60"],
            BODY,
            now(),
        ));
        let out: Envelope =
            read_yaml(&a.lane_dir("a-default").join("outbox/new").join(&id)).unwrap();
        mailbox_accept(&b.lane_dir("b-default"), &out, now()).unwrap();
        record_ack(
            &a.lane_dir("a-default"),
            &id,
            "hosta/b-default",
            now(),
            "local",
        )
        .unwrap();
        let later = now() + chrono::Duration::seconds(61);
        assert_eq!(run_s(&b, &["recv"], "", later).out, "");
        assert!(box_files(&b.lane_dir("b-default").join("inbox/new")).is_empty());
        assert!(
            run_s(&a, &["status", &id], "", later)
                .out
                .starts_with("acked:")
        );
    }

    #[test]
    fn gc_expires_an_unacked_outbox_entry_and_retention_drops_the_receipt() {
        let t = tempfile::tempdir().unwrap();
        let a = env(t.path(), Some("host"));
        let id = queued_id(&run_s(
            &a,
            &["send", "--to", "b/host", "--ttl", "60"],
            BODY,
            now(),
        ));
        let later = now() + chrono::Duration::seconds(65);
        let g = run_s(&a, &["gc"], "", later);
        assert_eq!(
            g.out,
            "ok:msg:gc:inbox=0:outbox-expired=1:dead=0:receipts=0\n"
        );
        assert!(a.lane_dir("host").join("dead").join(&id).exists());
        assert_eq!(
            run_s(&a, &["status", &id], "", later).out,
            "undelivered:expired\n"
        );
        let much_later = later + chrono::Duration::seconds(604_800);
        assert_eq!(
            run_s(&a, &["status", &id], "", much_later).out,
            "unknown:receipt-expired\n"
        );
        let g = run_s(&a, &["gc"], "", much_later);
        assert!(g.out.ends_with(":dead=1:receipts=1\n"), "{g:?}");
    }

    #[test]
    fn broadcasts_resolve_groups_ack_per_recipient_and_refuse_replies() {
        let t = tempfile::tempdir().unwrap();
        let a = env(t.path(), Some("host"));
        fs::create_dir_all(t.path().join("fleet/peers")).unwrap();
        fs::write(t.path().join("fleet/peers/hostb.yaml"), "host: hostb\n").unwrap();
        fs::write(t.path().join("fleet/peers/hostc.yaml"), "host: hostc\n").unwrap();
        fs::write(
            t.path().join("fleet/groups.yaml"),
            "'@builders': [hostb/host, '@more']\n'@more': [hostc/host, hostb/host]\n'@loop': ['@loop']\n",
        )
        .unwrap();
        let id = queued_id(&run_s(&a, &["send", "--to", "@builders"], BODY, now()));
        assert_eq!(
            run_s(&a, &["status", &id], "", now()).out,
            "broadcast:2\npending:hostb/host\npending:hostc/host\n"
        );
        let lane = a.lane_dir("host");
        record_ack(&lane, &id, "hostb/host", now(), "lan").unwrap();
        record_undelivered(&lane, &id, "hostc/host", "expired", now()).unwrap();
        assert_eq!(
            run_s(&a, &["status", &id], "", now()).out,
            "broadcast:2\nacked:hostb/host@2026-09-29T22:00:00Z\nundelivered:expired:hostc/host\n"
        );
        let all = queued_id(&run_s(&a, &["send", "--to", "@all-hosts"], BODY, now()));
        assert!(
            run_s(&a, &["status", &all], "", now())
                .out
                .starts_with("broadcast:2\n")
        );
        let o = run_s(&a, &["send", "--to", "@loop"], BODY, now());
        assert!(o.err.starts_with("refused:msg:group-cycle:@loop"), "{o:?}");
        // The sender side of the reply rule.
        let o = run_s(
            &a,
            &["send", "--to", "hostb/host", "--in-reply-to", &id],
            BODY,
            now(),
        );
        assert!(o.err.starts_with(&format!("refused:msg:reply-to-broadcast:{id}:a broadcast has no single counterpart; send a new message to ")), "{o:?}");
    }

    /// The recipient side of the reply rule, with a planted broadcast copy:
    /// an implementation that only checked its receipts would pass this reply.
    #[test]
    fn a_reply_to_a_received_broadcast_is_refused_and_a_unicast_reply_passes() {
        let t = tempfile::tempdir().unwrap();
        let b = env(t.path(), Some("b-default"));
        let lane = b.lane_dir("b-default");
        let mk = |id: &str, bcast: bool| Envelope {
            id: id.into(),
            from: "hostz/host".into(),
            to: vec!["hosta/b-default".into()],
            from_agent: "x".into(),
            seq: if bcast { 0 } else { 1 },
            ts: fmt_ts(now()),
            ttl_s: 86_400,
            broadcast: bcast,
            kind: "FYI".into(),
            row: None,
            in_reply_to: None,
            body: BODY.into(),
        };
        mailbox_accept(&lane, &mk("m-bcast", true), now()).unwrap();
        mailbox_accept(&lane, &mk("m-uni", false), now()).unwrap();
        let o = run_s(
            &b,
            &["send", "--to", "hostz/host", "--in-reply-to", "m-bcast"],
            BODY,
            now(),
        );
        assert!(o.err.starts_with("refused:msg:reply-to-broadcast:m-bcast:a broadcast has no single counterpart; send a new message to hostz/host instead\n"), "{o:?}");
        let o = run_s(
            &b,
            &["send", "--to", "hostz/host", "--in-reply-to", "m-uni"],
            BODY,
            now(),
        );
        assert!(o.out.starts_with("ok:msg:queued:"), "{o:?}");
    }

    #[test]
    fn a_seq_gap_is_flagged_and_stays_flagged() {
        let t = tempfile::tempdir().unwrap();
        let b = env(t.path(), Some("b-default"));
        let lane = b.lane_dir("b-default");
        for (id, seq) in [("m-one", 1), ("m-three", 3)] {
            let e = Envelope {
                id: id.into(),
                from: "hostz/host".into(),
                to: vec!["hosta/b-default".into()],
                from_agent: "x".into(),
                seq,
                ts: fmt_ts(now()),
                ttl_s: 86_400,
                broadcast: false,
                kind: "FYI".into(),
                row: None,
                in_reply_to: None,
                body: BODY.into(),
            };
            mailbox_accept(&lane, &e, now()).unwrap();
        }
        for _ in 0..2 {
            let o = run_s(&b, &["recv"], "", now());
            let heads: Vec<&str> = o.out.lines().filter(|l| !l.starts_with("  ")).collect();
            assert!(heads[0].starts_with("msg:m-one "), "{heads:?}");
            assert!(heads[1].starts_with("gap:msg:m-three "), "{heads:?}");
        }
    }
}
