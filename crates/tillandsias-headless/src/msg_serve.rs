// @trace order:1506-q7ab, openspec/changes/fleet-messaging-poc/design.md (Decisions 2, 3, 5a, 5b)
// @trace openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
//
// msg_serve — `tillandsias --msg-serve`, the SAME-HOST rung of the fleet
// message bus: the resident mover. The Linux tray runs it on a thread beside
// its control socket; `--msg-serve` runs it in the foreground (`--once` for a
// single pass). It opens NO network socket — the LAN rung is 1506-7tq4.
//
// WHAT IT DOES, per pass, for every lane directory under <root>/lanes/:
//   * reads each envelope in the lane's outbox/new and ATTRIBUTES IT BY MOUNT:
//     the directory it sits in is the sender. An envelope whose `from` is not
//     `<this host>/<that lane>` is refused (refused:msg:from-lane-mismatch) to
//     the lane's dead/ — a lane that lies is evidence, not a typo — and the
//     lane it named is never touched;
//   * repeats the checks the CLI ran, because a lane can write its outbox
//     directory directly: the secret check FIRST (refused:msg:secret-shaped),
//     then TTL bounds, addresses, size and the body budget;
//   * refuses an envelope whose in_reply_to names a broadcast any lane on this
//     host holds (refused:msg:reply-to-broadcast; the sender's status reads
//     undelivered:refused:reply-to-broadcast), the exchange layer's half of
//     operator ruling (4);
//   * resolves `@<this host>/*` to every OTHER lane present, one receipt entry
//     per lane;
//   * delivers each local recipient through store::mailbox_accept_with — the
//     copy fsync'd into inbox/new, the directory fsync'd, (from, id) fsync'd
//     into `seen` — and only THEN writes `acked:<host>/<lane>@<ts>` + via:local
//     into the sender's receipts/. The ack is this infrastructure's, never an
//     agent's (operator ruling 2026-09-29): no agent, verb or harness writes
//     one. The ack takes a proof value only a durable delivery constructs;
//   * pokes the wake socket ($XDG_RUNTIME_DIR/tillandsias/msg.sock) once per
//     delivery so `msg recv --wait` returns at once;
//   * removes the outbox entry when no recipient is pending (a recipient on
//     another host stays pending for the LAN rung, bounded by its TTL).
// Every sweep_every it runs store::sweep_lane on every lane: expired inbox
// copies dropped (read or unread), expired outbox entries to dead/ with
// undelivered:expired, receipts dropped after their retention.
//
// TRUST. Every read and write inside a lane goes through lanefs::Lane —
// fd-relative, O_NOFOLLOW per component — because a forge holds its lane
// directory read-write and could otherwise symlink its outbox onto another
// lane's inbox (a lane with such a symlink is refused:msg:lane-not-plain).
//
// FIXTURE SEAMS, honoured ONLY with an explicit TILLANDSIAS_MSG_ROOT so they
// can never weaken a real store:
//   TILLANDSIAS_MSG_MOVER_LAX=1   skip the mover's second secret check
//                                 (the direct-write arm's mutation control);
//   TILLANDSIAS_MSG_SKIP_FSYNC=1  deliver without fsync; the mover then holds
//                                 no proof of durability and REFUSES to ack
//                                 (refused:msg:ack-without-fsync).

use chrono::{DateTime, Utc};
use std::collections::BTreeSet;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tillandsias_msg::lanefs::{self, Lane, SyncFn};
use tillandsias_msg::shape;
use tillandsias_msg::store::{self, Accept, Envelope};

/// The bare-metal mailbox every host has (coordinator default, reversible).
pub const HOST_LANE: &str = "host";

/// The store root: TILLANDSIAS_MSG_ROOT, else
/// `$XDG_STATE_HOME/tillandsias/msg`, else `~/.local/state/tillandsias/msg`.
/// A unit-test build with no explicit root gets a per-process temp root, so no
/// test that builds forge launch args ever creates a lane under the real
/// $HOME.
pub fn store_root() -> PathBuf {
    let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    if let Some(r) = var("TILLANDSIAS_MSG_ROOT") {
        return PathBuf::from(r);
    }
    if cfg!(test) {
        return std::env::temp_dir().join(format!("tillandsias-test-msg-{}", std::process::id()));
    }
    store::default_store_root(
        var("XDG_STATE_HOME").map(PathBuf::from),
        var("HOME").map(PathBuf::from),
    )
}

pub fn lane_dir(root: &Path, lane: &str) -> PathBuf {
    root.join("lanes").join(lane)
}

// ── the forge side: one lane directory per forge ─────────────────────────────

/// The lane label of a forge: `<project>-<instance>` (instance `default`),
/// sanitized to the address alphabet so the CLI inside accepts it. The same
/// label the MCP socket uses for well-formed project names.
pub fn forge_lane_label(project: &str, instance: Option<&str>) -> Option<String> {
    let instance = instance
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("default");
    let label = store::sanitize_label(&format!("{project}-{instance}"));
    store::valid_label(&label).then_some(label)
}

/// What a forge launch adds for its mailbox: the lane directory on the host,
/// bind-mounted read-write at /run/host/tillandsias-msg, and the lane and
/// host labels the CLI inside needs to name itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForgeLaneMount {
    pub source: PathBuf,
    pub lane: String,
    pub host: String,
}

impl ForgeLaneMount {
    /// The podman argv, rendered exactly as ContainerSpec renders a
    /// read-write bind (`relabel=shared` so SELinux lets the forge write).
    pub fn podman_args(&self) -> Vec<String> {
        vec![
            "--mount".into(),
            format!(
                "type=bind,source={},target={},relabel=shared",
                self.source.display(),
                store::FORGE_LANE_MOUNT
            ),
            "--env".into(),
            format!("TILLANDSIAS_MSG_LANE={}", self.lane),
            "--env".into(),
            format!("TILLANDSIAS_MSG_HOST={}", self.host),
        ]
    }
}

/// Create (idempotently) the forge's lane directory under `root` and return
/// its mount. `None` — logged, the forge still launches, without a mailbox —
/// when the project yields no label or the directory cannot be made plain.
pub fn prepare_forge_lane_in(
    root: &Path,
    project: &str,
    instance: Option<&str>,
) -> Option<ForgeLaneMount> {
    let lane = forge_lane_label(project, instance)?;
    let source = lane_dir(root, &lane);
    if let Err(e) = store::ensure_lane(&source) {
        eprintln!(
            "[msg-serve] forge lane {lane}: could not prepare {}: {e}; the forge launches without a mailbox",
            source.display()
        );
        return None;
    }
    Some(ForgeLaneMount {
        source,
        lane,
        host: store::local_host_label(),
    })
}

