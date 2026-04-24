//! Mirror → host working-copy sync.
//!
//! The enclave's bare mirror at
//! `$CACHE_DIR/tillandsias/mirrors/<project>` is the source of truth for
//! forge commits (and for GitHub after the post-receive / startup retry-push
//! sweep). This module pulls those commits into the user's host working copy
//! at `<watch_path>/<project>` so what they see on disk matches what's on
//! GitHub.
//!
//! **Direction:** mirror → host only. The reverse direction (host edits →
//! mirror → forge) is deferred to a future change and requires more careful
//! handling (user edits are the authoritative source; we must not clobber
//! them).
//!
//! **Safety:**
//! - Fast-forward only. If the host branch has diverged from the mirror,
//!   we skip with a warning rather than auto-resolving.
//! - Dirty working tree → skip. Never clobber uncommitted user work.
//! - Detached HEAD → skip. We don't know which branch the user meant.
//! - Missing working copy → skip. User hasn't cloned this project locally.
//!
//! @trace spec:git-mirror-service

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc as std_mpsc;
use std::time::{Duration, Instant};

use notify::{EventKind, RecursiveMode, Watcher};
use tracing::{debug, info, warn};

/// Outcome of a single project's sync attempt.
///
/// @trace spec:git-mirror-service
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncResult {
    /// Mirror dir doesn't exist — no forge session has ever touched this
    /// project. Nothing to sync.
    MirrorAbsent,
    /// Host working copy absent — user has not cloned this project locally.
    /// Nothing to sync (and nothing to create — we never write outside
    /// the user's pre-existing working copies).
    HostAbsent,
    /// Host path exists but is not a git repo — maybe a sibling dir with
    /// the same name.
    HostNotAGitRepo,
    /// Host working tree has uncommitted changes. Skip, log.
    HostDirty,
    /// Host is not on a branch (detached HEAD / rebase / bisect / etc.).
    /// Skip.
    HostDetachedHead,
    /// Host branch has commits the mirror doesn't. Fast-forward impossible.
    /// Skip (user must merge/rebase manually).
    HostDiverged,
    /// Host branch does not exist on the mirror at all (e.g. a local-only
    /// branch). Skip — nothing to fast-forward to.
    BranchMissingOnMirror,
    /// Host was already at the mirror's tip. No-op.
    AlreadyUpToDate,
    /// Fast-forwarded successfully. Working tree updated.
    Synced {
        branch: String,
        from: String,
        to: String,
    },
}

