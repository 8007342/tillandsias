//! ORDER 2067-dwqd — a container held at `memory.high` is NAMED, never silent.
//!
//! `memory.high` is the graceful-throttle knob the operator chose over the
//! OOM killer (design: plan/issues/forge-memory-swap-architecture-design-2026-09-26.md
//! §3), so a forge whose working set outgrows its budget does not die: the
//! kernel reclaims and throttles it. That is the point, but it is also
//! invisible. On 2026-11-09 the demon_attack forge sat at its 10.2 GiB
//! `memory.high` for about two hours (four workers each loading their own
//! model, about 9M `high` events, host swap full), and its TUI and remote
//! control froze with nothing on the tray.
//!
//! This module reads the two counters that tell a throttled container from a
//! busy one, per container scope:
//! - `memory.pressure` `full avg60`: the share of the last minute in which
//!   EVERY non-idle task of the cgroup waited on memory (reclaim, swap-in,
//!   throttling). A busy container is near 0; a stalled one is not.
//! - `memory.events` `high`: how many times the cgroup crossed `memory.high`.
//!   A rise since the previous sample says the pressure is the budget's, not
//!   the host's I/O.
//!
//! [`StallWatch`] turns samples into episodes: one [`StallVerdict::Stalled`]
//! when a container enters a stall, one [`StallVerdict::Recovered`] when it
//! leaves, nothing in between, so the tray names a stall once.
//!
//! Pure with respect to process spawning, like [`crate::container`]: the scan
//! takes the `podman ps` JSON and the cgroup root as parameters.
// @trace order:2067-dwqd

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// `full avg60` at or above this, with `high` events rising, is a stall: for
/// at least 6 s of the last minute nothing in the container could run.
pub const STALL_FULL_AVG60: f64 = 10.0;
/// `full avg60` below this ends a stall episode (hysteresis, so a container
/// hovering at the threshold is not named every sample).
pub const RECOVER_FULL_AVG60: f64 = 2.0;

/// One container's memory-pressure sample.
#[derive(Debug, Clone, PartialEq)]
pub struct StallSample {
    pub name: String,
    /// `memory.pressure` `full avg60`, percent.
    pub full_avg60: f64,
    /// `memory.events` `high`, cumulative.
    pub high_events: u64,
    /// `memory.current`, bytes.
    pub current_bytes: Option<u64>,
    /// `memory.high`, bytes; `None` when `max` (unbudgeted).
    pub high_bytes: Option<u64>,
}

/// What [`StallWatch::observe`] reports for one sample.
#[derive(Debug, Clone, PartialEq)]
pub enum StallVerdict {
    /// The container just entered a stall. The message names it.
    Stalled(String),
    /// The container just left a stall.
    Recovered(String),
}

/// `full avg60=` from a `memory.pressure` body.
pub fn parse_full_avg60(pressure: &str) -> Option<f64> {
    let line = pressure.lines().find(|l| l.starts_with("full "))?;
    line.split_whitespace()
        .find_map(|kv| kv.strip_prefix("avg60="))?
        .parse()
        .ok()
}

/// The `high` counter from a `memory.events` body.
pub fn parse_high_events(events: &str) -> Option<u64> {
    events.lines().find_map(|l| {
        let mut f = l.split_whitespace();
        (f.next()? == "high").then(|| f.next()?.parse().ok())?
    })
}

fn read_u64(path: &Path) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Sample one scope directory. `memory.high` set through `--cgroup-conf` can
/// sit on the scope or on its `container` leaf, so the first finite value of
/// the two is the budget. `None` when the scope has no pressure file (no PSI,
/// or not a cgroup v2 scope): absent, never a fabricated calm zero.
pub fn sample_scope(name: &str, scope_dir: &Path) -> Option<StallSample> {
    let full_avg60 =
        parse_full_avg60(&fs::read_to_string(scope_dir.join("memory.pressure")).ok()?)?;
    let high_events =
        parse_high_events(&fs::read_to_string(scope_dir.join("memory.events")).ok()?)?;
    let high_bytes = [scope_dir.to_path_buf(), scope_dir.join("container")]
        .iter()
        .find_map(|d| read_u64(&d.join("memory.high")));
    Some(StallSample {
        name: name.to_string(),
        full_avg60,
        high_events,
        current_bytes: read_u64(&scope_dir.join("memory.current")),
        high_bytes,
    })
}