/// [`prepare_forge_lane_in`] at the real store root.
pub fn prepare_forge_lane(project: &str, instance: Option<&str>) -> Option<ForgeLaneMount> {
    prepare_forge_lane_in(&store_root(), project, instance)
}

// ── configuration ────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct MoverConfig {
    pub root: PathBuf,
    pub host: String,
    pub lax: bool,
    pub skip_fsync: bool,
    pub wake_sock: Option<PathBuf>,
    pub poll: Duration,
    pub sweep_every: Duration,
}

impl MoverConfig {
    pub fn from_env() -> Self {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let explicit_root = var("TILLANDSIAS_MSG_ROOT").is_some();
        let seam = |k: &str| explicit_root && var(k).as_deref() == Some("1");
        let ms = |k: &str, default: u64, lo: u64, hi: u64| {
            Duration::from_millis(
                var(k)
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(default)
                    .clamp(lo, hi),
            )
        };
        Self {
            root: store_root(),
            host: store::local_host_label(),
            lax: seam("TILLANDSIAS_MSG_MOVER_LAX"),
            skip_fsync: seam("TILLANDSIAS_MSG_SKIP_FSYNC"),
            wake_sock: store::wake_socket_path(
                var("TILLANDSIAS_MSG_WAKE_SOCK").map(PathBuf::from),
                var("XDG_RUNTIME_DIR").map(PathBuf::from),
            ),
            poll: ms("TILLANDSIAS_MSG_POLL_MS", 250, 20, 10_000),
            sweep_every: ms("TILLANDSIAS_MSG_SWEEP_MS", 30_000, 100, 3_600_000),
        }
    }
}

// ── the wake socket ──────────────────────────────────────────────────────────

#[cfg(unix)]
struct WakeHub {
    path: PathBuf,
    listener: std::os::unix::net::UnixListener,
    waiters: Vec<std::os::unix::net::UnixStream>,
}

#[cfg(unix)]
impl WakeHub {
    fn bind(path: &Path) -> io::Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        use std::os::unix::net::{UnixListener, UnixStream};
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if path.exists() {
            if UnixStream::connect(path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!("{} is served by a live mover", path.display()),
                ));
            }
            std::fs::remove_file(path)?;
        }
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        Ok(Self {
            path: path.to_path_buf(),
            listener,
            waiters: Vec::new(),
        })
    }

    fn accept(&mut self) {
        while let Ok((s, _)) = self.listener.accept() {
            if s.set_nonblocking(true).is_ok() {
                self.waiters.push(s);
            }
        }
    }

    /// One byte to every waiter; a waiter that is gone is dropped, one whose
    /// buffer is full already has a wake pending.
    fn poke(&mut self) {
        use std::io::Write;
        self.accept();
        self.waiters.retain_mut(|s| match s.write(&[1]) {
            Ok(_) => true,
            Err(e) => e.kind() == io::ErrorKind::WouldBlock,
        });
    }
}

#[cfg(unix)]
impl Drop for WakeHub {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(not(unix))]
struct WakeHub;
#[cfg(not(unix))]
impl WakeHub {
    fn bind(_: &Path) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "no Unix sockets on this platform",
        ))
    }
    fn accept(&mut self) {}
    fn poke(&mut self) {}
}

// ── the mover ────────────────────────────────────────────────────────────────

/// Proof that a copy, its directory and its `seen` entry were fsync'd. Only
/// [`Mover::deliver`] constructs one and only the ack consumes one, so no code
/// path can ack a delivery whose durability it did not establish.
struct Fsynced(());

enum Delivery {
    Durable(Fsynced),
    /// Written with the SKIP_FSYNC seam: no proof, so no ack.
    NotDurable,
    Expired,
}

/// A refusal of one envelope: the verdict token (after `refused:msg:`), the
/// reason recorded for each pending recipient, and the affordance.
struct Refusal {
    token: String,
    reason: String,
    why: String,
    remedy: String,
}

impl Refusal {
    fn new(token: impl Into<String>, reason: impl Into<String>, why: &str, remedy: &str) -> Self {
        Self {
            token: token.into(),
            reason: reason.into(),
            why: why.into(),
            remedy: remedy.into(),
        }
    }
}

/// What one pass did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Tick {
    pub acked: usize,
    pub refused: usize,
    pub pending: usize,
    pub swept: usize,
}

pub type LogFn = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Mover {
    cfg: MoverConfig,
    sync: SyncFn,
    wake: Option<WakeHub>,
    log: LogFn,
    logged_once: BTreeSet<String>,
    last_sweep: Option<Instant>,
    /// The flock on `<root>/.mover.lock`, held for the mover's life.
    _lock: Option<std::fs::File>,
}

/// `refused:msg-serve:already-running` and friends, printed by the CLI.
pub struct StartRefusal(pub String);

impl Mover {
    /// A mover without the singleton lock or the wake socket (tests, `--once`
    /// on a fixture root use [`Mover::start`] instead when they need them).
    pub fn new(cfg: MoverConfig, log: LogFn) -> Self {
        let _ = store::ensure_lane(&lane_dir(&cfg.root, HOST_LANE));
        Self {
            cfg,
            sync: lanefs::fsync,
            wake: None,
            log,
            logged_once: BTreeSet::new(),
            last_sweep: None,
            _lock: None,
        }
    }

    /// The resident: take `<root>/.mover.lock` (one mover per store), make the
    /// host lane, bind the wake socket (a bind failure costs only latency).
    pub fn start(cfg: MoverConfig, log: LogFn) -> Result<Self, StartRefusal> {
        let lock = take_singleton(&cfg.root)?;
        let wake_path = cfg.wake_sock.clone();
        let mut m = Self::new(cfg, log);
        m._lock = Some(lock);
        if let Some(p) = wake_path {
            match WakeHub::bind(&p) {
                Ok(h) => m.wake = Some(h),
                Err(e) => (m.log)(&format!(
                    "[msg-serve] no wake socket at {} ({e}); `msg recv --wait` polls instead",
                    p.display()
                )),
            }
        }
        Ok(m)
    }

    fn say_once(&mut self, key: String, msg: String) {
        if self.logged_once.insert(key) {
            (self.log)(&msg);
        }
    }

    /// Lane names under <root>/lanes: real directories with address-alphabet
    /// names, sorted. `<root>/lanes` is host-owned; no forge sees it.
    fn lanes(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(self.cfg.root.join("lanes"))
            .map(|rd| {
                rd.filter_map(Result::ok)
                    .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                    .filter_map(|e| e.file_name().to_str().map(str::to_string))
                    .filter(|n| store::valid_label(n))
                    .collect()
            })
            .unwrap_or_default();
        v.sort();
        v
    }

