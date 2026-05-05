//! Resolve the host filesystem location of the control socket.
//!
//! Primary path:    `$XDG_RUNTIME_DIR/tillandsias/control.sock`
//! Linux fallback:  `/tmp/tillandsias-$UID/control.sock`
//! macOS fallback:  same template, against `$TMPDIR` (APFS provides a
//!                  per-user tmpdir).
//!
//! The parent directory is created with mode `0700`. The socket node
//! itself is `chmod`-ed to `0600` between `bind(2)` and `listen(2)` —
//! that step lives in `mod.rs` because it operates on the bound listener.
//!
//! @trace spec:tray-host-control-socket
//! @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
//! @cheatsheet runtime/networking.md

use std::path::PathBuf;

/// Filename of the socket node inside the parent directory.
pub const SOCKET_FILENAME: &str = "control.sock";

/// Subdirectory under `$XDG_RUNTIME_DIR` that holds the socket node.
pub const SOCKET_SUBDIR: &str = "tillandsias";

/// Container-side mount target — the canonical in-container path consumers
/// connect to. Set as `TILLANDSIAS_CONTROL_SOCKET` in every container that
/// has `mount_control_socket = true` in its profile.
///
/// @trace spec:tray-host-control-socket, spec:podman-orchestration
pub const CONTAINER_SOCKET_PATH: &str = "/run/host/tillandsias/control.sock";

/// Resolution strategy chosen at startup. Recorded in the accountability
/// log so the operator can see whether the freedesktop runtime dir or the
/// per-user `/tmp` fallback was used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketPathSource {
    /// `$XDG_RUNTIME_DIR` was set and used as the parent.
    XdgRuntimeDir,
    /// `$TMPDIR` was used (typically macOS where `XDG_RUNTIME_DIR` is unset).
    Tmpdir,
    /// Per-user tmp fallback `/tmp/tillandsias-$UID/`.
    PerUserTmp,
}

/// A resolved socket location: where the parent directory and the socket
/// node should live, and which strategy produced them.
#[derive(Debug, Clone)]
pub struct ResolvedSocketPath {
    pub parent_dir: PathBuf,
    pub socket_path: PathBuf,
    pub source: SocketPathSource,
}

/// Resolve the socket location from environment + UID.
///
/// Strategy:
///
/// 1. If `XDG_RUNTIME_DIR` is set and non-empty, use it.
/// 2. Otherwise, if `TMPDIR` is set and non-empty (macOS default), use it.
/// 3. Otherwise, fall back to `/tmp/tillandsias-<euid>/`.
///
/// The return value is path-only — neither the directory nor the socket
/// node is touched on disk by this function. `mod.rs` is responsible for
/// `mkdir`-ing the parent and `bind`-ing the socket.
///
/// @trace spec:tray-host-control-socket
pub fn resolve() -> ResolvedSocketPath {
    if let Some(parent) = env_dir("XDG_RUNTIME_DIR") {
        let parent_dir = parent.join(SOCKET_SUBDIR);
        let socket_path = parent_dir.join(SOCKET_FILENAME);
        return ResolvedSocketPath {
            parent_dir,
            socket_path,
            source: SocketPathSource::XdgRuntimeDir,
        };
    }

    if let Some(parent) = env_dir("TMPDIR") {
        let parent_dir = parent.join(SOCKET_SUBDIR);
        let socket_path = parent_dir.join(SOCKET_FILENAME);
        return ResolvedSocketPath {
            parent_dir,
            socket_path,
            source: SocketPathSource::Tmpdir,
        };
    }

    let parent_dir = PathBuf::from(format!("/tmp/tillandsias-{}", current_uid()));
    let socket_path = parent_dir.join(SOCKET_FILENAME);
    ResolvedSocketPath {
        parent_dir,
        socket_path,
        source: SocketPathSource::PerUserTmp,
    }
}

