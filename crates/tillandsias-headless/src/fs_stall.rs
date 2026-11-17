//! Guest filesystem stall detector (order 2066-fxbh).
//!
//! Measured 2026-11-10 on the macOS guest (kernel 6.19.10-300.fc44.aarch64,
//! up 1d23h): the btrfs-transaction kthread sat in `__btrfs_run_delayed_items`
//! and every task that started a transaction (systemd, journald, dnf5, podman,
//! this binary's own mkdir threads) sat in D in `wait_current_trans`. Load was
//! about 14 while IO and memory pressure were 0. The kernel has no hung-task
//! detector and dmesg was silent, so the guest looked like "podman: database is
//! locked" for 22 hours. D tasks cannot be killed; the recovery is a reboot.
//!
//! This module names that state. It reads two samples of `/proc` a few seconds
//! apart, ON DEMAND (no background loop): a task is wedged when it is in D on a
//! btrfs wait in both samples and its context-switch counters did not move.
//! The verdict is wedged only when the transaction kthread itself is wedged,
//! because a healthy commit passes through D briefly and often.
//!
//! @trace order:2066-fxbh

use std::collections::BTreeMap;
use std::path::Path;

/// Kernel wait channels that mean "waiting on a btrfs transaction".
pub(crate) const BTRFS_WAITS: &[&str] = &[
    "wait_current_trans",
    "__btrfs_run_delayed_items",
    "btrfs_run_delayed_items",
    "btrfs_run_delayed_items_nr",
    "btrfs_inode_lock",
    "wait_for_commit",
    "btrfs_commit_transaction",
];

const TXN_COMM: &str = "btrfs-transaction";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Task {
    pub comm: String,
    pub state: char,
    pub wchan: String,
    pub switches: u64,
}

/// tid -> task, from one read of a proc root.
pub(crate) type Sample = BTreeMap<u32, Task>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Clear,
    Wedged {
        txn_tid: u32,
        txn_wchan: String,
        waiters: usize,
        examples: Vec<String>,
    },
}

impl Verdict {
    /// One pinned line: `fs-stall: none` or
    /// `fs-stall: btrfs-transaction-wedged tid=<n> wchan=<w> waiters=<n> examples=<a,b>`.
    pub(crate) fn line(&self) -> String {
        match self {
            Verdict::Clear => "fs-stall: none".to_string(),
            Verdict::Wedged {
                txn_tid,
                txn_wchan,
                waiters,
                examples,
            } => format!(
                "fs-stall: btrfs-transaction-wedged tid={txn_tid} wchan={txn_wchan} \
                 waiters={waiters} examples={} (D tasks cannot be killed; reboot the guest)",
                if examples.is_empty() {
                    "-".to_string()
                } else {
                    examples.join(",")
                }
            ),
        }
    }
}

fn read_trim(p: &Path) -> Option<String> {
    std::fs::read_to_string(p)
        .ok()
        .map(|s| s.trim().to_string())
}

/// `<tid> (<comm>) <state> ...` — comm may contain spaces and parentheses.
fn parse_stat(stat: &str) -> Option<(String, char)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let comm = stat.get(open + 1..close)?.to_string();
    let state = stat.get(close + 1..)?.trim_start().chars().next()?;
    Some((comm, state))
}

fn parse_switches(status: &str) -> u64 {
    status
        .lines()
        .filter(|l| {
            l.starts_with("voluntary_ctxt_switches") || l.starts_with("nonvoluntary_ctxt_switches")
        })
        .filter_map(|l| l.split_whitespace().last()?.parse::<u64>().ok())
        .sum()
}

/// Read every task under `<proc>/<pid>/task/<tid>`. Unreadable entries are
/// skipped: a task can exit between readdir and read.
pub(crate) fn sample(proc_root: &Path) -> Sample {
    let mut out = Sample::new();
    let Ok(pids) = std::fs::read_dir(proc_root) else {
        return out;
    };
    for pid in pids.flatten() {
        if !pid
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|b| b.is_ascii_digit())
        {
            continue;
        }
        let Ok(tasks) = std::fs::read_dir(pid.path().join("task")) else {
            continue;
        };
        for t in tasks.flatten() {
            let Ok(tid) = t.file_name().to_string_lossy().parse::<u32>() else {
                continue;
            };
            let dir = t.path();
            let Some((comm, state)) = read_trim(&dir.join("stat")).as_deref().and_then(parse_stat)
            else {
                continue;
            };
            let wchan = read_trim(&dir.join("wchan")).unwrap_or_default();
            let switches = read_trim(&dir.join("status"))
                .map(|s| parse_switches(&s))
                .unwrap_or(0);
            out.insert(
                tid,
                Task {
                    comm,
                    state,
                    wchan,
                    switches,
                },
            );
        }
    }
    out
}

fn wedged_in_both(a: &Task, b: &Task) -> bool {
    a.state == 'D'
        && b.state == 'D'
        && a.switches == b.switches
        && BTRFS_WAITS.contains(&b.wchan.as_str())
}

