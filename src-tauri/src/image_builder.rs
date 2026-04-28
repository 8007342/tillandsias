//! Direct podman image builder — replaces bash-based build-image.sh.
//!
//! Handles staleness detection, image routing, and direct podman build invocation
//! on all platforms (Linux, macOS, Windows).
//!
//! @trace spec:direct-podman-calls

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use sha2::{Sha256, Digest};
use tracing::{debug, error, info, warn};

use tillandsias_core::config::cache_dir;
use crate::strings;

/// ImageBuilder coordinates staleness detection and direct podman invocation.
///
/// # Thread Safety
///
/// Synchronous by design — caller is responsible for acquiring the global
/// BUILD_MUTEX before invoking `build_image()`. Rootless podman cannot handle
/// concurrent builds.
///
/// @trace spec:direct-podman-calls
pub struct ImageBuilder {
    /// Source directory containing image sources (flake.nix, images/, etc.)
    source_dir: PathBuf,

    /// Image name: "forge", "proxy", "git", "inference", "router", or "web"
    image_name: String,

    /// Target image tag, e.g., "tillandsias-forge:v0.1.97.83"
    tag: String,
}

impl ImageBuilder {
    /// Create a new ImageBuilder for the given image name and tag.
    ///
    /// @trace spec:direct-podman-calls
    pub fn new(source_dir: PathBuf, image_name: String, tag: String) -> Self {
        Self {
            source_dir,
            image_name,
            tag,
        }
    }

    /// Determine if a rebuild is needed by comparing source hash against cache.
    ///
    /// Returns:
    /// - `Ok(true)` if rebuild is needed
    /// - `Ok(false)` if cached hash matches and image exists
    /// - `Err(e)` if hash computation failed
    ///
    /// @trace spec:direct-podman-calls, spec:forge-staleness
    pub fn needs_rebuild(&self) -> Result<bool, String> {
        let current_hash = self.compute_source_hash()?;
        let cache_hash_path = self.cache_hash_path();

        // If no cached hash, definitely rebuild
        if !cache_hash_path.exists() {
            debug!(
                image = %self.image_name,
                reason = "no cached hash",
                spec = "direct-podman-calls",
                "Staleness check: rebuild needed"
            );
            return Ok(true);
        }

        // Read cached hash
        let cached_hash = std::fs::read_to_string(&cache_hash_path)
            .map_err(|e| {
                warn!(
                    image = %self.image_name,
                    path = %cache_hash_path.display(),
                    error = %e,
                    spec = "direct-podman-calls",
                    "Failed to read cached hash, assuming rebuild needed"
                );
                format!("Cannot read cache: {e}")
            })?;

        // Compare hashes
        if current_hash.trim() == cached_hash.trim() {
            // Hashes match — still verify image exists
            debug!(
                image = %self.image_name,
                spec = "direct-podman-calls",
                "Staleness check: hash match, verifying image exists"
            );
            // Image existence check is done by caller
            return Ok(false);
        }

        // Hashes differ — rebuild
        debug!(
            image = %self.image_name,
            current = %current_hash.trim(),
            cached = %cached_hash.trim(),
            spec = "direct-podman-calls",
            "Staleness check: rebuild needed (hash mismatch)"
        );
        Ok(true)
    }

    /// Compute SHA256 hash of Containerfile + all source files for the image.
    ///
    /// Hash includes:
    /// - The Containerfile for this image
    /// - All flake.nix and flake.lock
    /// - All files in the image's subdirectory
    ///
    /// @trace spec:direct-podman-calls, spec:forge-staleness
    fn compute_source_hash(&self) -> Result<String, String> {
        let (containerfile, context_dir) = self.image_build_paths();

        let mut hasher = Sha256::new();

        // Hash the Containerfile itself
        let containerfile_data = std::fs::read(&containerfile)
            .map_err(|e| {
                error!(
                    image = %self.image_name,
                    path = %containerfile.display(),
                    error = %e,
                    spec = "direct-podman-calls",
                    "Cannot read Containerfile"
                );
                format!("Cannot read Containerfile: {e}")
            })?;
        hasher.update(&containerfile_data);

        // Hash flake.nix and flake.lock if they exist
        for flake_file in &["flake.nix", "flake.lock"] {
            let path = self.source_dir.join(flake_file);
            if path.exists() {
                let data = std::fs::read(&path)
                    .map_err(|e| format!("Cannot read {}: {e}", flake_file))?;
                hasher.update(&data);
            }
        }

        // Hash all files in the image's context directory (recursively)
        self.hash_directory(&mut hasher, &context_dir)?;

        let hash = format!("{:x}", hasher.finalize());
        Ok(hash)
    }