/// Read an environment variable and return it as a path if non-empty.
fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// Best-effort UID lookup. On Unix, asks libc; on other platforms returns
/// `0` so the fallback path is at least deterministic.
#[cfg(unix)]
fn current_uid() -> u32 {
    // SAFETY: getuid is always safe and never fails.
    unsafe { libc::getuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    // Windows/other platforms hit this only via Cargo cross-compile checks.
    // The fallback path is informational on those platforms; the runtime
    // code refuses to bind a Unix socket on Windows in any case.
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to call `resolve` with a controlled environment. We can't
    /// safely mutate `std::env` in a multi-threaded test process, so we
    /// instead duplicate the resolution logic against a hand-built env
    /// shim. The resolution table is small enough to assert directly.
    fn resolve_with(xdg: Option<&str>, tmp: Option<&str>, uid: u32) -> ResolvedSocketPath {
        if let Some(p) = xdg.filter(|v| !v.is_empty()) {
            let parent_dir = PathBuf::from(p).join(SOCKET_SUBDIR);
            let socket_path = parent_dir.join(SOCKET_FILENAME);
            return ResolvedSocketPath {
                parent_dir,
                socket_path,
                source: SocketPathSource::XdgRuntimeDir,
            };
        }
        if let Some(p) = tmp.filter(|v| !v.is_empty()) {
            let parent_dir = PathBuf::from(p).join(SOCKET_SUBDIR);
            let socket_path = parent_dir.join(SOCKET_FILENAME);
            return ResolvedSocketPath {
                parent_dir,
                socket_path,
                source: SocketPathSource::Tmpdir,
            };
        }
        let parent_dir = PathBuf::from(format!("/tmp/tillandsias-{}", uid));
        let socket_path = parent_dir.join(SOCKET_FILENAME);
        ResolvedSocketPath {
            parent_dir,
            socket_path,
            source: SocketPathSource::PerUserTmp,
        }
    }

    #[test]
    fn xdg_runtime_dir_when_set() {
        let r = resolve_with(Some("/run/user/1000"), None, 1000);
        assert_eq!(r.parent_dir, PathBuf::from("/run/user/1000/tillandsias"));
        assert_eq!(
            r.socket_path,
            PathBuf::from("/run/user/1000/tillandsias/control.sock")
        );
        assert_eq!(r.source, SocketPathSource::XdgRuntimeDir);
    }

    #[test]
    fn tmpdir_fallback_when_xdg_missing() {
        let r = resolve_with(None, Some("/var/folders/abc"), 501);
        assert_eq!(r.parent_dir, PathBuf::from("/var/folders/abc/tillandsias"));
        assert_eq!(r.source, SocketPathSource::Tmpdir);
    }

    #[test]
    fn per_user_tmp_fallback_when_neither_set() {
        let r = resolve_with(None, None, 1000);
        assert_eq!(r.parent_dir, PathBuf::from("/tmp/tillandsias-1000"));
        assert_eq!(
            r.socket_path,
            PathBuf::from("/tmp/tillandsias-1000/control.sock")
        );
        assert_eq!(r.source, SocketPathSource::PerUserTmp);
    }

    #[test]
    fn empty_xdg_falls_through() {
        let r = resolve_with(Some(""), Some("/tmp"), 1000);
        assert_eq!(r.parent_dir, PathBuf::from("/tmp/tillandsias"));
        assert_eq!(r.source, SocketPathSource::Tmpdir);
    }

    #[test]
    fn empty_tmpdir_falls_through_to_per_user_tmp() {
        let r = resolve_with(None, Some(""), 42);
        assert_eq!(r.parent_dir, PathBuf::from("/tmp/tillandsias-42"));
        assert_eq!(r.source, SocketPathSource::PerUserTmp);
    }

    #[test]
    fn container_socket_path_constant_is_canonical() {
        assert_eq!(CONTAINER_SOCKET_PATH, "/run/host/tillandsias/control.sock");
    }
}