/// Compare two samples taken some seconds apart.
pub(crate) fn verdict(first: &Sample, second: &Sample) -> Verdict {
    let frozen: Vec<(u32, &Task)> = second
        .iter()
        .filter(|(tid, b)| first.get(tid).is_some_and(|a| wedged_in_both(a, b)))
        .map(|(tid, b)| (*tid, b))
        .collect();
    let Some((txn_tid, txn)) = frozen.iter().find(|(_, t)| t.comm == TXN_COMM) else {
        return Verdict::Clear;
    };
    let waiters: Vec<&Task> = frozen
        .iter()
        .filter(|(tid, _)| tid != txn_tid)
        .map(|(_, t)| *t)
        .collect();
    let mut examples: Vec<String> = waiters.iter().map(|t| t.comm.clone()).collect();
    examples.sort();
    examples.dedup();
    examples.truncate(6);
    Verdict::Wedged {
        txn_tid: *txn_tid,
        txn_wchan: txn.wchan.clone(),
        waiters: waiters.len(),
        examples,
    }
}

/// Two samples `gap` apart from the real /proc, then the verdict line.
pub(crate) fn check(proc_root: &Path, gap: std::time::Duration) -> Verdict {
    let a = sample(proc_root);
    std::thread::sleep(gap);
    let b = sample(proc_root);
    verdict(&a, &b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn task(root: &Path, pid: u32, tid: u32, comm: &str, state: char, wchan: &str, sw: u64) {
        let d = root
            .join(pid.to_string())
            .join("task")
            .join(tid.to_string());
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("stat"), format!("{tid} ({comm}) {state} 1 1 1 0")).unwrap();
        std::fs::write(d.join("wchan"), wchan).unwrap();
        std::fs::write(
            d.join("status"),
            format!(
                "Name:\t{comm}\nvoluntary_ctxt_switches:\t{sw}\nnonvoluntary_ctxt_switches:\t1\n"
            ),
        )
        .unwrap();
    }

    fn proc_with(f: impl Fn(&Path)) -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().to_path_buf();
        f(&p);
        (d, p)
    }

    /// The 2026-11-10 guest, reduced: the txn kthread and two waiters frozen.
    fn wedged(root: &Path) {
        task(
            root,
            527,
            527,
            "btrfs-transaction",
            'D',
            "btrfs_run_delayed_items",
            40,
        );
        task(root, 1, 1, "systemd", 'D', "wait_current_trans", 900);
        task(
            root,
            14658,
            472907,
            "tillandsias-hea",
            'D',
            "wait_current_trans",
            7,
        );
        task(root, 14658, 14668, "tillandsias-hea", 'S', "ep_poll", 50);
    }

    #[test]
    fn a_frozen_transaction_kthread_with_waiters_is_named() {
        let (_d, p) = proc_with(wedged);
        let a = sample(&p);
        let b = sample(&p);
        match verdict(&a, &b) {
            Verdict::Wedged {
                txn_tid,
                waiters,
                examples,
                ..
            } => {
                assert_eq!(txn_tid, 527);
                assert_eq!(waiters, 2);
                assert!(examples.contains(&"systemd".to_string()));
            }
            v => panic!("expected wedged, got {v:?}"),
        }
        assert!(
            verdict(&a, &b)
                .line()
                .starts_with("fs-stall: btrfs-transaction-wedged tid=527 ")
        );
    }

    #[test]
    fn a_commit_that_makes_progress_is_not_a_stall() {
        let (_d, p) = proc_with(wedged);
        let a = sample(&p);
        // The kthread switched between samples: it is running, just busy.
        task(
            &p,
            527,
            527,
            "btrfs-transaction",
            'D',
            "btrfs_run_delayed_items",
            41,
        );
        let b = sample(&p);
        assert_eq!(verdict(&a, &b), Verdict::Clear);
    }

    #[test]
    fn waiters_without_a_frozen_kthread_are_not_a_stall() {
        let (_d, p) = proc_with(|r| {
            task(
                r,
                527,
                527,
                "btrfs-transaction",
                'S',
                "transaction_kthread",
                40,
            );
            task(r, 1, 1, "systemd", 'D', "wait_current_trans", 900);
        });
        let s = sample(&p);
        assert_eq!(verdict(&s, &s), Verdict::Clear);
    }

    #[test]
    fn a_frozen_kthread_on_a_non_btrfs_wait_is_not_this_stall() {
        let (_d, p) = proc_with(|r| task(r, 527, 527, "btrfs-transaction", 'D', "io_schedule", 40));
        let s = sample(&p);
        assert_eq!(verdict(&s, &s), Verdict::Clear);
    }

    #[test]
    fn comm_with_spaces_and_parens_parses() {
        assert_eq!(
            parse_stat("9 (a (b) c) D 1 2"),
            Some(("a (b) c".to_string(), 'D'))
        );
    }

    #[test]
    fn an_empty_or_missing_proc_is_clear() {
        let s = sample(Path::new("/nonexistent-proc-root"));
        assert!(s.is_empty());
        assert_eq!(verdict(&s, &s).line(), "fs-stall: none");
    }
}
