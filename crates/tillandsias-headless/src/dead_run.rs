//! A tray start after an unclean exit reaps what the dead run left (order 1859-v5iv).
//!
//! WHY. A tray that dies without its graceful shutdown (kill -9, a crash, a
//! logout that skips SIGTERM) leaves its forges running with no owner: their
//! lane sockets have no listener and their configs stay live, and on
//! macuahuitl 2026-10-24 no further forge would launch until the store was
//! cleared by hand. Nothing on start noticed the dead run.
//!
//! HOW. Each tray run mints an id, exports it as [`RUN_ENV`] before it spawns
//! anything, and every forge launched under it carries [`RUN_LABEL`]`=<id>`
//! (the forge launches inherit the env). A run MARKER in the state dir records
//! the id with the tray's pid, process start time and boot id. On start the
//! previous marker is read: when no live process matches it, that run is dead
//! and its labelled containers are stopped (SIGTERM, then podman's own SIGKILL
//! after the timeout) and only THEN removed, followed by its labelled volumes.
//! Removal waits for every stop, so forced removal never races a network
//! teardown that a stop is still doing. A graceful exit removes its marker.
//!
//! OWNERSHIP. Only containers and volumes carrying the dead run's label are
//! touched: never the shared stack, another live tray's forges, or anything a
//! CLI lane launched outside a tray.
//!
//! @trace spec:graceful-shutdown, spec:app-lifecycle

#[cfg(feature = "tray")]
use std::path::{Path, PathBuf};
#[cfg(feature = "tray")]
use tillandsias_podman::{OperationKind, PodmanClient};
#[cfg(feature = "tray")]
use tracing::{info, warn};

/// The env var a tray run exports so the forges it launches can be labelled.
pub(crate) const RUN_ENV: &str = "TILLANDSIAS_TRAY_RUN";
/// The container and volume label naming the tray run that launched it.
pub(crate) const RUN_LABEL: &str = "tillandsias.tray-run";
#[cfg(feature = "tray")]
/// Seconds a dead run's container gets between SIGTERM and SIGKILL.
pub(crate) const REAP_STOP_SECS: u32 = 10;

#[cfg(feature = "tray")]
/// One tray run, as its marker records it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RunMarker {
    pub(crate) id: String,
    pub(crate) pid: u32,
    pub(crate) start: u64,
    pub(crate) boot: String,
}

#[cfg(feature = "tray")]
impl RunMarker {
    /// This process, under run id `id`.
    pub(crate) fn current(id: &str) -> Option<Self> {
        let pid = std::process::id();
        Some(Self {
            id: id.to_string(),
            pid,
            start: proc_start_time(pid)?,
            boot: boot_id()?,
        })
    }

    fn render(&self) -> String {
        format!(
            "id={}\npid={}\nstart={}\nboot={}\n",
            self.id, self.pid, self.start, self.boot
        )
    }

    fn parse(text: &str) -> Option<Self> {
        let field = |key: &str| {
            text.lines()
                .find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
                .map(str::to_string)
        };
        let id = field("id")?;
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return None;
        }
        Some(Self {
            id,
            pid: field("pid")?.parse().ok()?,
            start: field("start")?.parse().ok()?,
            boot: field("boot")?,
        })
    }

    /// Is the process this marker names still running? A different boot, a
    /// gone pid, or a reused pid (other start time) all read as dead.
    fn is_live(&self) -> bool {
        boot_id().as_deref() == Some(self.boot.as_str())
            && proc_start_time(self.pid) == Some(self.start)
    }
}

#[cfg(feature = "tray")]
/// Field 22 of /proc/<pid>/stat: the process start time in clock ticks since
/// boot. The comm field may hold spaces and parens, so count from the last ')'.
fn proc_start_time(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 1..];
    rest.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(feature = "tray")]
fn boot_id() -> Option<String> {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(feature = "tray")]
pub(crate) fn marker_path() -> PathBuf {
    tillandsias_core::config::state_dir().join("tray-run")
}

#[cfg(feature = "tray")]
/// Mint this run's id and export it as [`RUN_ENV`]. Call before the tray
/// starts any thread: the env is process-wide.
pub(crate) fn mint_run_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let id = format!("{}-{nanos:x}", std::process::id());
    // SAFETY: called at the top of tray start, before any thread exists.
    unsafe { std::env::set_var(RUN_ENV, &id) };
    id
}

