//! ORDER 1878-2cwt — the disk preflight before a new worktree (openspec change
//! forge-storage-single-root-and-disk-discipline, design D4).
//!
//! Before creating a worktree, read the free space of the target filesystem.
//! When it is below the threshold, max(2 GiB, 15 %) (an L0 tmpfs: 25 %), evict
//! existing worktrees that are BOTH clean and pushed (their HEAD is contained
//! in a remote-tracking ref), oldest HEAD first, re-reading free space after
//! each, until free space is above the threshold. A worktree with unpushed
//! commits or dirty files is never evicted. If eviction cannot reach the
//! threshold the verdict is `refused:disk-low:<path>:<free>`.

use std::path::{Path, PathBuf};
use std::process::Command;

const GIB: u64 = 1 << 30;

/// Free and total bytes of the filesystem holding a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Space {
    pub avail: u64,
    pub total: u64,
}

/// One linked worktree (never the main checkout).
#[derive(Debug, Clone)]
pub struct Worktree {
    pub path: PathBuf,
    pub clean: bool,
    pub pushed: bool,
    /// HEAD's committer time, seconds since the epoch; oldest is evicted first.
    pub head_time: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Free space is at or above the threshold (after `evicted`).
    Ok {
        avail: u64,
        threshold: u64,
        evicted: Vec<PathBuf>,
    },
    /// Eviction ran out of candidates below the threshold.
    DiskLow {
        avail: u64,
        threshold: u64,
        evicted: Vec<PathBuf>,
    },
    /// Free space could not be read: fail closed.
    Unknown,
}

/// The D4 threshold for a filesystem of `total` bytes.
pub fn threshold(total: u64, l0: bool) -> u64 {
    if l0 {
        total / 4
    } else {
        (2 * GIB).max(total / 100 * 15)
    }
}

/// The eviction loop, with free space and removal passed in so a test can
/// simulate a filesystem. `remove` returns false when a removal failed; that
/// worktree is then skipped.
pub fn run(
    worktrees: &[Worktree],
    l0: bool,
    mut space: impl FnMut() -> Option<Space>,
    mut remove: impl FnMut(&Path) -> bool,
) -> Outcome {
    let Some(first) = space() else {
        return Outcome::Unknown;
    };
    let threshold = threshold(first.total, l0);
    let mut avail = first.avail;
    let mut evicted = Vec::new();
    let mut candidates: Vec<&Worktree> = worktrees.iter().filter(|w| w.clean && w.pushed).collect();
    candidates.sort_by_key(|w| w.head_time);
    for w in candidates {
        if avail >= threshold {
            break;
        }
        if !remove(&w.path) {
            continue;
        }
        evicted.push(w.path.clone());
        match space() {
            Some(s) => avail = s.avail,
            None => return Outcome::Unknown,
        }
    }
    if avail >= threshold {
        Outcome::Ok {
            avail,
            threshold,
            evicted,
        }
    } else {
        Outcome::DiskLow {
            avail,
            threshold,
            evicted,
        }
    }
}

fn git_out(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The linked worktrees of `repo` (`git worktree list --porcelain`), with
/// their clean/pushed state. The main checkout is never listed; a worktree
/// whose state cannot be read is listed as dirty and unpushed, so it is kept.
pub fn list_worktrees(repo: &Path) -> Option<Vec<Worktree>> {
    let text = git_out(repo, &["worktree", "list", "--porcelain"])?;
    let mut out = Vec::new();
    for (i, block) in text.split("\n\n").enumerate() {
        let Some(path) = block.lines().find_map(|l| l.strip_prefix("worktree ")) else {
            continue;
        };
        if i == 0 || block.lines().any(|l| l == "bare") {
            continue;
        }
        let path = PathBuf::from(path);
        let clean = git_out(&path, &["status", "--porcelain", "--untracked-files=all"])
            .is_some_and(|s| s.trim().is_empty());
        let pushed = git_out(&path, &["branch", "-r", "--contains", "HEAD"])
            .is_some_and(|s| !s.trim().is_empty());
        let head_time = git_out(&path, &["log", "-1", "--format=%ct", "HEAD"])
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(i64::MAX);
        out.push(Worktree {
            path,
            clean,
            pushed,
            head_time,
        });
    }
    Some(out)
}

/// `git worktree remove` WITHOUT --force: git itself refuses a dirty tree,
/// a second guard behind the clean check.
pub fn remove_worktree(repo: &Path, wt: &Path) -> bool {
    let Some(wt) = wt.to_str() else { return false };
    git_out(repo, &["worktree", "remove", wt]).is_some()
}

/// Free and total bytes of the filesystem holding `path`.
#[cfg(unix)]
pub fn space_of(path: &Path) -> Option<Space> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: c is a valid NUL-terminated path and st a writable statvfs.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let frsize = st.f_frsize as u64;
    Some(Space {
        avail: (st.f_bavail as u64).saturating_mul(frsize),
        total: (st.f_blocks as u64).saturating_mul(frsize),
    })
}

/// Not measured off unix: [`run`] then fails closed.
#[cfg(not(unix))]
pub fn space_of(_path: &Path) -> Option<Space> {
    None
}

