// @trace spec:host-shell-architecture
// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
//! Shared filesystem scanner backing local-project enumeration on the Linux
//! native (unix-socket) transport.
//!
//! Order 997-e4v2 removed `EnumerateLocalProjects` from the vsock (in-VM)
//! transport, so only one resolver remains live: `host_project_root` below,
//! via `TILLANDSIAS_HOST_PROJECT_ROOT` env var (default `$HOME/src`). The
//! in-VM counterpart this doc used to describe (`TILLANDSIAS_IN_VM_PROJECT_ROOT`,
//! default `/home/forge/src`) had no caller left after that removal and was
//! deleted as dead code rather than kept `#[allow(dead_code)]`.
//!
//! `scan_project_root` here does the actual walk (dirs only, no dot-files,
//! sorted by label, mtime as `last_seen_unix`).

#[cfg(feature = "tray")]
use std::env;
use std::path::Path;
#[cfg(feature = "tray")]
use std::path::PathBuf;

use tillandsias_control_wire::LocalProjectEntry;

/// A per-lane bounded tmpfs volume, never a disk-backed source volume. Hash the
/// tuple (not a concatenated label) so project/instance hyphens cannot alias.
/// @trace spec:local-web-preview, spec:forge-hot-cold-split
pub(crate) fn ram_workspace_volume(project: &str, instance: &str) -> String {
    use sha2::Digest;
    let digest = sha2::Sha256::digest(format!("{project}\0{instance}"));
    format!("tillandsias-source-{:x}", digest)
}

#[cfg(feature = "tray")]
pub const HOST_PROJECT_ROOT_ENV: &str = "TILLANDSIAS_HOST_PROJECT_ROOT";

#[cfg(feature = "tray")]
pub fn host_project_root() -> PathBuf {
    if let Ok(v) = env::var(HOST_PROJECT_ROOT_ENV) {
        return PathBuf::from(v);
    }
    if let Some(mut d) = dirs::home_dir() {
        d.push("src");
        d
    } else {
        PathBuf::from("/nonexistent")
    }
}

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
// 997-e4v2 step 3 / 1031-q4pb: the wire enumerator that used to call this from
// a non-tray build is gone, and the four remaining callers (order 505 label
// validation in main.rs x3 and the MCP tool-socket guard in tray/mod.rs) are ALL
// behind `feature = "tray"`. So this is dead in a default build and load-bearing
// in a tray one. Scoped rather than blanket-allowed so a tray build still
// reports it if 1031-q4pb removes the last real caller.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
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

// ===========================================================================
// ORDER 505 LABEL VALIDATION (order 1031-q4pb)
// ===========================================================================
//
// THE BUG THIS REPLACES. Four sites carried, in two spellings:
//
//     if !known.is_empty() && !known.iter().any(|p| p.label == name) { deny }
//     let ok = known.is_empty() || known.iter().any(|p| p.label == name);
//
// Both mean "when we know of no projects, allow anything". On a check whose
// own comment says the label must be validated by EQUALITY and NEVER
// sanitized, the empty case was a BYPASS rather than a refusal — and the
// label then flowed into `format!("tillandsias-{project_name}-web")` and into
// filesystem paths.
//
// WHEN IT IS LIVE: today on any host whose ~/src is empty or absent, which is
// every fresh curl-install; and universally once ~/src retires (776-jcf3).
// The bypass is not hypothetical and it is not future — it ships now.
//
// WHAT THE SET IS, under the operator's cloud-only direction (776-jcf3: the
// fleet is cloud <-> ephemeral mirror <-> ephemeral forge, and the host
// checkout is to be removed). There is no successor DIRECTORY to enumerate,
// so the question "what do we validate against" cannot be answered by moving
// the scan somewhere else. The answer is the set of project names this host
// actually knows:
//
//     local enumeration (while a project root still exists, transitional)
//   ∪ the cloud project labels last CONFIRMED by a successful fetch
//
// and the label must appear in it. An EMPTY set denies — that is the whole
// point, and it is why this is a helper rather than three copies.
//
// WHY THE CLOUD HALF IS A FILE AND NOT A CALL. `fetch_cloud_projects` shells
// out to `gh`. Putting a network round-trip inside a security check that runs
// on every launch, status and stop would make validation fail whenever the
// network does — and under fail-closed, a flaky network would deny every
// launch on the host. So the tray persists labels it has already confirmed,
// and this path only ever reads a local file.
//
// AND ONLY ON A CONFIRMED FETCH (731-eupn). That packet exists because an
// empty list from a FAILED fetch was indistinguishable from a genuinely empty
// account. Persisting a failed fetch here would be that bug with teeth: it
// would erase the known set and deny every launch until the next success.
// `persist_cloud_labels` is therefore called from exactly one place — the
// success path in tray::cloud — and never from a `Failed`/`Unknown` outcome.

