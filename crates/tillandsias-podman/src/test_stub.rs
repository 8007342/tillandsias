//! ORDER 1478-9r6f: write a stub executable that is SAFE to execute at once.
//!
//! The write-then-exec race: while this process holds the new file open for
//! writing, a sibling test that forks hands its child a copy of that fd, which
//! stays open until the child's own exec. Executing the stub while any process
//! holds it open for writing is ETXTBSY ("Text file busy"), so a parallel test
//! run failed here at random (land86 gate, 2026-09-28). Same class as
//! 2053-bg68.
//!
//! The product code under test spawns the stub itself, so a retry cannot live
//! at the spawn. Instead the helper closes the write window before it returns:
//! the stub gets a probe line right after its shebang, and the helper executes
//! it in probe mode (which exits before the body) until that exec is not
//! ETXTBSY. Once one exec succeeds, no process holds a write fd: the only
//! writer was this process, which closed it, and a later fork copies only the
//! fds its forker still holds. So the product's own spawn cannot hit it.

use std::path::Path;

/// The env var that makes a stub exit 0 before its body.
const PROBE: &str = "TILLANDSIAS_TEST_STUB_PROBE";

/// Write `script` (which must start with a `#!` line) to `path` as an
/// executable, returning only once it can be executed without ETXTBSY.
/// Panics naming ETXTBSY if the window never closes within 2 s.
pub(crate) fn install_ready_stub(path: &Path, script: &str) {
    use std::os::unix::fs::PermissionsExt;
    let (shebang, body) = script
        .split_once('\n')
        .filter(|(first, _)| first.starts_with("#!"))
        .expect("a stub script starts with a #! line");
    let probed = format!("{shebang}\n[ -n \"${{{PROBE}:-}}\" ] && exit 0\n{body}");
    std::fs::write(path, probed).expect("write stub");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod stub");
    // No sleep (714-4r6w forbids sleep-polls in this crate): each probe is a
    // fork and exec, which paces the loop, and the window closes in
    // microseconds. The deadline bounds it.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < deadline {
        match std::process::Command::new(path).env(PROBE, "1").output() {
            Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => continue,
            Ok(o) if o.status.success() => return,
            Ok(o) => panic!("stub {} probe exited {:?}", path.display(), o.status.code()),
            Err(e) => panic!("stub {} probe: {e}", path.display()),
        }
    }
    panic!(
        "stub {} stayed ETXTBSY (text file busy) past its bound",
        path.display()
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// 1478-9r6f: a stub from the helper runs at once even while sibling
    /// threads fork. Pre-fix (write then chmod, no barrier): FAILS with
    /// ETXTBSY on a share of the 300 rounds.
    #[test]
    fn a_ready_stub_runs_at_once_while_sibling_threads_fork() {
        let dir =
            std::env::temp_dir().join(format!("tillandsias-ready-stub-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let forkers: Vec<_> = (0..4)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        let _ = std::process::Command::new("/bin/sh")
                            .arg("-c")
                            .arg(":")
                            .status();
                    }
                })
            })
            .collect();
        let (mut busy, mut other) = (0, Vec::new());
        for i in 0..300 {
            let stub = dir.join(format!("podman{i}"));
            install_ready_stub(&stub, "#!/bin/sh\necho ok\n");
            match std::process::Command::new(&stub).output() {
                Ok(o) if o.status.success() && o.stdout == b"ok\n" => {}
                Ok(o) => other.push(format!("{:?} {:?}", o.status.code(), o.stdout)),
                Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => busy += 1,
                Err(e) => other.push(e.to_string()),
            }
        }
        stop.store(true, Ordering::Relaxed);
        for f in forkers {
            f.join().unwrap();
        }
        let _ = std::fs::remove_dir_all(&dir);
        assert!(other.is_empty(), "unexpected: {other:?}");
        assert_eq!(busy, 0, "{busy} of 300 fresh stubs were ETXTBSY");
    }
    /// 1478-9r6f NEGATIVE CONTROL: the probe never runs the body (a stub
    /// that would leave a marker leaves none), and without the probe env the
    /// body runs as written.
    #[test]
    fn the_readiness_probe_does_not_run_the_stub_body() {
        let dir =
            std::env::temp_dir().join(format!("tillandsias-probe-body-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let marker = dir.join("ran");
        let stub = dir.join("podman");
        install_ready_stub(
            &stub,
            &format!("#!/bin/sh\ntouch '{}'\necho body\n", marker.display()),
        );
        let ran_during_install = marker.exists();
        let out = std::process::Command::new(&stub).output().unwrap();
        let ran_after = marker.exists();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!ran_during_install, "the probe ran the stub body");
        assert_eq!(out.stdout, b"body\n");
        assert!(ran_after, "the body did not run without the probe env");
    }
}