/// The one verdict line for an outcome.
pub fn verdict(target: &Path, out: &Outcome) -> String {
    let t = target.display();
    match out {
        Outcome::Ok {
            avail,
            threshold,
            evicted,
        } => format!(
            "ok:disk-preflight:{t}:free={avail}:threshold={threshold}:evicted={}",
            evicted.len()
        ),
        Outcome::DiskLow { avail, .. } => format!("refused:disk-low:{t}:{avail}"),
        Outcome::Unknown => format!("refused:disk-low:{t}:unknown (free space could not be read)"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn git(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap();
        assert!(
            st.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&st.stderr)
        );
    }

    /// A scratch repo with a bare remote and three worktrees: `pushed` (clean,
    /// HEAD on the remote), `unpushed` (a local commit) and `dirty` (an
    /// uncommitted file).
    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let base = d.path().to_path_buf();
        let remote = base.join("remote.git");
        let repo = base.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&base, &["init", "-q", "--bare", remote.to_str().unwrap()]);
        git(&repo, &["init", "-q", "-b", "main"]);
        git(&repo, &["commit", "-q", "--allow-empty", "-m", "root"]);
        git(
            &repo,
            &["remote", "add", "origin", remote.to_str().unwrap()],
        );
        git(&repo, &["push", "-q", "origin", "main"]);
        for (name, extra) in [("pushed", ""), ("unpushed", "commit"), ("dirty", "file")] {
            let wt = repo.join(".claude/worktrees").join(name);
            git(
                &repo,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    name,
                    wt.to_str().unwrap(),
                    "origin/main",
                ],
            );
            match extra {
                "commit" => git(&wt, &["commit", "-q", "--allow-empty", "-m", "local"]),
                "file" => std::fs::write(wt.join("scratch.txt"), "x").unwrap(),
                _ => {}
            }
        }
        (d, repo)
    }

    fn names(paths: &[PathBuf]) -> Vec<String> {
        paths
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    }

    /// 5.1: under a simulated low threshold only the pushed, clean worktree is
    /// evicted, and the git worktree is really gone.
    #[test]
    fn only_the_pushed_clean_worktree_is_evicted() {
        let (_d, repo) = fixture();
        let wts = list_worktrees(&repo).unwrap();
        assert_eq!(wts.len(), 3, "{wts:?}");
        // 10 GiB disk: threshold 2 GiB. 1 GiB free; each eviction frees 2 GiB.
        let avail = RefCell::new(GIB);
        let out = run(
            &wts,
            false,
            || {
                Some(Space {
                    avail: *avail.borrow(),
                    total: 10 * GIB,
                })
            },
            |p| {
                let ok = remove_worktree(&repo, p);
                if ok {
                    *avail.borrow_mut() += 2 * GIB;
                }
                ok
            },
        );
        match out {
            Outcome::Ok { evicted, .. } => assert_eq!(names(&evicted), ["pushed"]),
            other => panic!("expected ok after one eviction, got {other:?}"),
        }
        assert!(!repo.join(".claude/worktrees/pushed").exists());
        assert!(repo.join(".claude/worktrees/unpushed").exists());
        assert!(repo.join(".claude/worktrees/dirty/scratch.txt").exists());
    }

    /// 5.1: when evicting every candidate cannot reach the threshold, the
    /// verdict is disk-low, and the unpushed and dirty worktrees survive.
    #[test]
    fn an_unreachable_threshold_is_refused_disk_low() {
        let (_d, repo) = fixture();
        let wts = list_worktrees(&repo).unwrap();
        let out = run(
            &wts,
            false,
            || {
                Some(Space {
                    avail: GIB / 2,
                    total: 10 * GIB,
                })
            },
            |p| remove_worktree(&repo, p),
        );
        match &out {
            Outcome::DiskLow {
                evicted,
                avail,
                threshold,
            } => {
                assert_eq!(names(evicted), ["pushed"]);
                assert_eq!((*avail, *threshold), (GIB / 2, 2 * GIB));
            }
            other => panic!("expected disk-low, got {other:?}"),
        }
        assert_eq!(
            verdict(&repo, &out),
            format!("refused:disk-low:{}:{}", repo.display(), GIB / 2)
        );
        assert!(repo.join(".claude/worktrees/unpushed").exists());
        assert!(repo.join(".claude/worktrees/dirty").exists());
    }

    #[test]
    fn enough_space_evicts_nothing() {
        let (_d, repo) = fixture();
        let wts = list_worktrees(&repo).unwrap();
        let out = run(
            &wts,
            false,
            || {
                Some(Space {
                    avail: 5 * GIB,
                    total: 10 * GIB,
                })
            },
            |_| panic!("nothing may be removed above the threshold"),
        );
        assert!(
            matches!(out, Outcome::Ok { ref evicted, .. } if evicted.is_empty()),
            "{out:?}"
        );
    }

    #[test]
    fn unreadable_free_space_fails_closed() {
        let out = run(&[], false, || None, |_| true);
        assert_eq!(out, Outcome::Unknown);
        assert!(verdict(Path::new("/x"), &out).starts_with("refused:disk-low:/x:unknown"));
    }

    #[test]
    fn the_threshold_is_max_2gib_15pct_or_25pct_on_l0() {
        assert_eq!(threshold(10 * GIB, false), 2 * GIB);
        assert_eq!(threshold(100 * GIB, false), 15 * GIB);
        assert_eq!(threshold(1536 << 20, true), 384 << 20);
    }

    /// The oldest HEAD goes first among several eligible worktrees.
    #[test]
    fn eviction_is_oldest_head_first() {
        let wt = |n: &str, t| Worktree {
            path: PathBuf::from(n),
            clean: true,
            pushed: true,
            head_time: t,
        };
        let wts = [wt("new", 30), wt("old", 10), wt("mid", 20)];
        let avail = RefCell::new(0u64);
        let out = run(
            &wts,
            false,
            || {
                Some(Space {
                    avail: *avail.borrow(),
                    total: 10 * GIB,
                })
            },
            |_| {
                *avail.borrow_mut() += GIB;
                true
            },
        );
        match out {
            Outcome::Ok { evicted, .. } => assert_eq!(names(&evicted), ["old", "mid"]),
            other => panic!("{other:?}"),
        }
    }
}
