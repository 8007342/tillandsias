// @trace spec:host-shell-architecture
// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
//! Shared filesystem scanner for `EnumerateLocalProjects` across both
//! transports.
//!
//! Per the convergence packet's Q4 answer ("unified context; the in-VM
//! headless on Win/Mac sees the in-VM filesystem, the Linux native
//! headless sees the host filesystem — both populate
//! `EnumerateLocalProjects` correctly via their local scanner"), each
//! transport resolves its OWN project root path:
//!
//!   * vsock (in-VM): `vsock_server::in_vm_project_root` →
//!     `TILLANDSIAS_IN_VM_PROJECT_ROOT` env var (default
//!     `/home/forge/src`).
//!   * unix (Linux native host): `tray::host_project_root` →
//!     `TILLANDSIAS_HOST_PROJECT_ROOT` env var (default `$HOME/src`).
//!
//! Both transports then call `scan_project_root` here — the scan logic
//! (dirs only, no dot-files, sorted by label, mtime as
//! `last_seen_unix`) is identical and lives in one place.

use std::path::Path;

use tillandsias_control_wire::LocalProjectEntry;

/// Walk `root` and return one entry per visible directory child.
/// Hidden entries (leading dot) and non-directories are skipped.
/// `last_seen_unix` is the directory's mtime (seconds since epoch).
///
/// Cheap by design: a single `read_dir` + per-entry `metadata`. The
/// host tray re-issues this on user-visible events, not on a tight
/// loop. An unreadable `root` (missing dir, permission denied, ...)
/// returns an empty vec — the dispatchers downstream report a
/// well-formed empty `LocalProjectsReply` rather than an error,
/// matching the prior stub behaviour.
///
/// @trace spec:host-shell-architecture
pub fn scan_project_root(root: &Path) -> Vec<LocalProjectEntry> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let last_seen_unix = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        out.push(LocalProjectEntry {
            label: name.to_string(),
            guest_path: path.to_string_lossy().into_owned(),
            last_seen_unix,
        });
    }
    out.sort_by(|a, b| a.label.cmp(&b.label));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// `scan_project_root` returns one entry per visible directory,
    /// sorted by label.
    #[test]
    fn returns_dirs_only_sorted() {
        let tmp = tempfile::tempdir().expect("tempdir");
        fs::create_dir(tmp.path().join("alpha")).unwrap();
        fs::create_dir(tmp.path().join("beta")).unwrap();
        fs::write(tmp.path().join("regular-file"), b"").unwrap();
        fs::create_dir(tmp.path().join(".hidden")).unwrap();

        let entries = scan_project_root(tmp.path());

        let labels: Vec<&str> = entries.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(labels, vec!["alpha", "beta"]);
        assert!(
            entries.iter().all(|e| !e.guest_path.is_empty()),
            "guest_path must be populated"
        );
    }

    /// Missing or unreadable root returns an empty vec — well-formed
    /// reply, never panics.
    #[test]
    fn returns_empty_when_root_missing() {
        let entries = scan_project_root(Path::new("/this/path/does/not/exist"));
        assert!(entries.is_empty());
    }

    /// `last_seen_unix` is populated from mtime when readable.
    #[test]
    fn last_seen_unix_is_populated() {
        let tmp = tempfile::tempdir().expect("tempdir");
        fs::create_dir(tmp.path().join("recent")).unwrap();
        let entries = scan_project_root(tmp.path());
        assert_eq!(entries.len(), 1);
        assert!(
            entries[0].last_seen_unix > 0,
            "mtime should be a positive unix timestamp"
        );
    }
}