    fn lane_refusal(&mut self, lane: &str, e: &io::Error) {
        if lanefs::is_not_plain(e) {
            self.say_once(
                format!("not-plain:{lane}"),
                format!(
                    "refused:msg:lane-not-plain:{lane}\n  why: a component of lane {lane}'s directory is a symlink or not a directory ({e}); the mover never follows a link out of a lane, because one lane could then read, move or overwrite another lane's mailbox or a file on the host\n  remedy: remove the symlink under {} (the forge holding the lane made it) and relaunch that forge; nothing in lane {lane} is delivered until the layout is plain",
                    lane_dir(&self.cfg.root, lane).display()
                ),
            );
        } else {
            self.say_once(
                format!("io:{lane}:{}", e.kind()),
                format!("[msg-serve] lane {lane}: {e}; retrying every pass"),
            );
        }
    }

    /// One pass over every lane's outbox.
    pub fn tick(&mut self, now: DateTime<Utc>) -> Tick {
        let mut t = Tick::default();
        let lanes = self.lanes();
        for lane in &lanes {
            self.drain_lane(lane, &lanes, now, &mut t);
        }
        if let Some(w) = self.wake.as_mut() {
            w.accept();
        }
        t
    }

    /// The TTL sweep of every lane.
    pub fn sweep(&mut self, now: DateTime<Utc>) -> usize {
        let mut n = 0;
        for lane in self.lanes() {
            match store::sweep_lane(&lane_dir(&self.cfg.root, &lane), now) {
                Ok(s) => {
                    let k = s.inbox + s.outbox_expired + s.dead + s.receipts;
                    if k > 0 {
                        (self.log)(&format!(
                            "[msg-serve] swept lane {lane}: inbox={} outbox-expired={} dead={} receipts={}",
                            s.inbox, s.outbox_expired, s.dead, s.receipts
                        ));
                    }
                    n += k;
                }
                Err(e) => self.lane_refusal(&lane, &e),
            }
        }
        n
    }

    /// Run until `stop()`: a pass every `poll`, a sweep every `sweep_every`.
    pub fn serve(&mut self, stop: impl Fn() -> bool) {
        (self.log)(&format!(
            "[msg-serve] serving {} as host {} (poll {} ms, sweep {} ms)",
            self.cfg.root.join("lanes").display(),
            self.cfg.host,
            self.cfg.poll.as_millis(),
            self.cfg.sweep_every.as_millis()
        ));
        while !stop() {
            let now = Utc::now();
            self.tick(now);
            if self
                .last_sweep
                .is_none_or(|t| t.elapsed() >= self.cfg.sweep_every)
            {
                self.sweep(now);
                self.last_sweep = Some(Instant::now());
            }
            let until = Instant::now() + self.cfg.poll;
            while !stop() && Instant::now() < until {
                std::thread::sleep(self.cfg.poll.min(Duration::from_millis(50)));
            }
        }
    }

    fn drain_lane(&mut self, lane: &str, lanes: &[String], now: DateTime<Utc>, t: &mut Tick) {
        let dir = lane_dir(&self.cfg.root, lane);
        let l = match Lane::open(&dir).and_then(|l| l.ensure_dirs(store::LANE_DIRS).map(|_| l)) {
            Ok(l) => l,
            Err(e) => return self.lane_refusal(lane, &e),
        };
        let names = match l.list("outbox/new") {
            Ok(n) => n,
            Err(e) => return self.lane_refusal(lane, &e),
        };
        for name in names {
            self.process(&l, lane, &name, lanes, now, t);
        }
    }

    fn process(
        &mut self,
        l: &Lane,
        lane: &str,
        name: &str,
        lanes: &[String],
        now: DateTime<Utc>,
        t: &mut Tick,
    ) {
        let me = format!("{}/{lane}", self.cfg.host);
        let bytes = match l.read("outbox/new", name) {
            Ok(Some(b)) => b,
            Ok(None) => return,
            Err(e) => {
                let r = malformed(&format!("it cannot be read as a regular file ({e})"));
                return self.refuse(l, lane, name, None, r, now, t);
            }
        };
        let env = match Envelope::from_yaml(&bytes) {
            Ok(e) => e,
            Err(e) => {
                // A writer that bypassed tmp → rename may still be writing.
                if l.age("outbox/new", name)
                    .is_some_and(|a| a < Duration::from_secs(2))
                {
                    return;
                }
                let r = malformed(&format!("it does not parse as an envelope ({e})"));
                return self.refuse(l, lane, name, None, r, now, t);
            }
        };
        if !store::valid_id(&env.id) || env.id != name {
            let r = malformed(&format!(
                "its id {:?} is not the file name {name:?} or not of the id alphabet",
                env.id
            ));
            return self.refuse(l, lane, name, None, r, now, t);
        }
        if env.from != me {
            let r = Refusal::new(
                "from-lane-mismatch",
                "refused:from-lane-mismatch",
                &format!(
                    "the envelope claims from={} but sits in lane {lane}'s outbox, so the mount says it was written by {me}; a lane speaks only for itself (attribution by mount, design Decision 3)",
                    env.from
                ),
                &format!(
                    "send with `tillandsias-plan msg send` inside lane {lane}; it stamps from={me}. Nothing was delivered and lane {} was not touched",
                    env.from
                ),
            );
            return self.refuse(l, lane, name, Some(&env), r, now, t);
        }
        if env.expired(now) {
            // The sweep moves it to dead/ as undelivered:expired.
            return;
        }
        if let Err(r) = self.check(&env, bytes.len()) {
            return self.refuse(l, lane, name, Some(&env), r, now, t);
        }
        if let Some(target) = env.in_reply_to.as_deref()
            && self.holds_broadcast(target, lanes)
        {
            let r = Refusal::new(
                format!("reply-to-broadcast:{target}"),
                "refused:reply-to-broadcast",
                "in_reply_to names a broadcast held on this host; a broadcast went to many mailboxes with one id, so a reply has no single counterpart (operator ruling 2026-09-29)",
                "send a new message to the broadcast's sender with `tillandsias-plan msg send --to <address>` and no --in-reply-to",
            );
            return self.refuse(l, lane, name, Some(&env), r, now, t);
        }
        self.deliver_all(l, lane, name, &env, lanes, now, t);
    }

