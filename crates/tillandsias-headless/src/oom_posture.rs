//! ORDER 1913-ebv8 — forges run in their own `tillandsias.slice`, which
//! systemd-oomd monitors with its own pressure limit, and each forge is the
//! LAST candidate there (1911-3dqo: oomd killed a forge and its session could
//! not be rejoined).
//!
//! How systemd-oomd 259 decides (src/oom/oomd-manager.c, oomd-util.{c,h}):
//!   * the candidates under a monitored cgroup are its LEAF cgroups, plus any
//!     cgroup with `memory.oom.group=1`, which then stands for its whole
//!     subtree;
//!   * a candidate's preference is read from its own `user.oomd_avoid` xattr,
//!     and only when the cgroup is owned by root or by the owner of the
//!     monitored cgroup — never inherited;
//!   * AVOID sorts last; OMIT is never killed (not used: it only moves the
//!     kill to Chrome or a toolchain).
//!
//! Podman's leaf for a container is `libpod-<id>.scope/container`, owned by the
//! container's subuid, so an xattr there is ignored. The scope above it is
//! owned by the user, like `tillandsias.slice`. So the forge's SCOPE gets
//! `memory.oom.group=1` (the scope becomes the candidate) and
//! `user.oomd_avoid=1`. Its siblings (browser, toolchain, image generation,
//! preview) share the slice without the mark, so pressure picks them first.
//! `systemctl set-property ManagedOOMPreference=avoid` on the scope was
//! measured to write no xattr on this host, so the xattr is written directly.
//!
//! NEVER BLOCKS A LAUNCH. No systemd cgroup manager (WSL, cgroupfs), no user
//! manager, a refused write: each prints one `[tillandsias] oom:` line and the
//! forge runs as before.
// @trace order:1913-ebv8

use std::path::{Path, PathBuf};

pub(crate) const SLICE: &str = "tillandsias.slice";
/// The slice's own pressure limit (oomd's default for a unit is 60%; app.slice
/// on Fedora uses 80%). Lower than the desktop's, so the enclave sheds its
/// siblings before the session's apps feel it.
pub(crate) const PRESSURE_LIMIT: &str = "60%";

/// Whether this host can place containers in the slice: Linux, podman on the
/// systemd cgroup manager. Asked once.
pub(crate) fn available() -> bool {
    // Argv tests must not depend on the host they run on.
    if cfg!(test) {
        return false;
    }
    static AVAILABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *AVAILABLE.get_or_init(|| {
        let out = tillandsias_podman::podman_cmd_sync()
            .args(["info", "--format", "{{.Host.CgroupManager}}"])
            .output_bounded(std::time::Duration::from_secs(15));
        let systemd = matches!(&out, Ok(o) if o.status.success()
            && String::from_utf8_lossy(&o.stdout).trim() == "systemd");
        if systemd {
            ensure_slice_monitored();
        }
        systemd
    })
}

