// @trace order:1922-rann, spec:podman-orchestration
//! Enclave services announce readiness as an event (operator ruling 2026-10-28).
//!
//! The launcher binds one unix datagram socket per service launch and starts
//! the container with `--sdnotify=container` and `NOTIFY_SOCKET` pointing at it
//! on the podman PROCESS. Conmon relays the container's own `READY=1` there
//! (measured on lenovinha, podman 5.8.9: `MAINPID=` at 1.1 s, the container's
//! `READY=1` at 4.1 s, `podman run -d` returning at once). The service decides
//! when it is ready; nothing here probes it.
//!
//! One launch yields exactly one outcome: the first `READY=1` becomes
//! `event:service_ready`, and silence past the deadline becomes one
//! `event:service_ready_failed` carrying `retry_after`. On macOS and Windows
//! this runs inside the VM or WSL distro beside podman, so the socket is local
//! there too.

#[cfg(unix)]
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;

/// What a launch ends with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadyOutcome {
    /// The service sent `READY=1`; `status` is its `STATUS=` text, if any.
    Ready { status: Option<String> },
    /// No `READY=1` before the deadline (or the socket failed).
    Failed {
        reason: String,
        retry_after: Duration,
    },
}

/// One sd_notify datagram, reduced to the fields this module acts on.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct NotifyMessage {
    pub ready: bool,
    pub status: Option<String>,
}

/// Parse an sd_notify datagram (`KEY=VALUE` lines). `MAINPID=` from conmon and
/// any other key is ignored; only `READY=1` means ready.
pub fn parse_notify(datagram: &[u8]) -> NotifyMessage {
    let mut msg = NotifyMessage::default();
    for line in String::from_utf8_lossy(datagram).lines() {
        match line.split_once('=') {
            Some(("READY", "1")) => msg.ready = true,
            Some(("STATUS", v)) if !v.trim().is_empty() => msg.status = Some(v.trim().to_string()),
            _ => {}
        }
    }
    msg
}

/// The event line for an outcome. Field order is pinned by test so a litmus
/// can grep it.
pub fn outcome_event(
    service: &str,
    container: &str,
    outcome: &ReadyOutcome,
) -> (&'static str, String) {
    match outcome {
        ReadyOutcome::Ready { status } => {
            let mut body = format!("event:service_ready service={service} container={container}");
            if let Some(s) = status {
                body.push_str(&format!(" status={}", s.replace(char::is_whitespace, "_")));
            }
            ("event:service_ready", body)
        }
        ReadyOutcome::Failed {
            reason,
            retry_after,
        } => (
            "event:service_ready_failed",
            format!(
                "event:service_ready_failed service={service} container={container} reason={} retry_after={}s",
                reason.replace(char::is_whitespace, "_"),
                retry_after.as_secs()
            ),
        ),
    }
}

/// Where a service's notify socket lives. AF_UNIX paths are capped at 108
/// bytes, so this stays under the runtime dir, never a deep scratch path.
pub fn notify_socket_path(runtime_dir: &Path, service: &str) -> PathBuf {
    runtime_dir
        .join("tillandsias")
        .join("notify")
        .join(format!("{service}.sock"))
}

#[cfg(unix)]
fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
}

/// A bound notify socket for one service launch.
#[cfg(unix)]
pub struct ReadyListener {
    path: PathBuf,
    socket: UnixDatagram,
}

#[cfg(unix)]
impl Drop for ReadyListener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(unix)]
impl ReadyListener {
    /// Bind the service's socket under `$XDG_RUNTIME_DIR`, replacing a stale
    /// one from an earlier launch.
    pub fn bind(service: &str) -> std::io::Result<Self> {
        Self::bind_at(notify_socket_path(&runtime_dir(), service))
    }