#[cfg(feature = "tray")]
/// Record `me` as the current run and return the id of the previous run when
/// it died without its graceful exit. A previous run that is still live is
/// another tray: its marker is left in place and nothing is reaped.
pub(crate) fn claim_run(path: &Path, me: &RunMarker) -> Option<String> {
    let previous = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| RunMarker::parse(&text));
    if let Some(prev) = &previous
        && prev.id != me.id
        && prev.is_live()
    {
        warn!(
            spec = "graceful-shutdown",
            pid = prev.pid,
            "another tray run is live; not claiming the run marker"
        );
        return None;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, me.render()).is_err() || std::fs::rename(&tmp, path).is_err() {
        warn!(path = %path.display(), "could not write the tray run marker");
    }
    previous.filter(|prev| prev.id != me.id).map(|prev| prev.id)
}

#[cfg(feature = "tray")]
/// A graceful exit drops the marker, but only its own.
pub(crate) fn release_run(path: &Path, id: &str) {
    let ours = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| RunMarker::parse(&text))
        .is_some_and(|m| m.id == id);
    if ours {
        let _ = std::fs::remove_file(path);
    }
}

/// `--label tillandsias.tray-run=<id>` when this process runs under a tray run.
pub(crate) fn run_label_args() -> Vec<String> {
    run_label_value()
        .map(|id| vec!["--label".to_string(), format!("{RUN_LABEL}={id}")])
        .unwrap_or_default()
}

pub(crate) fn run_label_value() -> Option<String> {
    std::env::var(RUN_ENV)
        .ok()
        .filter(|id| !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
}

#[cfg(feature = "tray")]
/// What a reap did, for the log and the tests.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ReapReport {
    pub(crate) stopped: Vec<String>,
    pub(crate) removed: Vec<String>,
    pub(crate) volumes: Vec<String>,
}

#[cfg(feature = "tray")]
/// Stop, then remove, every container labelled with `run`; then its volumes.
pub(crate) async fn reap_dead_run(client: &PodmanClient, run: &str) -> ReapReport {
    let filter = format!("label={RUN_LABEL}={run}");
    let mut report = ReapReport::default();
    let listed = client
        .execute(
            OperationKind::Container,
            &[
                "ps".into(),
                "-a".into(),
                "--filter".into(),
                filter.clone(),
                "--format".into(),
                "{{.Names}}\t{{.State}}".into(),
            ],
        )
        .await;
    let containers: Vec<(String, String)> = match listed {
        Ok(out) => out
            .stdout
            .lines()
            .filter_map(|line| {
                let (name, state) = line.split_once('\t')?;
                Some((name.trim().to_string(), state.trim().to_string()))
            })
            .filter(|(name, _)| !name.is_empty())
            .collect(),
        Err(err) => {
            warn!(spec = "graceful-shutdown", run, error = %err, "could not list the dead run's containers");
            return report;
        }
    };

    let running: Vec<String> = containers
        .iter()
        .filter(|(_, state)| state == "running")
        .map(|(name, _)| name.clone())
        .collect();
    let stops = running.iter().map(|name| async move {
        let _ = client.stop_container(name, REAP_STOP_SECS).await;
        name.clone()
    });
    report.stopped = futures::future::join_all(stops).await;

    for (name, _) in &containers {
        let _ = client.remove_container(name).await;
        report.removed.push(name.clone());
    }

    if let Ok(out) = client
        .execute(
            OperationKind::Container,
            &[
                "volume".into(),
                "ls".into(),
                "--filter".into(),
                filter,
                "--format".into(),
                "{{.Name}}".into(),
            ],
        )
        .await
    {
        for volume in out.stdout.lines().map(str::trim).filter(|v| !v.is_empty()) {
            let argv = ["volume".to_string(), "rm".to_string(), volume.to_string()];
            if client
                .execute(OperationKind::Container, &argv)
                .await
                .is_ok()
            {
                report.volumes.push(volume.to_string());
            }
        }
    }

    info!(
        spec = "graceful-shutdown",
        run,
        stopped = report.stopped.len(),
        removed = report.removed.len(),
        volumes = report.volumes.len(),
        "reaped the dead tray run"
    );
    report
}

#[cfg(all(test, feature = "tray"))]
mod tests {
    use super::*;

    fn marker(id: &str, pid: u32, start: u64, boot: &str) -> RunMarker {
        RunMarker {
            id: id.into(),
            pid,
            start,
            boot: boot.into(),
        }
    }

