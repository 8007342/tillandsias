// @trace spec:runtime-logging, spec:external-logs-layer
use std::path::{Path, PathBuf};
use tokio::fs;

/// Rotation policy: 7-day TTL, 10MB per file
#[derive(Debug, Clone)]
pub struct RotationPolicy {
    /// Maximum file size before rotation (bytes)
    pub max_size: u64,

    /// File age limit (seconds)
    pub max_age_secs: u64,
}

impl Default for RotationPolicy {
    fn default() -> Self {
        Self {
            max_size: 10 * 1024 * 1024,    // 10MB
            max_age_secs: 7 * 24 * 60 * 60, // 7 days
        }
    }
}

impl RotationPolicy {
    /// Check if file needs rotation based on size
    pub async fn should_rotate_by_size(&self, path: &Path) -> bool {
        if !path.exists() {
            return false;
        }

        match fs::metadata(path).await {
            Ok(metadata) => metadata.len() >= self.max_size,
            Err(_) => false,
        }
    }

    /// Check if file needs rotation based on age
    pub async fn should_rotate_by_age(&self, path: &Path) -> bool {
        if !path.exists() {
            return false;
        }

        match fs::metadata(path).await {
            Ok(metadata) => {
                if let Ok(modified) = metadata.modified() {
                    if let Ok(elapsed) = modified.elapsed() {
                        return elapsed.as_secs() >= self.max_age_secs;
                    }
                }
                false
            }
            Err(_) => false,
        }
    }

    /// Check if file should be rotated
    pub async fn should_rotate(&self, path: &Path) -> bool {
        self.should_rotate_by_size(path).await || self.should_rotate_by_age(path).await
    }

    /// Rotate log file in place (keep newest 50% of content)
    ///
    /// Reads the entire file, keeps the newest half by byte count,
    /// and truncates. No `.1` `.2` rotation files created.
    pub async fn rotate_in_place(&self, path: &Path) -> crate::Result<()> {
        if !path.exists() {
            return Ok(());
        }

        let content = fs::read_to_string(path)
            .await
            .map_err(|e| crate::LoggingError::RotationError(e.to_string()))?;

        let bytes = content.as_bytes();
        let mid_point = bytes.len() / 2;
        let truncated = &content[mid_point..];

        fs::write(path, truncated)
            .await
            .map_err(|e| crate::LoggingError::RotationError(e.to_string()))?;

        Ok(())
    }

    /// Clean up expired log files matching a pattern
    pub async fn cleanup_expired(&self, dir: &Path, pattern: &str) -> crate::Result<Vec<PathBuf>> {
        if !dir.exists() {
            return Ok(Vec::new());
        }

        let mut removed = Vec::new();
        let mut entries = fs::read_dir(dir)
            .await
            .map_err(|e| crate::LoggingError::RotationError(e.to_string()))?;

        while let Some(entry) = entries
            .next_entry()
            .await
            .map_err(|e| crate::LoggingError::RotationError(e.to_string()))?
        {
            let path = entry.path();
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if !name.contains(pattern) {
                    continue;
                }

                if self.should_rotate_by_age(&path).await {
                    if let Err(e) = fs::remove_file(&path).await {
                        eprintln!("failed to remove expired log {}: {}", path.display(), e);
                    } else {
                        removed.push(path);
                    }
                }
            }
        }

        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_rotation_policy_default() {
        let policy = RotationPolicy::default();
        assert_eq!(policy.max_size, 10 * 1024 * 1024);
        assert_eq!(policy.max_age_secs, 7 * 24 * 60 * 60);
    }

    #[tokio::test]
    async fn test_rotate_in_place() {
        let dir = tempdir().unwrap();
        let log_file = dir.path().join("test.log");

        let content = "a".repeat(1000);
        fs::write(&log_file, &content).await.unwrap();

        let policy = RotationPolicy::default();
        policy.rotate_in_place(&log_file).await.unwrap();

        let rotated = fs::read_to_string(&log_file).await.unwrap();
        assert!(rotated.len() < 1000);
        assert!(rotated.len() >= 400); // roughly half
    }

    #[tokio::test]
    async fn test_should_rotate_by_size() {
        let dir = tempdir().unwrap();
        let log_file = dir.path().join("test.log");

        let mut policy = RotationPolicy::default();
        policy.max_size = 100;

        // Small file
        fs::write(&log_file, "small").await.unwrap();
        assert!(!policy.should_rotate_by_size(&log_file).await);

        // Large file
        fs::write(&log_file, "x".repeat(200)).await.unwrap();
        assert!(policy.should_rotate_by_size(&log_file).await);
    }
}