    pub fn bind_at(path: PathBuf) -> std::io::Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let socket = UnixDatagram::bind(&path)?;
        Ok(Self { path, socket })
    }

    /// The environment for the podman process that runs the service.
    pub fn podman_env(&self) -> Vec<(String, String)> {
        vec![("NOTIFY_SOCKET".to_string(), self.path.display().to_string())]
    }

    /// Wait for the first `READY=1`, at most `deadline`. Returns exactly one
    /// outcome and removes the socket.
    pub fn wait(self, deadline: Duration, retry_after: Duration) -> ReadyOutcome {
        let started = Instant::now();
        let mut buf = [0u8; 4096];
        let outcome = loop {
            let left = deadline.saturating_sub(started.elapsed());
            if left.is_zero() {
                break ReadyOutcome::Failed {
                    reason: format!("no READY=1 within {}s", deadline.as_secs()),
                    retry_after,
                };
            }
            if let Err(e) = self.socket.set_read_timeout(Some(left)) {
                break ReadyOutcome::Failed {
                    reason: e.to_string(),
                    retry_after,
                };
            }
            match self.socket.recv(&mut buf) {
                Ok(n) => {
                    let msg = parse_notify(&buf[..n]);
                    if msg.ready {
                        break ReadyOutcome::Ready { status: msg.status };
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e) => {
                    break ReadyOutcome::Failed {
                        reason: e.to_string(),
                        retry_after,
                    };
                }
            }
        };
        let _ = std::fs::remove_file(&self.path);
        outcome
    }

    /// Wait on a background thread and emit the one event line for the launch.
    /// The handle yields the outcome for a caller (the 1922-gate readiness
    /// gate) that wants to block on it.
    pub fn announce(
        self,
        service: &str,
        container: &str,
        deadline: Duration,
        retry_after: Duration,
    ) -> std::thread::JoinHandle<ReadyOutcome> {
        let (service, container) = (service.to_string(), container.to_string());
        std::thread::spawn(move || {
            let outcome = self.wait(deadline, retry_after);
            let (kind, body) = outcome_event(&service, &container, &outcome);
            crate::client::emit_diagnostic_event(true, kind, &container, &body);
            publish(&container, outcome.clone());
            outcome
        })
    }
}

/// The argv flag a launch carries to opt in.
pub const SDNOTIFY_FLAG: &str = "--sdnotify=container";

/// How long a launch may stay silent before its one failed event. A cold
/// mirror seed is measured in minutes (the 1200 s mirror budget), the others in
/// seconds.
pub fn ready_deadline(container: &str) -> Duration {
    if container.starts_with("tillandsias-git-") {
        Duration::from_secs(1200)
    } else {
        Duration::from_secs(120)
    }
}

/// What a failed event tells a subscriber to wait before trying again.
pub const RETRY_AFTER: Duration = Duration::from_secs(5);

/// The service label in an event: the container name without the stack prefix.
pub fn service_label(container: &str) -> &str {
    container.strip_prefix("tillandsias-").unwrap_or(container)
}

/// Bind a listener for a launch whose argv opts in; `None` (and a warning) if
/// it does not opt in or the socket cannot be bound, so the launch proceeds as
/// before.
#[cfg(unix)]
pub fn bind_for_launch(container: &str, args: &[String]) -> Option<ReadyListener> {
    if !args.iter().any(|a| a == SDNOTIFY_FLAG) {
        return None;
    }
    match ReadyListener::bind(service_label(container)) {
        Ok(l) => {
            begin(container);
            Some(l)
        }
        Err(e) => {
            eprintln!(
                "[tillandsias] readiness socket for {container} not bound ({e}); no ready event this launch"
            );
            None
        }
    }
}

/// Announce the launch's one outcome on a background thread.
#[cfg(unix)]
pub fn announce_launch(listener: ReadyListener, container: &str) {
    let _ = listener.announce(
        service_label(container),
        container,
        ready_deadline(container),
        RETRY_AFTER,
    );
}

// ── 1922-gate: the readiness board ───────────────────────────────────────────
//
// One entry per container this process launched or reused. A launch marks its
// entry pending when it binds the notify socket and publishes its one outcome
// when the announce thread ends; a container the launcher found already running
// (and accepted as such) is published Ready with a `reused` status, since no
// new READY=1 will come. The gate subscribes to the entries and returns when
// every one holds an outcome: it never probes a service.

type Slot = tokio::sync::watch::Sender<Option<ReadyOutcome>>;

fn board() -> &'static std::sync::Mutex<std::collections::HashMap<String, Slot>> {
    static BOARD: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, Slot>>> =
        std::sync::OnceLock::new();
    BOARD.get_or_init(Default::default)
}

