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
//!
//! ORDER 2329-9etw: before any worktree, the cargo incremental cache goes
//! (`<target>/debug/incremental`, oldest crate session first, never `deps/` or
//! `build/`), unless a build holds the target. `pruned:incremental:...` names
//! the bytes freed.

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

/// [`run_to`] at the D4 threshold.
pub fn run(
    worktrees: &[Worktree],
    l0: bool,
    space: impl FnMut() -> Option<Space>,
    remove: impl FnMut(&Path) -> bool,
) -> Outcome {
    run_to(None, worktrees, l0, space, remove)
}

/// The eviction loop, with free space and removal passed in so a test can
/// simulate a filesystem. `remove` returns false when a removal failed; that
/// worktree is then skipped.
pub fn run_to(
    floor: Option<u64>,
    worktrees: &[Worktree],
    l0: bool,
    mut space: impl FnMut() -> Option<Space>,
    mut remove: impl FnMut(&Path) -> bool,
) -> Outcome {
    let Some(first) = space() else {
        return Outcome::Unknown;
    };
    let threshold = floor.unwrap_or_else(|| threshold(first.total, l0));
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

/// ORDER 2329-9etw. One crate-session directory of cargo's incremental cache,
/// `<target>/debug/incremental/<crate>-<hash>`. It is regenerable; `deps/` and
/// `build/` beside it are what the next build reuses and are never listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub path: PathBuf,
    /// Seconds since the epoch; the oldest is pruned first.
    pub mtime: i64,
    pub bytes: u64,
}

/// What pruning the incremental cache did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pruned {
    /// Nothing to do: free space was at or above the floor, or no cache.
    Nothing,
    /// Not pruned, and why (`busy`, `other-filesystem`, `symlink`).
    Kept(&'static str),
    Done {
        dirs: usize,
        bytes: u64,
    },
}

/// The incremental cache of a cargo target directory.
pub fn incremental_dir(target: &Path) -> PathBuf {
    target.join("debug").join("incremental")
}

