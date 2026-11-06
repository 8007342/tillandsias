//! ORDER 1913-fh6l — does a forge's `memory.low` protect anything?
//!
//! ForgeBudget gives the forge `--memory-reservation` (cgroup v2
//! `memory.low`). With `memory_recursiveprot` a cgroup's protection is
//! bounded by its ancestors': a 2G `memory.low` under an ancestor whose
//! `memory.low` is 0 protects nothing. Measured 2026-10-28 on lenovinha
//! (rootless podman, user.slice and user@1000.service at 0) and 2026-11-06 in
//! the macOS VZ guest (root podman, machine.slice at 0): the reservation was
//! void on both.
//!
//! This module reads the chain from a container's cgroup up to the root and
//! reports the EFFECTIVE protection: walking down from the root, each level
//! can protect at most what its parent does, so the effective value is the
//! minimum of `memory.low` along the chain (`max` is unbounded). That is an
//! upper bound on what the kernel grants, which is exactly the question:
//! when it is below what the forge asked for, the reservation is (partly)
//! void.

// The probe only runs on Linux (cgroup v2); elsewhere the core is used by the
// tests alone, so the darwin and windows lint lines would call it dead.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::path::Path;

/// One cgroup on the chain, leaf first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Level {
    /// Path relative to the cgroup root, e.g. `/machine.slice`.
    pub path: String,
    /// `memory.low` in bytes; `None` for `max` or an absent file (the root).
    pub low: Option<u64>,
}

/// Parse one `memory.low` / `memory.min` value: a byte count or `max`.
fn parse_value(raw: &str) -> Result<Option<u64>, String> {
    let v = raw.trim();
    if v == "max" {
        return Ok(None);
    }
    v.parse::<u64>()
        .map(Some)
        .map_err(|_| format!("unparseable cgroup value {v:?}"))
}

/// Read the chain from `rel` (a `/proc/<pid>/cgroup` path) up to the root,
/// under `cgroup_root` (`/sys/fs/cgroup`, or a fixture tree). Leaf first.
pub(crate) fn read_chain(cgroup_root: &Path, rel: &str) -> Result<Vec<Level>, String> {
    let mut chain = Vec::new();
    let mut cur = rel.trim_end_matches('/').to_string();
    while !cur.is_empty() && cur != "/" {
        let file = cgroup_root
            .join(cur.trim_start_matches('/'))
            .join("memory.low");
        let raw =
            std::fs::read_to_string(&file).map_err(|e| format!("read {}: {e}", file.display()))?;
        chain.push(Level {
            path: cur.clone(),
            low: parse_value(&raw)?,
        });
        cur = match cur.rfind('/') {
            Some(0) | None => String::new(),
            Some(i) => cur[..i].to_string(),
        };
    }
    Ok(chain)
}

/// The most protection the chain can give its leaf: the minimum `memory.low`
/// along it, `None` when every level is `max`.
pub(crate) fn effective_low(chain: &[Level]) -> Option<u64> {
    chain.iter().filter_map(|l| l.low).min()
}

/// The ancestor that caps the leaf's protection (the first level, from the
/// root down, holding the minimum), for the report.
pub(crate) fn limiting_level(chain: &[Level]) -> Option<&Level> {
    let eff = effective_low(chain)?;
    chain.iter().rev().find(|l| l.low == Some(eff))
}

/// The probe's one-line verdict for a container whose own (leaf) reservation
/// is `chain[0]`: ok when the chain grants at least that, a violation naming
/// the limiting ancestor otherwise.
pub(crate) fn verdict(container: &str, chain: &[Level]) -> (String, i32) {
    let requested = chain.first().and_then(|l| l.low).unwrap_or(0);
    let eff = effective_low(chain);
    let eff_n = eff.unwrap_or(u64::MAX);
    if requested == 0 {
        return (
            format!("ok:memory-protection:{container}:requested=0 (no reservation to protect)"),
            0,
        );
    }
    if eff_n >= requested {
        return (
            format!(
                "ok:memory-protection:{container}:requested={requested}:effective={}",
                eff.map_or("max".into(), |v| v.to_string())
            ),
            0,
        );
    }
    let at = limiting_level(chain).map_or("?", |l| l.path.as_str());
    (
        format!(
            "violation:memory-protection-void:{container}:requested={requested}:effective={eff_n}:limited-by={at}"
        ),
        1,
    )
}