/// `systemctl --user set-property --runtime` argv for the slice's oomd policy.
pub(crate) fn slice_policy_argv() -> Vec<String> {
    [
        "--user",
        "--no-ask-password",
        "set-property",
        "--runtime",
        SLICE,
        "ManagedOOMMemoryPressure=kill",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain([format!("ManagedOOMMemoryPressureLimit={PRESSURE_LIMIT}")])
    .collect()
}

fn ensure_slice_monitored() {
    let out = std::process::Command::new("systemctl")
        .args(slice_policy_argv())
        .output();
    match out {
        Ok(o) if o.status.success() => {}
        Ok(o) => eprintln!(
            "[tillandsias] oom: {SLICE} is not monitored by systemd-oomd ({}); forges run without the slice policy",
            String::from_utf8_lossy(&o.stderr).trim()
        ),
        Err(e) => eprintln!(
            "[tillandsias] oom: systemctl unavailable ({e}); forges run without the slice policy"
        ),
    }
}

/// The cgroup oomd ranks for a container whose `/proc/<pid>/cgroup` reads
/// `cgroup`: the `libpod-*.scope` (the parent of podman's `container` leaf).
/// `None` unless the path is a cgroup v2 entry under the slice.
pub(crate) fn candidate_cgroup(proc_cgroup: &str, root: &Path) -> Option<PathBuf> {
    let rel = proc_cgroup
        .lines()
        .find_map(|l| l.strip_prefix("0::"))?
        .trim();
    let rel = rel.strip_suffix("/container").unwrap_or(rel);
    let mut parts = rel.trim_start_matches('/').split('/');
    let in_slice = parts.clone().any(|p| p == SLICE);
    let scope = parts.next_back()?;
    if !in_slice || !(scope.starts_with("libpod-") && scope.ends_with(".scope")) {
        return None;
    }
    Some(root.join(rel.trim_start_matches('/')))
}

/// Mark `scope` as one oomd candidate that is chosen last.
pub(crate) fn mark_avoid(scope: &Path) -> Result<(), String> {
    std::fs::write(scope.join("memory.oom.group"), "1")
        .map_err(|e| format!("memory.oom.group: {e}"))?;
    use std::os::unix::ffi::OsStrExt as _;
    let path = std::ffi::CString::new(scope.as_os_str().as_bytes())
        .map_err(|_| "scope path has a NUL".to_string())?;
    let name = c"user.oomd_avoid";
    let value = b"1";
    // SAFETY: both strings are NUL-terminated and outlive the call; the value
    // pointer and length describe `value`.
    let rc = unsafe {
        libc::setxattr(
            path.as_ptr(),
            name.as_ptr(),
            value.as_ptr().cast(),
            value.len(),
            0,
        )
    };
    if rc != 0 {
        return Err(format!(
            "user.oomd_avoid: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// Once `container` runs, mark its scope. Called BEFORE the attached run
/// creates it, so it subscribes to podman's lifecycle events (the container's
/// own start, not a probe loop) on a background thread and never delays the
/// launch. Bounded: a forge that has not started in 10 minutes is not marked.
pub(crate) fn guard_forge(container: &str, debug: bool) {
    if !available() {
        return;
    }
    let container = container.to_string();
    std::thread::spawn(move || {
        let Ok(rt) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        else {
            return;
        };
        let started = rt.block_on(async {
            let (tx, mut rx) = tokio::sync::mpsc::channel(16);
            let stream =
                tokio::spawn(tillandsias_podman::PodmanEventStream::new(&container).stream(tx));
            let seen = tokio::time::timeout(std::time::Duration::from_secs(600), async {
                while let Some(ev) = rx.recv().await {
                    if ev.container_name == container
                        && ev.new_state == tillandsias_core::event::ContainerState::Running
                    {
                        return true;
                    }
                }
                false
            })
            .await
            .unwrap_or(false);
            drop(rx);
            stream.abort();
            seen
        });
        if !started {
            return;
        }
        match mark_running(&container) {
            Err(e) => eprintln!(
                "[tillandsias] oom: {container} is not marked oomd-avoid ({e}); it is ranked like its siblings"
            ),
            Ok(()) if debug => {
                eprintln!("[tillandsias] oom: {container} is the last oomd candidate in {SLICE}")
            }
            Ok(()) => {}
        }
    });
}

/// Mark an already-running `container`'s scope.
pub(crate) fn mark_running(container: &str) -> Result<(), String> {
    let out = tillandsias_podman::podman_cmd_sync()
        .args(["inspect", "--format", "{{.State.Pid}}", container])
        .output_bounded(std::time::Duration::from_secs(15))
        .map_err(|e| format!("inspect: {e}"))?;
    let pid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || pid.is_empty() || pid == "0" {
        return Err("not running".into());
    }
    let cg = std::fs::read_to_string(format!("/proc/{pid}/cgroup"))
        .map_err(|e| format!("/proc/{pid}/cgroup: {e}"))?;
    let scope = candidate_cgroup(&cg, Path::new("/sys/fs/cgroup"))
        .ok_or_else(|| format!("not in {SLICE}"))?;
    mark_avoid(&scope)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_candidate_is_the_scope_above_podmans_leaf_and_only_in_the_slice() {
        let root = Path::new("/sys/fs/cgroup");
        let id = "e4b230e9a41863f9d2225b92c4b778e50b37290f38b16f1b5ed9e3be1d08dcc7";
        let ours = format!(
            "0::/user.slice/user-1000.slice/user@1000.service/tillandsias.slice/libpod-{id}.scope/container\n"
        );
        assert_eq!(
            candidate_cgroup(&ours, root).unwrap(),
            root.join(format!(
                "user.slice/user-1000.slice/user@1000.service/tillandsias.slice/libpod-{id}.scope"
            ))
        );
        // Outside the slice (an older launch, or another tool's container).
        let theirs = format!(
            "0::/user.slice/user-1000.slice/user@1000.service/user.slice/libpod-{id}.scope/container\n"
        );
        assert_eq!(candidate_cgroup(&theirs, root), None);
        // Not a libpod scope, or a v1 line only.
        assert_eq!(
            candidate_cgroup(
                "0::/user.slice/user@1000.service/tillandsias.slice/app.scope\n",
                root
            ),
            None
        );
        assert_eq!(candidate_cgroup("1:name=systemd:/x\n", root), None);
    }

    #[test]
    fn the_slice_policy_is_kill_under_its_own_limit_and_never_omit() {
        let argv = slice_policy_argv().join(" ");
        assert_eq!(
            argv,
            "--user --no-ask-password set-property --runtime tillandsias.slice \
             ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=60%"
        );
        assert!(!argv.contains("omit"));
    }

    /// The xattr oomd reads, written where the user owns the cgroup. A tmpfs
    /// stands in for cgroupfs: it takes user.* xattrs the same way.
    #[test]
    fn mark_avoid_writes_oom_group_and_the_avoid_xattr() {
        let dir = std::path::PathBuf::from("/dev/shm").join(format!("ebv8-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let r = mark_avoid(&dir);
        let group = std::fs::read_to_string(dir.join("memory.oom.group")).unwrap_or_default();
        let mut buf = [0u8; 8];
        let p = std::ffi::CString::new(dir.as_os_str().to_str().unwrap()).unwrap();
        // SAFETY: valid NUL-terminated strings and a buffer of the given size.
        let n = unsafe {
            libc::getxattr(
                p.as_ptr(),
                c"user.oomd_avoid".as_ptr(),
                buf.as_mut_ptr().cast(),
                buf.len(),
            )
        };
        let _ = std::fs::remove_dir_all(&dir);
        if let Err(e) = &r
            && e.contains("Operation not supported")
        {
            // A tmpfs without user xattrs (older kernels): nothing to assert.
            return;
        }
        r.unwrap();
        assert_eq!(group, "1");
        assert_eq!(&buf[..n.max(0) as usize], b"1");
    }
}