fn slot(container: &str) -> Slot {
    let mut map = board().lock().unwrap_or_else(|e| e.into_inner());
    map.entry(container.to_string())
        .or_insert_with(|| tokio::sync::watch::channel(None).0)
        .clone()
}

/// A launch of `container` started: forget any earlier outcome.
pub fn begin(container: &str) {
    slot(container).send_replace(None);
}

/// The launch's one outcome. The announce thread calls this; a fixture is the
/// other caller, standing in for conmon.
pub fn publish(container: &str, outcome: ReadyOutcome) {
    slot(container).send_replace(Some(outcome));
}

/// The launcher accepted an already-running `container`: it is ready, and no
/// new event will say so.
pub fn mark_reused(container: &str) {
    publish(
        container,
        ReadyOutcome::Ready {
            status: Some("reused".to_string()),
        },
    );
}

/// Whether anything in this process launched or reused `container`.
pub fn is_tracked(container: &str) -> bool {
    board()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .contains_key(container)
}

/// Await `container`'s outcome for at most `deadline`. An outcome already
/// published returns at once. Silence past the deadline is published as one
/// failed outcome and emitted as its one `event:service_ready_failed`; a
/// failure the announce thread already emitted is returned, not re-emitted.
pub async fn await_ready(container: &str, deadline: Duration) -> ReadyOutcome {
    let mut rx = slot(container).subscribe();
    let waited = tokio::time::timeout(deadline, rx.wait_for(Option::is_some)).await;
    if let Ok(Ok(outcome)) = waited
        && let Some(outcome) = outcome.clone()
    {
        return outcome;
    }
    let outcome = ReadyOutcome::Failed {
        reason: format!("no ready event within {}s", deadline.as_secs()),
        retry_after: RETRY_AFTER,
    };
    let (kind, body) = outcome_event(service_label(container), container, &outcome);
    crate::client::emit_diagnostic_event(true, kind, container, &body);
    publish(container, outcome.clone());
    outcome
}

/// The gate's own deadline: the announce thread's, plus slack so a published
/// outcome always wins the race against the gate's timeout.
pub fn gate_deadline(container: &str) -> Duration {
    ready_deadline(container) + Duration::from_secs(5)
}

/// Await every hard requirement. `Ok` only when all of them are ready; `Err`
/// names each one that failed and the longest `retry_after`.
pub async fn gate(containers: &[&str]) -> Result<(), String> {
    gate_within(containers, gate_deadline).await
}