/// Sync one project by name. `mirror_dir` is the bare mirror path (must
/// exist); `host_working_copy` is the user's clone path (may or may not
/// exist).
///
/// @trace spec:git-mirror-service
pub fn sync_project(project_name: &str, mirror_dir: &PathBuf, host_working_copy: &PathBuf) -> SyncResult {
    if !mirror_dir.exists() {
        return SyncResult::MirrorAbsent;
    }
    if !host_working_copy.exists() {
        return SyncResult::HostAbsent;
    }
    if !host_working_copy.join(".git").exists() {
        return SyncResult::HostNotAGitRepo;
    }

    // Probe current branch. `symbolic-ref --short HEAD` fails on detached HEAD.
    let branch_cmd = Command::new("git")
        .arg("-C")
        .arg(host_working_copy)
        .args(["symbolic-ref", "--short", "HEAD"])
        .output();
    let branch = match branch_cmd {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            debug!(
                spec = "git-mirror-service",
                project = project_name,
                "host is detached HEAD — skipping sync"
            );
            return SyncResult::HostDetachedHead;
        }
    };

    // Dirty-tree check — `status --porcelain` is empty iff clean.
    match Command::new("git")
        .arg("-C")
        .arg(host_working_copy)
        .args(["status", "--porcelain"])
        .output()
    {
        Ok(o) if o.status.success() && !o.stdout.is_empty() => {
            debug!(
                spec = "git-mirror-service",
                project = project_name,
                "host has uncommitted changes — skipping sync"
            );
            return SyncResult::HostDirty;
        }
        Ok(_) => {}
        Err(e) => {
            warn!(
                spec = "git-mirror-service",
                project = project_name,
                error = %e,
                "failed to run git status — aborting sync"
            );
            return SyncResult::HostDirty;
        }
    }

    // Capture current HEAD SHA.
    let before_sha = match Command::new("git")
        .arg("-C")
        .arg(host_working_copy)
        .args(["rev-parse", "HEAD"])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    };

    // Look up the mirror's tip for our branch: `git -C <mirror> rev-parse refs/heads/<branch>`.
    let mirror_tip = match Command::new("git")
        .arg("-C")
        .arg(mirror_dir)
        .args(["rev-parse", &format!("refs/heads/{branch}")])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            debug!(
                spec = "git-mirror-service",
                project = project_name,
                branch = %branch,
                "mirror has no such branch — skipping"
            );
            return SyncResult::BranchMissingOnMirror;
        }
    };

    if mirror_tip == before_sha {
        return SyncResult::AlreadyUpToDate;
    }

    // Fetch only the one branch we care about. `<mirror_dir>` as a path URL
    // works for fetch without needing to add a named remote.
    let fetch_out = Command::new("git")
        .arg("-C")
        .arg(host_working_copy)
        .arg("fetch")
        .arg("--quiet")
        .arg(mirror_dir)
        .arg(&format!("refs/heads/{branch}:refs/tillandsias-mirror/{branch}"))
        .output();
    match fetch_out {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            warn!(
                spec = "git-mirror-service",
                project = project_name,
                stderr = %String::from_utf8_lossy(&o.stderr),
                "git fetch from mirror failed"
            );
            return SyncResult::HostDiverged;
        }
        Err(e) => {
            warn!(
                spec = "git-mirror-service",
                project = project_name,
                error = %e,
                "failed to spawn git fetch"
            );
            return SyncResult::HostDiverged;
        }
    }

    // merge --ff-only: succeeds only if host branch is strict ancestor.
    let merge_out = Command::new("git")
        .arg("-C")
        .arg(host_working_copy)
        .args(["merge", "--ff-only", "--quiet"])
        .arg(&format!("refs/tillandsias-mirror/{branch}"))
        .output();
    match merge_out {
        Ok(o) if o.status.success() => {
            info!(
                accountability = true,
                category = "enclave",
                spec = "git-mirror-service",
                project = project_name,
                branch = %branch,
                from = %before_sha,
                to = %mirror_tip,
                "Mirror → host sync: fast-forwarded working copy"
            );
            SyncResult::Synced {
                branch,
                from: before_sha,
                to: mirror_tip,
            }
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if stderr.contains("not possible to fast-forward")
                || stderr.contains("Not possible to fast-forward")
                || stderr.contains("refusing to merge")
            {
                debug!(
                    spec = "git-mirror-service",
                    project = project_name,
                    branch = %branch,
                    "host branch has diverged from mirror — user must merge/rebase manually"
                );
                SyncResult::HostDiverged
            } else {
                warn!(
                    spec = "git-mirror-service",
                    project = project_name,
                    stderr = %stderr,
                    "git merge --ff-only failed"
                );
                SyncResult::HostDiverged
            }
        }
        Err(e) => {
            warn!(
                spec = "git-mirror-service",
                project = project_name,
                error = %e,
                "failed to spawn git merge"
            );
            SyncResult::HostDiverged
        }
    }
}

/// Sync every project whose bare mirror exists, trying each configured
/// watch path until we find the working copy. Called on tray startup and
/// after forge-container lifecycle events (stop / die).
///
/// @trace spec:git-mirror-service
pub fn sync_all_projects(mirrors_root: &PathBuf, watch_paths: &[PathBuf]) {
    let mirrors = match std::fs::read_dir(mirrors_root) {
        Ok(r) => r,
        Err(e) => {
            debug!(
                spec = "git-mirror-service",
                path = %mirrors_root.display(),
                error = %e,
                "mirrors root unreadable — nothing to sync"
            );
            return;
        }
    };

    for entry in mirrors.flatten() {
        let mirror_dir = entry.path();
        let project_name = match entry.file_name().into_string() {
            Ok(s) => s,
            Err(_) => continue,
        };
        for watch_path in watch_paths {
            let host = watch_path.join(&project_name);
            if host.exists() {
                let result = sync_project(&project_name, &mirror_dir, &host);
                debug!(
                    spec = "git-mirror-service",
                    project = %project_name,
                    host = %host.display(),
                    outcome = ?result,
                    "mirror → host sync attempt"
                );
                break;
            }
        }
    }
}

