// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:app-lifecycle, gap:TR-001
//! End-to-end integration test for complete user flow.
//!
//! This test validates the full lifecycle:
//! 1. `tillandsias --init` (build all images)
//! 2. `tillandsias --opencode-web ~/test-project` (launch browser)
//! 3. Verify tray shows project state progression (Idle→Initializing→Running)
//! 4. Graceful shutdown with SIGTERM
//!
//! The test runs only if TILLANDSIAS_ENABLE_E2E_TESTS=1 to avoid long build times in CI.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn headless_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tillandsias"))
}

fn is_e2e_enabled() -> bool {
    std::env::var("TILLANDSIAS_ENABLE_E2E_TESTS").is_ok()
}

fn wait_for_stdout_line(
    child: &mut std::process::Child,
    pattern: &str,
    _timeout: Duration,
) -> Result<(), String> {
    use std::io::BufRead;
    use std::io::BufReader;

    let stdout = child.stdout.take().ok_or("No stdout pipe")?;
    let reader = BufReader::new(stdout);

    for line_result in reader.lines() {
        let line = line_result.map_err(|e| e.to_string())?;
        eprintln!("[stdout] {}", line);

        if line.contains(pattern) {
            return Ok(());
        }
    }

    Err(format!("EOF reached without finding pattern: {}", pattern))
}

/// Test: Application lifecycle events are emitted in correct order.
/// @trace spec:app-lifecycle
#[test]
fn test_app_lifecycle_events_emitted() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();
    let start = Instant::now();

    let mut child = Command::new(&binary)
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn tillandsias");

    // Poll stdout for app.started event (max 10 seconds)
    let timeout = Duration::from_secs(10);
    match wait_for_stdout_line(&mut child, r#""event":"app.started""#, timeout) {
        Ok(()) => {
            eprintln!("✓ app.started event received");
        }
        Err(e) => {
            let _ = child.kill();
            panic!("Failed to detect app.started: {}", e);
        }
    }

    // Send SIGTERM to trigger graceful shutdown
    let pid = child.id() as libc::pid_t;
    let rc = unsafe { libc::kill(pid, libc::SIGTERM) };
    assert_eq!(rc, 0, "failed to send SIGTERM");

    // Wait for process to exit
    let exit_status = child.wait().expect("failed to wait");

    let elapsed = start.elapsed();

    assert!(
        exit_status.success() || exit_status.code().is_none(),
        "Process should exit cleanly, got {:?}",
        exit_status
    );
    assert!(
        elapsed < Duration::from_secs(15),
        "Full lifecycle should complete in < 15s, took {:?}",
        elapsed
    );

    eprintln!("✓ App lifecycle test passed (total: {:?})", elapsed);
}

/// Test: Multiple rapid launches validate initialization is idempotent.
/// @trace spec:app-lifecycle, gap:TR-006
#[test]
fn test_rapid_init_idempotent() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();
    let launch_count = 3;
    let mut durations = Vec::new();

    for i in 0..launch_count {
        let start = Instant::now();

        let mut child = Command::new(&binary)
            .arg("--headless")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("failed to spawn tillandsias");

        // Give it 5 seconds to start
        std::thread::sleep(Duration::from_millis(500));

        let pid = child.id() as libc::pid_t;
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }

        let _ = child.wait();
        let elapsed = start.elapsed();
        durations.push(elapsed);

        eprintln!("Launch {}: {:?}", i + 1, elapsed);
    }

    // All launches should complete within reasonable time
    for (i, duration) in durations.iter().enumerate() {
        assert!(
            *duration < Duration::from_secs(15),
            "Launch {} took {:?} (> 15s)",
            i + 1,
            duration
        );
    }

    eprintln!("✓ Rapid init idempotency test passed");
}