/// Env override for the confirmed-cloud-label cache. Set by tests and by the
/// empty-root control run; unset in normal operation.
#[cfg(feature = "tray")]
pub const CLOUD_LABEL_CACHE_ENV: &str = "TILLANDSIAS_CLOUD_PROJECT_CACHE";

/// Path of the persisted set of cloud project labels.
#[cfg(feature = "tray")]
pub fn cloud_label_cache_path() -> PathBuf {
    if let Ok(v) = env::var(CLOUD_LABEL_CACHE_ENV) {
        return PathBuf::from(v);
    }
    tillandsias_core::config::state_dir().join("known-cloud-projects")
}

/// Record the labels of a CONFIRMED cloud fetch.
///
/// Call this ONLY where the fetch succeeded (731-eupn). Writing the empty list
/// of a failed fetch would deny every launch until the next success.
#[cfg(feature = "tray")]
pub fn persist_cloud_labels(labels: &[String]) -> std::io::Result<()> {
    let path = cloud_label_cache_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut body = String::new();
    for l in labels {
        // A label with a newline would forge extra entries on read-back. Such
        // a label cannot name a real repo, so drop it rather than encode it.
        if l.contains('\n') || l.is_empty() {
            continue;
        }
        body.push_str(l);
        body.push('\n');
    }
    std::fs::write(&path, body)
}