    /// The CLI's checks again, secret FIRST (a credential is named as one
    /// whatever else is wrong).
    fn check(&self, env: &Envelope, size: usize) -> Result<(), Refusal> {
        if !self.cfg.lax
            && let Some(p) = shape::secret_shaped(&env.body)
        {
            let (why, remedy) = shape::secret_affordance(p);
            return Err(Refusal::new(
                format!("secret-shaped:{p}"),
                format!("refused:secret-shaped:{p}"),
                &format!(
                    "{why}; the mover repeats the check because a lane can write its outbox directory without the CLI"
                ),
                &remedy,
            ));
        }
        if let Err(token) = shape::check_ttl(env.ttl_s) {
            let v = token.trim_start_matches("refused:msg:").to_string();
            return Err(Refusal::new(
                v.clone(),
                format!("refused:{v}"),
                "the queue is ephemeral with a bounded TTL (design Decision 5a)",
                "send with `tillandsias-plan msg send --ttl <60..604800>`",
            ));
        }
        if env.to.is_empty() {
            return Err(Refusal::new(
                "no-recipient",
                "refused:no-recipient",
                "the envelope names no recipient",
                "send with `tillandsias-plan msg send --to <host>/<lane>`",
            ));
        }
        if let Some(bad) = env
            .to
            .iter()
            .find(|t| !store::valid_address(t) && store::wildcard_host(t).is_none())
        {
            return Err(Refusal::new(
                format!("bad-address:{bad}"),
                "refused:bad-address",
                "an address is <host>/<lane> (both [a-z0-9-]) or @<host>/*",
                "ask the recipient for `tillandsias-plan msg whoami` and send to exactly that",
            ));
        }
        if size > shape::ENVELOPE_MAX_BYTES {
            return Err(Refusal::new(
                format!("envelope-too-large:{size}"),
                "refused:envelope-too-large",
                "the whole envelope is capped at 4096 bytes so a mailbox stays bounded",
                "send a shorter body or fewer recipients per message",
            ));
        }
        match shape::check_shape(&env.body) {
            Err(e) => Err(Refusal::new(
                format!("shape:{}", e.reason),
                format!("refused:shape:{}", e.reason),
                e.why,
                e.remedy,
            )),
            Ok(kind) if kind != env.kind => Err(Refusal::new(
                format!("shape:kind-mismatch:{}", env.kind),
                "refused:shape:kind-mismatch",
                "the envelope's kind disagrees with the KIND on line 1 of its body",
                "send with `tillandsias-plan msg send`, which takes the kind from line 1",
            )),
            Ok(_) => match &env.row {
                Some(r) if !store::valid_order(r) => Err(Refusal::new(
                    format!("bad-row:{r}"),
                    "refused:bad-row",
                    "row names a ledger order token such as 1506-q7ab",
                    "pass the row's order token with --row, or omit it",
                )),
                _ => Ok(()),
            },
        }
    }

    /// Does any lane on this host hold `id` as a broadcast — a received copy
    /// (inbox/new or inbox/cur) or a sent receipt?
    fn holds_broadcast(&self, id: &str, lanes: &[String]) -> bool {
        if !store::valid_id(id) {
            return false;
        }
        lanes.iter().any(|lane| {
            let Ok(l) = Lane::open(&lane_dir(&self.cfg.root, lane)) else {
                return false;
            };
            ["inbox/new", "inbox/cur"]
                .iter()
                .any(|sub| store::read_envelope_in(&l, sub, id).is_some_and(|e| e.broadcast))
                || store::read_receipt_in(&l, id).is_some_and(|r| r.broadcast)
        })
    }

