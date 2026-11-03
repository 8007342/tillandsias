//! ORDER 1984-pexe: this binary's path, robust to the file being replaced on
//! disk while it runs.
//!
//! An install or upgrade replaces the binary under a running tray. Linux then
//! reports `std::env::current_exe()` as `…/tillandsias (deleted)`: a path that
//! does not exist. Every spawn of that path failed with ENOENT ("spawn image
//! ensure helper: No such file or directory"), so studio.start and every image
//! ensure broke until a restart (kumbia forge, 2026-11-03).
//!
//! Two needs, two answers:
//! - [`for_spawn`]: THIS process starts a copy of itself (a helper that must be
//!   the same build). On Linux that is `/proc/self/exe`, which the kernel
//!   resolves to the running image even when its file is gone. Reading it
//!   ([`crate::mcp_socket::build_identity`]) works the same way.
//! - [`for_other_process`]: the path is handed to ANOTHER process (a terminal,
//!   pkexec), where `/proc/self` would name that process. That is the
//!   installed path: the `(deleted)` suffix stripped when a file is there again
//!   (an upgrade put the new build at the same path), else the path as reported.
//! @trace order:1984-pexe

use std::path::{Path, PathBuf};

const DELETED_SUFFIX: &str = " (deleted)";

/// The path this process spawns itself through.
pub fn for_spawn() -> std::io::Result<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        let proc_exe = Path::new("/proc/self/exe");
        if proc_exe.exists() {
            return Ok(proc_exe.to_path_buf());
        }
    }
    std::env::current_exe()
}

/// The path another process should run to get this program.
pub fn for_other_process() -> std::io::Result<PathBuf> {
    std::env::current_exe().map(|p| installed_path(&p, &|q: &Path| q.is_file()))
}

/// `reported` with a trailing ` (deleted)` removed when `exists` says the
/// stripped path is a file again; otherwise `reported` unchanged.
fn installed_path(reported: &Path, exists: &dyn Fn(&Path) -> bool) -> PathBuf {
    let s = reported.to_string_lossy();
    match s.strip_suffix(DELETED_SUFFIX) {
        Some(stripped) if exists(Path::new(stripped)) => PathBuf::from(stripped),
        _ => reported.to_path_buf(),
    }
}

/// Whether the running binary's file was replaced or removed (a restart
/// picks up the installed build).
pub fn replaced_on_disk() -> bool {
    std::env::current_exe()
        .map(|p| p.to_string_lossy().ends_with(DELETED_SUFFIX))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_installed_path_drops_the_deleted_suffix_only_when_a_file_is_there() {
        let p = Path::new("/opt/t/tillandsias (deleted)");
        assert_eq!(
            installed_path(p, &|_| true),
            PathBuf::from("/opt/t/tillandsias")
        );
        assert_eq!(installed_path(p, &|_| false), p.to_path_buf());
        let live = Path::new("/opt/t/tillandsias");
        assert_eq!(installed_path(live, &|_| true), live.to_path_buf());
    }

    /// The child half of the unlink test: run inside a COPY of the test
    /// binary that it deletes first, then spawn itself.
    #[test]
    fn self_exe_child_probe() {
        if std::env::var_os("TILLANDSIAS_SELF_EXE_PROBE").is_none() {
            return;
        }
        let me = std::env::current_exe().unwrap();
        std::fs::remove_file(&me).unwrap();
        assert!(
            std::env::current_exe()
                .unwrap()
                .to_string_lossy()
                .ends_with(DELETED_SUFFIX)
        );
        assert!(replaced_on_disk());
        let via = if std::env::var_os("TILLANDSIAS_SELF_EXE_PROBE_OLD").is_some() {
            std::env::current_exe().unwrap()
        } else {
            for_spawn().unwrap()
        };
        let out = std::process::Command::new(&via)
            .args(["--list", "self_exe_child_probe"])
            .env_remove("TILLANDSIAS_SELF_EXE_PROBE")
            .output();
        match out {
            Ok(o) if o.status.success() => println!("PROBE-SPAWNED-OK"),
            Ok(o) => println!("PROBE-SPAWN-EXIT {:?}", o.status.code()),
            Err(e) => println!("PROBE-SPAWN-ERR {e}"),
        }
    }

    /// ORDER 1984-pexe: after the running binary is unlinked, a self-spawn
    /// through for_spawn still starts. Pre-fix: FAILS, current_exe() names
    /// "… (deleted)" and the spawn is ENOENT (the old path is the control).
    #[cfg(target_os = "linux")]
    #[test]
    fn a_self_spawn_works_after_the_running_binary_is_unlinked() {
        let src = std::env::current_exe().unwrap();
        let dir = tempfile::tempdir_in(src.parent().unwrap()).unwrap();
        let run = |old: bool| {
            let copy = dir.path().join(if old { "probe-old" } else { "probe-new" });
            std::fs::copy(&src, &copy).unwrap();
            let mut cmd = std::process::Command::new(&copy);
            cmd.args([
                "--exact",
                "self_exe::tests::self_exe_child_probe",
                "--nocapture",
            ])
            .env("TILLANDSIAS_SELF_EXE_PROBE", "1");
            if old {
                cmd.env("TILLANDSIAS_SELF_EXE_PROBE_OLD", "1");
            }
            String::from_utf8_lossy(&cmd.output().unwrap().stdout).into_owned()
        };
        let old = run(true);
        assert!(
            old.contains("PROBE-SPAWN-ERR"),
            "control: current_exe after unlink: {old}"
        );
        let new = run(false);
        assert!(
            new.contains("PROBE-SPAWNED-OK"),
            "for_spawn after unlink: {new}"
        );
    }
}