#[derive(Debug, Deserialize)]
struct PsRow {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Names")]
    names: Vec<String>,
}

/// Sample every container in `ps_json` whose name starts with `prefix`
/// (`tillandsias-` in the tray: forges and their siblings alike). A container
/// whose scope cannot be found or read is left out; the watch only names what
/// it measured.
pub fn scan(ps_json: &str, cgroup_root: &Path, prefix: &str) -> Vec<StallSample> {
    let Ok(rows) = serde_json::from_str::<Vec<PsRow>>(ps_json) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| {
            let name = row.names.first()?;
            if !name.starts_with(prefix) {
                return None;
            }
            let scope = crate::container::resolve_scope_dir(cgroup_root, &row.id)?;
            sample_scope(name, &scope)
        })
        .collect()
}

fn mib(bytes: u64) -> u64 {
    bytes / (1024 * 1024)
}

/// The message the tray shows for a stall: what, how bad, what to do.
pub fn stall_message(s: &StallSample, high_delta: u64) -> String {
    let budget = match (s.current_bytes, s.high_bytes) {
        (Some(c), Some(h)) => format!("{} MiB in use against a {} MiB memory.high", mib(c), mib(h)),
        (Some(c), None) => format!("{} MiB in use", mib(c)),
        _ => "memory use unreadable".to_string(),
    };
    format!(
        "{} is stalled on memory: for {:.0}% of the last minute every task in it waited on reclaim ({budget}, {high_delta} new memory.high events). It is being throttled, not killed, so it will look frozen until its jobs use less memory: stop a job, or run fewer workers at once.",
        s.name, s.full_avg60
    )
}

/// Episode state across samples, keyed by container name.
#[derive(Debug, Default)]
pub struct StallWatch {
    last_high: HashMap<String, u64>,
    stalled: HashMap<String, bool>,
}

impl StallWatch {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fold one sample in; `Some` only on entering or leaving a stall. The
    /// first sample of a container sets its baseline and never names a stall:
    /// a rise needs two samples.
    pub fn observe(&mut self, s: &StallSample) -> Option<StallVerdict> {
        let prev = self.last_high.insert(s.name.clone(), s.high_events);
        let was = self.stalled.get(&s.name).copied().unwrap_or(false);
        let delta = s.high_events.saturating_sub(prev?);
        if !was && s.full_avg60 >= STALL_FULL_AVG60 && delta > 0 {
            self.stalled.insert(s.name.clone(), true);
            return Some(StallVerdict::Stalled(stall_message(s, delta)));
        }
        if was && s.full_avg60 < RECOVER_FULL_AVG60 {
            self.stalled.insert(s.name.clone(), false);
            return Some(StallVerdict::Recovered(format!(
                "{} is no longer stalled on memory",
                s.name
            )));
        }
        None
    }

    /// Drop state for containers no longer present, so a recreated forge of
    /// the same name starts from a fresh baseline.
    pub fn retain(&mut self, present: &[String]) {
        self.last_high.retain(|k, _| present.contains(k));
        self.stalled.retain(|k, _| present.contains(k));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0449b61bc369b649098dd1152b295f6b0d0709bd4a3d82eb1298cf62b2040506";

    fn pressure(full60: f64) -> String {
        format!(
            "some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60={full60:.2} avg300=0.00 total=1\n"
        )
    }

    fn events(high: u64) -> String {
        format!("low 0\nhigh {high}\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n")
    }

    /// A rootless forge launched with `--cgroup-parent=tillandsias.slice`
    /// (1913-ebv8) lives under user@<uid>.service/tillandsias.slice, not
    /// user.slice: the watch must find it there, or every forge is invisible.
    fn forge_tree(full60: f64, high: u64) -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        let scope = root
            .path()
            .join("user.slice/user-1000.slice/user@1000.service/tillandsias.slice")
            .join(format!("libpod-{ID}.scope"));
        fs::create_dir_all(scope.join("container")).unwrap();
        fs::write(scope.join("memory.pressure"), pressure(full60)).unwrap();
        fs::write(scope.join("memory.events"), events(high)).unwrap();
        fs::write(scope.join("memory.current"), (10_700u64 << 20).to_string()).unwrap();
        fs::write(scope.join("memory.high"), "max\n").unwrap();
        fs::write(
            scope.join("container/memory.high"),
            (10_444u64 << 20).to_string(),
        )
        .unwrap();
        root
    }

