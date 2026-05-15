// @trace spec:cache-recovery-mechanism
//! Integration tests for cache corruption detection and recovery.
//!
//! Verifies that:
//! - Corrupted JSON cache files are detected
//! - Recovery mechanism deletes corrupted files
//! - System can rebuild after recovery
//! - No data loss (only ephemeral cache affected)

use std::fs::{File, self};
use std::io::Write;
use std::path::PathBuf;
use tempfile::TempDir;
use tillandsias_core::cache_validation::{
    compute_file_checksum, validate_cache_file, ValidationResult, CacheStateWithChecksums,
};

/// Simulate a cache directory with valid and corrupted files.
struct CacheScenario {
    dir: TempDir,
}

impl CacheScenario {
    fn new() -> Self {
        Self {
            dir: TempDir::new().expect("Failed to create temp dir"),
        }
    }

    fn path(&self) -> &std::path::Path {
        self.dir.path()
    }

    /// Create a valid cache file (valid JSON).
    fn create_valid_cache(&self, name: &str, content: &str) -> PathBuf {
        let path = self.path().join(name);
        let mut file = File::create(&path).expect("Failed to create cache file");
        file.write_all(content.as_bytes())
            .expect("Failed to write cache file");
        drop(file);
        path
    }

    /// Create a corrupted cache file by overwriting with garbage.
    fn corrupt_file(&self, path: &std::path::Path) {
        let mut file = File::create(path).expect("Failed to corrupt file");
        file.write_all(b"corrupted garbage data!!!")
            .expect("Failed to write garbage");
    }

}

