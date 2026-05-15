// @trace spec:cache-recovery-mechanism, spec:init-incremental-builds
//! Cache validation and recovery for pre-release reliability.
//!
//! Provides checksum-based cache file validation and automatic recovery
//! when corruption is detected. Only ephemeral cache is deleted; project
//! state is never affected.

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// SHA256 checksum of a cache file (hex-encoded).
pub type FileChecksum = String;

/// Cache file validation result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationResult {
    /// File is valid (exists and checksum matches).
    Valid,
    /// File is corrupted (exists but checksum doesn't match).
    Corrupted {
        expected: FileChecksum,
        actual: FileChecksum,
    },
    /// File is missing or unreadable.
    Missing,
}

impl ValidationResult {
    /// Returns true if the file is corrupted.
    pub fn is_corrupted(&self) -> bool {
        matches!(self, Self::Corrupted { .. })
    }

    /// Returns true if validation passed (file exists and is valid).
    pub fn is_valid(&self) -> bool {
        matches!(self, Self::Valid)
    }
}

/// Compute SHA256 checksum of a file.
///
/// Returns the checksum as a hex string, or an error if the file cannot be read.
/// @trace spec:cache-recovery-mechanism
pub fn compute_file_checksum(path: &Path) -> Result<FileChecksum, String> {
    let contents =
        fs::read(path).map_err(|e| format!("Failed to read file for checksumming: {}", e))?;

    let mut hasher = Sha256::new();
    hasher.update(&contents);
    let digest = hasher.finalize();

    Ok(format!("{:x}", digest))
}

/// Validate a cache file against its expected checksum.
///
/// @trace spec:cache-recovery-mechanism
pub fn validate_cache_file(
    path: &Path,
    expected_checksum: &FileChecksum,
) -> Result<ValidationResult, String> {
    if !path.exists() {
        return Ok(ValidationResult::Missing);
    }

    let actual = compute_file_checksum(path)?;
    if actual == *expected_checksum {
        Ok(ValidationResult::Valid)
    } else {
        Ok(ValidationResult::Corrupted {
            expected: expected_checksum.clone(),
            actual,
        })
    }
}

/// Cache state with checksums for validation.
///
/// Extends the build state to include checksums of cache files.
/// Used to detect and recover from cache corruption.
/// @trace spec:cache-recovery-mechanism, spec:init-incremental-builds
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CacheStateWithChecksums {
    /// Map of cache file path (relative to cache dir) -> checksum.
    #[serde(default)]
    pub file_checksums: HashMap<String, FileChecksum>,
    /// Map of image name -> build status.
    #[serde(default)]
    pub images: HashMap<String, String>,
    /// Timestamp of when checksums were computed.
    #[serde(default)]
    pub checksum_timestamp: Option<String>,
}

impl CacheStateWithChecksums {
    pub fn new() -> Self {
        Self {
            file_checksums: HashMap::new(),
            images: HashMap::new(),
            checksum_timestamp: None,
        }
    }

    /// Validate all cached files and return validation results.
    ///
    /// Returns a map of file path -> ValidationResult.
    /// @trace spec:cache-recovery-mechanism
    pub fn validate_all_files(
        &self,
        cache_dir: &Path,
    ) -> Result<HashMap<String, ValidationResult>, String> {
        let mut results = HashMap::new();

        for (rel_path, expected_checksum) in &self.file_checksums {
            let full_path = cache_dir.join(rel_path);
            let result = validate_cache_file(&full_path, expected_checksum)?;
            results.insert(rel_path.clone(), result);
        }

        Ok(results)
    }

    /// Check if any files are corrupted.
    ///
    /// @trace spec:cache-recovery-mechanism
    pub fn has_corrupted_files(&self, cache_dir: &Path) -> Result<bool, String> {
        let results = self.validate_all_files(cache_dir)?;
        Ok(results.values().any(|r| r.is_corrupted()))
    }

    /// Get a list of corrupted files.
    ///
    /// @trace spec:cache-recovery-mechanism
    pub fn get_corrupted_files(
        &self,
        cache_dir: &Path,
    ) -> Result<Vec<(String, FileChecksum, FileChecksum)>, String> {
        let results = self.validate_all_files(cache_dir)?;
        let mut corrupted = Vec::new();

        for (rel_path, result) in results {
            if let ValidationResult::Corrupted { expected, actual } = result {
                corrupted.push((rel_path, expected, actual));
            }
        }

        Ok(corrupted)
    }
}

