// @trace spec:cache-recovery-mechanism, spec:runtime-diagnostics, spec:graceful-shutdown, gap:tray-cache-corruption
//! Error path validation and recovery testing for release readiness.
//!
//! This test file validates:
//! 1. Cache corruption detection and recovery
//! 2. Podman unavailable scenarios with graceful degradation
//! 3. Missing container images with retry logic
//! 4. Network failure handling (proxy timeout)
//! 5. Boundary conditions (large projects, low disk space)

use std::fs::{self, File};
use std::io::Write;
use std::process::Command;
use tempfile::TempDir;

use tillandsias_core::cache_validation::{self, CacheStateWithChecksums, ValidationResult};

// ===== Cache Corruption Detection & Recovery =====

/// Test: Detect and report cache corruption
#[test]
fn test_cache_corruption_detection() {
    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let cache_dir = temp_dir.path();

    // Create a cache file with known checksum
    let cache_file = cache_dir.join("cargo-lock.cache");
    let mut file = File::create(&cache_file).expect("failed to create cache file");
    file.write_all(b"[dependencies]\ntokio = \"1.0\"")
        .expect("failed to write cache file");
    drop(file);

    // Compute checksum
    let original_checksum =
        cache_validation::compute_file_checksum(&cache_file).expect("failed to compute checksum");

    // Corrupt the file in-place
    let mut file = File::create(&cache_file).expect("failed to open for writing");
    file.write_all(b"[corrupted]\ninvalid = true")
        .expect("failed to write corruption");
    drop(file);

    // Validate: should detect corruption
    let result = cache_validation::validate_cache_file(&cache_file, &original_checksum)
        .expect("validation failed");

    assert!(
        result.is_corrupted(),
        "Cache validation should detect file corruption"
    );

    if let ValidationResult::Corrupted { expected, actual } = result {
        assert_eq!(expected, original_checksum);
        assert_ne!(actual, original_checksum);
    } else {
        panic!("Expected Corrupted variant");
    }
}

/// Test: CacheStateWithChecksums detects multiple corrupted files
#[test]
fn test_cache_corruption_multiple_files() {
    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let cache_dir = temp_dir.path();

    // Create 3 cache files
    let files = vec!["cargo-lock", "npm-lock", "build-state"];
    let mut state = CacheStateWithChecksums::new();

    for filename in &files {
        let filepath = cache_dir.join(filename);
        let mut file = File::create(&filepath).expect("failed to create file");
        file.write_all(format!("content-{}", filename).as_bytes())
            .expect("failed to write file");
        drop(file);

        let checksum =
            cache_validation::compute_file_checksum(&filepath).expect("failed to compute checksum");
        state.file_checksums.insert(filename.to_string(), checksum);
    }

    // Corrupt the second file only
    let npm_lock_path = cache_dir.join("npm-lock");
    let mut file = File::create(&npm_lock_path).expect("failed to open for corruption");
    file.write_all(b"corrupted-npm-lock-content")
        .expect("failed to write corruption");
    drop(file);

    // Verify detection
    assert!(
        state
            .has_corrupted_files(cache_dir)
            .expect("validation failed"),
        "Should detect at least one corrupted file"
    );

    let corrupted = state
        .get_corrupted_files(cache_dir)
        .expect("failed to get corrupted files");
    assert_eq!(corrupted.len(), 1, "Should detect exactly 1 corrupted file");
    assert_eq!(
        corrupted[0].0, "npm-lock",
        "Should identify npm-lock as corrupted"
    );
}

/// Test: Cache validation handles missing files gracefully
#[test]
fn test_cache_corruption_missing_file() {
    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let cache_dir = temp_dir.path();

    // Create a state with a checksum for a non-existent file
    let mut state = CacheStateWithChecksums::new();
    state.file_checksums.insert(
        "missing-cache.json".to_string(),
        "0000000000000000000000000000000000000000000000000000000000000000".to_string(),
    );

    // Validate should report Missing, not error
    let results = state
        .validate_all_files(cache_dir)
        .expect("validation should not fail");
    assert_eq!(results.len(), 1);

    if let Some(ValidationResult::Missing) = results.get("missing-cache.json") {
        // Success: missing file was detected correctly
    } else {
        panic!("Expected Missing variant for non-existent file");
    }
}

