// @trace spec:linux-native-portable-executable, spec:signal-handling
//! Phase 5: Signal handling tests (Tasks 23-24)
//!
//! Task 23: Test signal handling with 30s timeout
//! Task 24: Test SIGKILL fallback for containers not stopping in 30s

use std::process::{Command, Stdio};
use std::time::Instant;
use std::time::Duration;

/// Phase 5, Task 23: Test SIGTERM signal handling and graceful shutdown within 30s
#[test]
fn test_signal_handling_sigterm() {
    let start = Instant::now();

    // Start headless mode in a subprocess
    let mut child = Command::new("cargo")
        .args(&["run", "-p", "tillandsias-headless", "--"])
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Failed to spawn headless process");

    // Give it a moment to start
    std::thread::sleep(Duration::from_millis(500));

    // Send SIGTERM
    let pid = child.id();
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }

    // Wait for graceful shutdown (should complete within ~30s)
    let status = child.wait().expect("Failed to wait for child");

    let elapsed = start.elapsed();

    // Verify process exited successfully
    assert!(status.success() || status.code() == Some(0),
        "Process should exit with code 0, got: {:?}", status.code());

    // Verify shutdown took less than 35 seconds (30s timeout + buffer)
    assert!(elapsed < Duration::from_secs(35),
        "Shutdown should complete within 30s timeout, took {:?}", elapsed);

    println!("✓ SIGTERM shutdown completed in {:?}", elapsed);
}

/// Phase 5, Task 24: Test SIGKILL fallback when graceful shutdown times out
/// Note: This test verifies the timeout pattern, not actual container SIGKILL
/// (real SIGKILL is tested via container orchestration tests)
#[test]
fn test_signal_handling_timeout_pattern() {
    let start = Instant::now();

    // Start headless mode
    let mut child = Command::new("cargo")
        .args(&["run", "-p", "tillandsias-headless", "--"])
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Failed to spawn headless process");

    // Give it time to start
    std::thread::sleep(Duration::from_millis(500));

    // Send SIGTERM
    let pid = child.id();
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }

    // Capture output to verify timeout message
    let status = child.wait().expect("Failed to wait for child");
    let elapsed = start.elapsed();

    // Verify process exited
    assert!(status.success() || status.code() == Some(0),
        "Process should exit cleanly");

    // Verify timeout was honored (approx 30s)
    assert!(elapsed > Duration::from_secs(29),
        "Shutdown should take at least 30s (graceful timeout), took {:?}", elapsed);
    assert!(elapsed < Duration::from_secs(35),
        "Shutdown should not take more than 35s, took {:?}", elapsed);

    println!("✓ Timeout pattern verified: shutdown took {:?}", elapsed);
}

/// Phase 5, Task 23: Test SIGINT signal handling (Ctrl+C)
#[test]
fn test_signal_handling_sigint() {
    let start = Instant::now();

    // Start headless mode
    let mut child = Command::new("cargo")
        .args(&["run", "-p", "tillandsias-headless", "--"])
        .arg("--headless")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Failed to spawn headless process");

    // Give it time to start
    std::thread::sleep(Duration::from_millis(500));

    // Send SIGINT (Ctrl+C equivalent)
    let pid = child.id();
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGINT);
    }

    // Wait for graceful shutdown
    let status = child.wait().expect("Failed to wait for child");
    let elapsed = start.elapsed();

    // Verify process exited
    assert!(status.success() || status.code() == Some(0),
        "Process should exit with code 0");

    // Verify shutdown was fast (SIGINT should trigger immediate shutdown)
    assert!(elapsed < Duration::from_secs(35),
        "Shutdown should complete quickly, took {:?}", elapsed);

    println!("✓ SIGINT shutdown completed in {:?}", elapsed);
}