impl Default for CacheStateWithChecksums {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn test_compute_file_checksum() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"hello world").unwrap();
        drop(file);

        let checksum = compute_file_checksum(&file_path).unwrap();

        // Verify it's a valid SHA256 hex string (64 chars)
        assert_eq!(checksum.len(), 64);
        assert!(checksum.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_compute_file_checksum_consistency() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"consistent content").unwrap();
        drop(file);

        let checksum1 = compute_file_checksum(&file_path).unwrap();
        let checksum2 = compute_file_checksum(&file_path).unwrap();

        assert_eq!(checksum1, checksum2);
    }

    #[test]
    fn test_validate_cache_file_valid() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"test content").unwrap();
        drop(file);

        let checksum = compute_file_checksum(&file_path).unwrap();
        let result = validate_cache_file(&file_path, &checksum).unwrap();

        assert_eq!(result, ValidationResult::Valid);
    }

    #[test]
    fn test_validate_cache_file_corrupted() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("test.txt");

        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"original content").unwrap();
        drop(file);

        let original_checksum = compute_file_checksum(&file_path).unwrap();

        // Corrupt the file
        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"corrupted content!").unwrap();
        drop(file);

        let result = validate_cache_file(&file_path, &original_checksum).unwrap();

        assert!(result.is_corrupted());
        if let ValidationResult::Corrupted { expected, actual } = result {
            assert_eq!(expected, original_checksum);
            assert_ne!(actual, original_checksum);
        } else {
            panic!("Expected Corrupted variant");
        }
    }

    #[test]
    fn test_validate_cache_file_missing() {
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("nonexistent.txt");

        let fake_checksum =
            "0000000000000000000000000000000000000000000000000000000000000000".to_string();
        let result = validate_cache_file(&file_path, &fake_checksum).unwrap();

        assert_eq!(result, ValidationResult::Missing);
    }

    #[test]
    fn test_cache_state_with_checksums_validate_all_files() {
        let temp_dir = TempDir::new().unwrap();

        // Create a test file
        let file_path = temp_dir.path().join("init-build-state.json");
        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"{}").unwrap();
        drop(file);

        let checksum = compute_file_checksum(&file_path).unwrap();

        let mut state = CacheStateWithChecksums::new();
        state
            .file_checksums
            .insert("init-build-state.json".to_string(), checksum);

        let results = state.validate_all_files(temp_dir.path()).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results["init-build-state.json"].is_valid());
    }

    #[test]
    fn test_cache_state_detect_corrupted_files() {
        let temp_dir = TempDir::new().unwrap();

        // Create and checksum a file
        let file_path = temp_dir.path().join("data.json");
        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"{\"key\": \"value\"}").unwrap();
        drop(file);

        let original_checksum = compute_file_checksum(&file_path).unwrap();

        let mut state = CacheStateWithChecksums::new();
        state
            .file_checksums
            .insert("data.json".to_string(), original_checksum);

        // Corrupt the file
        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"{\"key\": \"corrupted\"}").unwrap();
        drop(file);

        assert!(state.has_corrupted_files(temp_dir.path()).unwrap());

        let corrupted = state.get_corrupted_files(temp_dir.path()).unwrap();
        assert_eq!(corrupted.len(), 1);
        assert_eq!(corrupted[0].0, "data.json");
    }

    #[test]
    fn test_cache_state_no_corrupted_files() {
        let temp_dir = TempDir::new().unwrap();

        let file_path = temp_dir.path().join("clean.json");
        let mut file = File::create(&file_path).unwrap();
        file.write_all(b"[]").unwrap();
        drop(file);

        let checksum = compute_file_checksum(&file_path).unwrap();

        let mut state = CacheStateWithChecksums::new();
        state
            .file_checksums
            .insert("clean.json".to_string(), checksum);

        assert!(!state.has_corrupted_files(temp_dir.path()).unwrap());
    }

    #[test]
    fn test_validation_result_is_corrupted() {
        let valid = ValidationResult::Valid;
        assert!(!valid.is_corrupted());
        assert!(valid.is_valid());

        let corrupted = ValidationResult::Corrupted {
            expected: "aaa".to_string(),
            actual: "bbb".to_string(),
        };
        assert!(corrupted.is_corrupted());
        assert!(!corrupted.is_valid());

        let missing = ValidationResult::Missing;
        assert!(!missing.is_corrupted());
        assert!(!missing.is_valid());
    }
}