    #[test]
    fn marker_round_trips_and_refuses_a_hostile_id() {
        let m = marker("123-abc", 123, 456, "b00t");
        assert_eq!(RunMarker::parse(&m.render()), Some(m));
        assert_eq!(
            RunMarker::parse("id=../x\npid=1\nstart=1\nboot=b\n"),
            None,
            "an id that is not [A-Za-z0-9-] never reaches a podman filter"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn this_process_reads_live_and_a_dead_or_reused_pid_reads_dead() {
        let me = RunMarker::current("me").expect("procfs");
        assert!(me.is_live());
        assert!(
            !marker("x", me.pid, me.start + 1, &me.boot).is_live(),
            "pid reuse"
        );
        assert!(
            !marker("x", me.pid, me.start, "other-boot").is_live(),
            "reboot"
        );
        assert!(
            !marker("x", u32::MAX - 1, me.start, &me.boot).is_live(),
            "gone pid"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn claim_returns_a_dead_run_and_leaves_a_live_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tray-run");
        let me = RunMarker::current("new-run").unwrap();

        assert_eq!(
            claim_run(&path, &me),
            None,
            "first ever start reaps nothing"
        );

        let dead = marker("dead-run", me.pid, me.start + 1, &me.boot);
        std::fs::write(&path, dead.render()).unwrap();
        assert_eq!(claim_run(&path, &me).as_deref(), Some("dead-run"));
        assert_eq!(
            RunMarker::parse(&std::fs::read_to_string(&path).unwrap()),
            Some(me.clone())
        );

        let live = RunMarker::current("other-tray").unwrap();
        std::fs::write(&path, live.render()).unwrap();
        assert_eq!(
            claim_run(&path, &me),
            None,
            "a live tray's run is not reaped"
        );
        assert_eq!(
            RunMarker::parse(&std::fs::read_to_string(&path).unwrap()),
            Some(live),
            "nor is its marker taken"
        );

        release_run(&path, "new-run");
        assert!(path.exists(), "release drops only its own marker");
        release_run(&path, "other-tray");
        assert!(!path.exists());
    }

    /// The reap against a fake podman: the running container is stopped with
    /// the timeout BEFORE anything is removed, both are removed, then the
    /// run's volume, and every call is filtered by the dead run's label.
    #[cfg(unix)]
    #[test]
    fn reap_stops_before_removing_and_touches_only_the_dead_runs_label() {
        use std::os::unix::fs::PermissionsExt;
        let _seam = crate::runtime_assets::podman_seam_lock();
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("calls");
        let fake = dir.path().join("podman");
        std::fs::write(
            &fake,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$*" >> '{log}'
case "$1 $2" in
  "ps -a") printf 'tillandsias-p-forge\trunning\ntillandsias-q-forge\texited\n' ;;
  "volume ls") printf 'tillandsias-src-p\n' ;;
esac
exit 0
"#,
                log = log.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        let prev = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", &fake) };

        let report = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(reap_dead_run(&PodmanClient::new(), "dead-1"));

        unsafe {
            match prev {
                Some(v) => std::env::set_var("TILLANDSIAS_PODMAN_BIN", v),
                None => std::env::remove_var("TILLANDSIAS_PODMAN_BIN"),
            }
        }

        assert_eq!(report.stopped, vec!["tillandsias-p-forge"]);
        assert_eq!(
            report.removed,
            vec!["tillandsias-p-forge", "tillandsias-q-forge"]
        );
        assert_eq!(report.volumes, vec!["tillandsias-src-p"]);

        let calls = std::fs::read_to_string(&log).unwrap();
        let at = |needle: &str| {
            calls
                .lines()
                .position(|l| l.contains(needle))
                .unwrap_or_else(|| panic!("no call containing {needle:?} in:\n{calls}"))
        };
        assert!(calls.contains("ps -a --filter label=tillandsias.tray-run=dead-1"));
        assert!(calls.contains("volume ls --filter label=tillandsias.tray-run=dead-1"));
        let stop = at(&format!("stop -t {REAP_STOP_SECS} tillandsias-p-forge"));
        assert!(
            stop < at("rm -f tillandsias-p-forge"),
            "stop before remove:\n{calls}"
        );
        assert!(
            stop < at("rm -f tillandsias-q-forge"),
            "every stop before any remove:\n{calls}"
        );
        assert!(
            at("rm -f tillandsias-q-forge") < at("volume rm"),
            "containers before volumes"
        );
        assert!(
            !calls.contains("stop -t 10 tillandsias-q-forge"),
            "an exited one is not stopped"
        );
    }
}