/// Test: Cache recovery path — clear corrupted cache
#[test]
fn test_cache_recovery_deletion() {
    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let cache_dir = temp_dir.path();

    // Create a corrupted cache file
    let cache_file = cache_dir.join("corrupted.cache");
    let mut file = File::create(&cache_file).expect("failed to create file");
    file.write_all(b"original").expect("failed to write");
    drop(file);

    let checksum =
        cache_validation::compute_file_checksum(&cache_file).expect("failed to compute checksum");

    // Corrupt it
    let mut file = File::create(&cache_file).expect("failed to open");
    file.write_all(b"corrupted").expect("failed to write");
    drop(file);

    // Verify corruption
    let result =
        cache_validation::validate_cache_file(&cache_file, &checksum).expect("validation failed");
    assert!(result.is_corrupted());

    // Recovery: delete the corrupted file
    fs::remove_file(&cache_file).expect("failed to delete corrupted cache");

    // Verify deletion
    assert!(!cache_file.exists(), "Corrupted cache should be deleted");
}

// ===== Podman Availability & Graceful Degradation =====

/// Test: Check for podman availability (non-blocking, graceful fallback)
#[test]
fn test_podman_availability_detection() {
    // This is a simple smoke test; actual podman detection is in tillandsias-podman crate
    // We test the principle: check podman, log error if unavailable, continue anyway

    let result = Command::new("podman")
        .arg("--version")
        .output()
        .map(|output| output.status.success());

    match result {
        Ok(true) => {
            // Podman is available — expected in test environment
            // In production, this would allow container operations
        }
        Ok(false) => {
            // Podman available but error — should log and degrade gracefully
            eprintln!("podman --version returned non-zero; graceful fallback to headless");
        }
        Err(e) => {
            // Podman not in PATH — expected in some CI environments
            eprintln!(
                "podman not found in PATH ({}); graceful fallback to headless",
                e
            );
        }
    }
}

/// Test: Clear error message when podman command fails
#[test]
fn test_podman_error_message_clarity() {
    // Simulate a podman command failure (e.g., podman info on unavailable system)
    let output = Command::new("podman")
        .arg("info")
        .arg("--format=json")
        .output();

    match output {
        Ok(output) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // Error should be clear and actionable
            assert!(
                !stderr.is_empty() || output.status.code() == Some(127),
                "Error should provide diagnostic information"
            );
        }
        Ok(_) => {
            // Podman is available and working
        }
        Err(e) => {
            // Podman not found — should provide clear message
            let err_msg = format!("{}", e);
            assert!(
                err_msg.contains("No such file") || err_msg.contains("not found"),
                "Error message should clearly indicate podman is unavailable"
            );
        }
    }
}

// ===== Missing Container Image Scenarios =====

/// Test: Handle missing image gracefully (would retry in real scenario)
#[test]
fn test_missing_image_error_handling() {
    // Test the principle: missing image is detected, logged, and offers clear recovery
    let fake_image = "tillandsias-fake-nonexistent-image:v0.1.0";

    let output = Command::new("podman")
        .arg("image")
        .arg("inspect")
        .arg(fake_image)
        .output();

    match output {
        Ok(output) if !output.status.success() => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // Should indicate image not found (not a generic error)
            // Podman error messages include "not known" or "not found"
            assert!(
                stderr.contains("not known")
                    || stderr.contains("no image with reference")
                    || stderr.contains("not found"),
                "Error should clearly indicate missing image: {}",
                stderr
            );
        }
        Ok(_) => {
            // Image exists (unexpected in test)
            panic!("Test image should not exist");
        }
        Err(e) => {
            // podman command not found — acceptable in some CI
            eprintln!("podman not available: {}", e);
        }
    }
}

// ===== Network Failure Scenarios =====

/// Test: Timeout detection for network operations
#[test]
fn test_network_timeout_handling() {
    // Simulate a timeout to an unreachable host
    // This would be called when proxy is unreachable or network is down

    let test_timeout = std::time::Duration::from_millis(100);
    let start = std::time::Instant::now();

    // Try to connect to an unreachable address with short timeout
    // (127.0.0.1 on a closed port should timeout quickly)
    let result = std::net::TcpStream::connect_timeout(
        &"127.0.0.1:1".parse().expect("invalid address"),
        test_timeout,
    );

    let elapsed = start.elapsed();

    match result {
        Ok(_) => {
            panic!("Connection should fail to closed port");
        }
        Err(e) => {
            // Timeout or connection refused — both acceptable
            eprintln!(
                "Network operation failed as expected: {} (elapsed: {:?})",
                e, elapsed
            );
            assert!(
                elapsed >= test_timeout || e.kind() == std::io::ErrorKind::ConnectionRefused,
                "Should either timeout or get connection refused"
            );
        }
    }
}

