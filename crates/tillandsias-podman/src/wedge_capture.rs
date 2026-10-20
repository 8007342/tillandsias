//! What podman was doing when an invocation blew its budget (order 1784-skfj).
//!
//! A budget kill (order 690-7adz) says THAT a podman call wedged, never WHY.
//! On the v56.10.17.1 macOS smoke a `podman run tillandsias-router` hung after
//! conmon started for its whole 300 s, a `podman inspect` of a live Vault timed
//! out beside it, and nothing anywhere named the holder: the guest powered off
//! before its journal flushed. So at the moment of the kill, before the evidence
//! goes away, this writes every podman-family process (state, parent, wait
//! channel, age, argv) and `/proc/locks` to a file that survives a reboot, and
//! the budget message names the file.
//!
//! Best-effort by construction: a capture that cannot be written returns
//! `None` and the caller's error is unchanged. Linux only: other hosts have no
//! `/proc`, and on them the podman CLI is a client of a VM that this process
//! cannot see into.

use std::fs;
use std::path::{Path, PathBuf};

/// Overrides where captures are written.
pub const WEDGE_DIR_ENV: &str = "TILLANDSIAS_PODMAN_WEDGE_DIR";

/// Captures kept per directory; older ones are removed when a new one lands.
const KEEP: usize = 10;