    /// Move the envelope to the lane's dead/, log the verdict with its
    /// affordance, and mark every still-pending recipient undelivered.
    #[allow(clippy::too_many_arguments)]
    fn refuse(
        &mut self,
        l: &Lane,
        lane: &str,
        name: &str,
        env: Option<&Envelope>,
        r: Refusal,
        now: DateTime<Utc>,
        t: &mut Tick,
    ) {
        (self.log)(&format!(
            "refused:msg:{}:{name} lane={lane}\n  why: {}\n  remedy: {}",
            r.token, r.why, r.remedy
        ));
        if let Err(e) = l.rename("outbox/new", name, "dead", name) {
            (self.log)(&format!(
                "[msg-serve] could not move {name} to lane {lane}'s dead/ ({e}); removing it so it is not refused every pass"
            ));
            let _ = l.remove("outbox/new", name);
        }
        t.refused += 1;
        let Some(env) = env else { return };
        let dir = lane_dir(&self.cfg.root, lane);
        let me = format!("{}/{lane}", self.cfg.host);
        if store::ensure_receipt(&dir, env, &me).is_err() {
            return;
        }
        if let Some(rc) = store::read_receipt(&dir, &env.id) {
            for x in rc.recipients.iter().filter(|x| x.state == "pending") {
                let _ = store::record_undelivered(&dir, &env.id, &x.to, &r.reason, now);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn deliver_all(
        &mut self,
        l: &Lane,
        lane: &str,
        name: &str,
        env: &Envelope,
        lanes: &[String],
        now: DateTime<Utc>,
        t: &mut Tick,
    ) {
        let dir = lane_dir(&self.cfg.root, lane);
        let me = format!("{}/{lane}", self.cfg.host);
        if let Err(e) = store::ensure_receipt(&dir, env, &me) {
            return self.lane_refusal(lane, &e);
        }
        let Some(receipt) = store::read_receipt(&dir, &env.id) else {
            return;
        };
        // `@<this host>/*`: every OTHER lane present now, one entry each.
        for w in receipt.recipients.iter().filter(|x| x.state == "pending") {
            if store::wildcard_host(&w.to) == Some(self.cfg.host.as_str()) {
                let targets: Vec<String> = lanes
                    .iter()
                    .filter(|x| x.as_str() != lane)
                    .map(|x| format!("{}/{x}", self.cfg.host))
                    .collect();
                let _ = store::resolve_wildcard(&dir, &env.id, &w.to, &targets, now);
            }
        }
        let Some(receipt) = store::read_receipt(&dir, &env.id) else {
            return;
        };
        let broadcast = env.broadcast || receipt.broadcast;
        for rs in receipt.recipients.iter().filter(|x| x.state == "pending") {
            let Some((h, dest)) = rs.to.split_once('/') else {
                continue;
            };
            if h != self.cfg.host || !store::valid_label(dest) {
                // Another host (the LAN rung, 1506-7tq4) or an unresolved
                // group: stays pending until delivered or its TTL.
                t.pending += 1;
                continue;
            }
            if !lanes.iter().any(|x| x == dest) {
                // No such mailbox on this host yet (a forge not launched since
                // the store was made): pending until it appears or the TTL.
                t.pending += 1;
                continue;
            }
            let copy = Envelope {
                to: vec![rs.to.clone()],
                broadcast,
                ..env.clone()
            };
            match self.deliver(&lane_dir(&self.cfg.root, dest), &copy, now) {
                Ok(Delivery::Durable(proof)) => {
                    match ack(&dir, &env.id, &rs.to, now, proof) {
                        Ok(()) => {
                            t.acked += 1;
                            if let Some(w) = self.wake.as_mut() {
                                w.poke();
                            }
                        }
                        Err(e) => self.say_once(
                            format!("ack-io:{}:{}", env.id, rs.to),
                            format!(
                                "[msg-serve] {} was accepted by {} but its ack could not be written ({e}); the next pass acks again (the mailbox dedupes)",
                                env.id, rs.to
                            ),
                        ),
                    }
                }
                Ok(Delivery::NotDurable) => {
                    t.pending += 1;
                    self.say_once(
                        format!("no-fsync:{}:{}", env.id, rs.to),
                        format!(
                            "refused:msg:ack-without-fsync:{}\n  why: the copy for {} was written with TILLANDSIAS_MSG_SKIP_FSYNC=1, so the mover holds no proof it is durable, and an ack means the mailbox durably accepted it\n  remedy: unset TILLANDSIAS_MSG_SKIP_FSYNC (a fixture seam) and let the next pass deliver it; the receipt stays pending until then",
                            env.id, rs.to
                        ),
                    );
                }
                Ok(Delivery::Expired) => {}
                Err(e) => {
                    t.pending += 1;
                    if lanefs::is_not_plain(&e) {
                        self.lane_refusal(dest, &e);
                    } else {
                        self.say_once(
                            format!("deliver-io:{}:{}", env.id, rs.to),
                            format!(
                                "[msg-serve] delivering {} to {} failed ({e}); no ack was written and the next pass retries",
                                env.id, rs.to
                            ),
                        );
                    }
                }
            }
        }
        let done = store::read_receipt(&dir, &env.id)
            .is_some_and(|r| r.recipients.iter().all(|x| x.state != "pending"));
        if done {
            let _ = l.remove("outbox/new", name);
        }
    }

    /// The mailbox's durable acceptance. Returns the proof an ack needs only
    /// when every sync ran.
    fn deliver(&self, dest: &Path, copy: &Envelope, now: DateTime<Utc>) -> io::Result<Delivery> {
        let sync = if self.cfg.skip_fsync {
            lanefs::no_sync
        } else {
            self.sync
        };
        Ok(match store::mailbox_accept_with(dest, copy, now, sync)? {
            Accept::Expired => Delivery::Expired,
            Accept::Accepted | Accept::Duplicate if self.cfg.skip_fsync => Delivery::NotDurable,
            Accept::Accepted | Accept::Duplicate => Delivery::Durable(Fsynced(())),
        })
    }
}

/// The ack: `acked:<mailbox>@<ts>` + via:local in the sender's receipt. It
/// takes the durability proof BY VALUE — the only way to call it is with a
/// delivery whose file, directory and seen entry were fsync'd.
fn ack(
    sender_dir: &Path,
    id: &str,
    mailbox: &str,
    now: DateTime<Utc>,
    _durable: Fsynced,
) -> io::Result<()> {
    store::record_ack(sender_dir, id, mailbox, now, "local")
}

fn malformed(detail: &str) -> Refusal {
    Refusal::new(
        "malformed-envelope",
        "refused:malformed-envelope",
        &format!("the outbox entry is not an envelope the mover can deliver: {detail}"),
        "write messages with `tillandsias-plan msg send` (tmp then rename, YAML, file named by its id); the entry was moved to dead/",
    )
}

#[cfg(unix)]
fn take_singleton(root: &Path) -> Result<std::fs::File, StartRefusal> {
    use std::os::fd::AsRawFd;
    let path = root.join(".mover.lock");
    let f = std::fs::create_dir_all(root)
        .and_then(|_| {
            std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(&path)
        })
        .map_err(|e| {
            StartRefusal(format!(
                "refused:msg-serve:store-unwritable:{}\n  why: the mover could not open its lock in the store ({e})\n  remedy: check that {} is writable by this uid, or point TILLANDSIAS_MSG_ROOT at a writable directory",
                path.display(),
                root.display()
            ))
        })?;
    // SAFETY: a valid fd for the call's duration.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(StartRefusal(format!(
            "refused:msg-serve:already-running:{}\n  why: another mover holds {}; one mover per store keeps every delivery and sweep single-writer\n  remedy: nothing to do if the tray is running (it serves the store beside its control socket); otherwise stop the other `tillandsias --msg-serve`, or point TILLANDSIAS_MSG_ROOT at another store",
            root.display(),
            path.display()
        )));
    }
    Ok(f)
}

#[cfg(not(unix))]
fn take_singleton(root: &Path) -> Result<std::fs::File, StartRefusal> {
    std::fs::create_dir_all(root)
        .and_then(|_| {
            std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(root.join(".mover.lock"))
        })
        .map_err(|e| StartRefusal(format!("refused:msg-serve:store-unwritable:{e}")))
}

fn stderr_log() -> LogFn {
    Arc::new(|s: &str| eprintln!("{s}"))
}

/// The tray's resident: a thread beside the control socket, stopped by the
/// tray's shutdown latch. A second mover (a foreground `--msg-serve`) keeps
/// the store; the tray then logs why and runs none.
pub fn spawn_resident(stop: impl Fn() -> bool + Send + 'static) {
    std::thread::spawn(
        move || match Mover::start(MoverConfig::from_env(), stderr_log()) {
            Ok(mut m) => m.serve(stop),
            Err(StartRefusal(msg)) => eprintln!("{msg}"),
        },
    );
}

pub const USAGE: &str = "usage: tillandsias --msg-serve [--once]
       tillandsias --msg-serve --mint [--rotate] [--peers DIR]
       tillandsias --msg-serve --accept-once ADDR | --dial-once ADDR [--peers DIR]
  the same-host mover of the fleet message bus: delivers every lane's outbox
  into the destination lanes' inboxes on this host, acks after fsync, sweeps
  at TTL. --once runs one pass and one sweep and exits.
  --mint (order 1506-32k5) generates this host's X25519 message identity into
  its own Vault and writes plan/fleet/peers/<host>.yaml; an existing key is
  kept unless --rotate. --accept-once / --dial-once run ONE Noise XX session
  pinned to the peer directory (default ./plan/fleet/peers).";