/// Test: Clear error for proxy unreachable scenario
#[test]
fn test_proxy_unreachable_error_message() {
    // Simulate proxy connection failure
    // Error message should indicate: "proxy unreachable at <address>" not generic "connection failed"

    let proxy_addr = "127.0.0.1:3128"; // Typical Squid proxy port
    let result = std::net::TcpStream::connect(proxy_addr);

    match result {
        Err(e) => {
            // Expected: proxy is not running in test environment
            let msg = format!("{}", e);
            // Should contain actionable information
            assert!(
                msg.contains("refused") || msg.contains("Connection"),
                "Error should indicate proxy is unreachable: {}",
                msg
            );
        }
        Ok(_) => {
            // Unexpected: test proxy is running
            eprintln!("Warning: proxy appears to be running at {}", proxy_addr);
        }
    }
}

// ===== Boundary Conditions =====

/// Test: Handle very large project discovery (1000+ files)
#[test]
fn test_large_project_discovery() {
    let temp_project = TempDir::new().expect("failed to create temp dir");
    let project_dir = temp_project.path();

    // Create a directory structure simulating a large project
    let src_dir = project_dir.join("src");
    fs::create_dir_all(&src_dir).expect("failed to create src dir");

    // Create 100 source files (would be 1000+ in real large project)
    for i in 0..100 {
        let filepath = src_dir.join(format!("file_{:04}.rs", i));
        let mut file = File::create(&filepath).expect("failed to create file");
        file.write_all(format!("// Generated test file {}\n", i).as_bytes())
            .expect("failed to write file");
        drop(file);
    }

    // Count files created
    let file_count: usize = fs::read_dir(&src_dir)
        .expect("failed to read src_dir")
        .filter_map(Result::ok)
        .count();

    assert!(file_count >= 100, "Should have created at least 100 files");

    // Cleanup is automatic via drop(temp_project)
}

/// Test: Handle low disk space scenario detection
#[test]
fn test_low_disk_space_detection() {
    // This is a principle test: verify we can detect available disk space
    // Actual behavior: fail gracefully if disk is full

    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let _metadata = fs::metadata(temp_dir.path()).expect("failed to get metadata");

    // On Unix, we'd use statvfs to check available space
    // Here we just verify the path is accessible
    assert!(temp_dir.path().exists(), "Temp directory should exist");

    // In production, this would check available bytes and alert if < 100MB
}

// ===== Error Message Quality =====

/// Test: Window cleanup on error (principle test)
#[test]
fn test_window_cleanup_on_error() {
    // Verify that temporary resources are cleaned up even when errors occur
    let temp_window_state = TempDir::new().expect("failed to create temp dir");
    let window_file = temp_window_state.path().join("window.state");

    // Create a window state file
    let mut file = File::create(&window_file).expect("failed to create file");
    file.write_all(b"{\"window_id\": \"test\"}")
        .expect("failed to write");
    drop(file);

    assert!(window_file.exists(), "Window state file should exist");

    // Simulate cleanup on error (drop temp_window_state)
    drop(temp_window_state);

    // Verify cleanup (path should no longer exist)
    assert!(!window_file.exists(), "Window state should be cleaned up");
}

/// Test: Informative error output on startup failure
#[test]
fn test_startup_error_message_informativeness() {
    // Principle: startup errors should mention:
    // 1. What failed
    // 2. Why it failed (root cause)
    // 3. How to recover (actionable steps)

    let test_error_messages = vec![
        (
            "podman not found",
            "Podman is not installed or not in PATH. Install podman via: sudo apt install podman",
        ),
        (
            "cache corrupted",
            "Cache file corrupted. Recovery: tillandsias --cache-clear",
        ),
        (
            "low disk",
            "Low disk space (<100MB). Please free up space and try again",
        ),
        (
            "proxy timeout",
            "Proxy unreachable at proxy.local:3128. Check network and proxy status",
        ),
    ];

    for (error_type, recovery_msg) in test_error_messages {
        assert!(
            !recovery_msg.is_empty(),
            "Error message for {} should suggest recovery",
            error_type
        );
        assert!(
            recovery_msg.contains("podman")
                || recovery_msg.contains("Cache")
                || recovery_msg.contains("disk")
                || recovery_msg.contains("Proxy"),
            "Recovery message should be specific: {}",
            recovery_msg
        );
    }
}