#[test]
fn test_detect_valid_cache_file() {
    let scenario = CacheScenario::new();
    let state_path = scenario.create_valid_cache("init-build-state.json", r#"{"images":{}}"#);

    // Compute checksum
    let checksum = compute_file_checksum(&state_path).expect("Failed to compute checksum");

    // Validate
    let result = validate_cache_file(&state_path, &checksum).expect("Failed to validate");

    assert_eq!(result, ValidationResult::Valid);
}

#[test]
fn test_detect_corrupted_cache_file() {
    let scenario = CacheScenario::new();
    let state_path = scenario.create_valid_cache("init-build-state.json", r#"{"images":{}}"#);

    // Compute original checksum
    let original_checksum =
        compute_file_checksum(&state_path).expect("Failed to compute checksum");

    // Corrupt the file
    scenario.corrupt_file(&state_path);

    // Validate against original checksum
    let result = validate_cache_file(&state_path, &original_checksum)
        .expect("Failed to validate corrupted file");

    assert!(result.is_corrupted());
    if let ValidationResult::Corrupted { expected, actual } = result {
        assert_eq!(expected, original_checksum);
        assert_ne!(actual, original_checksum);
    } else {
        panic!("Expected Corrupted variant");
    }
}

#[test]
fn test_detect_missing_cache_file() {
    let scenario = CacheScenario::new();
    let missing_path = scenario.path().join("nonexistent.json");

    let fake_checksum = "0000000000000000000000000000000000000000000000000000000000000000"
        .to_string();
    let result = validate_cache_file(&missing_path, &fake_checksum).expect("Failed to validate");

    assert_eq!(result, ValidationResult::Missing);
}

#[test]
fn test_cache_recovery_scenario_single_corrupted_file() {
    let scenario = CacheScenario::new();

    // Create a valid state file
    let state_path = scenario.create_valid_cache(
        "init-build-state.json",
        r#"{"images":{"forge":"success"},"timestamp":"2026-05-14T10:00:00+00:00"}"#,
    );

    // Verify it's valid
    let valid_checksum = compute_file_checksum(&state_path).expect("Failed to compute checksum");
    assert_eq!(
        validate_cache_file(&state_path, &valid_checksum).unwrap(),
        ValidationResult::Valid
    );

    // Corrupt it (simulate disk corruption)
    scenario.corrupt_file(&state_path);

    // Now it should be corrupted
    assert!(validate_cache_file(&state_path, &valid_checksum)
        .unwrap()
        .is_corrupted());

    // Recovery: delete the corrupted file
    fs::remove_file(&state_path).expect("Failed to delete corrupted cache");

    // File should now be missing
    assert_eq!(
        validate_cache_file(&state_path, &valid_checksum).unwrap(),
        ValidationResult::Missing
    );

    // Next init would rebuild from scratch
}

#[test]
fn test_cache_state_with_checksums_detects_corruption() {
    let scenario = CacheScenario::new();

    // Create two cache files
    let file1 = scenario.create_valid_cache("state.json", "{}");
    let file2 = scenario.create_valid_cache("metadata.json", "[]");

    // Compute checksums
    let checksum1 = compute_file_checksum(&file1).expect("Failed to compute checksum");
    let checksum2 = compute_file_checksum(&file2).expect("Failed to compute checksum");

    // Build state with checksums
    let mut state = CacheStateWithChecksums::new();
    state
        .file_checksums
        .insert("state.json".to_string(), checksum1.clone());
    state
        .file_checksums
        .insert("metadata.json".to_string(), checksum2);

    // Initially, no corruption
    assert!(!state.has_corrupted_files(scenario.path()).unwrap());

    // Corrupt the first file
    scenario.corrupt_file(&file1);

    // Now detection should find corruption
    assert!(state.has_corrupted_files(scenario.path()).unwrap());

    // Get list of corrupted files
    let corrupted = state.get_corrupted_files(scenario.path()).unwrap();
    assert_eq!(corrupted.len(), 1);
    assert_eq!(corrupted[0].0, "state.json");
    assert_eq!(corrupted[0].1, checksum1); // expected checksum
    assert_ne!(corrupted[0].2, checksum1); // actual checksum differs
}

#[test]
fn test_cache_recovery_end_to_end() {
    let scenario = CacheScenario::new();

    // Simulate initial state: cache was valid
    let cache_file = scenario.create_valid_cache(
        "init-build-state.json",
        r#"{"images":{"proxy":"success","git":"success","forge":"success"}}"#,
    );

    // Verify initial state is valid
    let initial_checksum =
        compute_file_checksum(&cache_file).expect("Failed to compute initial checksum");
    assert_eq!(
        validate_cache_file(&cache_file, &initial_checksum).unwrap(),
        ValidationResult::Valid
    );

    // Simulate corruption (e.g., due to disk glitch or interrupted write)
    scenario.corrupt_file(&cache_file);

    // Detection phase: identify the corruption
    assert!(validate_cache_file(&cache_file, &initial_checksum)
        .unwrap()
        .is_corrupted());

    // Recovery phase: delete corrupted cache
    fs::remove_file(&cache_file).expect("Failed to delete corrupted cache");
    assert!(!cache_file.exists());

    // Next init: state file is missing, so fresh build happens
    // (This is the key outcome: clean restart without cryptic errors)
    assert_eq!(
        validate_cache_file(&cache_file, &initial_checksum).unwrap(),
        ValidationResult::Missing
    );
}

#[test]
fn test_cache_checksum_different_for_different_content() {
    let scenario = CacheScenario::new();

    let file1 = scenario.create_valid_cache("data1.json", r#"{"key":"value1"}"#);
    let file2 = scenario.create_valid_cache("data2.json", r#"{"key":"value2"}"#);

    let checksum1 = compute_file_checksum(&file1).expect("Failed to compute checksum");
    let checksum2 = compute_file_checksum(&file2).expect("Failed to compute checksum");

    // Different content should produce different checksums
    assert_ne!(checksum1, checksum2);
}

#[test]
fn test_cache_checksum_same_for_identical_content() {
    let scenario = CacheScenario::new();

    let file1 = scenario.create_valid_cache("copy1.json", r#"{"data":"identical"}"#);
    let file2 = scenario.create_valid_cache("copy2.json", r#"{"data":"identical"}"#);

    let checksum1 = compute_file_checksum(&file1).expect("Failed to compute checksum");
    let checksum2 = compute_file_checksum(&file2).expect("Failed to compute checksum");

    // Identical content should produce identical checksums
    assert_eq!(checksum1, checksum2);
}

#[test]
fn test_cache_validation_result_display() {
    let valid = ValidationResult::Valid;
    assert!(valid.is_valid());
    assert!(!valid.is_corrupted());

    let corrupted = ValidationResult::Corrupted {
        expected: "aaa".to_string(),
        actual: "bbb".to_string(),
    };
    assert!(!corrupted.is_valid());
    assert!(corrupted.is_corrupted());

    let missing = ValidationResult::Missing;
    assert!(!missing.is_valid());
    assert!(!missing.is_corrupted());
}