pub async fn gate_within(
    containers: &[&str],
    deadline: impl Fn(&str) -> Duration,
) -> Result<(), String> {
    // Concurrently, so the deadlines run side by side and never stack.
    let mut waits = tokio::task::JoinSet::new();
    for c in containers {
        let (container, within) = (c.to_string(), deadline(c));
        waits.spawn(async move {
            let outcome = await_ready(&container, within).await;
            (container, outcome)
        });
    }
    let mut failed = Vec::new();
    let mut retry = Duration::ZERO;
    while let Some(joined) = waits.join_next().await {
        let (container, outcome) = joined.map_err(|e| format!("readiness gate task: {e}"))?;
        if let ReadyOutcome::Failed {
            reason,
            retry_after,
        } = outcome
        {
            retry = retry.max(retry_after);
            failed.push(format!("{container}: {reason}"));
        }
    }
    failed.sort();
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "readiness gate: {} not ready ({}); retry_after={}s",
            if failed.len() == 1 {
                "a hard requirement is"
            } else {
                "hard requirements are"
            },
            failed.join("; "),
            retry.as_secs()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_ready_1_is_ready_and_mainpid_is_ignored() {
        assert_eq!(parse_notify(b"MAINPID=24414"), NotifyMessage::default());
        assert!(!parse_notify(b"READY=0").ready);
        let m = parse_notify(b"READY=1\nSTATUS=mirror seeded");
        assert!(m.ready);
        assert_eq!(m.status.as_deref(), Some("mirror seeded"));
    }

    #[test]
    fn event_lines_are_pinned() {
        let ok = ReadyOutcome::Ready {
            status: Some("vault unsealed".into()),
        };
        assert_eq!(
            outcome_event("vault", "tillandsias-vault", &ok),
            (
                "event:service_ready",
                "event:service_ready service=vault container=tillandsias-vault status=vault_unsealed".into()
            )
        );
        let failed = ReadyOutcome::Failed {
            reason: "no READY=1 within 2s".into(),
            retry_after: Duration::from_secs(5),
        };
        assert_eq!(
            outcome_event("proxy", "tillandsias-proxy", &failed).1,
            "event:service_ready_failed service=proxy container=tillandsias-proxy reason=no_READY=1_within_2s retry_after=5s"
        );
    }

    #[test]
    fn deadlines_and_labels_follow_the_service() {
        assert_eq!(
            service_label("tillandsias-git-kumbia-kombat"),
            "git-kumbia-kombat"
        );
        assert_eq!(
            ready_deadline("tillandsias-git-x"),
            Duration::from_secs(1200)
        );
        assert_eq!(
            ready_deadline("tillandsias-proxy"),
            Duration::from_secs(120)
        );
    }

    #[cfg(unix)]
    #[test]
    fn only_an_opted_in_launch_binds_a_socket() {
        assert!(bind_for_launch("tillandsias-forge-x", &["--detach".to_string()]).is_none());
    }

    #[test]
    fn the_socket_path_fits_af_unix() {
        let p = notify_socket_path(Path::new("/run/user/1000"), "git-kumbia-kombat");
        assert!(p.as_os_str().len() < 108, "{}", p.display());
    }

    #[cfg(unix)]
    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tl-rann-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d.join("s.sock")
    }

    #[cfg(unix)]
    #[test]
    fn one_outcome_per_launch_first_ready_wins_after_mainpid() {
        let path = scratch("ready");
        let l = ReadyListener::bind_at(path.clone()).expect("bind");
        let tx = UnixDatagram::unbound().expect("sock");
        tx.send_to(b"MAINPID=7", &path).expect("send");
        tx.send_to(b"READY=1\nSTATUS=first", &path).expect("send");
        tx.send_to(b"READY=1\nSTATUS=second", &path).expect("send");
        let out = l.wait(Duration::from_secs(5), Duration::from_secs(5));
        assert_eq!(
            out,
            ReadyOutcome::Ready {
                status: Some("first".into())
            }
        );
        assert!(
            !path.exists(),
            "the socket is removed after the one outcome"
        );
    }

    #[cfg(unix)]
    #[test]
    fn silence_is_one_failed_outcome_with_retry_after() {
        let path = scratch("silent");
        let l = ReadyListener::bind_at(path).expect("bind");
        let out = l.wait(Duration::from_millis(200), Duration::from_secs(7));
        match out {
            ReadyOutcome::Failed { retry_after, .. } => {
                assert_eq!(retry_after, Duration::from_secs(7))
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    /// 1922-gate: the board answers from published outcomes, never a probe.
    #[tokio::test]
    async fn the_gate_waits_for_every_outcome_and_refuses_with_retry_after() {
        let short = |_: &str| Duration::from_millis(100);
        mark_reused("gate-test-a");
        begin("gate-test-b");
        // b is pending: the gate times out on it alone, once.
        let err = gate_within(&["gate-test-a", "gate-test-b"], short)
            .await
            .unwrap_err();
        assert!(
            err.contains("gate-test-b") && !err.contains("gate-test-a"),
            "{err}"
        );
        assert!(err.contains("retry_after=5s"), "{err}");
        // The timeout was published, so the next await answers at once.
        assert!(matches!(
            await_ready("gate-test-b", Duration::ZERO).await,
            ReadyOutcome::Failed { .. }
        ));
        // A relaunch clears it; a later READY lets the gate through.
        begin("gate-test-b");
        let later = tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(20)).await;
            publish("gate-test-b", ReadyOutcome::Ready { status: None });
        });
        gate_within(&["gate-test-a", "gate-test-b"], |_: &str| {
            Duration::from_secs(5)
        })
        .await
        .unwrap();
        later.await.unwrap();
        assert!(is_tracked("gate-test-a") && !is_tracked("gate-test-never"));
    }
}