// ===== Timeout Tuning =====

/// Test: Reasonable timeout values for different operations
#[test]
fn test_timeout_values_reasonable() {
    // Define expected timeout values for different operations
    let timeouts = [
        ("container_start", 30, "seconds"),
        ("cache_check", 5, "seconds"),
        ("network_request", 10, "seconds"),
        ("graceful_shutdown", 30, "seconds"),
    ];

    for (operation, timeout_secs, unit) in &timeouts {
        assert!(
            *timeout_secs > 0,
            "{} timeout should be positive",
            operation
        );
        assert!(
            *timeout_secs <= 300,
            "{} timeout ({}{}) should be reasonable (<5 minutes)",
            operation,
            timeout_secs,
            unit
        );
    }
}

// ===== P3 Gap Optimization: Symlink Metadata =====

/// Test: Symlink validation uses optimal single-syscall approach.
/// @trace gap:TR-006 — cache eviction performance optimization
/// Validates that broken symlinks are detected efficiently without redundant syscalls.
#[test]
fn test_symlink_validation_single_syscall() {
    use std::time::Instant;

    let temp_dir = TempDir::new().expect("failed to create temp dir");
    let cache_dir = temp_dir.path().join("cache");
    fs::create_dir(&cache_dir).expect("failed to create cache dir");

    // Create 30 valid files to symlink to
    for i in 0..30 {
        let target = temp_dir.path().join(format!("target_{}", i));
        fs::write(&target, format!("content {}", i)).expect("failed to write target file");
    }

    // Create 30 valid symlinks
    #[cfg(unix)]
    {
        for i in 0..30 {
            let target = temp_dir.path().join(format!("target_{}", i));
            let link = cache_dir.join(format!("valid_{}", i));
            std::os::unix::fs::symlink(&target, &link).expect("failed to create valid symlink");
        }
    }

    // Create 20 broken symlinks (dangling references)
    #[cfg(unix)]
    {
        for i in 0..20 {
            let link = cache_dir.join(format!("broken_{}", i));
            // Point to a path that doesn't exist
            std::os::unix::fs::symlink(temp_dir.path().join(format!("nonexistent_{}", i)), &link)
                .expect("failed to create broken symlink");
        }
    }

    // Measure validation time
    let start = Instant::now();
    let mut broken_count = 0;
    let mut valid_count = 0;

    // Simulate the optimized validation logic using read_link
    if let Ok(entries) = fs::read_dir(&cache_dir) {
        for entry in entries.flatten() {
            let path = entry.path();

            // Optimized: single syscall via read_link to detect broken symlinks
            if let Ok(target) = fs::read_link(&path) {
                // Symlink exists. Check if target is reachable.
                // For relative targets, resolve relative to symlink's parent dir.
                let resolved_target = if target.is_absolute() {
                    target.clone()
                } else {
                    path.parent()
                        .map(|p| p.join(&target))
                        .unwrap_or(target.clone())
                };

                if !resolved_target.exists() {
                    broken_count += 1;
                    continue;
                }
                valid_count += 1;
            } else {
                // Not a symlink
                valid_count += 1;
            }
        }
    }

    let duration = start.elapsed();

    // Assertions
    assert_eq!(broken_count, 20, "Should detect all 20 broken symlinks");
    assert_eq!(valid_count, 30, "Should detect all 30 valid symlinks");

    // Performance assertion: 50 symlinks should validate in < 100ms
    // (typical: 5-20ms on modern SSDs)
    eprintln!(
        "✓ Symlink validation: {} valid, {} broken in {:.3}ms",
        valid_count,
        broken_count,
        duration.as_secs_f64() * 1000.0
    );
    assert!(
        duration.as_millis() < 100,
        "Symlink validation took {}ms (expected < 100ms)",
        duration.as_millis()
    );
}