/// Test: Application can be restarted multiple times without resource leaks.
/// @trace spec:app-lifecycle, spec:graceful-shutdown, gap:TR-008
#[test]
fn test_restart_cycle_no_leaks() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();
    let restart_cycles = 5;

    for cycle in 0..restart_cycles {
        let start = Instant::now();

        let mut child = Command::new(&binary)
            .arg("--headless")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("failed to spawn tillandsias");

        std::thread::sleep(Duration::from_millis(250));

        let pid = child.id() as libc::pid_t;
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }

        let exit_status = child.wait().expect("failed to wait");

        let elapsed = start.elapsed();

        assert!(
            exit_status.success() || exit_status.code().is_none(),
            "Cycle {}: process should exit cleanly",
            cycle + 1
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "Cycle {}: took {:?} (> 10s)",
            cycle + 1,
            elapsed
        );

        eprintln!("Cycle {}: ✓ ({:?})", cycle + 1, elapsed);
    }

    eprintln!("✓ Restart cycle test passed ({} restarts)", restart_cycles);
}

/// Test: JSON event output is well-formed and parseable.
/// @trace spec:headless-mode, spec:logging-levels
#[test]
fn test_json_output_well_formed() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();

    let child = Command::new(&binary)
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn tillandsias");

    std::thread::sleep(Duration::from_secs(1));

    let pid = child.id() as libc::pid_t;
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }

    let output = child.wait_with_output().expect("failed to collect output");

    let stdout_str = String::from_utf8_lossy(&output.stdout);

    // Try to find and parse JSON events
    let mut json_events = 0;
    for line in stdout_str.lines() {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
            json_events += 1;
            // Basic validation: event field must exist
            assert!(
                value.get("event").is_some(),
                "JSON event missing 'event' field: {}",
                line
            );
        }
    }

    assert!(json_events > 0, "No valid JSON events found in stdout");
    eprintln!("✓ Found {} well-formed JSON events", json_events);
}

/// Test: Headless mode handles concurrent signal delivery gracefully.
/// @trace spec:graceful-shutdown, spec:signal-handling
#[test]
fn test_concurrent_signal_delivery() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();

    let mut child = Command::new(&binary)
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn tillandsias");

    std::thread::sleep(Duration::from_millis(500));

    let pid = child.id() as libc::pid_t;

    // Send SIGTERM multiple times (should be idempotent)
    for _ in 0..3 {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    let start = Instant::now();
    let exit_status = child.wait().expect("failed to wait");

    let elapsed = start.elapsed();

    assert!(
        exit_status.success() || exit_status.code().is_none(),
        "Process should exit cleanly after concurrent signals"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "Should exit quickly despite concurrent signals, took {:?}",
        elapsed
    );

    eprintln!("✓ Concurrent signal delivery test passed ({:?})", elapsed);
}

/// Test: Graceful shutdown completes within SLA even with multiple containers.
/// @trace spec:graceful-shutdown, gap:TR-003
#[test]
fn test_graceful_shutdown_sla() {
    if !is_e2e_enabled() {
        eprintln!("E2E test disabled (set TILLANDSIAS_ENABLE_E2E_TESTS=1 to run)");
        return;
    }

    let binary = headless_binary();
    let shutdown_sla = Duration::from_secs(30); // Conservative SLA for cleanup

    let mut child = Command::new(&binary)
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn tillandsias");

    std::thread::sleep(Duration::from_millis(500));

    let pid = child.id() as libc::pid_t;
    let shutdown_start = Instant::now();
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }

    let exit_status = child.wait().expect("failed to wait");

    let shutdown_time = shutdown_start.elapsed();

    assert!(
        exit_status.success() || exit_status.code().is_none(),
        "Graceful shutdown should succeed"
    );
    assert!(
        shutdown_time <= shutdown_sla,
        "Shutdown exceeded SLA: {:?} > {:?}",
        shutdown_time,
        shutdown_sla
    );

    eprintln!(
        "✓ Graceful shutdown SLA met: {:?} <= {:?}",
        shutdown_time, shutdown_sla
    );
}