/// The processes a podman wedge involves. Matched against `comm` (which the
/// kernel truncates to 15 bytes) and the basename of argv[0].
const FAMILY: &[&str] = &[
    "podman",
    "conmon",
    "crun",
    "runc",
    "buildah",
    "netavark",
    "aardvark-dns",
    "pasta",
    "slirp4netns",
    "catatonit",
    "fuse-overlayfs",
    "tillandsias-headless",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcRow {
    pub pid: u32,
    pub ppid: u32,
    pub state: char,
    pub comm: String,
    pub age_s: Option<u64>,
    pub wchan: String,
    pub cmdline: String,
}

fn in_family(comm: &str, cmdline: &str) -> bool {
    let argv0 = cmdline.split(' ').next().unwrap_or("");
    let base = argv0.rsplit('/').next().unwrap_or("");
    FAMILY.iter().any(|f| {
        // comm is cut at 15 bytes, so a long family name matches its prefix.
        let cut = &f[..f.len().min(15)];
        comm == cut || base == *f
    })
}

/// Parse `/proc/<pid>/stat`. `comm` sits in parentheses and may itself contain
/// spaces or parentheses, so the fields are split after the LAST `)`.
fn parse_stat(raw: &str) -> Option<(String, char, u32, u64)> {
    let open = raw.find('(')?;
    let close = raw.rfind(')')?;
    let comm = raw.get(open + 1..close)?.to_string();
    let rest: Vec<&str> = raw.get(close + 1..)?.split_whitespace().collect();
    // rest[0] is field 3 (state); field 4 is ppid; field 22 is starttime.
    let state = rest.first()?.chars().next()?;
    let ppid = rest.get(1)?.parse().ok()?;
    let start_ticks = rest.get(19)?.parse().ok()?;
    Some((comm, state, ppid, start_ticks))
}

fn clock_ticks() -> u64 {
    #[cfg(unix)]
    {
        // SAFETY: sysconf has no preconditions and only reads a constant.
        let t = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if t > 0 {
            return t as u64;
        }
    }
    100
}

/// Every podman-family process under `proc_root`, oldest pid first.
pub fn scan(proc_root: &Path) -> Vec<ProcRow> {
    let uptime_s = fs::read_to_string(proc_root.join("uptime"))
        .ok()
        .and_then(|s| s.split_whitespace().next()?.parse::<f64>().ok());
    let ticks = clock_ticks();
    let mut rows = Vec::new();
    let Ok(entries) = fs::read_dir(proc_root) else {
        return rows;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        let dir = entry.path();
        let Some((comm, state, ppid, start)) = fs::read_to_string(dir.join("stat"))
            .ok()
            .as_deref()
            .and_then(parse_stat)
        else {
            continue;
        };
        let cmdline = fs::read(dir.join("cmdline"))
            .map(|b| {
                String::from_utf8_lossy(&b)
                    .split('\0')
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        if !in_family(&comm, &cmdline) {
            continue;
        }
        let wchan = fs::read_to_string(dir.join("wchan"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        let age_s = uptime_s.map(|up| (up - start as f64 / ticks as f64).max(0.0) as u64);
        rows.push(ProcRow {
            pid,
            ppid,
            state,
            comm,
            age_s,
            wchan,
            cmdline,
        });
    }
    rows.sort_by_key(|r| r.pid);
    rows
}

/// The capture's text. `secrets` never appear: argv is redacted by the caller
/// for the failing command, and the process table is shown argv-truncated.
pub fn render(message: &str, rows: &[ProcRow], locks: &str) -> String {
    let mut out = String::new();
    out.push_str("# tillandsias podman wedge capture (order 1784-skfj)\n");
    out.push_str(&format!("budget: {message}\n"));
    out.push_str(&format!("podman-family processes: {}\n", rows.len()));
    out.push_str("pid ppid state age_s wchan comm :: argv\n");
    for r in rows {
        let age = r.age_s.map(|a| a.to_string()).unwrap_or_else(|| "?".into());
        let wchan = if r.wchan.is_empty() || r.wchan == "0" {
            "-"
        } else {
            &r.wchan
        };
        let mut argv = r.cmdline.clone();
        if argv.len() > 300 {
            let mut cut = 300;
            while !argv.is_char_boundary(cut) {
                cut -= 1;
            }
            argv.truncate(cut);
            argv.push_str("...");
        }
        out.push_str(&format!(
            "{} {} {} {} {} {} :: {}\n",
            r.pid, r.ppid, r.state, age, wchan, r.comm, argv
        ));
    }
    out.push_str("--- /proc/locks\n");
    out.push_str(locks);
    if !locks.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn default_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os(WEDGE_DIR_ENV) {
        return Some(PathBuf::from(dir));
    }
    #[cfg(unix)]
    {
        // SAFETY: geteuid cannot fail.
        if unsafe { libc::geteuid() } == 0 {
            return Some(PathBuf::from("/var/log/tillandsias/podman-wedge"));
        }
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(state.join("tillandsias/podman-wedge"))
}

/// Remove all but the newest `keep` captures (names sort by time).
fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let mut names: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("wedge-") && n.ends_with(".txt"))
        })
        .collect();
    names.sort();
    let excess = names.len().saturating_sub(keep);
    for old in names.into_iter().take(excess) {
        let _ = fs::remove_file(old);
    }
}

/// Write a capture of `proc_root` into `dir`; the path written, or `None`.
pub fn capture_into(dir: &Path, proc_root: &Path, message: &str) -> Option<PathBuf> {
    if !proc_root.join("self").exists() && !proc_root.join("uptime").exists() {
        return None;
    }
    let rows = scan(proc_root);
    let locks = fs::read_to_string(proc_root.join("locks")).unwrap_or_default();
    fs::create_dir_all(dir).ok()?;
    let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ");
    let path = dir.join(format!("wedge-{stamp}-{}.txt", std::process::id()));
    fs::write(&path, render(message, &rows, &locks)).ok()?;
    prune(dir, KEEP);
    Some(path)
}

/// Capture the live host's podman processes after a budget kill.
pub fn capture(message: &str) -> Option<PathBuf> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    // This crate's own timeout tests must not write into the gate host's
    // state directory; they opt in by naming a directory.
    if cfg!(test) && std::env::var_os(WEDGE_DIR_ENV).is_none() {
        return None;
    }
    capture_into(&default_dir()?, Path::new("/proc"), message)
}

/// `message` with the capture's path appended, when one was written.
pub fn annotate(message: String) -> String {
    match capture(&message) {
        Some(path) => format!("{message} (process capture: {})", path.display()),
        None => message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_proc(root: &Path, pid: u32, comm: &str, state: char, ppid: u32, argv: &[&str]) {
        let dir = root.join(pid.to_string());
        fs::create_dir_all(&dir).unwrap();
        // 52 fields; starttime (field 22) = 500 ticks.
        let mut fields = vec!["0"; 49];
        fields[19] = "500";
        fs::write(
            dir.join("stat"),
            format!("{pid} ({comm}) {state} {ppid} {}", fields.join(" ")),
        )
        .unwrap();
        fs::write(dir.join("cmdline"), argv.join("\0")).unwrap();
        fs::write(dir.join("wchan"), "do_wait").unwrap();
    }

    #[test]
    fn a_budget_kill_capture_lists_only_the_podman_family_with_state_and_locks() {
        let tmp = std::env::temp_dir().join(format!("wedge-proc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let proc_root = tmp.join("proc");
        fs::create_dir_all(&proc_root).unwrap();
        fs::write(proc_root.join("uptime"), "1000.00 900.00\n").unwrap();
        fs::write(
            proc_root.join("locks"),
            "1: FLOCK ADVISORY WRITE 4242 00:2a:77 0 EOF\n",
        )
        .unwrap();
        fake_proc(
            &proc_root,
            4242,
            "podman",
            'D',
            1,
            &["/usr/bin/podman", "image", "prune"],
        );
        fake_proc(
            &proc_root,
            4300,
            "conmon",
            'S',
            1,
            &["/usr/bin/conmon", "--api-version", "1"],
        );
        // comm is truncated at 15 bytes by the kernel.
        fake_proc(
            &proc_root,
            77,
            "tillandsias-hea",
            'S',
            1,
            &["/usr/local/bin/tillandsias-headless"],
        );
        // NEGATIVE CONTROL: an unrelated process is left out.
        fake_proc(&proc_root, 500, "sshd", 'S', 1, &["/usr/sbin/sshd", "-D"]);
        // A comm with a space and a parenthesis still parses.
        fake_proc(
            &proc_root,
            4400,
            "crun (x)",
            'R',
            4300,
            &["/usr/bin/crun", "start"],
        );

        let out_dir = tmp.join("out");
        let path = capture_into(
            &out_dir,
            &proc_root,
            "podman container operation exceeded its 300s budget",
        )
        .unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("podman-family processes: 4"), "{text}");
        assert!(text.contains("4242 1 D "), "{text}");
        assert!(text.contains(":: /usr/bin/podman image prune"), "{text}");
        assert!(text.contains("4400 4300 R "), "{text}");
        assert!(text.contains("tillandsias-hea"), "{text}");
        assert!(!text.contains("sshd"), "{text}");
        assert!(text.contains("FLOCK ADVISORY WRITE 4242"), "{text}");
        // age = uptime - starttime/CLK_TCK, never negative.
        assert!(text.contains(" do_wait podman "), "{text}");
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn captures_are_bounded_to_the_newest_ten() {
        let dir = std::env::temp_dir().join(format!("wedge-prune-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        for i in 0..14 {
            fs::write(dir.join(format!("wedge-2026101{i:02}.txt")), "x").unwrap();
        }
        fs::write(dir.join("keep-me.log"), "x").unwrap();
        prune(&dir, KEEP);
        let left: Vec<_> = fs::read_dir(&dir).unwrap().flatten().collect();
        assert_eq!(left.len(), KEEP + 1);
        assert!(dir.join("wedge-202610113.txt").exists());
        assert!(dir.join("wedge-202610104.txt").exists());
        assert!(!dir.join("wedge-202610103.txt").exists());
        assert!(dir.join("keep-me.log").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_proc_means_no_capture_and_an_unchanged_message() {
        let dir = std::env::temp_dir().join(format!("wedge-noproc-{}", std::process::id()));
        assert!(capture_into(&dir, Path::new("/nonexistent-proc-root"), "m").is_none());
        assert!(!dir.exists());
    }
}