/// `tillandsias --msg-serve [--once]`, or one identity verb
/// (crate::msg_identity). Returns the exit code.
pub fn run_cli(args: &[String]) -> i32 {
    use crate::msg_identity::{self, IdentityVerb};
    let usage = |other: &str| {
        eprintln!("refused:msg-serve:usage:{other}");
        eprintln!(
            "  why: --msg-serve takes --once, or one of --mint [--rotate] / --accept-once ADDR / --dial-once ADDR with an optional --peers DIR (and --debug); the store and the seams come from the environment"
        );
        eprintln!("  remedy: run `tillandsias --msg-serve` or `tillandsias --msg-serve --once`");
        eprintln!("{USAGE}");
        2
    };
    let mut once = false;
    let mut debug = false;
    let mut rotate = false;
    let mut peers: Option<String> = None;
    let mut verbs: Vec<IdentityVerb> = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--msg-serve" => {}
            "--debug" => debug = true,
            "--once" => once = true,
            "--mint" => verbs.push(IdentityVerb::Mint { rotate: false }),
            "--rotate" => rotate = true,
            flag @ ("--accept-once" | "--dial-once" | "--peers") => {
                let Some(v) = it.next().filter(|v| !v.starts_with("--")) else {
                    return usage(&format!("{flag}:missing-value"));
                };
                match flag {
                    "--accept-once" => verbs.push(IdentityVerb::AcceptOnce(v.clone())),
                    "--dial-once" => verbs.push(IdentityVerb::DialOnce(v.clone())),
                    _ => peers = Some(v.clone()),
                }
            }
            other => return usage(other),
        }
    }
    if verbs.len() > 1 || (!verbs.is_empty() && once) {
        return usage("one-verb-at-a-time");
    }
    if let Some(mut verb) = verbs.pop() {
        if let IdentityVerb::Mint { rotate: r } = &mut verb {
            *r = rotate;
        } else if rotate {
            return usage("--rotate-without-mint");
        }
        return msg_identity::run(verb, peers.as_deref(), debug);
    }
    if rotate || peers.is_some() {
        return usage("--rotate/--peers-without-an-identity-verb");
    }
    let cfg = MoverConfig::from_env();
    let mut m = match Mover::start(cfg, stderr_log()) {
        Ok(m) => m,
        Err(StartRefusal(msg)) => {
            eprintln!("{msg}");
            return 1;
        }
    };
    if once {
        let now = Utc::now();
        let t = m.tick(now);
        let swept = m.sweep(now);
        println!(
            "ok:msg-serve:once:acked={}:refused={}:pending={}:swept={swept}",
            t.acked, t.refused, t.pending
        );
        return 0;
    }
    let stop = match crate::install_shutdown_signal_handlers() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("refused:msg-serve:signals:{e}");
            eprintln!("  why: without SIGTERM/SIGINT handlers the mover could not stop cleanly");
            eprintln!(
                "  remedy: run it under a supervisor that can deliver signals, or use --once"
            );
            return 1;
        }
    };
    m.serve(move || stop.load(std::sync::atomic::Ordering::SeqCst));
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tillandsias_msg::store::{Receipt, RecipientState};

    const BODY: &str =
        "FYI:1506-q7ab:mover fixture\n- crates/tillandsias-headless/src/msg_serve.rs";

    fn now() -> DateTime<Utc> {
        store::parse_ts("2026-09-29T22:00:00Z").unwrap()
    }

    struct Fx {
        _t: tempfile::TempDir,
        root: PathBuf,
        logs: Arc<Mutex<Vec<String>>>,
    }

    impl Fx {
        fn new() -> Self {
            let t = tempfile::tempdir().unwrap();
            let root = t.path().join("msg");
            for l in [HOST_LANE, "a-default", "b-default"] {
                store::ensure_lane(&lane_dir(&root, l)).unwrap();
            }
            Self {
                _t: t,
                root,
                logs: Arc::default(),
            }
        }
        fn cfg(&self) -> MoverConfig {
            MoverConfig {
                root: self.root.clone(),
                host: "h".into(),
                lax: false,
                skip_fsync: false,
                wake_sock: None,
                poll: Duration::from_millis(20),
                sweep_every: Duration::from_millis(100),
            }
        }
        fn mover_with(&self, cfg: MoverConfig) -> Mover {
            let logs = Arc::clone(&self.logs);
            Mover::new(
                cfg,
                Arc::new(move |s: &str| logs.lock().unwrap().push(s.to_string())),
            )
        }
        fn mover(&self) -> Mover {
            self.mover_with(self.cfg())
        }
        fn dir(&self, lane: &str) -> PathBuf {
            lane_dir(&self.root, lane)
        }
        fn log(&self) -> String {
            self.logs.lock().unwrap().join("\n")
        }
        /// What `msg send` does: the pending receipt, then the outbox file.
        fn send(&self, e: &Envelope) {
            let lane = e.from.split_once('/').unwrap().1;
            let r = Receipt {
                id: e.id.clone(),
                from: e.from.clone(),
                ts: e.ts.clone(),
                ttl_s: e.ttl_s,
                broadcast: e.broadcast,
                row: None,
                recipients: e.to.iter().map(|t| RecipientState::pending(t)).collect(),
            };
            store::write_receipt(&self.dir(lane), &r).unwrap();
            self.write_straight(lane, e);
        }
        /// What a lane bypassing the CLI does: the outbox file alone.
        fn write_straight(&self, lane: &str, e: &Envelope) {
            let d = self.dir(lane);
            store::write_durable(
                &d.join("outbox/tmp"),
                &d.join("outbox/new"),
                &e.id,
                e.to_yaml().as_bytes(),
            )
            .unwrap();
        }
        fn status(&self, lane: &str, id: &str) -> Vec<String> {
            store::read_receipt(&self.dir(lane), id)
                .map(|r| r.status_lines())
                .unwrap_or_default()
        }
        fn files(&self, lane: &str, sub: &str) -> Vec<PathBuf> {
            store::box_files(&self.dir(lane).join(sub))
        }
        fn snapshot(&self, lane: &str) -> Vec<(PathBuf, Vec<u8>)> {
            fn walk(d: &Path, out: &mut Vec<(PathBuf, Vec<u8>)>) {
                if let Ok(rd) = std::fs::read_dir(d) {
                    for e in rd.flatten() {
                        let p = e.path();
                        if p.is_dir() {
                            walk(&p, out);
                        } else {
                            out.push((p.clone(), std::fs::read(&p).unwrap_or_default()));
                        }
                    }
                }
            }
            let mut v = Vec::new();
            walk(&self.dir(lane), &mut v);
            v.sort();
            v
        }
    }

    fn env(id: &str, from: &str, to: &[&str]) -> Envelope {
        Envelope {
            id: id.into(),
            from: from.into(),
            to: to.iter().map(|s| s.to_string()).collect(),
            from_agent: "test".into(),
            seq: 1,
            ts: store::fmt_ts(now()),
            ttl_s: 3600,
            broadcast: to.len() > 1 || to.iter().any(|t| t.starts_with('@')),
            kind: "FYI".into(),
            row: None,
            in_reply_to: None,
            body: BODY.into(),
        }
    }

    #[test]
    fn the_mover_acks_after_fsync_with_no_recv_ever_run() {
        let fx = Fx::new();
        fx.send(&env("m-1", "h/a-default", &["h/b-default"]));
        let t = fx.mover().tick(now());
        assert_eq!(t.acked, 1, "{}", fx.log());
        assert_eq!(
            fx.status("a-default", "m-1"),
            vec![
                "acked:h/b-default@2026-09-29T22:00:00Z".to_string(),
                "via:local".into()
            ]
        );
        assert_eq!(fx.files("b-default", "inbox/new").len(), 1);
        assert!(fx.files("b-default", "inbox/cur").is_empty(), "no recv ran");
        assert!(fx.files("a-default", "outbox/new").is_empty());
        // A second pass is idempotent: nothing left to move.
        assert_eq!(fx.mover().tick(now()), Tick::default());
    }

    /// NEGATIVE CONTROL for the ack: a crash between write and fsync (an
    /// injected fsync failure) never produces an ack, loses nothing, and the
    /// next healthy pass delivers and acks.
    #[test]
    fn a_failed_fsync_never_produces_an_ack() {
        fn fail(_: &std::fs::File) -> io::Result<()> {
            Err(io::Error::other(
                "injected: power lost before fsync returned",
            ))
        }
        let fx = Fx::new();
        fx.send(&env("m-2", "h/a-default", &["h/b-default"]));
        let mut m = fx.mover();
        m.sync = fail;
        let t = m.tick(now());
        assert_eq!(t.acked, 0);
        assert_eq!(fx.status("a-default", "m-2"), vec!["pending".to_string()]);
        assert!(fx.files("b-default", "inbox/new").is_empty());
        assert_eq!(
            fx.files("a-default", "outbox/new").len(),
            1,
            "kept for the retry"
        );
        assert_eq!(fx.mover().tick(now()).acked, 1);
        assert_eq!(
            fx.status("a-default", "m-2")[0],
            "acked:h/b-default@2026-09-29T22:00:00Z"
        );
    }

    #[test]
    fn the_skip_fsync_seam_refuses_the_ack() {
        let fx = Fx::new();
        fx.send(&env("m-3", "h/a-default", &["h/b-default"]));
        let mut cfg = fx.cfg();
        cfg.skip_fsync = true;
        let t = fx.mover_with(cfg).tick(now());
        assert_eq!(t.acked, 0);
        assert_eq!(fx.status("a-default", "m-3"), vec!["pending".to_string()]);
        assert!(
            fx.log().contains("refused:msg:ack-without-fsync:m-3"),
            "{}",
            fx.log()
        );
        assert!(fx.log().contains("  why: ") && fx.log().contains("  remedy: "));
    }

    #[test]
    fn a_lane_that_claims_another_lane_is_attributed_by_its_mount() {
        let fx = Fx::new();
        let b_before = fx.snapshot("b-default");
        // Written into a-default's outbox, claiming to be b-default.
        fx.write_straight("a-default", &env("m-4", "h/b-default", &["h/b-default"]));
        let t = fx.mover().tick(now());
        assert_eq!((t.acked, t.refused), (0, 1));
        assert!(
            fx.log().contains("refused:msg:from-lane-mismatch:m-4"),
            "{}",
            fx.log()
        );
        assert!(fx.dir("a-default").join("dead/m-4").is_file());
        assert_eq!(
            fx.snapshot("b-default"),
            b_before,
            "the claimed lane is untouched"
        );
        assert_eq!(
            fx.status("a-default", "m-4"),
            vec!["undelivered:refused:from-lane-mismatch".to_string()]
        );
        // The receipt names the MOUNT, never the claim.
        let r = store::read_receipt(&fx.dir("a-default"), "m-4").unwrap();
        assert_eq!(r.from, "h/a-default");
    }

    #[test]
    fn a_secret_written_straight_into_an_outbox_is_refused_by_the_mover() {
        let body = format!("FYI:creds:leak\n- 1506-q7ab hvs.{}", "a".repeat(24));
        let mk = |id: &str| Envelope {
            body: body.clone(),
            ..env(id, "h/a-default", &["h/b-default"])
        };
        let fx = Fx::new();
        fx.write_straight("a-default", &mk("m-5"));
        let t = fx.mover().tick(now());
        assert_eq!((t.acked, t.refused), (0, 1));
        assert!(
            fx.log()
                .contains("refused:msg:secret-shaped:vault-token:m-5"),
            "{}",
            fx.log()
        );
        assert!(fx.files("b-default", "inbox/new").is_empty());
        assert!(fx.dir("a-default").join("dead/m-5").is_file());
        // MUTATION CONTROL: without the mover's second check (the LAX seam)
        // the same envelope is delivered — the check above is what refused it.
        let mut cfg = fx.cfg();
        cfg.lax = true;
        fx.write_straight("a-default", &mk("m-6"));
        assert_eq!(fx.mover_with(cfg).tick(now()).acked, 1);
    }

    #[test]
    fn a_reply_to_a_broadcast_is_refused_by_the_exchange_layer() {
        let fx = Fx::new();
        // host → @h/* reaches a-default and b-default.
        fx.send(&env("m-bcast", "h/host", &["@h/*"]));
        assert_eq!(fx.mover().tick(now()).acked, 2, "{}", fx.log());
        // b-default writes a reply straight into its outbox.
        let reply = Envelope {
            in_reply_to: Some("m-bcast".into()),
            broadcast: false,
            ..env("m-reply", "h/b-default", &["h/host"])
        };
        fx.write_straight("b-default", &reply);
        let t = fx.mover().tick(now());
        assert_eq!(t.refused, 1);
        assert!(
            fx.log()
                .contains("refused:msg:reply-to-broadcast:m-bcast:m-reply"),
            "{}",
            fx.log()
        );
        assert!(fx.dir("b-default").join("dead/m-reply").is_file());
        assert_eq!(
            fx.status("b-default", "m-reply"),
            vec!["undelivered:refused:reply-to-broadcast".to_string()]
        );
        // CONTROL: a reply to a UNICAST passes the same check.
        fx.send(&env("m-uni", "h/a-default", &["h/b-default"]));
        fx.mover().tick(now());
        fx.send(&Envelope {
            in_reply_to: Some("m-uni".into()),
            ..env("m-reply2", "h/b-default", &["h/a-default"])
        });
        assert_eq!(fx.mover().tick(now()).acked, 1, "{}", fx.log());
    }

    #[test]
    fn a_wildcard_reaches_every_other_lane_with_one_ack_each() {
        let fx = Fx::new();
        fx.send(&env("m-7", "h/host", &["@h/*"]));
        fx.mover().tick(now());
        assert_eq!(
            fx.status("host", "m-7"),
            vec![
                "broadcast:2".to_string(),
                "acked:h/a-default@2026-09-29T22:00:00Z".into(),
                "acked:h/b-default@2026-09-29T22:00:00Z".into(),
            ]
        );
        for lane in ["a-default", "b-default"] {
            let copy: Envelope = store::read_yaml(&fx.dir(lane).join("inbox/new/m-7")).unwrap();
            assert_eq!(copy.to, vec![format!("h/{lane}")]);
            assert!(copy.broadcast);
        }
        assert!(
            fx.files("host", "inbox/new").is_empty(),
            "the sender is not a recipient"
        );
    }

    #[test]
    fn a_remote_recipient_stays_pending_and_keeps_the_outbox_entry() {
        let fx = Fx::new();
        fx.send(&env("m-8", "h/a-default", &["h/b-default", "yoga/host"]));
        let t = fx.mover().tick(now());
        assert_eq!((t.acked, t.pending), (1, 1));
        assert_eq!(
            fx.status("a-default", "m-8"),
            vec![
                "broadcast:2".to_string(),
                "acked:h/b-default@2026-09-29T22:00:00Z".into(),
                "pending:yoga/host".into()
            ]
        );
        assert_eq!(fx.files("a-default", "outbox/new").len(), 1);
        // The next pass does not re-ack the local recipient.
        let before = std::fs::read(fx.dir("a-default").join("receipts/m-8")).unwrap();
        fx.mover().tick(now() + chrono::Duration::seconds(5));
        assert_eq!(
            std::fs::read(fx.dir("a-default").join("receipts/m-8")).unwrap(),
            before
        );
    }

    #[test]
    fn the_ttl_sweep_drops_an_acked_copy_and_the_ack_stays() {
        let fx = Fx::new();
        fx.send(&Envelope {
            ttl_s: 60,
            ..env("m-9", "h/a-default", &["h/b-default"])
        });
        let mut m = fx.mover();
        m.tick(now());
        assert_eq!(fx.files("b-default", "inbox/new").len(), 1);
        m.sweep(now() + chrono::Duration::seconds(59));
        assert_eq!(fx.files("b-default", "inbox/new").len(), 1, "not yet");
        m.sweep(now() + chrono::Duration::seconds(61));
        assert!(fx.files("b-default", "inbox/new").is_empty());
        assert_eq!(
            fx.status("a-default", "m-9")[0],
            "acked:h/b-default@2026-09-29T22:00:00Z"
        );
    }

    #[test]
    fn an_unacked_message_expires_undelivered() {
        let fx = Fx::new();
        fx.send(&Envelope {
            ttl_s: 60,
            ..env("m-10", "h/a-default", &["h/c-default"])
        });
        let mut m = fx.mover();
        assert_eq!(m.tick(now()).pending, 1, "no c-default mailbox yet");
        m.sweep(now() + chrono::Duration::seconds(61));
        assert_eq!(
            fx.status("a-default", "m-10"),
            vec!["undelivered:expired".to_string()]
        );
        assert!(fx.dir("a-default").join("dead/m-10").is_file());
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_outbox_cannot_read_another_lanes_inbox() {
        let fx = Fx::new();
        fx.send(&env("m-11", "h/a-default", &["h/b-default"]));
        fx.mover().tick(now());
        let b_before = fx.snapshot("b-default");
        // A hostile c-default points its outbox at b-default's inbox.
        let c = fx.dir("c-default");
        std::fs::create_dir_all(c.join("outbox")).unwrap();
        std::os::unix::fs::symlink("../../b-default/inbox/new", c.join("outbox/new")).unwrap();
        let t = fx.mover().tick(now());
        assert_eq!(t.refused, 0);
        assert!(
            fx.log().contains("refused:msg:lane-not-plain:c-default"),
            "{}",
            fx.log()
        );
        assert_eq!(
            fx.snapshot("b-default"),
            b_before,
            "b's mail neither read nor moved"
        );
        assert!(store::box_files(&c.join("dead")).is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn the_wake_socket_gets_a_byte_per_delivery() {
        use std::io::Read;
        let fx = Fx::new();
        let mut cfg = fx.cfg();
        let sock = fx.root.join("run/msg.sock");
        cfg.wake_sock = Some(sock.clone());
        let logs = Arc::clone(&fx.logs);
        let mut m = Mover::start(
            cfg,
            Arc::new(move |s: &str| logs.lock().unwrap().push(s.into())),
        )
        .unwrap_or_else(|StartRefusal(s)| panic!("{s}"));
        let mut client = std::os::unix::net::UnixStream::connect(&sock).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        m.tick(now()); // accepts the waiter
        fx.send(&env("m-12", "h/a-default", &["h/b-default"]));
        m.tick(now());
        let mut b = [0u8; 1];
        assert_eq!(client.read(&mut b).unwrap(), 1, "{}", fx.log());
        // A second mover on the same store is refused, with its affordance.
        let second = Mover::start(fx.cfg(), stderr_log());
        match second {
            Err(StartRefusal(s)) => {
                assert!(s.starts_with("refused:msg-serve:already-running:"), "{s}");
                assert!(s.contains("  why: ") && s.contains("  remedy: "));
            }
            Ok(_) => panic!("two movers on one store"),
        }
    }

    #[test]
    fn a_malformed_entry_goes_to_dead_without_a_receipt() {
        let fx = Fx::new();
        let d = fx.dir("a-default");
        std::fs::write(d.join("outbox/new/junk"), "not: [an envelope").unwrap();
        // Age it past the in-flight grace.
        let old = std::time::SystemTime::now() - Duration::from_secs(10);
        std::fs::File::options()
            .write(true)
            .open(d.join("outbox/new/junk"))
            .unwrap()
            .set_modified(old)
            .unwrap();
        assert_eq!(fx.mover().tick(now()).refused, 1);
        assert!(d.join("dead/junk").is_file());
        assert!(fx.log().contains("refused:msg:malformed-envelope:junk"));
    }

    #[test]
    fn forge_lane_labels_and_mount_args() {
        assert_eq!(
            forge_lane_label("tillandsias", None).as_deref(),
            Some("tillandsias-default")
        );
        assert_eq!(
            forge_lane_label("alpha", Some("w1")).as_deref(),
            Some("alpha-w1")
        );
        assert_eq!(
            forge_lane_label("My_Proj", Some(" ")).as_deref(),
            Some("my-proj-default")
        );
        let t = tempfile::tempdir().unwrap();
        let m = prepare_forge_lane_in(t.path(), "alpha", Some("w1")).unwrap();
        assert!(m.source.join("outbox/new").is_dir() && m.source.join("inbox/new").is_dir());
        let args = m.podman_args();
        assert_eq!(args[0], "--mount");
        assert_eq!(
            args[1],
            format!(
                "type=bind,source={}/lanes/alpha-w1,target=/run/host/tillandsias-msg,relabel=shared",
                t.path().display()
            )
        );
        assert_eq!(args[3], "TILLANDSIAS_MSG_LANE=alpha-w1");
        assert!(args[5].starts_with("TILLANDSIAS_MSG_HOST="));
    }
}