    /// Recursively hash all files in a directory.
    fn hash_directory(&self, hasher: &mut Sha256, dir: &Path) -> Result<(), String> {
        let mut entries = std::fs::read_dir(dir)
            .map_err(|e| format!("Cannot read directory {}: {e}", dir.display()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Error iterating directory: {e}"))?;

        // Sort for deterministic hashing
        entries.sort_by_key(|e| e.path());

        for entry in entries {
            let path = entry.path();
            if path.is_file() {
                let data = std::fs::read(&path)
                    .map_err(|e| format!("Cannot read file {}: {e}", path.display()))?;
                // Include filename in hash for determinism
                hasher.update(path.file_name().unwrap_or_default().to_string_lossy().as_bytes());
                hasher.update(&data);
            } else if path.is_dir() && !path.ends_with(".git") {
                // Skip .git directories
                self.hash_directory(hasher, &path)?;
            }
        }

        Ok(())
    }

    /// Get the (Containerfile, context_dir) paths for this image.
    ///
    /// @trace spec:direct-podman-calls
    fn image_build_paths(&self) -> (PathBuf, PathBuf) {
        let subdir = match self.image_name.as_str() {
            "proxy" => "proxy",
            "git" => "git",
            "inference" => "inference",
            "web" => "web",
            "router" => "router",
            _ => "default", // forge or unknown
        };
        let dir = self.source_dir.join("images").join(subdir);
        (dir.join("Containerfile"), dir)
    }

    /// Get the cache directory path for build hashes.
    fn cache_hash_dir(&self) -> PathBuf {
        cache_dir()
            .join("build-hashes")
    }

    /// Get the cache file path for this image's hash.
    fn cache_hash_path(&self) -> PathBuf {
        self.cache_hash_dir().join(format!("{}.sha256", self.image_name))
    }

    /// Save the current source hash to cache.
    fn save_hash(&self) -> Result<(), String> {
        let hash = self.compute_source_hash()?;
        let cache_dir = self.cache_hash_dir();

        std::fs::create_dir_all(&cache_dir)
            .map_err(|e| format!("Cannot create cache dir: {e}"))?;

        let cache_path = self.cache_hash_path();
        std::fs::write(&cache_path, format!("{}\n", hash))
            .map_err(|e| {
                error!(
                    image = %self.image_name,
                    path = %cache_path.display(),
                    error = %e,
                    spec = "direct-podman-calls",
                    "Failed to write hash cache"
                );
                format!("Cannot write cache: {e}")
            })?;

        Ok(())
    }

    /// Build the image directly via podman.
    ///
    /// Invokes `podman build --tag <tag> -f <Containerfile> <context>` with
    /// proper error handling and verification.
    ///
    /// Returns `Ok(())` on success, `Err(String)` on failure.
    ///
    /// Inherits stdio so users see build progress in real-time.
    /// @trace spec:direct-podman-calls, spec:default-image
    pub fn build_image(&self) -> Result<(), String> {
        let (containerfile, context_dir) = self.image_build_paths();

        info!(
            image = %self.image_name,
            tag = %self.tag,
            containerfile = %containerfile.display(),
            context = %context_dir.display(),
            spec = "direct-podman-calls",
            "Starting direct podman build"
        );

        // Build the podman command, inheriting stdio so users see progress
        let status = Command::new(tillandsias_podman::find_podman_path())
            .args(&["build", "--tag", &self.tag])
            .arg("-f")
            .arg(&containerfile)
            .args(&["--security-opt", "label=disable"]) // SELinux compat
            .arg(&context_dir)
            .env_remove("LD_LIBRARY_PATH")
            .env_remove("LD_PRELOAD")
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .map_err(|e| {
                error!(
                    image = %self.image_name,
                    error = %e,
                    spec = "direct-podman-calls",
                    "Failed to launch podman build"
                );
                strings::SETUP_ERROR.to_string()
            })?;

        // Check exit status
        if !status.success() {
            error!(
                image = %self.image_name,
                tag = %self.tag,
                exit_code = status.code().unwrap_or(-1),
                spec = "direct-podman-calls",
                "podman build failed"
            );
            return Err(strings::SETUP_ERROR.into());
        }

        info!(
            image = %self.image_name,
            tag = %self.tag,
            spec = "direct-podman-calls",
            "podman build completed successfully"
        );

        // Save the hash for next time
        self.save_hash()?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_image_build_paths_routing() {
        let source_dir = PathBuf::from("/tmp/sources");

        let tests = vec![
            ("forge", "default"),
            ("proxy", "proxy"),
            ("git", "git"),
            ("inference", "inference"),
            ("web", "web"),
            ("router", "router"),
            ("unknown", "default"),
        ];

        for (image_name, expected_subdir) in tests {
            let builder = ImageBuilder::new(
                source_dir.clone(),
                image_name.to_string(),
                "test:tag".to_string(),
            );
            let (containerfile, context_dir) = builder.image_build_paths();

            assert!(containerfile.ends_with(&format!("images/{}/Containerfile", expected_subdir)));
            assert!(context_dir.ends_with(&format!("images/{}", expected_subdir)));
        }
    }

    #[test]
    fn test_staleness_detection_missing_cache() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TempDir::new()?;
        let source_dir = temp.path().to_path_buf();

        // Create minimal Containerfile
        let images_dir = source_dir.join("images").join("default");
        fs::create_dir_all(&images_dir)?;
        fs::write(images_dir.join("Containerfile"), "FROM scratch\n")?;

        let builder = ImageBuilder::new(
            source_dir,
            "forge".to_string(),
            "test:tag".to_string(),
        );

        // No cached hash should trigger rebuild
        assert!(builder.needs_rebuild()?);

        Ok(())
    }

    #[test]
    fn test_hash_consistency() -> Result<(), Box<dyn std::error::Error>> {
        let temp = TempDir::new()?;
        let source_dir = temp.path().to_path_buf();

        // Create test files
        let images_dir = source_dir.join("images").join("default");
        fs::create_dir_all(&images_dir)?;
        fs::write(images_dir.join("Containerfile"), "FROM scratch\n")?;

        let builder = ImageBuilder::new(
            source_dir,
            "forge".to_string(),
            "test:tag".to_string(),
        );

        let hash1 = builder.compute_source_hash()?;
        let hash2 = builder.compute_source_hash()?;

        // Same inputs should produce same hash
        assert_eq!(hash1, hash2);

        Ok(())
    }
}