/// Spawn an inotify/FSEvents watcher on the mirrors root. When any
/// `<mirror>/refs/heads/*` or `<mirror>/packed-refs` file changes (i.e. a
/// push to the mirror just landed, whether from forge or from startup
/// retry-push), trigger a mirror → host sync for that project.
///
/// No polling. Event-driven from the kernel's filesystem notification
/// subsystem. Debounce window of 500ms coalesces the burst of FS events
/// a single `git push` produces (loose-ref write + pack + HEAD update)
/// into one sync run.
///
/// The watcher thread keeps the `Watcher` handle alive for the tray's
/// lifetime. Exiting is handled by the sender closing the channel when
/// the handle is dropped at tray shutdown.
///
/// @trace spec:git-mirror-service
pub fn spawn_watcher(mirrors_root: PathBuf, watch_paths: Vec<PathBuf>) -> Result<(), String> {
    // Create the mirrors root if missing — new installs may not have any
    // project mirrored yet, and notify::watch fails on non-existent paths.
    if let Err(e) = std::fs::create_dir_all(&mirrors_root) {
        return Err(format!(
            "mirrors root {:?} unusable: {e}",
            mirrors_root
        ));
    }

    let (tx, rx) = std_mpsc::channel::<Result<notify::Event, notify::Error>>();
    let mut watcher = notify::recommended_watcher(move |res| {
        // Sender can fail only if the receiver is gone — normal on shutdown.
        let _ = tx.send(res);
    })
    .map_err(|e| format!("notify watcher init failed: {e}"))?;
    watcher
        .watch(&mirrors_root, RecursiveMode::Recursive)
        .map_err(|e| format!("notify watch({}): {e}", mirrors_root.display()))?;

    info!(
        spec = "git-mirror-service",
        path = %mirrors_root.display(),
        "mirror watcher armed — mirror→host sync fires on every ref update"
    );

    std::thread::spawn(move || {
        // Keep watcher alive for the thread's lifetime.
        let _keep_alive = watcher;
        let mut last_sync: HashMap<String, Instant> = HashMap::new();
        let debounce = Duration::from_millis(500);

        while let Ok(res) = rx.recv() {
            let event = match res {
                Ok(e) => e,
                Err(_) => continue,
            };
            // Only care about writes / creates / renames that finalize.
            // ModifyKind::Name(To) = rename target exists (atomic ref update).
            match event.kind {
                EventKind::Create(_) | EventKind::Modify(_) => {}
                _ => continue,
            }
            for path in &event.paths {
                let rel = match path.strip_prefix(&mirrors_root) {
                    Ok(r) => r,
                    Err(_) => continue,
                };
                let mut comps = rel.components();
                let project = match comps.next() {
                    Some(c) => c.as_os_str().to_string_lossy().into_owned(),
                    None => continue,
                };
                let tail_str = comps
                    .as_path()
                    .to_string_lossy()
                    .replace('\\', "/");
                let is_ref_change = tail_str.starts_with("refs/heads/")
                    || tail_str == "packed-refs"
                    || tail_str == "HEAD"
                    || tail_str == "FETCH_HEAD";
                if !is_ref_change {
                    continue;
                }
                let now = Instant::now();
                if let Some(last) = last_sync.get(&project) {
                    if now.duration_since(*last) < debounce {
                        continue;
                    }
                }
                last_sync.insert(project.clone(), now);

                let mirror_dir = mirrors_root.join(&project);
                for watch_path in &watch_paths {
                    let host = watch_path.join(&project);
                    if host.exists() {
                        let result = sync_project(&project, &mirror_dir, &host);
                        debug!(
                            spec = "git-mirror-service",
                            project = %project,
                            host = %host.display(),
                            outcome = ?result,
                            "mirror -> host sync (fs-event)"
                        );
                        break;
                    }
                }
            }
        }
        info!(
            spec = "git-mirror-service",
            "mirror watcher exiting (channel closed)"
        );
    });

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;

    fn run_git(dir: &PathBuf, args: &[&str]) {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn make_fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let tmp = tempfile::TempDir::new().unwrap();
        let mirror = tmp.path().join("mirror");
        let host = tmp.path().join("host");

        // Seed a throwaway "upstream" that both mirror and host clone.
        let seed = tmp.path().join("seed");
        fs::create_dir_all(&seed).unwrap();
        run_git(&seed, &["init", "--initial-branch=main"]);
        run_git(&seed, &["config", "user.email", "test@example.com"]);
        run_git(&seed, &["config", "user.name", "Test"]);
        fs::write(seed.join("README.md"), "v1").unwrap();
        run_git(&seed, &["add", "README.md"]);
        run_git(&seed, &["commit", "-m", "init"]);

        // Mirror = bare clone.
        Command::new("git")
            .args(["clone", "--mirror"])
            .arg(&seed)
            .arg(&mirror)
            .output()
            .unwrap();
        // Host = normal clone from seed.
        Command::new("git")
            .args(["clone"])
            .arg(&seed)
            .arg(&host)
            .output()
            .unwrap();
        run_git(&host, &["config", "user.email", "test@example.com"]);
        run_git(&host, &["config", "user.name", "Test"]);

        (tmp, mirror, host)
    }

    #[test]
    fn already_up_to_date_returns_noop() {
        let (_tmp, mirror, host) = make_fixture();
        match sync_project("fixture", &mirror, &host) {
            SyncResult::AlreadyUpToDate => {}
            r => panic!("expected AlreadyUpToDate, got {:?}", r),
        }
    }

    #[test]
    fn mirror_advances_fast_forwards_host() {
        let (_tmp, mirror, host) = make_fixture();
        // Advance the mirror by committing directly.
        let work = _tmp.path().join("work-for-mirror");
        Command::new("git").args(["clone"]).arg(&mirror).arg(&work).output().unwrap();
        run_git(&work, &["config", "user.email", "t@e.com"]);
        run_git(&work, &["config", "user.name", "t"]);
        fs::write(work.join("new.txt"), "hi").unwrap();
        run_git(&work, &["add", "."]);
        run_git(&work, &["commit", "-m", "add new.txt"]);
        run_git(&work, &["push", "origin", "main"]);

        match sync_project("fixture", &mirror, &host) {
            SyncResult::Synced { branch, from, to } => {
                assert_eq!(branch, "main");
                assert_ne!(from, to);
                assert!(host.join("new.txt").exists(), "file should have been fast-forwarded");
            }
            r => panic!("expected Synced, got {:?}", r),
        }
    }

    #[test]
    fn dirty_host_is_skipped() {
        let (_tmp, mirror, host) = make_fixture();
        fs::write(host.join("dirty.txt"), "uncommitted").unwrap();
        run_git(&host, &["add", "dirty.txt"]);
        assert_eq!(sync_project("fixture", &mirror, &host), SyncResult::HostDirty);
    }

    #[test]
    fn diverged_host_is_skipped_not_force_merged() {
        let (_tmp, mirror, host) = make_fixture();
        // Advance mirror with one commit.
        let work = _tmp.path().join("work");
        Command::new("git").args(["clone"]).arg(&mirror).arg(&work).output().unwrap();
        run_git(&work, &["config", "user.email", "t@e.com"]);
        run_git(&work, &["config", "user.name", "t"]);
        fs::write(work.join("a.txt"), "a").unwrap();
        run_git(&work, &["add", "."]);
        run_git(&work, &["commit", "-m", "a"]);
        run_git(&work, &["push", "origin", "main"]);
        // Make host also diverge with its OWN commit.
        fs::write(host.join("b.txt"), "b").unwrap();
        run_git(&host, &["add", "."]);
        run_git(&host, &["commit", "-m", "b"]);

        assert_eq!(sync_project("fixture", &mirror, &host), SyncResult::HostDiverged);
    }

    #[test]
    fn absent_host_returns_host_absent() {
        let tmp = tempfile::TempDir::new().unwrap();
        let mirror = tmp.path().join("mirror");
        fs::create_dir_all(&mirror).unwrap();
        let host = tmp.path().join("nope");
        assert_eq!(sync_project("x", &mirror, &host), SyncResult::HostAbsent);
    }

    #[test]
    fn absent_mirror_returns_mirror_absent() {
        let tmp = tempfile::TempDir::new().unwrap();
        let mirror = tmp.path().join("no-mirror");
        let host = tmp.path().join("host");
        fs::create_dir_all(&host).unwrap();
        assert_eq!(sync_project("x", &mirror, &host), SyncResult::MirrorAbsent);
    }
}
