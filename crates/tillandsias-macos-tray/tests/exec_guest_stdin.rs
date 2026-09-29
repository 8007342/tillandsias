//! Behavioral pin for the `--exec-guest` stdin-forwarding bound (663-69kp).
//!
//! Spawns the real binary rather than scanning source, so it pins observable
//! behavior. Neither test boots the VM: both assert on what happens *before*
//! the boot, which is exactly where the hang lived.
//!
//! @trace spec:macos-native-tray, plan 663-69kp

#![cfg(target_os = "macos")]

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

/// Both tests spawn a `--exec-guest` one-shot, and order 277's
/// `require_no_live_tray` probes the tray singleton by trying to acquire it.
/// Run them concurrently (cargo's default) and one probe sees the other's
/// process holding the lock, so it exits 3 with "a running Tillandsias tray
/// owns it" — before reaching any stdin code. Serialize them.
fn exec_guest_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 1475-3mpc: an ISOLATED HOME for the child, so these tests exercise the stdin
/// path whatever this host is doing.
///
/// They used to run the child with the caller's HOME. On a Mac whose tray was
/// running (every operator workstation), order 277's live-tray probe found the
/// REAL singleton lock (`dirs::cache_dir()`, i.e. `$HOME/Library/Caches`) held,
/// so the child exited on the refusal before reaching stdin, and both tests
/// failed "proved nothing". The workspace gate's baseline ratchet read that as
/// new-red=2, so `./build.sh --check` was red on any Mac with its tray up.
/// Without a tray, the child instead reached the REAL image root, so the test's
/// behaviour depended on the operator's VM state either way.
///
/// With HOME pointed at a scratch dir, the child takes its own singleton lock,
/// and a placeholder `rootfs.img` satisfies `is_provisioned()` (a stat of that
/// file) under the scratch image root, so the child reaches the stdin read. The
/// VM start that follows fails fast and harmlessly (an unsigned test binary
/// lacks the virtualization entitlement; measured at ~6s and 136 KB). Both
/// tests assert only on what happens before the boot. The real VM and the
/// operator's tray are never touched.
struct IsolatedHome(std::path::PathBuf);

impl IsolatedHome {
    fn new(tag: &str) -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let home = std::env::temp_dir().join(format!(
            "tillandsias-exec-guest-stdin-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let image_root = home.join("Library/Application Support/tillandsias");
        std::fs::create_dir_all(&image_root).expect("scratch image root");
        std::fs::write(image_root.join("rootfs.img"), b"").expect("placeholder rootfs");
        IsolatedHome(home)
    }
}

impl Drop for IsolatedHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Guard against a vacuously-passing assertion: if the one-shot bailed on the
/// live-tray refusal it never exercised the stdin path at all, and any
/// conclusion drawn from its stderr is meaningless.
fn assert_reached_stdin_path(stderr_text: &str) {
    assert!(
        !stderr_text.contains("owns it"),
        "one-shot exited on the order-277 live-tray refusal, so it never reached \
         the stdin path — this test proved nothing. Quit any running tray and re-run. \
         stderr: {stderr_text}"
    );
}

/// THE REGRESSION. `--exec-guest` inherits a stdin that is not a terminal and
/// never reaches EOF — an agent harness, a launchd job, a background shell.
/// The old code called `read_to_end` unconditionally in that case and parked on
/// the main thread forever, before the first `eprintln!` and before the VM was
/// created: 12+ minutes of total silence, observed live 2026-08-11.
///
/// The bound must be observable, so this asserts on the WARNING reaching
/// stderr, not merely on the process making progress — a silent recovery would
/// leave the operator back where they started.
#[test]
fn stdin_that_never_eofs_does_not_block_the_boot_forever() {
    let _serialized = exec_guest_lock();
    let home = IsolatedHome::new("never-eof");
    let mut child = Command::new(env!("CARGO_BIN_EXE_tillandsias-tray"))
        .env("HOME", &home.0)
        // A held-open pipe we deliberately never write to or close.
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .arg("--exec-guest")
        .arg("echo unreachable-in-this-test")
        .spawn()
        .expect("tray binary runs");

    // Keep the write end open for the whole test: `_stdin` is intentionally not
    // dropped until the end, so the child can never see EOF.
    let _stdin = child.stdin.take().expect("stdin piped");

    let started = Instant::now();
    let mut stderr = child.stderr.take().expect("stderr piped");
    let mut buf = String::new();
    let reader = std::thread::spawn(move || {
        let _ = stderr.read_to_string(&mut buf);
        buf
    });

    // The in-binary bound is 5s. Give it generous slack for a loaded CI host,
    // but far below the "forever" the regression produced.
    let deadline = Duration::from_secs(60);
    loop {
        if let Some(_status) = child.try_wait().expect("try_wait") {
            break;
        }
        if started.elapsed() > deadline {
            let _ = child.kill();
            panic!(
                "--exec-guest still had not progressed past the stdin read after {}s \
                 with a never-EOF stdin (663-69kp regression)",
                deadline.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(200));
    }

    let stderr_text = reader.join().expect("stderr reader joins");
    assert_reached_stdin_path(&stderr_text);
    assert!(
        stderr_text.contains("sent no EOF"),
        "the bound must be OBSERVABLE — operator needs to know stdin was dropped. stderr: {stderr_text}"
    );
}

/// NEGATIVE CONTROL (bar-raise 634-39ik). A pin that only ever fires positively
/// proves nothing: a build that unconditionally ignored stdin would satisfy the
/// test above. Here stdin is a real pipe that DOES close, so the warning must
/// NOT appear — the forwarding path is still taken, not bypassed.
#[test]
fn stdin_that_closes_is_still_forwarded_without_the_bound_warning() {
    let _serialized = exec_guest_lock();
    let home = IsolatedHome::new("closes");
    let mut child = Command::new(env!("CARGO_BIN_EXE_tillandsias-tray"))
        .env("HOME", &home.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .arg("--exec-guest")
        .arg("true")
        .spawn()
        .expect("tray binary runs");

    {
        use std::io::Write;
        let mut stdin = child.stdin.take().expect("stdin piped");
        let _ = stdin.write_all(b"payload\n");
        // Dropping here closes the write end -> the child sees EOF immediately.
    }

    let out = child.wait_with_output().expect("child completes");
    let stderr_text = String::from_utf8_lossy(&out.stderr);
    assert_reached_stdin_path(&stderr_text);
    assert!(
        !stderr_text.contains("sent no EOF"),
        "a promptly-closed stdin must not trip the bound warning; stderr: {stderr_text}"
    );
}
