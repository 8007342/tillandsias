//! ORDER 2067-dwqd — the tray names a container held at its `memory.high`.
//!
//! The detector is `tillandsias_metrics::memory_stall`; this is the resident
//! loop. Every [`INTERVAL`] it lists the running containers, samples every
//! `tillandsias-*` scope (forges and their siblings), and on the start of a
//! stall episode prints one `warn:memory-stall:` line and hands the message to
//! the tray's desktop notifier. A recovery prints one `ok:` line. Nothing is
//! killed: `memory.high` throttles by the operator's choice, and the watch
//! makes that throttling visible instead of silent.
//!
//! NEVER BLOCKS THE TRAY: a podman that cannot list, a host without PSI, a
//! scope it cannot read, each leaves that sample out and the loop continues.
// @trace order:2067-dwqd

use std::path::Path;
use std::time::Duration;
use tillandsias_metrics::memory_stall::{StallVerdict, StallWatch, scan};

/// How often the watch samples. `full avg60` is a one-minute average, so a
/// 15 s cadence names a stall within about a minute of it starting.
pub(crate) const INTERVAL: Duration = Duration::from_secs(15);

const PREFIX: &str = "tillandsias-";

/// One pass: sample, fold, and return what to say. Pure over its inputs so the
/// tests drive it from a fixture tree.
pub(crate) fn pass(watch: &mut StallWatch, ps_json: &str, cgroup_root: &Path) -> Vec<StallVerdict> {
    let samples = scan(ps_json, cgroup_root, PREFIX);
    let present: Vec<String> = samples.iter().map(|s| s.name.clone()).collect();
    let verdicts = samples.iter().filter_map(|s| watch.observe(s)).collect();
    watch.retain(&present);
    verdicts
}

fn list_containers() -> Option<String> {
    let out = tillandsias_podman::podman_cmd_sync()
        .args(["ps", "--format", "json"])
        .output_bounded(Duration::from_secs(15))
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// `tillandsias --memory-stall [--for <secs>]`: the same passes as the tray's
/// watch, every 5 s for `secs` (at least two samples, since a stall needs a
/// rise). Prints one `warn:memory-stall:` line per stalled container; exits 1
/// when any is, 0 when none is, 2 when podman cannot list containers.
pub(crate) fn run_cli(secs: u64) -> i32 {
    const STEP: Duration = Duration::from_secs(5);
    let samples = (secs / STEP.as_secs()).max(1) + 1;
    let mut watch = StallWatch::new();
    let mut stalled = 0usize;
    let mut seen = 0usize;
    for i in 0..samples {
        if i > 0 {
            std::thread::sleep(STEP);
        }
        let Some(ps) = list_containers() else {
            println!("could-not-run:memory-stall:podman-ps: podman could not list containers");
            return 2;
        };
        seen = scan(&ps, Path::new("/sys/fs/cgroup"), PREFIX).len();
        for v in pass(&mut watch, &ps, Path::new("/sys/fs/cgroup")) {
            match v {
                StallVerdict::Stalled(msg) => {
                    stalled += 1;
                    println!("warn:memory-stall: {msg}");
                }
                StallVerdict::Recovered(msg) => println!("ok:memory-stall-recovered: {msg}"),
            }
        }
    }
    if stalled > 0 {
        1
    } else {
        println!("ok:memory-stall:none: {seen} tillandsias container(s) sampled over {secs} s");
        0
    }
}

/// Start the resident watch. `on_stall` gets the message of each new stall.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn spawn(on_stall: Box<dyn Fn(String) + Send + 'static>) {
    let _ = std::thread::Builder::new()
        .name("memory-stall".into())
        .spawn(move || {
            let mut watch = StallWatch::new();
            loop {
                if let Some(ps) = list_containers() {
                    for v in pass(&mut watch, &ps, Path::new("/sys/fs/cgroup")) {
                        match v {
                            StallVerdict::Stalled(msg) => {
                                eprintln!("[tillandsias] warn:memory-stall: {msg}");
                                on_stall(msg);
                            }
                            StallVerdict::Recovered(msg) => {
                                eprintln!("[tillandsias] ok:memory-stall-recovered: {msg}");
                            }
                        }
                    }
                }
                std::thread::sleep(INTERVAL);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const ID: &str = "74eafb675de6cbadcf737486aad6257f84d48dd4177ce56362f1e53b32937062";

    fn write_scope(root: &Path, full60: f64, high: u64) {
        let scope = root
            .join("user.slice/user-1000.slice/user@1000.service/tillandsias.slice")
            .join(format!("libpod-{ID}.scope"));
        fs::create_dir_all(&scope).unwrap();
        fs::write(
            scope.join("memory.pressure"),
            format!("some avg10=0 avg60=0 avg300=0 total=0\nfull avg10=0 avg60={full60} avg300=0 total=0\n"),
        )
        .unwrap();
        fs::write(
            scope.join("memory.events"),
            format!("low 0\nhigh {high}\nmax 0\n"),
        )
        .unwrap();
    }

    /// Two passes over a forge pinned at high: the second names it, by name.
    #[test]
    fn a_pinned_forge_is_named_by_the_tray_pass() {
        let root = tempfile::tempdir().unwrap();
        let ps = format!(r#"[{{"Id":"{ID}","Names":["tillandsias-demon_attack-forge"]}}]"#);
        let mut w = StallWatch::new();
        write_scope(root.path(), 50.0, 10);
        assert!(pass(&mut w, &ps, root.path()).is_empty());
        write_scope(root.path(), 50.0, 50_000);
        let v = pass(&mut w, &ps, root.path());
        assert!(
            matches!(&v[..], [StallVerdict::Stalled(m)] if m.starts_with("tillandsias-demon_attack-forge is stalled on memory")),
            "{v:?}"
        );
    }
}