/// Labels from the last confirmed cloud fetch. Absent cache = empty, which
/// denies rather than allows.
#[cfg(feature = "tray")]
pub fn read_cloud_labels() -> Vec<String> {
    let path = cloud_label_cache_path();
    match std::fs::read_to_string(&path) {
        Ok(body) => body
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(str::to_string)
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// The set order 505 validates a label against.
#[cfg(feature = "tray")]
pub fn known_project_labels() -> std::collections::BTreeSet<String> {
    let mut set: std::collections::BTreeSet<String> = scan_project_root(&host_project_root())
        .into_iter()
        .map(|p| p.label)
        .collect();
    set.extend(read_cloud_labels());
    set
}

/// 1626-r4xm: the local projects THIS process launched a lane for, each bound
/// to the canonical path it was launched from. The lane listener runs in the
/// launching process, so the binding lives exactly as long as the lane.
#[cfg(feature = "tray")]
fn launched_bindings() -> std::sync::MutexGuard<'static, std::collections::BTreeMap<String, PathBuf>>
{
    static BINDINGS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::BTreeMap<String, PathBuf>>,
    > = std::sync::OnceLock::new();
    BINDINGS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A binding holds while its path is still a directory that canonicalizes to
/// itself. A project moved, deleted or swapped for a symlink stops admitting.
#[cfg(feature = "tray")]
fn binding_holds(path: &Path) -> bool {
    path.is_dir() && path.canonicalize().ok().as_deref() == Some(path)
}

/// 1626-r4xm: admit the one project a lane was launched for, wherever it lives
/// (e.g. `~/claudia/<x>`, outside the host project root), with nothing for the
/// operator to set. `canonical` must already be canonical and `label` must be
/// its last component, so the label names exactly the launched directory.
///
/// Refuses to rebind a label that still holds a DIFFERENT path: two projects
/// with one label would make the lane's identity ambiguous.
#[cfg(feature = "tray")]
pub fn bind_launched_project(label: &str, canonical: &Path) -> Result<(), String> {
    if canonical.file_name().and_then(|n| n.to_str()) != Some(label) || !binding_holds(canonical) {
        return Err(format!(
            "cannot bind lane '{label}' to {}: the label must be the last component \
             of the project's canonical directory",
            canonical.display()
        ));
    }
    let mut bindings = launched_bindings();
    if let Some(bound) = bindings.get(label)
        && bound != canonical
        && binding_holds(bound)
    {
        return Err(format!(
            "lane '{label}' is already bound to {}; refusing to bind it to {} as well",
            bound.display(),
            canonical.display()
        ));
    }
    bindings.insert(label.to_string(), canonical.to_path_buf());
    Ok(())
}

/// Order 505: validate a project label by EQUALITY against the known set.
///
/// FAILS CLOSED. An empty set denies, which is the defect this replaces.
/// Never sanitizes: the label is either known verbatim or refused.
///
/// 1626-r4xm: the known set also holds the projects this process launched a
/// lane for ([`bind_launched_project`]), while their bound path holds. Every
/// other label outside the root is still refused.
#[cfg(feature = "tray")]
pub fn validate_project_label(label: &str) -> Result<(), String> {
    if launched_bindings()
        .get(label)
        .is_some_and(|bound| binding_holds(bound))
    {
        return Ok(());
    }
    let known = known_project_labels();
    if known.contains(label) {
        return Ok(());
    }
    // The message distinguishes "we know of nothing" from "we know of things
    // and this is not one", because those need different operator responses:
    // the first is a host that has never had a confirmed cloud fetch, the
    // second is a genuinely wrong label.
    if known.is_empty() {
        Err(format!(
            "Project '{label}' cannot be validated: this host knows of no projects \
             (no local enumeration under {} and no confirmed cloud project list at {}). \
             Refusing rather than accepting an unvalidated label.",
            host_project_root().display(),
            cloud_label_cache_path().display()
        ))
    } else {
        // 1626-r4xm: name WHERE the host looked, and the variable that moves it.
        // A forge agent that hits this cannot see the host; this sentence is
        // what it can relay to the operator.
        Err(format!(
            "Project '{label}' is not a known project on this host: local projects \
             are the directories directly under {} (set {HOST_PROJECT_ROOT_ENV} to \
             the directory that holds it, or move the project there) plus the one \
             project a lane was launched for, and cloud projects come from the \
             confirmed list at {}",
            host_project_root().display(),
            cloud_label_cache_path().display()
        ))
    }
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

    // === ORDER 505 FAIL-CLOSED VALIDATION (1031-q4pb) ==========================
    //
    // ENV IS PROCESS-GLOBAL AND CARGO RUNS TESTS IN THREADS, so these tests
    // serialize on the crate-wide lock (crate::test_support::env_lock,
    // 1437-5czv). Without it they pass alone and fail in a full run, which is
    // the flaky-test shape that gets a suite ignored rather than fixed.
    #[cfg(feature = "tray")]
    struct EnvScope {
        _g: std::sync::MutexGuard<'static, ()>,
        _tmp: std::path::PathBuf,
    }

    #[cfg(feature = "tray")]
    impl Drop for EnvScope {
        fn drop(&mut self) {
            unsafe {
                std::env::remove_var(super::HOST_PROJECT_ROOT_ENV);
                std::env::remove_var(super::CLOUD_LABEL_CACHE_ENV);
            }
            let _ = std::fs::remove_dir_all(&self._tmp);
        }
    }

    /// Point both halves of the validation set at a scratch dir. `locals` are
    /// created as directories under the project root; `cloud` is written to the
    /// confirmed-cloud cache.
    #[cfg(feature = "tray")]
    fn scoped(locals: &[&str], cloud: Option<&[&str]>) -> EnvScope {
        let g = crate::test_support::env_lock();
        let tmp = std::env::temp_dir().join(format!(
            "tillandsias-1031-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&tmp);
        let root = tmp.join("src");
        std::fs::create_dir_all(&root).unwrap();
        for l in locals {
            std::fs::create_dir_all(root.join(l)).unwrap();
        }
        let cache = tmp.join("known-cloud-projects");
        unsafe {
            std::env::set_var(super::HOST_PROJECT_ROOT_ENV, &root);
            std::env::set_var(super::CLOUD_LABEL_CACHE_ENV, &cache);
        }
        if let Some(c) = cloud {
            let owned: Vec<String> = c.iter().map(|s| s.to_string()).collect();
            super::persist_cloud_labels(&owned).unwrap();
        }
        EnvScope { _g: g, _tmp: tmp }
    }

    /// THE PACKET'S CRITERION 1, and the pre-fix behaviour it replaces.
    ///
    /// Before 1031-q4pb all four sites read `!known.is_empty() && !any(..)` (or
    /// its inverted twin), so an empty enumeration made the condition false and
    /// validation was SKIPPED — the label flowed straight into
    /// `format!("tillandsias-{name}-web")` and into paths. This is the state of
    /// every fresh curl-install, whose ~/src does not exist.
    #[cfg(feature = "tray")]
    #[test]
    fn empty_enumeration_denies_instead_of_allowing_anything() {
        let _s = scoped(&[], None);
        let err = super::validate_project_label("anything-at-all")
            .expect_err("an empty known set must DENY; allowing is the 1031-q4pb bypass");
        assert!(
            err.contains("knows of no projects"),
            "the empty case needs its own reason so an operator can tell \
             'never fetched' from 'wrong label'; got: {err}"
        );
    }

    /// A label that is not merely absent but actively hostile still gets no
    /// special handling — it is refused by equality, never sanitized.
    #[cfg(feature = "tray")]
    #[test]
    fn traversal_shaped_label_is_denied_on_an_empty_host() {
        let _s = scoped(&[], None);
        for hostile in ["../../etc", "a/../../b", "..", "web --privileged"] {
            assert!(
                super::validate_project_label(hostile).is_err(),
                "{hostile:?} must be refused, not sanitized"
            );
        }
    }

    /// CRITERION 2: a cloud-known label passes with no local checkout at all —
    /// the cloud-only end state (776-jcf3), where there is no directory to scan.
    #[cfg(feature = "tray")]
    #[test]
    fn cloud_known_label_passes_with_no_local_projects() {
        let _s = scoped(&[], Some(&["forge", "tillandsias"]));
        assert!(super::validate_project_label("forge").is_ok());
        assert!(super::validate_project_label("tillandsias").is_ok());
        let err = super::validate_project_label("not-a-repo").unwrap_err();
        assert!(
            err.contains("is not a known project"),
            "a non-empty set must give the wrong-label reason, not the empty one: {err}"
        );
    }

    /// 1626-r4xm, criterion 2: the wrong-label refusal names the root it scanned
    /// and the variable that moves it, so a forge agent that hits it on a lane
    /// socket can tell the operator what to change. It still refuses.
    #[cfg(feature = "tray")]
    #[test]
    fn unknown_label_refusal_names_the_scanned_root_and_its_variable() {
        let _s = scoped(&["known-project"], None);
        let err = super::validate_project_label("scratch-6iwd").unwrap_err();
        assert!(err.contains("is not a known project"), "{err}");
        assert!(
            err.contains(&super::host_project_root().display().to_string()),
            "names the scanned root: {err}"
        );
        assert!(
            err.contains(super::HOST_PROJECT_ROOT_ENV),
            "names the variable: {err}"
        );
    }

    /// 1626-r4xm: a project outside the root is refused until a lane is
    /// launched for it (red), then admitted bound to its canonical path
    /// (green). Another outside label is still refused, and the binding stops
    /// admitting once its directory is gone.
    #[cfg(feature = "tray")]
    #[test]
    fn launched_project_outside_the_root_is_admitted_and_no_other() {
        let _s = scoped(&["known-project"], None);
        let elsewhere = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(elsewhere.path().join("r4xm-launched")).unwrap();
        std::fs::create_dir_all(elsewhere.path().join("r4xm-other")).unwrap();
        let launched = elsewhere
            .path()
            .join("r4xm-launched")
            .canonicalize()
            .unwrap();

        let before = super::validate_project_label("r4xm-launched");
        assert!(
            before.is_err(),
            "RED: refused before its lane is launched: {before:?}"
        );

        super::bind_launched_project("r4xm-launched", &launched).expect("bind");
        assert!(
            super::validate_project_label("r4xm-launched").is_ok(),
            "GREEN: the launched project is admitted outside the root"
        );
        let other = super::validate_project_label("r4xm-other").unwrap_err();
        assert!(
            other.contains("is not a known project"),
            "NEGATIVE: {other}"
        );
        assert!(super::validate_project_label("known-project").is_ok());

        std::fs::remove_dir(&launched).unwrap();
        assert!(
            super::validate_project_label("r4xm-launched").is_err(),
            "a binding follows its directory: gone means refused"
        );
    }

    /// 1626-r4xm: a binding names exactly the launched directory. A label that
    /// is not the path's last component is refused, and a label that still
    /// holds one path cannot be rebound to another.
    #[cfg(feature = "tray")]
    #[test]
    fn launched_binding_refuses_a_mismatched_label_and_a_second_path() {
        let elsewhere = tempfile::tempdir().expect("tempdir");
        let first = elsewhere.path().join("a").join("r4xm-twin");
        let second = elsewhere.path().join("b").join("r4xm-twin");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let first = first.canonicalize().unwrap();
        let second = second.canonicalize().unwrap();

        assert!(super::bind_launched_project("not-the-name", &first).is_err());
        super::bind_launched_project("r4xm-twin", &first).expect("first bind");
        super::bind_launched_project("r4xm-twin", &first).expect("same path rebinds");
        let err = super::bind_launched_project("r4xm-twin", &second).unwrap_err();
        assert!(err.contains("already bound"), "{err}");
    }

    /// The local half still works, and the two halves union rather than one
    /// shadowing the other.
    #[cfg(feature = "tray")]
    #[test]
    fn local_and_cloud_labels_union() {
        let _s = scoped(&["local-only"], Some(&["cloud-only"]));
        assert!(super::validate_project_label("local-only").is_ok());
        assert!(super::validate_project_label("cloud-only").is_ok());
        assert!(super::validate_project_label("neither").is_err());
    }

    /// 731-eupn's constraint, expressed as data: a cache written from a
    /// CONFIRMED-empty account is empty, and an empty cache denies. The
    /// call-site half (never persisting a FAILED fetch) is enforced by
    /// persist_cloud_labels having exactly one caller, on the success path.
    #[cfg(feature = "tray")]
    #[test]
    fn confirmed_empty_cloud_account_still_denies() {
        let _s = scoped(&[], Some(&[]));
        assert!(super::validate_project_label("forge").is_err());
    }

    /// A newline in a label would forge extra cache entries on read-back, so it
    /// is dropped rather than encoded — it cannot name a real repo.
    #[cfg(feature = "tray")]
    #[test]
    fn newline_bearing_label_cannot_forge_cache_entries() {
        let _s = scoped(&[], None);
        super::persist_cloud_labels(&["good".to_string(), "evil\nsmuggled".to_string()]).unwrap();
        let back = super::read_cloud_labels();
        assert_eq!(back, vec!["good".to_string()]);
        assert!(super::validate_project_label("smuggled").is_err());
        assert!(super::validate_project_label("evil").is_err());
    }
}