fn dir_bytes(dir: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .map(|e| match e.path().symlink_metadata() {
            Ok(m) if m.is_dir() => dir_bytes(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

/// The crate-session directories of `dir`: real directories only, so a symlink
/// is never followed out of the cache, and a plain file is left alone.
pub fn list_sessions(dir: &Path) -> Vec<Session> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| {
            let m = e.path().symlink_metadata().ok()?;
            if !m.is_dir() {
                return None;
            }
            let mtime = m
                .modified()
                .ok()?
                .duration_since(std::time::UNIX_EPOCH)
                .ok()?
                .as_secs() as i64;
            Some(Session {
                bytes: dir_bytes(&e.path()),
                path: e.path(),
                mtime,
            })
        })
        .collect()
}

/// Prune sessions oldest first until `space` reaches `floor`, re-reading it
/// after each. `remove` returns false when a removal failed.
pub fn prune_sessions(
    sessions: &[Session],
    floor: u64,
    mut space: impl FnMut() -> Option<Space>,
    mut remove: impl FnMut(&Path) -> bool,
) -> Pruned {
    let mut sorted: Vec<&Session> = sessions.iter().collect();
    sorted.sort_by_key(|s| (s.mtime, s.path.clone()));
    let (mut dirs, mut bytes) = (0, 0);
    for s in sorted {
        // Unreadable free space prunes nothing: the caller then fails closed.
        match space() {
            Some(sp) if sp.avail < floor => {}
            _ => break,
        }
        if remove(&s.path) {
            dirs += 1;
            bytes += s.bytes;
        }
    }
    if dirs == 0 {
        Pruned::Nothing
    } else {
        Pruned::Done { dirs, bytes }
    }
}

/// Hold a cargo target's locks, so nothing builds in it meanwhile: cargo's own
/// (`debug/.cargo-lock`) and the shared-target lock (1807-shtg). `None` when
/// either is held by someone else. A lock file that does not exist is not made.
pub fn hold_target(target: &Path) -> Option<Vec<std::fs::File>> {
    let mut held = Vec::new();
    for f in [
        target.join(".shared-target.lock"),
        target.join("debug").join(".cargo-lock"),
    ] {
        match std::fs::OpenOptions::new().read(true).write(true).open(&f) {
            Ok(file) => match file.try_lock() {
                Ok(()) => held.push(file),
                Err(_) => return None,
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
    }
    Some(held)
}

#[cfg(unix)]
fn device_of(path: &Path) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| m.dev())
}

#[cfg(not(unix))]
fn device_of(_path: &Path) -> Option<u64> {
    None
}

/// Prune the incremental cache of `cargo_target` while the filesystem of
/// `target` is below `floor`. Every removal is a direct child of the cache.
pub fn prune_incremental(
    cargo_target: &Path,
    target: &Path,
    floor: u64,
    dry_run: bool,
    mut space: impl FnMut() -> Option<Space>,
) -> Pruned {
    let dir = incremental_dir(cargo_target);
    let Ok(meta) = dir.symlink_metadata() else {
        return Pruned::Nothing;
    };
    if !space().is_some_and(|s| s.avail < floor) {
        return Pruned::Nothing;
    }
    if !meta.is_dir() {
        return Pruned::Kept("symlink");
    }
    if device_of(&dir) != device_of(target) {
        return Pruned::Kept("other-filesystem");
    }
    let Some(_held) = hold_target(cargo_target) else {
        return Pruned::Kept("busy");
    };
    let sessions = list_sessions(&dir);
    if dry_run {
        return match sessions.len() {
            0 => Pruned::Nothing,
            dirs => Pruned::Done {
                dirs,
                bytes: sessions.iter().map(|s| s.bytes).sum(),
            },
        };
    }
    prune_sessions(&sessions, floor, space, |p| {
        p.parent() == Some(dir.as_path()) && std::fs::remove_dir_all(p).is_ok()
    })
}

/// The line saying what pruning did, if it did or refused anything.
pub fn prune_line(cargo_target: &Path, pruned: &Pruned, dry_run: bool) -> Option<String> {
    let d = incremental_dir(cargo_target);
    let d = d.display();
    match pruned {
        Pruned::Nothing => None,
        Pruned::Kept(why) => Some(format!("kept:incremental:{d}:{why}")),
        Pruned::Done { dirs, bytes } if dry_run => Some(format!(
            "would-prune:incremental:{d}:dirs={dirs}:bytes={bytes}"
        )),
        Pruned::Done { dirs, bytes } => {
            Some(format!("pruned:incremental:{d}:dirs={dirs}:freed={bytes}"))
        }
    }
}

/// The target directory a checkout builds in: CARGO_TARGET_DIR, else
/// `<main checkout>/target` (scripts/shared-target.sh).
pub fn cargo_target_of(repo: &Path) -> Option<PathBuf> {
    if let Some(t) = std::env::var_os("CARGO_TARGET_DIR").filter(|t| !t.is_empty()) {
        return Some(PathBuf::from(t));
    }
    let common = git_out(
        repo,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    Some(Path::new(common.trim()).parent()?.join("target"))
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

    /// ORDER 2329-9etw. A cargo target with three crate sessions (old, mid, new,
    /// 1000 bytes each), a file and a symlink in incremental/, and full deps/ and
    /// build/ beside it.
    fn cargo_target() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let t = d.path().join("target");
        for sub in ["debug/deps", "debug/build", "debug/incremental"] {
            std::fs::create_dir_all(t.join(sub)).unwrap();
        }
        std::fs::write(t.join("debug/deps/libfoo.rlib"), vec![7u8; 5000]).unwrap();
        std::fs::write(t.join("debug/build/out"), vec![8u8; 5000]).unwrap();
        std::fs::write(t.join("debug/incremental/note"), "kept").unwrap();
        for (i, name) in ["old", "mid", "new"].iter().enumerate() {
            let s = t.join("debug/incremental").join(name);
            std::fs::create_dir_all(s.join("s-x")).unwrap();
            std::fs::write(s.join("s-x/query-cache.bin"), vec![1u8; 1000]).unwrap();
            std::fs::File::open(&s)
                .unwrap()
                .set_modified(
                    std::time::UNIX_EPOCH + std::time::Duration::from_secs(1000 + i as u64),
                )
                .unwrap();
        }
        (d, t)
    }

    /// Free space as a function of what is left in the cache: `base` plus 1000
    /// bytes per session gone.
    fn space_by_cache(t: &Path, base: u64) -> impl FnMut() -> Option<Space> + use<> {
        let dir = incremental_dir(t);
        move || {
            let left = list_sessions(&dir).len() as u64;
            Some(Space {
                avail: base + (3 - left) * 1000,
                total: 100_000,
            })
        }
    }

    fn beside(t: &Path) -> (Vec<u8>, Vec<u8>) {
        (
            std::fs::read(t.join("debug/deps/libfoo.rlib")).unwrap(),
            std::fs::read(t.join("debug/build/out")).unwrap(),
        )
    }

    /// The exit criterion: below the floor with the bulk in incremental/. Alone,
    /// the old run() refuses; pruning first, the same filesystem is ok, the
    /// oldest sessions went, and deps/ and build/ are byte-identical.
    #[test]
    fn below_the_floor_incremental_is_pruned_oldest_first_and_the_run_is_ok() {
        let (_d, t) = cargo_target();
        let before = beside(&t);
        let floor = 10_000;
        assert!(matches!(
            run_to(Some(floor), &[], false, space_by_cache(&t, 8_500), |_| {
                false
            }),
            Outcome::DiskLow { .. }
        ));
        let p = prune_incremental(&t, &t, floor, false, space_by_cache(&t, 8_500));
        assert_eq!(
            p,
            Pruned::Done {
                dirs: 2,
                bytes: 2000
            }
        );
        let out = run_to(Some(floor), &[], false, space_by_cache(&t, 8_500), |_| {
            false
        });
        assert!(matches!(out, Outcome::Ok { avail: 10_500, .. }), "{out:?}");
        let inc = incremental_dir(&t);
        assert!(!inc.join("old").exists() && !inc.join("mid").exists());
        assert!(inc.join("new/s-x/query-cache.bin").exists() && inc.join("note").exists());
        assert_eq!(beside(&t), before);
        assert_eq!(
            prune_line(&t, &p, false).unwrap(),
            format!("pruned:incremental:{}:dirs=2:freed=2000", inc.display())
        );
    }

    #[test]
    fn at_the_floor_nothing_is_pruned_and_a_dry_run_removes_nothing() {
        let (_d, t) = cargo_target();
        for dry in [false, true] {
            let p = prune_incremental(&t, &t, 8_500, dry, space_by_cache(&t, 8_500));
            assert_eq!((prune_line(&t, &p, dry), p), (None, Pruned::Nothing));
        }
        let p = prune_incremental(&t, &t, 10_000, true, space_by_cache(&t, 8_500));
        assert_eq!(
            p,
            Pruned::Done {
                dirs: 3,
                bytes: 3000
            }
        );
        assert!(
            prune_line(&t, &p, true)
                .unwrap()
                .starts_with("would-prune:")
        );
        assert_eq!(list_sessions(&incremental_dir(&t)).len(), 3);
    }

    #[test]
    fn unreadable_free_space_prunes_nothing() {
        let (_d, t) = cargo_target();
        assert_eq!(
            prune_incremental(&t, &t, 1, false, || None),
            Pruned::Nothing
        );
        assert_eq!(list_sessions(&incremental_dir(&t)).len(), 3);
    }

    /// Cargo holds debug/.cargo-lock for a whole build, and the shared target has
    /// a lock of its own. Either one held by another keeps the cache.
    #[test]
    fn a_held_target_is_kept_and_named_busy() {
        for lock in ["debug/.cargo-lock", ".shared-target.lock"] {
            let (_d, t) = cargo_target();
            let f = std::fs::File::create(t.join(lock)).unwrap();
            f.lock().unwrap();
            let p = prune_incremental(&t, &t, 10_000, false, space_by_cache(&t, 8_500));
            assert_eq!(p, Pruned::Kept("busy"), "{lock}");
            assert!(prune_line(&t, &p, false).unwrap().ends_with(":busy"));
            assert_eq!(list_sessions(&incremental_dir(&t)).len(), 3);
            // unlock, not drop: a child forked by a parallel test may still hold a
            // copy of the descriptor, and an unlock releases it for every copy.
            f.unlock().unwrap();
            let p = prune_incremental(&t, &t, 10_000, false, space_by_cache(&t, 8_500));
            assert!(matches!(p, Pruned::Done { .. }), "{lock}: {p:?}");
        }
    }

    /// A symlink is never followed: not as the cache itself, and not inside it.
    #[cfg(unix)]
    #[test]
    fn symlinks_are_never_followed() {
        let (_d, t) = cargo_target();
        let inc = incremental_dir(&t);
        std::os::unix::fs::symlink(t.join("debug/deps"), inc.join("link")).unwrap();
        let p = prune_incremental(&t, &t, u64::MAX, false, space_by_cache(&t, 0));
        assert_eq!(
            p,
            Pruned::Done {
                dirs: 3,
                bytes: 3000
            }
        );
        assert!(inc.join("link").symlink_metadata().is_ok());
        assert_eq!(beside(&t).0.len(), 5000);
        let (_d, t) = cargo_target();
        std::fs::remove_dir_all(incremental_dir(&t)).unwrap();
        std::os::unix::fs::symlink(t.join("debug/deps"), incremental_dir(&t)).unwrap();
        let p = prune_incremental(&t, &t, u64::MAX, false, space_by_cache(&t, 0));
        assert_eq!(p, Pruned::Kept("symlink"));
        assert_eq!(beside(&t).0.len(), 5000);
    }
}