    fn ps(name: &str) -> String {
        format!(r#"[{{"Id":"{ID}","Names":["{name}"]}}]"#)
    }

    #[test]
    fn parses_the_kernel_shapes() {
        assert_eq!(parse_full_avg60(&pressure(37.5)), Some(37.5));
        assert_eq!(
            parse_full_avg60("some avg10=1.00 avg60=2.00 avg300=0.00 total=1\n"),
            None
        );
        assert_eq!(parse_high_events(&events(9_000_000)), Some(9_000_000));
        assert_eq!(parse_high_events("low 1\nmax 2\n"), None);
    }

    #[test]
    fn a_forge_in_tillandsias_slice_is_found_and_its_budget_read_from_the_leaf() {
        let root = forge_tree(40.0, 5);
        let got = scan(&ps("tillandsias-demon-forge"), root.path(), "tillandsias-");
        assert_eq!(got.len(), 1, "{got:?}");
        assert_eq!(got[0].high_bytes, Some(10_444 << 20));
        assert_eq!(got[0].full_avg60, 40.0);
        assert!(scan(&ps("someone-else"), root.path(), "tillandsias-").is_empty());
    }

    /// The demon_attack shape: pinned at high, events rising, full pressure.
    #[test]
    fn a_container_pinned_at_high_is_named_once_then_its_recovery() {
        let mut w = StallWatch::new();
        let mut s = StallSample {
            name: "tillandsias-demon-forge".into(),
            full_avg60: 45.0,
            high_events: 100,
            current_bytes: Some(10_700 << 20),
            high_bytes: Some(10_444 << 20),
        };
        assert_eq!(w.observe(&s), None, "the first sample is a baseline");
        s.high_events = 90_000;
        let Some(StallVerdict::Stalled(msg)) = w.observe(&s) else {
            panic!("a pinned container was not named");
        };
        assert!(
            msg.starts_with("tillandsias-demon-forge is stalled on memory"),
            "{msg}"
        );
        assert!(
            msg.contains("10444 MiB memory.high") && msg.contains("89900 new"),
            "{msg}"
        );
        s.high_events = 180_000;
        assert_eq!(w.observe(&s), None, "named once per episode");
        s.full_avg60 = 5.0;
        assert_eq!(
            w.observe(&s),
            None,
            "between the thresholds the episode holds"
        );
        s.full_avg60 = 0.5;
        assert!(matches!(w.observe(&s), Some(StallVerdict::Recovered(_))));
    }

    #[test]
    fn busy_or_host_pressure_without_high_events_is_not_a_stall() {
        let mut w = StallWatch::new();
        let mut s = StallSample {
            name: "tillandsias-p-forge".into(),
            full_avg60: 60.0,
            high_events: 7,
            current_bytes: None,
            high_bytes: None,
        };
        w.observe(&s);
        assert_eq!(w.observe(&s), None, "no new high events: not the budget");
        s.full_avg60 = 1.0;
        s.high_events = 900;
        assert_eq!(
            w.observe(&s),
            None,
            "crossing high while running freely is fine"
        );
    }

    #[test]
    fn a_recreated_container_starts_from_a_fresh_baseline() {
        let mut w = StallWatch::new();
        let s = StallSample {
            name: "tillandsias-p-forge".into(),
            full_avg60: 50.0,
            high_events: 10,
            current_bytes: None,
            high_bytes: None,
        };
        w.observe(&s);
        w.retain(&[]);
        assert_eq!(w.observe(&s), None);
    }
}