/// `tillandsias --memory-protection <container>`: print the chain and the
/// verdict line; exit 0 (protected or no reservation), 1 (void), 2 (could
/// not read).
#[cfg(target_os = "linux")]
pub(crate) fn run_cli(container: &str) -> i32 {
    let out = match tillandsias_podman::podman_cmd_sync()
        .args(["inspect", "--format", "{{.State.Pid}}", container])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
    {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            eprintln!(
                "could-not-run:memory-protection:{container}: podman inspect: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            return 2;
        }
        Err(e) => {
            eprintln!("could-not-run:memory-protection:{container}: podman: {e}");
            return 2;
        }
    };
    let pid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if pid.is_empty() || pid == "0" {
        eprintln!("could-not-run:memory-protection:{container}: not running (pid {pid:?})");
        return 2;
    }
    let cg = match std::fs::read_to_string(format!("/proc/{pid}/cgroup")) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("could-not-run:memory-protection:{container}: /proc/{pid}/cgroup: {e}");
            return 2;
        }
    };
    let Some(rel) = cg.lines().find_map(|l| l.strip_prefix("0::")) else {
        eprintln!(
            "could-not-run:memory-protection:{container}: no cgroup v2 entry in /proc/{pid}/cgroup"
        );
        return 2;
    };
    let chain = match read_chain(Path::new("/sys/fs/cgroup"), rel) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("could-not-run:memory-protection:{container}: {e}");
            return 2;
        }
    };
    for l in &chain {
        eprintln!(
            "  {:<72} memory.low={}",
            l.path,
            l.low.map_or("max".to_string(), |v| v.to_string())
        );
    }
    let (line, rc) = verdict(container, &chain);
    println!("{line}");
    rc
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn run_cli(container: &str) -> i32 {
    eprintln!(
        "could-not-run:memory-protection:{container}: cgroup v2 is Linux-only; run it where the containers run (in the macOS or Windows guest: tillandsias-tray --exec-guest 'tillandsias --memory-protection {container}')"
    );
    2
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(levels: &[(&str, &str)]) -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        for (path, low) in levels {
            let d = t.path().join(path.trim_start_matches('/'));
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("memory.low"), format!("{low}\n")).unwrap();
        }
        t
    }

    const SCOPE: &str = "/machine.slice/libpod-abc.scope/container";

    /// Today's macOS guest, measured: every ancestor at 0, so a 2G
    /// reservation on the forge protects nothing.
    #[test]
    fn a_reservation_under_an_unprotected_ancestor_is_void() {
        let t = tree(&[
            ("/machine.slice", "0"),
            ("/machine.slice/libpod-abc.scope", "0"),
            (SCOPE, "2147483648"),
        ]);
        let chain = read_chain(t.path(), SCOPE).unwrap();
        assert_eq!(chain.len(), 3);
        assert_eq!(effective_low(&chain), Some(0));
        let (line, rc) = verdict("forge", &chain);
        assert_eq!(rc, 1);
        assert_eq!(
            line,
            "violation:memory-protection-void:forge:requested=2147483648:effective=0:limited-by=/machine.slice"
        );
    }

    /// The fixed chain: ancestors protect at least the forge's reservation.
    #[test]
    fn a_reservation_the_ancestors_cover_is_effective() {
        let t = tree(&[
            ("/machine.slice", "4294967296"),
            ("/machine.slice/libpod-abc.scope", "max"),
            (SCOPE, "2147483648"),
        ]);
        let chain = read_chain(t.path(), SCOPE).unwrap();
        assert_eq!(effective_low(&chain), Some(2147483648));
        let (line, rc) = verdict("forge", &chain);
        assert_eq!(
            (
                rc,
                line.starts_with("ok:memory-protection:forge:requested=2147483648")
            ),
            (0, true)
        );
    }

    /// A partial cover is still a violation, naming the ancestor that caps it.
    #[test]
    fn a_smaller_ancestor_caps_the_reservation() {
        let t = tree(&[("/machine.slice", "1073741824"), (SCOPE, "2147483648")]);
        let t2 = t.path().join("machine.slice/libpod-abc.scope");
        std::fs::write(t2.join("memory.low"), "max\n").unwrap();
        let chain = read_chain(t.path(), SCOPE).unwrap();
        let (line, rc) = verdict("forge", &chain);
        assert_eq!(rc, 1);
        assert!(
            line.ends_with(":effective=1073741824:limited-by=/machine.slice"),
            "{line}"
        );
    }

    #[test]
    fn an_unreadable_level_is_an_error_not_a_pass() {
        let t = tree(&[(SCOPE, "2147483648")]);
        std::fs::remove_file(t.path().join("machine.slice/memory.low")).ok();
        assert!(read_chain(t.path(), SCOPE).is_err());
    }
}
